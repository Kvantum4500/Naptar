# Calendar samples (.ics)

These files are written **by hand**, after the files that Apple Calendar,
Outlook (Windows) and Google Calendar produce: the same structure and property
order, the zone names each of them uses, the escaping and the 75-octet line
folding, the CRLF line ends (and a byte order mark in the Outlook one).

They are **not exports of real calendars.** What a real export holds can differ
from what is imitated here, so a real file is still the better test. If you have
one that the app reads wrongly, take out what is private (titles, places, notes
– the structure is what matters) and add it here with a test next to it.

| File | Imitates | What is in it |
|---|---|---|
| `apple_calendar.ics` | Apple Calendar (macOS) | `VTIMEZONE` for `Europe/Budapest`, `X-WR-TIMEZONE`, `X-APPLE-*`, `VALARM`, a weekly series with an `EXDATE` list and a UTC `UNTIL`, a moved occurrence (`RECURRENCE-ID`), an all-day event of several days, a yearly all-day event, a night shift over the end of summer time |
| `outlook_windows_tz.ics` | Outlook for Windows | BOM, Windows zone names (`W. Europe Standard Time`, `Pacific Standard Time`, `GMT Standard Time`) in quoted `TZID`s, `X-MICROSOFT-CDO-*`, `SUMMARY;LANGUAGE=hu`, `WKST=SU`, folded long UIDs, a cancelled meeting and a cancelled occurrence (`STATUS:CANCELLED`), an `EXDATE;VALUE=DATE`, an end time in another zone than the start |
| `google_export.ics` | Google Calendar (export) | times in UTC (`Z`) and with `TZID`, escaped text (`\n`, `\,`, `\;`, `\\`) and a folded line, `WKST=SU;INTERVAL=2`, `2MO` / `-1FR`, `RDATE`, a moved occurrence whose series is not in the file, a series fixed in UTC |

The Google API samples for the app are in `apps/kvantum_app/test/fixtures/google`.

`.gitattributes` marks `*.ics` as binary for git (no line end conversion): the
byte-exact form is the point.
