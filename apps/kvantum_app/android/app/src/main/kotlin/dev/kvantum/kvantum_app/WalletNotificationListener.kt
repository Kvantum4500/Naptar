package dev.kvantum.kvantum_app

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Collects payment notifications of the Google Wallet app (and nothing else)
 * into a small local queue. The Flutter side drains the queue when the app is
 * open, so nothing is lost while it is closed. Only title, text and the time
 * are kept; the queue never leaves the device by itself.
 */
class WalletNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        if (!ALLOWED.contains(n.packageName)) return
        val extras = n.notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        enqueue(
            applicationContext,
            JSONObject()
                .put("pkg", n.packageName)
                .put("title", title.take(200))
                .put("text", text.take(500))
                .put("time", n.postTime)
        )
    }

    companion object {
        /** Wallet packages that are read. Everything else is ignored. */
        val ALLOWED = setOf("com.google.android.apps.walletnfcrel")

        private const val PREFS = "wallet_queue"
        private const val KEY = "items"
        private const val MAX = 200
        private val lock = Any()

        fun enqueue(context: Context, item: JSONObject) {
            synchronized(lock) {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val list = try {
                    JSONArray(prefs.getString(KEY, "[]"))
                } catch (e: Exception) {
                    JSONArray()
                }
                // the same notification can be posted twice (updates): skip exact repeats
                for (i in 0 until list.length()) {
                    val o = list.optJSONObject(i) ?: continue
                    if (o.optLong("time") == item.optLong("time") &&
                        o.optString("title") == item.optString("title") &&
                        o.optString("text") == item.optString("text")
                    ) return
                }
                list.put(item)
                // keep the newest MAX
                val trimmed = JSONArray()
                val from = maxOf(0, list.length() - MAX)
                for (i in from until list.length()) trimmed.put(list.get(i))
                prefs.edit().putString(KEY, trimmed.toString()).apply()
            }
        }

        /** Returns the queued notifications as JSON text and empties the queue. */
        fun drain(context: Context): String {
            synchronized(lock) {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val s = prefs.getString(KEY, "[]") ?: "[]"
                prefs.edit().remove(KEY).apply()
                return s
            }
        }
    }
}
