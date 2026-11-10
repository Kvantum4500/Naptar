# Kvantum Naptár

Személyes naptár- és életvezetési app (Windows + Android, Flutter), **saját szerver nélkül**: a Google Calendar, a Google Drive és (kérésre) egy általad választott AI-szolgáltató a háttér. Magyar felület.

## Mit tud

| Terület | Állapot |
|---|---|
| **Naptár** – hónap-, hét- és napnézet időskálával, színek, teljes ismétlődés-szerkesztő (kivételekkel), kétirányú szinkron a Google Calendar saját „Naptar” naptárával, offline sor, `.ics` mentés/visszaállítás | kész |
| **Beosztás** – műszakciklus-generátor (pl. 3 éjszaka – 3 szabad – 3 nappal – 3 szabad), műszakcsere, extra műszak, havi összesítő | kész |
| **Feladatok és napi check-in** – a Drive `appDataFolder`-ben, mezőnkénti összefésüléssel, több eszközön | kész |
| **Asszisztens** – Gemini / Groq / Mistral / OpenRouter / OpenAI / egyéni (OpenAI-kompatibilis) szolgáltató, szerkeszthető kézikönyv, javaslat → jóváhagyás; áthelyezés és törlés csak jóváhagyással; feladat-ütemezés; időjárás (Open-Meteo) és helyszín; a kemény szabályokat **kód** ellenőrzi, az AI csak javasol | kész, élő modellel a felhasználó próbálja |
| **Pénzügyek** – napló, havi keretek, ismétlődő tételek, megtakarítási célok; telefon ↔ gép „postalevél” szinkron a Drive-on; Google Wallet értesítések automatikus felvétele (Android) | kész |
| **Emlékeztetők** – műszak és napi check-in (Android) | kész (Windowson nincs) |
| **Önfrissítés** – Windows: csere + visszaállítás hibánál; Android: a rendszertelepítő; stabil és előzetes csatorna | kész |

A részletes ellenőrzés és a fejlesztési terv: [`docs/audit-es-fejlesztesi-terv.md`](docs/audit-es-fejlesztesi-terv.md). Változások: [`CHANGELOG.md`](CHANGELOG.md).

## Futtatás fejlesztéshez

Flutter **3.47.9** (Dart 3.13.7) kell; a CI is ezt használja.

```bash
# mag (tiszta Dart)
cd packages/kvantum_core && dart pub get && dart analyze && dart test
# app
cd apps/kvantum_app && flutter pub get && dart run build_runner build --delete-conflicting-outputs && flutter analyze && flutter test
# titkok: másold, töltsd ki (a secrets.json git-ből kizárt)
cp secrets.example.json secrets.json
flutter run -d windows --dart-define-from-file=secrets.json   # vagy -d <android-eszköz>
```

A `secrets.json` kulcsai: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (Google Cloud OAuth-kliens), `UPDATE_TOKEN` (csak olvasó GitHub-token az önfrissítéshez). Ezek a buildbe kerülnek, ezért **soha** ne kerüljenek a repóba.

## Fő tervezési döntések

- **Idő:** falióra + IANA zóna (mint a Google); az ismétlődés falióra-időben fut (DST-biztos), az esemény időtartama valós eltelt idő.
- **Duplikáció-védelem:** `reconcile()` sorrend: tárolt link → `appEventId` (saját írás visszhangja) → iCalUID → új.
- **AI:** a modell csak javasol. Minden írás (új esemény, áthelyezés, törlés, megjegyzett szokás) külön gombnyomásra történik; a szabályokat (alvás, puffer, energia, műszak, időjárás, határidő) a `validateProposal` kóddal ellenőrzi. A modellnek szánt szöveg adatként, jelölt blokkban megy, tisztítva.
- **Adatok helye:** az események a Google Calendarban és a helyi adatbázisban; a feladatok, check-inek, kézikönyv a Drive `appDataFolder`-ben; a pénzügyi adat **helyben**, a gépek között rövid életű „levelekkel” (a megérkezett levél törlődik). A Drive-ban a pénzügyről nincs teljes másolat: a rendszeres mentés (Beállítások → Mentés) fontos.
- **Titkok:** az eszköz biztonságos tárolójában (Windows DPAPI / Android Keystore); az API-kulcs csak fejlécben utazik; nincs telemetria, nincs naplózott kulcs.
- **Android:** az automatikus (felhő-/eszközátvitel) mentés ki van kapcsolva; az adat a Google-fiókból és a többi eszközről áll helyre.

## Kiadás és önfrissítés

- A `build.yml` megépíti a Windows-zipet és az Android-APK-t, SHA-256 összeggel, és GitHub-kiadást (`build-<szám>`) készít belőle.
- **Stabil kiadás:** a `main`-re és a `v*` címkére küldött változás. **Előzetes kiadás** (pre-release): a munkaágakról (`[build]` a commit üzenetben, vagy kézi indítás) készült build; ezt az app csak akkor ajánlja fel, ha a Frissítés ablakban az „Előzetes verziókat is keressen” be van kapcsolva.
- Az app „Frissítés keresése” menüpontja a csak olvasó `UPDATE_TOKEN`-nel kérdezi le a kiadásokat, ellenőrzi az összeget, és (Windowson) lecseréli magát, hibánál visszaállítja a régit. Az ellenőrzés csak kézi indításra fut.
- Az első indításnál a Windows figyelmeztet („ismeretlen kiadó”): a ZIP tulajdonságainál jelöld be a **Feloldás** (Unblock) négyzetet kicsomagolás előtt. A frissítések már nem figyelmeztetnek.
- Titkok (GitHub → Settings → Secrets → Actions): `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `UPDATE_TOKEN`; Androidhoz még `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (az **Android keystore (egyszeri)** workflow előállítja; a kulcsot **őrizd meg**, elvesztése után újra kell telepíteni az appot). Aláírt kulcs nélkül az APK nem kerül a kiadásba.

## Mit tegyek, ha…

- **„A Google-bejelentkezés lejárt”:** koppints a „Belépés szükséges” gombra (az adat megvan, a függő módosítások utána feltöltődnek). Ha hetente ismétlődik: a Google Cloud OAuth-hozzájárulási képernyő „Testing” állapotban van, állítsd „In production”-re.
- **A naptár egyik eseménye nem látszik, sárga/piros sáv jelzi:** az ismétlődési szabálya nem olvasható; a sáv „Részletek” gombjával egyszeri eseménnyé alakítható, vagy kijavítható a Google Naptárban.
- **Az asszisztens limitet jelez:** az ingyenes szintek percenkénti/napi tokenkerete kicsi (Groq: 8 000 token/perc); várj, vagy válts szolgáltatót a Beállításokban.
