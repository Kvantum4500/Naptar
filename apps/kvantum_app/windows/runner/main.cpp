#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Marks a running copy of the app. "Local\" = per login session.
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\KvantumNaptar.SingleInstance";

// The window class and title the runner creates (win32_window.cpp, below).
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"kvantum_app";

// What Windows passes when it starts the app at sign-in (the entry the app
// writes in the user's startup list): the window then sits in the taskbar.
constexpr char kMinimizedFlag[] = "--minimized";

bool HasArgument(const std::vector<std::string>& arguments,
                 const std::string& wanted) {
  for (const std::string& argument : arguments) {
    if (argument == wanted) {
      return true;
    }
  }
  return false;
}

// Brings the window of the copy that is already running to the front.
void BringRunningInstanceToFront() {
  HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
  if (existing == nullptr) {
    return;
  }
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  }
  ::SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_minimized =
      HasArgument(command_line_arguments, kMinimizedFlag);

  // One copy at a time: a second one would open the same database and the
  // same sync state. The self-update starts the new copy before the old one
  // has quite left, so a newcomer waits a little for the owner of the mutex
  // before it decides that another copy is really running. The handle stays
  // open (and owned) until the process ends. If the mutex cannot be created
  // the app simply starts, as it always did.
  HANDLE single_instance = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
  if (single_instance != nullptr) {
    if (::WaitForSingleObject(single_instance, 3000) == WAIT_TIMEOUT) {
      // A copy started by Windows at sign-in has nothing to show to the
      // user; only someone who started the app wants to see its window.
      if (!start_minimized) {
        BringRunningInstanceToFront();
      }
      ::CloseHandle(single_instance);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartMinimized(start_minimized);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"kvantum_app", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
