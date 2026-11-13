package dev.kvantum.kvantum_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews

/**
 * The home-screen widget: today's events and tasks, the holiday, the next
 * shift. It draws the text the app last wrote (TodayWidgetStore); it asks the
 * app for nothing and runs no Dart. It is drawn again
 *
 *  - when the app hands over a new text (refreshAll),
 *  - when the day ends or the next shift begins (an inexact alarm that does not
 *    wake the device: the screen is right by the time anyone looks), and
 *  - once an hour at the latest, by the platform (updatePeriodMillis).
 */
class TodayWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        draw(context, manager, appWidgetIds)
    }

    // (the widget was resized: the same text, more or fewer lines fit)
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        draw(context, manager, intArrayOf(appWidgetId))
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_TICK) {
            refreshAll(context)
        } else {
            super.onReceive(context, intent)
        }
    }

    // The last widget is gone: its text goes with it (the app then has nothing
    // to prepare either, see WidgetBridge.isPlaced), and so does the alarm.
    override fun onDisabled(context: Context) {
        TodayWidgetStore.clear(context)
        cancelTick(context)
        super.onDisabled(context)
    }

    companion object {
        /** Sent by our own alarm to this receiver only (it is not exported). */
        const val ACTION_TICK = "dev.kvantum.kvantum_app.WIDGET_TICK"

        /** A little after the moment itself, so that the new day has surely begun. */
        private const val TICK_SLACK_MS = 5_000L

        private val LINE_IDS = intArrayOf(
            R.id.widget_line_0,
            R.id.widget_line_1,
            R.id.widget_line_2,
            R.id.widget_line_3,
            R.id.widget_line_4,
            R.id.widget_line_5,
            R.id.widget_line_6,
        )

        private fun component(context: Context) =
            ComponentName(context, TodayWidgetProvider::class.java)

        /** Whether the user has put the widget on a home screen. */
        fun hasWidgets(context: Context): Boolean =
            AppWidgetManager.getInstance(context).getAppWidgetIds(component(context)).isNotEmpty()

        /** Draws every widget again from the stored text. */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(component(context))
            if (ids.isEmpty()) {
                cancelTick(context)
                return
            }
            draw(context, manager, ids)
        }

        private fun draw(context: Context, manager: AppWidgetManager, ids: IntArray) {
            if (ids.isEmpty()) return
            val now = System.currentTimeMillis()
            val saved = TodayWidgetStore.read(context)
            val view = TodayWidgetContent.view(saved.text, now)

            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.widget_title, view.title)
            show(views, R.id.widget_special, view.special)
            for (i in LINE_IDS.indices) show(views, LINE_IDS[i], view.lines.getOrNull(i))
            show(views, R.id.widget_note, view.note)
            show(views, R.id.widget_shift, view.shift)
            show(
                views,
                R.id.widget_updated,
                TodayWidgetContent.updatedText(saved.writtenAt, now, view.zoneId).ifEmpty { null },
            )

            // a tap anywhere opens the app
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                val open = PendingIntent.getActivity(
                    context,
                    0,
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(R.id.widget_root, open)
            }

            manager.updateAppWidget(ids, views)
            scheduleTick(context, view.changesAt, now)
        }

        private fun show(views: RemoteViews, id: Int, text: String?) {
            if (text.isNullOrEmpty()) {
                views.setViewVisibility(id, View.GONE)
            } else {
                views.setTextViewText(id, text)
                views.setViewVisibility(id, View.VISIBLE)
            }
        }

        private fun tickIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                1,
                Intent(context, TodayWidgetProvider::class.java).setAction(ACTION_TICK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        // Inexact and not waking the device (RTC, not RTC_WAKEUP): no special
        // permission is needed, and nothing runs while the phone sleeps.
        private fun scheduleTick(context: Context, changesAt: Long?, now: Long) {
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val pending = tickIntent(context)
            if (changesAt == null || changesAt <= now) {
                alarms.cancel(pending)
                return
            }
            alarms.set(AlarmManager.RTC, changesAt + TICK_SLACK_MS, pending)
        }

        private fun cancelTick(context: Context) {
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            alarms.cancel(tickIntent(context))
        }
    }
}
