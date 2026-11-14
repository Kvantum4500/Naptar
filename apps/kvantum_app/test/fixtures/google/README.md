# Google Calendar API samples

These files are written **by hand**, after what the Google Calendar API's
`events.list` answers with: the same fields (a real answer has dozens), the same
types, `dateTime` with an explicit offset and a `timeZone`, cancelled events as
an id and a status, instances of a series with `recurringEventId` and
`originalStartTime`, `recurrence` as lines of an iCalendar text.

They are **not recordings of real answers.** What a real calendar returns can
differ in details; if the app reads a real answer wrongly, take out what is
private (titles, places, e-mail addresses) and add the answer here with a test
next to it.

| File | What is in it |
|---|---|
| `events_page1.json`, `events_page2.json` | one listing in two pages (`nextPageToken`, then `nextSyncToken`), timed and all-day events, a deleted event |
| `recurring_with_exception.json` | a series, an occurrence that was moved, one that was cancelled |
| `all_day_multiday.json` | all-day events of several days, over the turn of the year, a yearly one |
| `event_types.json` | `eventType`: birthday, outOfOffice, focusTime, workingLocation, fromGmail |
| `rich_event.json` | guests, a Meet room, reminders, an attachment, HTML in the description, our own markers next to a foreign one |
| `recurrence_forms.json` | the forms of `recurrence`: `EXDATE` with a zone, in UTC, `VALUE=DATE`, `VALUE=DATE-TIME`, `RDATE`, two rules |

The calendar files (.ics) for the same purpose are in
`packages/kvantum_core/test/fixtures/ics`.
