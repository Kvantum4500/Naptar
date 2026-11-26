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
 *
 * Handing the queue out is a two-step affair ([drain], then [ack]) so that a
 * crash while the app books the payments loses nothing. Text that nobody picked
 * up for [MAX_AGE_MS] is thrown away, so raw notification text cannot linger.
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
                .put("title", mask(title).take(200))
                .put("text", mask(text).take(500))
                .put("time", n.postTime)
        )
    }

    companion object {
        /** Wallet packages that are read. Everything else is ignored. */
        val ALLOWED = setOf("com.google.android.apps.walletnfcrel")

        private const val PREFS = "wallet_queue"
        private const val KEY = "items"

        /** Handed out by [drain], waiting for [ack]. */
        private const val INFLIGHT = "inflight"
        private const val MAX = 200
        private const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000
        private val lock = Any()

        /**
         * 11 or more digits (single separators allowed) are a card, account or
         * phone number, never a forint amount: they are not stored at all.
         */
        private val LONG_DIGITS = Regex("""\d(?:[ \-.]?\d){10,}""")

        fun mask(s: String): String = s.replace(LONG_DIGITS, "••••")

        private fun read(context: Context, key: String): JSONArray {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return try {
                JSONArray(prefs.getString(key, "[]"))
            } catch (e: Exception) {
                JSONArray()
            }
        }

        private fun same(a: JSONObject, b: JSONObject): Boolean =
            a.optLong("time") == b.optLong("time") &&
                a.optString("title") == b.optString("title") &&
                a.optString("text") == b.optString("text")

        private fun contains(list: JSONArray, item: JSONObject): Boolean {
            for (i in 0 until list.length()) {
                val o = list.optJSONObject(i) ?: continue
                if (same(o, item)) return true
            }
            return false
        }

        fun enqueue(context: Context, item: JSONObject) {
            synchronized(lock) {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val list = read(context, KEY)
                // the same notification can be posted twice (updates): skip exact repeats
                if (contains(list, item)) return
                list.put(item)
                // keep the newest MAX, and nothing older than MAX_AGE_MS
                val cutoff = System.currentTimeMillis() - MAX_AGE_MS
                val kept = ArrayList<JSONObject>()
                for (i in 0 until list.length()) {
                    val o = list.optJSONObject(i) ?: continue
                    if (o.optLong("time") >= cutoff) kept.add(o)
                }
                val from = maxOf(0, kept.size - MAX)
                val trimmed = JSONArray()
                for (i in from until kept.size) trimmed.put(kept[i])
                prefs.edit().putString(KEY, trimmed.toString()).apply()
            }
        }

        /**
         * Returns everything queued so far as JSON text. It is NOT forgotten
         * yet: it stays until [ack], so a crash in between loses nothing (the
         * app books idempotently, so seeing an item twice is harmless).
         */
        fun drain(context: Context): String {
            synchronized(lock) {
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val cutoff = System.currentTimeMillis() - MAX_AGE_MS
                val merged = JSONArray()
                for (key in arrayOf(INFLIGHT, KEY)) {
                    val part = read(context, key)
                    for (i in 0 until part.length()) {
                        val o = part.optJSONObject(i) ?: continue
                        if (o.optLong("time") < cutoff) continue
                        if (!contains(merged, o)) merged.put(o)
                    }
                }
                prefs.edit().putString(INFLIGHT, merged.toString()).remove(KEY).apply()
                return merged.toString()
            }
        }

        /** What [drain] returned has been booked: forget it. */
        fun ack(context: Context) {
            synchronized(lock) {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().remove(INFLIGHT).apply()
            }
        }

        /** Throws everything away (the feature is switched off). */
        fun clear(context: Context) {
            synchronized(lock) {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().remove(KEY).remove(INFLIGHT).apply()
            }
        }
    }
}
