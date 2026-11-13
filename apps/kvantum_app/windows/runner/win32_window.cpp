#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// The smallest window the calendar can be used in (logical pixels; scaled by
// the screen the window is on).
constexpr int kMinWindowWidth = 480;
constexpr int kMinWindowHeight = 640;

// Where the window's place is kept between runs (current user only).
constexpr const wchar_t kPlacementRegKey[] = L"Software\\KvantumNaptar";
constexpr const wchar_t kPlacementRegValue[] = L"WindowState";

// What is kept of the window between runs: where it is when it is not
// maximised (screen coordinates), and whether it was maximised.
struct SavedWindow {
  RECT rect;
  DWORD maximized;
};

// The part of a screen a window can use (the screen without the taskbar).
bool WorkAreaOf(HMONITOR monitor, RECT* work) {
  MONITORINFO info = {};
  info.cbSize = static_cast<DWORD>(sizeof(info));
  if (!GetMonitorInfo(monitor, &info)) {
    return false;
  }
  *work = info.rcWork;
  return true;
}

// The smallest size the calendar can be used at on [monitor]: the minimum
// scaled to its resolution, but never more than the screen can show.
void MinWindowSize(HMONITOR monitor, LONG* width, LONG* height) {
  const double scale_factor = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  *width = Scale(kMinWindowWidth, scale_factor);
  *height = Scale(kMinWindowHeight, scale_factor);
  RECT work = {};
  if (WorkAreaOf(monitor, &work)) {
    if (*width > work.right - work.left) {
      *width = work.right - work.left;
    }
    if (*height > work.bottom - work.top) {
      *height = work.bottom - work.top;
    }
  }
}

// Moves and trims [rect] so that it lies inside the work area of the screen
// nearest to it, and is not smaller than the minimum: a screen may have been
// unplugged or changed since the last run.
void FitToScreen(RECT* rect) {
  HMONITOR monitor = MonitorFromRect(rect, MONITOR_DEFAULTTONEAREST);
  RECT work = {};
  if (!WorkAreaOf(monitor, &work)) {
    return;
  }
  LONG min_width = 0;
  LONG min_height = 0;
  MinWindowSize(monitor, &min_width, &min_height);
  LONG width = rect->right - rect->left;
  LONG height = rect->bottom - rect->top;
  if (width < min_width) {
    width = min_width;
  }
  if (height < min_height) {
    height = min_height;
  }
  if (width > work.right - work.left) {
    width = work.right - work.left;
  }
  if (height > work.bottom - work.top) {
    height = work.bottom - work.top;
  }
  LONG left = rect->left;
  LONG top = rect->top;
  if (left + width > work.right) {
    left = work.right - width;
  }
  if (top + height > work.bottom) {
    top = work.bottom - height;
  }
  if (left < work.left) {
    left = work.left;
  }
  if (top < work.top) {
    top = work.top;
  }
  rect->left = left;
  rect->top = top;
  rect->right = left + width;
  rect->bottom = top + height;
}

// Reads what was kept when the window was last closed. Returns false when
// there is nothing, or it is damaged.
bool LoadSavedWindow(SavedWindow* saved) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kPlacementRegKey, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  SavedWindow value = {};
  DWORD type = 0;
  DWORD size = static_cast<DWORD>(sizeof(value));
  const LONG result =
      RegQueryValueExW(key, kPlacementRegValue, nullptr, &type,
                       reinterpret_cast<LPBYTE>(&value), &size);
  RegCloseKey(key);
  if (result != ERROR_SUCCESS || type != REG_BINARY ||
      size != static_cast<DWORD>(sizeof(value))) {
    return false;
  }
  if (value.rect.right <= value.rect.left ||
      value.rect.bottom <= value.rect.top) {
    return false;
  }
  *saved = value;
  return true;
}

// Keeps the window's place (and whether it is maximised) for the next run.
void SaveWindow(const RECT& normal_rect, bool maximized) {
  SavedWindow saved = {};
  saved.rect = normal_rect;
  saved.maximized = maximized ? 1 : 0;
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kPlacementRegKey, 0, nullptr, 0,
                      KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  RegSetValueExW(key, kPlacementRegValue, 0, REG_BINARY,
                 reinterpret_cast<const BYTE*>(&saved),
                 static_cast<DWORD>(sizeof(saved)));
  RegCloseKey(key);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // The place it had when it was last closed. Set here, while the window is
  // still hidden and before the view is created, so that the first frame has
  // the right size. A maximised window is shown maximised by Show(); the size
  // set here is the one it returns to.
  SavedWindow saved = {};
  if (LoadSavedWindow(&saved)) {
    RECT rect = saved.rect;
    FitToScreen(&rect);
    SetWindowPos(window, nullptr, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
    maximize_on_show_ = saved.maximized != 0;
  }
  GetWindowRect(window, &normal_rect_);

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  if (start_minimized_) {
    // Only the first time: later calls show the window as usual.
    start_minimized_ = false;
    // The window sits in the taskbar and takes no focus. It is placed (not
    // just shown) so that restoring it from there brings back the size or the
    // maximised state it had when it was last closed.
    WINDOWPLACEMENT placement = {};
    placement.length = static_cast<UINT>(sizeof(placement));
    if (GetWindowPlacement(window_handle_, &placement)) {
      placement.showCmd = SW_SHOWMINNOACTIVE;
      if (maximize_on_show_) {
        placement.flags |= WPF_RESTORETOMAXIMIZED;
      }
      return SetWindowPlacement(window_handle_, &placement) != FALSE;
    }
    return ShowWindow(window_handle_, SW_SHOWMINNOACTIVE) != FALSE;
  }
  return ShowWindow(window_handle_,
                    maximize_on_show_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
}

void Win32Window::SetStartMinimized(bool start_minimized) {
  start_minimized_ = start_minimized;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_GETMINMAXINFO: {
      // No smaller than the calendar can be used at (scaled by the screen,
      // and never more than the screen can show).
      LONG min_width = 0;
      LONG min_height = 0;
      MinWindowSize(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                    &min_width, &min_height);
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = min_width;
      info->ptMinTrackSize.y = min_height;
      return 0;
    }

    case WM_MOVE:
      // follow the window while it is neither maximised nor minimised
      if (!IsZoomed(hwnd) && !IsIconic(hwnd)) {
        GetWindowRect(hwnd, &normal_rect_);
      }
      break;

    case WM_CLOSE:
      // remember where the window was; the default handling closes it
      SaveWindow(normal_rect_, IsZoomed(hwnd) != FALSE);
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      if (!IsZoomed(hwnd) && !IsIconic(hwnd)) {
        GetWindowRect(hwnd, &normal_rect_);
      }
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
