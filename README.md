# Kvantum Naptár

Személyes naptárapp (Windows + Android, Flutter), szerver nélkül: Google Calendar (események) + Google Drive `appDataFolder` (saját adat) + Gemini (AI). Teljes terv: lásd a munkamenet tervfájlját; a lényeg lent.

## Állapot
| Rész | Állapot |
|---|---|
| `packages/kvantum_core` – tiszta Dart mag: időzóna/DST, ismétlődés, ISO-hét, duplikáció-védelem, AI szabályellenőrző | **kész, 23 teszt zöld** |
| `handbook/` – Gemini kézikönyv | **első verzió** |
| `apps/kvantum_app` – Flutter app: helyi SQLite (drift), hónapnézet + napi lista, eseményszerkesztő (ismétlődéssel), outbox | **kész, tesztelve** |
| Szinkronmotor (`lib/sync`): pull → reconcile → push, syncToken, teljes újraszinkron, ütközéskezelés, idempotens újrapróbálás | **kész, 9 teszt (hamis távoli naptárral)** |
| Google Calendar adapter (`GoogleCalendarRemote`), Google belépés (OAuth, biztonságos tároló), szinkronvezérlő (60 mp + mentés után + előtérbe lépéskor) | **kész, 21 teszt hamis HTTP-vel; élő fiókkal még nem próbálva** |
| Windows zip + Android APK építés, GitHub-kiadás (`build.yml`) | kész |
| Nézetek (hónap/hét/nap), színek, szerkesztő teljes ismétlődéssel, szinkronállapot | kész, 109 app teszt |
| Önfrissítés (Windows kész, Android a kulcs beállítása után) | kész, éles próba kell |
| Drive `appDataFolder` (feladatok, check-in), Gemini hívás | következő lépés |
| Turbo mód (Cloudflare Worker + FCM) | következő lépés |

## Futtatás
```bash
# mag
cd packages/kvantum_core && dart pub get && dart analyze && dart test
# app (Flutter 3.47+)
cd apps/kvantum_app && flutter pub get && dart run build_runner build && flutter analyze && flutter test
cp secrets.example.json secrets.json   # töltsd ki (git kizárja)
flutter run -d windows --dart-define-from-file=secrets.json   # vagy -d <android-eszköz>
```
Ismert korlát: egy ismétlődő esemény szerkesztése az egész sorozatra vonatkozik (az „csak ez a példány” szerkesztés a következő lépés; a mag már támogatja).

## Fő tervezési döntések
- Időpont tárolás: **falióra + IANA zóna** (mint a Google), az instant származtatott. Ismétlődés falióra-időben fut (DST-biztos), az esemény időtartama valós eltelt idő.
- DST: tavaszi hiányzó idő előre tolódik, őszi dupla idő az első előfordulást kapja.
- Duplikáció: `reconcile()` sorrend: tárolt link → `appEventId` (saját írás visszhangja) → iCalUID → új.
- AI: Gemini a kézikönyvvel; a szabad idősávokat és a kemény szabályokat **kód** ellenőrzi (`validateProposal`), az AI csak választ és indokol.
- Titkok (API-kulcs, tokenek) soha nem kerülnek a repóba; az eszköz biztonságos tárolójában élnek.

## Önfrissítés és kiadás
- Minden `main`-re küldött változás (és a `[build]` jelű commit feature ágon) megépíti a Windows-zipet és az Android-APK-t, és létrehoz egy GitHub Release-t (`build-<szám>`), SHA-256 összeggel.
- Az app „Frissítés keresése” menüpontja ezt a kiadást nézi meg a csak olvasási `UPDATE_TOKEN`-nel, ellenőrzi az összeget, és (Windowson) lecseréli magát, hibánál visszaállítja a régit.
- Az első indításnál a Windows figyelmeztet („ismeretlen kiadó”): a ZIP tulajdonságainál jelöld be a **Feloldás** (Unblock) négyzetet kicsomagolás előtt. A frissítések már nem figyelmeztetnek.
- Titkok (GitHub → Settings → Secrets → Actions): `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `UPDATE_TOKEN`; Androidhoz még `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (az **Android keystore (egyszeri)** workflow előállítja).
