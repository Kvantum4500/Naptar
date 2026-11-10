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
