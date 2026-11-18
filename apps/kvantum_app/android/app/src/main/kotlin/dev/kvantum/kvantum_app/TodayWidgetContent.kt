package dev.kvantum.kvantum_app

import org.json.JSONObject
import java.util.Locale
import java.util.TimeZone

/**
 * What the home-screen widget shows, worked out from the snapshot the app wrote
 * (lib/widget/widget_data.dart). Pure logic and no views, so that it can be
 * tried on a plain JVM; TodayWidgetProvider only puts the result on the screen.
 *
 * The snapshot, as the app writes it:
 *
 *     {"v":1,"tz":"Europe/Budapest",
 *      "days":[{"from":ms,"to":ms,"label":"hétfő, nov. 16.",
 *               "special":"Munkaszüneti nap: Újév" or null,
 *               "lines":["08:00 Műszak","Feladat: ..."]}, ...],
 *      "shifts":[{"at":ms,"text":"kedd, nov. 17. 18:00 Éjszakai műszak"}, ...]}
 *
 * A day lasts from "from" (inclusive) to "to" (exclusive), in epoch
 * milliseconds. The widget shows the day that holds the moment it is drawn, so
 * it moves on by itself when the app is not opened for a few days.
 */
data class TodayWidgetView(
    /** "Ma · hétfő, nov. 16.", or the name of the app when there is nothing to show. */
    val title: String,
    /** A holiday or a moved working day. */
    val special: String?,
    /** The events and tasks of the day, one per line, at most [TodayWidgetContent.MAX_LINES]. */
    val lines: List<String>,
    /** A short remark: a free day, or the request to open the app. */
    val note: String?,
    /** "Következő műszak: ...". */
    val shift: String?,
    /** True when the snapshot has no day for now (missing, unreadable, too old). */
    val needsApp: Boolean,
    /** When what is shown goes out of date (epoch ms): the day ends or the next shift begins. */
    val changesAt: Long?,
    /** The zone the app drew the days in. */
    val zoneId: String,
)

object TodayWidgetContent {
    const val MAX_LINES = 7
    const val DEFAULT_ZONE = "Europe/Budapest"
    const val APP_NAME = "Kvantum Naptár"
    const val OPEN_APP = "Koppints ide: megnyitja az appot, és feltölti a widgetet."
    const val FREE_DAY = "Nincs program."

    private const val DAY_MS = 24L * 60 * 60 * 1000

    /** What to draw at [nowMs] for the text the app wrote ([snapshot], null when none). */
    fun view(snapshot: String?, nowMs: Long): TodayWidgetView {
        val none = TodayWidgetView(
            title = APP_NAME,
            special = null,
            lines = emptyList(),
            note = OPEN_APP,
            shift = null,
            needsApp = true,
            changesAt = null,
            zoneId = DEFAULT_ZONE,
        )
        if (snapshot.isNullOrEmpty()) return none
        try {
            val root = JSONObject(snapshot)
            if (root.optInt("v", 0) != 1) return none
            val zone = if (root.isNull("tz")) DEFAULT_ZONE else root.optString("tz", DEFAULT_ZONE)
            val days = root.optJSONArray("days") ?: return none.copy(zoneId = zone)

            var today: JSONObject? = null
            for (i in 0 until days.length()) {
                val d = days.optJSONObject(i) ?: continue
                val from = d.optLong("from", Long.MAX_VALUE)
                val to = d.optLong("to", Long.MIN_VALUE)
                if (nowMs >= from && nowMs < to) {
                    today = d
                    break
                }
            }
            if (today == null) return none.copy(zoneId = zone)

            val all = ArrayList<String>()
            val raw = today.optJSONArray("lines")
            if (raw != null) {
                for (i in 0 until raw.length()) {
                    val line = raw.opt(i) as? String
                    if (!line.isNullOrBlank()) all.add(line)
                }
            }
            val lines = if (all.size > MAX_LINES) {
                // one line says how many are left out
                all.subList(0, MAX_LINES - 1) + "+${all.size - (MAX_LINES - 1)} további"
            } else {
                all
            }

            val special = if (today.isNull("special")) null else today.optString("special", "")
                .takeIf { it.isNotBlank() }

            // the first shift that has not begun
            var shift: String? = null
            var shiftAt: Long? = null
            val shifts = root.optJSONArray("shifts")
            if (shifts != null) {
                for (i in 0 until shifts.length()) {
                    val s = shifts.optJSONObject(i) ?: continue
                    val at = s.optLong("at", Long.MIN_VALUE)
                    val text = if (s.isNull("text")) "" else s.optString("text", "")
                    if (at > nowMs && text.isNotBlank()) {
                        shift = "Következő műszak: $text"
                        shiftAt = at
                        break
                    }
                }
            }

            val dayEnd = today.optLong("to", Long.MAX_VALUE)
            val changesAt = if (shiftAt != null && shiftAt < dayEnd) shiftAt else dayEnd
            val label = if (today.isNull("label")) "" else today.optString("label", "")
            return TodayWidgetView(
                title = if (label.isBlank()) "Ma" else "Ma · $label",
                special = special,
                lines = lines,
                note = if (lines.isEmpty()) FREE_DAY else null,
                shift = shift,
                needsApp = false,
                changesAt = changesAt,
                zoneId = zone,
            )
        } catch (e: Exception) {
            // a damaged or foreign text: the widget asks for the app, never crashes
            return none
        }
    }

    /** "Frissítve: 08:12", "Frissítve: tegnap 21:40" or "Frissítve: 3 napja". */
    fun updatedText(writtenAt: Long, nowMs: Long, zoneId: String): String {
        if (writtenAt <= 0L) return ""
        val zone = zoneOf(zoneId)
        val written = writtenAt + zone.getOffset(writtenAt)
        val now = nowMs + zone.getOffset(nowMs)
        val minutes = (written % DAY_MS) / 60_000
        val clock = String.format(Locale.ROOT, "%02d:%02d", minutes / 60, minutes % 60)
        val days = now / DAY_MS - written / DAY_MS
        return when {
            days <= 0L -> "Frissítve: $clock"
            days == 1L -> "Frissítve: tegnap $clock"
            else -> "Frissítve: $days napja"
        }
    }

    private fun zoneOf(id: String): TimeZone {
        val zone = TimeZone.getTimeZone(id)
        // an unknown name comes back as GMT: use the app's own zone instead
        return if (zone.id == "GMT" && id != "GMT") TimeZone.getTimeZone(DEFAULT_ZONE) else zone
    }
}
