package dev.kvantum.kvantum_app

import android.content.Context

/**
 * The text of the home-screen widget, in the app's private preferences: written
 * by the app (through the "kvantum/widget" channel), read by the widget. It
 * lives as long as there is a widget on a home screen (see
 * TodayWidgetProvider.onDisabled).
 */
object TodayWidgetStore {
    /** A day's worth of text is a few kilobytes; more than this is not ours. */
    const val MAX_SNAPSHOT = 64 * 1024

    private const val PREFS = "today_widget"
    private const val KEY_SNAPSHOT = "snapshot"
    private const val KEY_WRITTEN = "written_at"

    class Saved(val text: String?, val writtenAt: Long)

    fun read(context: Context): Saved {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Saved(prefs.getString(KEY_SNAPSHOT, null), prefs.getLong(KEY_WRITTEN, 0L))
    }

    fun write(context: Context, snapshot: String, nowMs: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_SNAPSHOT, snapshot)
            .putLong(KEY_WRITTEN, nowMs)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
