package dev.kvantum.kvantum_app

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kvantum/wallet")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isEnabled" -> result.success(listenerEnabled())
                    "drain" -> result.success(WalletNotificationListener.drain(applicationContext))
                    "ack" -> {
                        WalletNotificationListener.ack(applicationContext)
                        result.success(null)
                    }
                    "clear" -> {
                        WalletNotificationListener.clear(applicationContext)
                        result.success(null)
                    }
                    "openListenerSettings" -> {
                        openSettings(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }
                    "openAppInfo" -> {
                        openSettings(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        configureWidgetChannel(flutterEngine)
    }

    private fun configureWidgetChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kvantum/widget")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Is the widget on a home screen? (The app prepares nothing if not.)
                    "isPlaced" -> result.success(TodayWidgetProvider.hasWidgets(applicationContext))
                    // The text for the widget; it is drawn at once. The answer says
                    // whether there was a widget to take it.
                    "update" -> {
                        val snapshot = call.arguments as? String
                        if (snapshot == null || snapshot.length > TodayWidgetStore.MAX_SNAPSHOT) {
                            result.error("bad_args", "snapshot", null)
                        } else if (!TodayWidgetProvider.hasWidgets(applicationContext)) {
                            // (taken off meanwhile: nothing is kept for it)
                            result.success(false)
                        } else {
                            TodayWidgetStore.write(applicationContext, snapshot, System.currentTimeMillis())
                            TodayWidgetProvider.refreshAll(applicationContext)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun listenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?: return false
        return flat.split(":").any { it.startsWith("$packageName/") }
    }

    private fun openSettings(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }
}
