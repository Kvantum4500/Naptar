# Kvantum Naptár

Személyes naptárapp (Windows + Android, Flutter), szerver nélkül: Google Calendar (események) + Google Drive `appDataFolder` (saját adat) + Gemini (AI). Teljes terv: lásd a munkamenet tervfájlját; a lényeg lent.

## Állapot
| Rész | Állapot |
|---|---|
| `packages/kvantum_core` – tiszta Dart mag: időzóna/DST, ismétlődés, ISO-hét, duplikáció-védelem, AI szabályellenőrző | **kész, 23 teszt zöld** |
| `handbook/` – Gemini kézikönyv | **első verzió** |
| `apps/kvantum_app` – Flutter app: helyi SQLite (drift), hónapnézet + napi lista, eseményszerkesztő (ismétlődéssel), outbox | **kész, tesztelve** |
| Szinkronmotor (`lib/sync`): pull → reconcile → push, syncToken, teljes újraszinkron, ütközéskezelés, idempotens újrapróbálás | **kész, 9 teszt (hamis távoli naptárral)** |
| Valódi Google Calendar adapter (`RemoteCalendar` implementáció), Google belépés | következő lépés (Google Cloud OAuth-kliens kell hozzá) |
| Drive `appDataFolder` (feladatok, check-in), Gemini hívás | következő lépés |
| Turbo mód (Cloudflare Worker + FCM) | következő lépés |

## Futtatás
```bash
# mag
cd packages/kvantum_core && dart pub get && dart analyze && dart test
# app (Flutter 3.47+)
cd apps/kvantum_app && flutter pub get && dart run build_runner build && flutter analyze && flutter test
flutter run -d windows     # vagy -d <android-eszköz>
```
Ismert korlát: egy ismétlődő esemény szerkesztése az egész sorozatra vonatkozik (az „csak ez a példány” szerkesztés a következő lépés; a mag már támogatja).

## Fő tervezési döntések
- Időpont tárolás: **falióra + IANA zóna** (mint a Google), az instant származtatott. Ismétlődés falióra-időben fut (DST-biztos), az esemény időtartama valós eltelt idő.
- DST: tavaszi hiányzó idő előre tolódik, őszi dupla idő az első előfordulást kapja.
- Duplikáció: `reconcile()` sorrend: tárolt link → `appEventId` (saját írás visszhangja) → iCalUID → új.
- AI: Gemini a kézikönyvvel; a szabad idősávokat és a kemény szabályokat **kód** ellenőrzi (`validateProposal`), az AI csak választ és indokol.
- Titkok (API-kulcs, tokenek) soha nem kerülnek a repóba; az eszköz biztonságos tárolójában élnek.
