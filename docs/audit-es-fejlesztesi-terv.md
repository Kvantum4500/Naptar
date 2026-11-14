# Kvantum Naptár – teljes audit és fejlesztési terv (2026-11-10)

## Context
A felhasználó teljes ellenőrzést kért „minden oldalról” (kezelhetőség, plusz funkciók, token- és adattakarékosság, kompatibilitás stb.), hozzá ellenőrzési tervet, majd fejlesztési tervet. Az app jelenleg: Flutter (Windows + Android), kb. 23 000 sor Dart (mag ≈3 800, app ≈19 000, + 4 100 generált drift-kód), ≈405 app- és 173 mag-teszt, Build 33 kint, PR #3 (draft) a `claude/sweet-goodall-bn5pp9` ágon; a felhasználó még tesztel („Később ellenőrzőm”), a PR #3-at csak az ő jóváhagyása után merge-eljük.

**Mi készült most:** három párhuzamos, csak olvasó átvilágítás (1. biztonság/adatvédelem/kiadás, 2. szinkron/adatintegritás/teljesítmény/formátum-kompatibilitás, 3. AI-token/adatforgalom/kimenet-biztonság) + saját átvilágítás a felületről, kezelhetőségről, hozzáférhetőségről, kompatibilitásról, tesztekről. A legsúlyosabb állításokat magam is ellenőriztem a kódban (jelölés a táblákban: **✔** = saját ellenőrzés, **◦** = átvilágítási jelentés forrás-hivatkozással, külön nem ellenőriztem, **?** = élő környezet kell). Semmi nem módosult, nem épült, nem futott; Google/Groq/Gemini API-t nem hívtam, tokent nem mértem.

**Jelmagyarázat:** Súly: Magas / Közepes / Alacsony / Info (kritikus nincs). Munka: S ≈ fél munkamenet alatt, M ≈ 1–2 munkamenet, L ≈ 3+.

---

## 0. Összegzés
- **Nincs kritikus hiba, és nincs titok a repóban** (minden revíziót átnéztek; egyetlen találat egy teszt-helykitöltő). Eszközön a titkok biztonságos tárolóban vannak, a modell semmit nem ír gombnyomás nélkül, a frissítő zárt hibakezelésű.
- **12 magas súlyú** megállapítás, 4 csoportban: (1) kiadási lánc és egy konkrét kulcs-útválasztási hiba (SEC-1, SEC-2); (2) szinkron-ellenálló képesség: egy hibás ismétlődési szabály mindent elnémít, nincs HTTP időkorlát, a teljes újraszinkron helyi történetet törölhet, az újrapróbálás csendben feladja (REL-1, 3, 4, 7); (3) az AI-réteg nincs méretezve a Groq 8 000 token/perc keretre, a javítási kör mindent újraküld, a kódkapuk a modell `hard` állítására épülnek (AI-1…6).
- **Saját hibám (SEC-13):** a legutóbbi `isAuthExpired` túl tág: a `googleapis_auth` *minden* nem-200 token-válaszra ugyanazt a „Failed to obtain access credentials” üzenetet adja ✔, tehát egy átmeneti Google 5xx/429 is kijelentkeztet. A 0. fázis szűkíti (csak HTTP 400 + `invalid_grant`).
- **Token:** a tipikus „Tervezz edzést a jövő hétre” kérés ≈ 5,3–6,4 k prompt-token (becslés), ebből ≈ 4,2 k fix rész minden körben; egy javítási körrel > 13 k. Célérték: ≈ 3,0 k és tipikusan 1 hívás (−48 %).
- **Kezelhetőség:** az Asszisztens/Feladatok/Beosztás/Beállítások telefonon egy lenyíló menü mögött vannak ✔; nincs visszavonás ✔, keresés, napirend nézet, gesztus, húzás, Windows-billentyűparancs (csak a szerkesztőben), nincs hibadiagnosztika, a hibaüzenetek részben angol osztály-dumpok; Windowson egyáltalán nincs emlékeztető ✔.
- **Legolcsóbb, legnagyobb haszon (0. fázis):** SEC-2, SEC-13, AI-12 (egysoros hiba), REL-1, REL-3, SEC-5, SEC-7, AI-15, SEC-1.

---

## A. ELLENŐRZÉSI TERV

### A1. Dimenziók, módszer, elfogadási küszöb
| # | Terület | Mit vizsgálunk | Módszer | Elfogadási küszöb | Állapot |
|---|---|---|---|---|---|
| 1 | Biztonság | titkok, OAuth, frissítő, Android/Windows beállítás, ellátási lánc | statikus átvilágítás; GitHub/Google beállítások kézi átnézése; CI-kapuk (titokkereső, függőség-ellenőrzés, merged manifest) | 0 nyitott Magas; titok soha nincs repóban/logban/exportban | statikus **kész**; beállítások: te (D. rész); CI-kapuk: 5. fázis |
| 2 | Adatvédelem | mi megy ki, hová, mikor | adatfolyam-tábla (**kész**, B1 alatt) + „mit küldünk” előnézet + kapcsoló-tesztek | kikapcsolt forrásból 0 bájt megy ki (teszt) | tábla kész; teszt: 0./2. fázis |
| 3 | Megbízhatóság / szinkron | átfedés, időkorlát, újrapróbálás, 410/412/403/429, fiókváltás, outbox | kódátvilágítás (**kész**) + hibainjektáló tesztek (hamis HTTP: lefagyás, 5xx, quota, 410, fiókváltás) + eszközön repülőgép-mód / alvó gép | 0 beragadó szinkron; minden hiba vagy újrapróbálódik, vagy látszik | 1. fázis |
| 4 | Adatintegritás / formátum | migráció, tranzakciók, tombstone, óraeltérés, verziókapu, import/export | fixture-tesztek v1–v4 DB-re, körút-tesztek, óraeltérés-teszt | régi app újabb adatot nem ront el; migráció megszakadásnál is épen marad | 1. fázis |
| 5 | Idő | DST, zóna-váltás, évhatár, szökőnap, 12 napos ciklus | meglévő tesztek + utazás/zóna-forgatókönyv | „ma” és kijelzés ugyanabban a zónában | részben kész; 1. fázis |
| 6 | Teljesítmény / akku | indulás, képkocka-idő, HTTP-hívás/perc, reminder-újraütemezés | debug számlálók + 24 órás eszközmérés | idle ≤ 1 hívás/perc; hónapnézet nem akad 1 000 eseménnyel | 1. fázis (+ mérés: te) |
| 7 | AI token és adat | prompt-méret, körök, ismétlés, cache-barát sorrend | `usage` mezők naplózása, 3 kanonikus kérés mérése, élő Groq/Gemini próba | tervezési kérés ≤ 3,0 k prompt-token, tipikusan 1 hívás | becslés **kész**; mérés: 2. fázis |
| 8 | AI kimenet-biztonság | jóváhagyási kapuk, ref-validáció, prompt-injection | 50 elemes „ellenséges szöveg” korpusz-teszt, tulajdonság-alapú tesztek a `validateProposal`-ra | 0 írás gomb nélkül; hostile szöveg nem tud blokkot lezárni | részben kész (meglévő tesztek); 2. fázis |
| 9 | Kezelhetőség | 10 fő feladat bejárása, első indítás, hibaüzenet-katalógus | heurisztikus értékelés + eszközön végigjátszás | minden fő feladat ≤ 3 koppintás; hiba = magyar + teendő | statikus kész; eszköz: 3. fázis eleje |
| 10 | Hozzáférhetőség | Semantics, nagy betű, kontraszt, billentyűzet | Semantics-fa teszt, golden képek 200 % betűvel + sötét témával, TalkBack/Narrator bejárás | rács és szerkesztő használható képernyőolvasóval; AA kontraszt | 3. fázis |
| 11 | Kompatibilitás | Android/Windows verziók, képernyők, Google API valóság, ICS más naptárakkal, adatformátum-verziók | eszközmátrix, valós JSON/ICS fixture-ök (Google/Apple/Outlook), merged manifest, 16 KB-oldal ellenőrzés | a támogatott mátrix minden sora zöld | 5. fázis (+ eszközök: te) |
| 12 | Kiadás / CI / karbantarthatóság | reprodukálható build, csatornák, lefedettség, fájlméret, dokumentáció | CI-kapuk, `flutter test --coverage`, `pub outdated`, formázás-ellenőrzés | main-re csak zöld CI után; README/CHANGELOG naprakész | 0. és 5. fázis |

### A2. Kézi ellenőrző protokoll (te, eszközön; a fázisok végén a releváns részt kapod meg)
**Telefon (Android)**
1. Új build telepítése, belépés (Google után **vissza az appba**).
2. Repülőgép-mód: vegyél fel eseményt + feladatot + pénzügyi tételt → „N függőben”; kapcsold vissza → 1–2 percen belül „Szinkronban”.
3. Műszak-emlékeztető 5 percre előre: mérd a késést (ha > 2 perc → pontos riasztás téma, REL-19).
4. Nagy betű (rendszer max) + sötét téma: hónap, hét, szerkesztő, Pénzügyek olvasható, nincs levágás/overflow.
5. TalkBack: új esemény létrehozása képernyőolvasóval.
6. Wallet: egy valódi fizetés után a tétel megjelenik; 2–3 értesítés-minta bemásolva (Beállítások → Wallet → Legutóbbi értesítések → Másolás; kártyaszám nem kell).
7. 24 óra használat után Beállítások → Akku → az app részaránya.

**PC (Windows)**
1. Zip „Feloldás” (Unblock) → kicsomagolás → első indítás; majd „Frissítés keresése” egy újabb buildre.
2. Alvó gép/ébresztés után 1 percen belül szinkron.
3. Ablak átméretezése ~480 px-ig: nincs overflow.
4. Második példány indítása (a javítás után ne induljon).
5. Dokumentumok mappa OneDrive-ra van-e irányítva (Explorer → Dokumentumok → Tulajdonságok → Hely): ez a DB helye (SEC-6).

**Két eszköz**
1. PC-n felvett pénzügyi tétel a telefonon 2 percen belül; telefonról törölt a PC-n is eltűnik.
2. PC 3 napig kikapcsolva, telefonon 5 tétel; PC indítás után mind megérkezik.
3. Ugyanazon rekord egyidejű szerkesztése: az újabb nyer, nincs duplikátum.
4. Fiókváltás (kilépés → másik Google-fiók): a régi fiók eseményei ne kerüljenek az újba (REL-4 után).

**AI**
1. Három kanonikus kérés: „Tervezz edzést a jövő hétre”, „Töröld a kézzel felvett programokat holnapra”, „Hogy állok a költségkerettel?” → feljegyzendő: 1 hívásból sikerült-e, token-használat (a kijelzés után), volt-e javítási kör.
2. Kikapcsolt adatforrás → az előnézetben nincs benne.
3. Rossz idő napjára szabadtéri sport nem javasolt.

### A3. Automatikus kapuk (bevezetés: 0. és 5. fázis)
`dart format --set-exit-if-changed`, `flutter analyze --fatal-infos`, `flutter test --coverage` (küszöb a magra), titokkereső (gitleaks) és GitHub push protection, függőség-ellenőrzés (`dart pub outdated`, OSV), `apkanalyzer manifest print` + engedély-lista összevetés, `zipalign -c -P 16`, APK/zip méretkeret, release csak zöld tesztek után és csak `main`/`v*`-ról.

### A4. Mérőszámok (jelenlegi → cél)
| Mutató | Most | Cél |
|---|---|---|
| Terv-kérés prompt-token („jövő hét”) | ≈ 5,3–6,4 k (becslés) | ≤ 3,0 k |
| Törlés-kérés prompt-token | ≈ 4,7 k | ≤ 2,2 k |
| Fix rész (rendszerprompt + eszközök) | ≈ 4,2 k | ≤ 2,3 k |
| Javítási/csonka kör gyakorisága | ismeretlen | < 10 % (naplóból mérve) |
| Idle HTTP-hívás/perc | ≥ 5 | ≤ 1 aktívan, ≤ 0,3 10 perc tétlenség után |
| Beragadó szinkron | lehetséges | 0 (≤ 30 s időkorlát, ≤ 1 várakozó) |
| Egy hibás esemény hatása | minden nézet üres | 1 esemény kimarad + figyelmeztető sáv |
| Kimenő adat kikapcsolt kapcsolónál | szivárog (SEC-8) | 0 bájt (teszt) |
| Android automatikus mentés | be (alapértelmezés) | ki |
| Magyar, teendőt adó hibaüzenet | részben | 100 % (katalógus) |

---

## B. AUDIT EREDMÉNYEK

### B1. Biztonság és adatvédelem
| ID | Súly | Megállapítás | Hely | Javítás | Munka | Ell. |
|---|---|---|---|---|---|---|
| SEC-1 | Magas | A feature-ági `[build]` is „latest” kiadás: minden eszköz jóváhagyatlan kódot kaphat; ágból a workflow szerkesztésével titkok/kiadási jog érhető el | `build.yml` (`claude/**` trigger, `release` job őr nélkül, `make_latest`) | `release` csak `main`/`v*`-ra; más ág → *prerelease* + „Előzetes csatorna” kapcsoló az appban (hogy a tesztelés megmaradjon); titkok GitHub *Environment* mögé kézi jóváhagyással; Actions SHA-pin; CODEOWNERS/ruleset a `.github/**`-ra | S | ✔ |
| SEC-2 | Magas | Elavult egyéni URL felülír minden OpenAI-kompatibilis szolgáltatót: a Groq/Mistral/… kulcs és az események/pénzügyek a régi (akár `http://`) hosztra mennek; a kulcs-ellenőrzés közben átmegy | `ai_providers.dart:182-188`, `provider_catalog.dart:110`, `ai_settings.dart:117,148`, `settings_page.dart:78,106` (`copyWith(null)` nem töröl) | `baseUrl` csak `custom`-nál; szolgáltatóváltáskor törlés; `clearCustomBaseUrl`; regressziós teszt | S | ✔ |
| SEC-3 | Közepes | Frissítés: integritás igen, hitelesség nem (a SHA-256 ugyanabból a kiadásból jön); a Windows-exe aláíratlan, a saját letöltés nem kap Mark-of-the-Web-et | `update_service.dart:227-273` | Ed25519 aláírás `build-N\|sha256` fölött, beégetett publikus kulccsal; az app a hiányzó/rossz aláírást elutasítja | M | ◦ |
| SEC-4 | Közepes | A beégetett `UPDATE_TOKEN` és Google client secret kinyerhető a binárisból (a token csak olvas, de a privát repó forrását/kiadásait megnyitja; lejáratkor a frissítő megáll, kézi telepítés kell) | `update_config.dart:4`, `google_auth_service.dart:14-15` | Döntés kell (E. rész): marad + aláírás, vagy külön nyilvános kiadási repó (token nélkül); token lejárat-emlékeztető | M | ◦ |
| SEC-5 | Közepes | Android Auto Backup: nincs `allowBackup`/`dataExtractionRules` → a DB (pénzügy!), a Wallet-sor és a secure-prefs Google-mentésbe/új telefonra kerülhet | `AndroidManifest.xml` `<application>` | `allowBackup="false"` + `dataExtractionRules` (database, sharedpref, file kizárva); lásd REL-6 | S | ✔ |
| SEC-6 | Közepes | SQLite titkosítatlan; Windowson `Documents\kvantum.sqlite` (OneDrive-ütközés, bárki által olvasható) | `db.dart:94`, drift_flutter alapértelmezés | útvonal `%LOCALAPPDATA%`-ba egyszeri áthelyezéssel; opcionális `sqlite3mc` titkosítás, kulcs a secure storage-ból | M | ✔ |
| SEC-7 | Közepes | Wallet-értesítések nyersen és korlátlan ideig maradnak a SharedPreferences-ben, ha az „automatikus” ki van kapcsolva (a `run()` a `drain` előtt visszatér; maszkolás csak a drain után); a `maskSensitive` csak ≥8 számjegyet és néhány kulcsszót fed | `WalletNotificationListener.kt:26-33`, `wallet_ingest.dart:102`, `wallet_parser.dart:75-83` | maszkolás/rövidítés Kotlinban sorba tétel előtt; TTL (14 nap); auto-off → sor ürítése; regex bővítés (csoportosított PAN/IBAN/telefon, „…1234”, „Kártya vége: 1234”) | S | ✔ |
| SEC-8 | Közepes | A szabálysértési visszajelzés megkerüli a megosztási kapcsolókat és a `sanitizeText`-et: eseménycímek, műszaknevek, check-in energia megy a modellnek kikapcsolt forrásnál is | `rules.dart:105-109,144-149,154-167`, `assistant_service.dart:344,685` | kapcsoló-tudatos, általános szöveg + `sanitizeText` | S | ◦ |
| SEC-9 | Közepes | Az AI-alapértelmezések mind BE ✔; a kézikönyv (profil: sérülések, célok) minden kérésben megy, kapcsoló nélkül; a check-in megjegyzés és a helyszín-címke is megy; a felület szövege szerint csak a kerekített koordináta távozik (ez csak az Open-Meteo-ra igaz) | `ai_settings.dart:65-71`, `assistant_context.dart:375`, `weather.dart:122-125`, `settings_page.dart:499` | egyszeri beleegyezés-ablak (szolgáltató neve + kategóriák + „a kézikönyv mindig megy”); kézikönyv-kapcsoló/figyelmeztetés; szöveg javítása; ingyenes szintek tanítási kitétele. A pénzügy alapértelmezése marad BE (a felhasználó döntése), de a beleegyezés ablakban látszik | S | ◦ |
| SEC-10 | Közepes | A `calendar` hatókör az összes naptárat eléri; a tulajdonos-szerepű, jelölőt tartalmazó naptárat az app „sajátjának” fogadja el | `google_auth_service.dart:18-21`, `google_calendar_remote.dart:55-81` | `calendar.app.created` + calendarId a Drive appData-ban (élőben ellenőrizendő, hogy a naptárlista nélkül működik-e); addig tulajdonos+leírás+név ellenőrzés | M | ? |
| SEC-11 | Alacsony | Az egyéni végpont `http://` és bármely host lehet; a Gemini hibaszöveg nincs szűrve (csak `sk-`/`gsk_`/`AIza` redakció) | `settings_page.dart:78-82`, `gemini_provider.dart:286-288` | https kötelező, kivéve loopback/RFC1918/.local (megerősítéssel); közös `_safeDetail` | S | ◦ |
| SEC-12 | Alacsony | Modell-jogosultság és injekció-rések: új javaslatok előre kijelöltek; `sanitizeText` nem szűri a C1/Cf/bidi/Unicode-Tag karaktereket; `taskId`, `reason` szűretlen. (A törlés/áthelyezés kapuzása: AI-15) | `ai_providers.dart:248`, `assistant_context.dart:24-31` | alapból kijelöletlen; `\p{Cc}\p{Cf}` szűrés; azonosítók és indoklás szűrése; ≤ 20 tétel | S | ◦ |
| SEC-13 | Közepes | **Saját hiba:** `isAuthExpired` a „failed to obtain access credentials” szövegre is illeszkedik, amit a `googleapis_auth` minden nem-200 token-válasznál ad ✔ → átmeneti Google 5xx/429 kijelentkeztet; kijelentkezéskor a token a Google-nél érvényes marad; a bejelentkezésnek nincs időkorlátja/megszakítása | `sync_controller.dart:143-148`, `googleapis_auth utils.dart:122-141`, `google_auth_service.dart:100-125` | csak HTTP 400 + `invalid_grant` = lejárt; kijelentkezéskor `oauth2.googleapis.com/revoke`; bejelentkezési időkorlát + mégse | S | ✔ |
| SEC-14 | Alacsony | `open_filex` felesleges média-engedélyeket és root-path FileProvidert hozhat a merged manifestbe (nem ellenőrzött) | `pubspec.yaml`, plugin-manifest | `tools:node="remove"` vagy saját szűk FileProvider; merged manifest ellenőrzés a CI-ben | S | ? |
| SEC-15 | Alacsony | Frissítő finomságok: a token hozzáadása csak host-egyezésen múlik (nincs séma/port-ellenőrzés), nincs méretkorlát, a zip teljes egészében memóriában, a temp-fájlok megmaradnak, verify és kicsomagolás közt nincs újra-hash | `update_service.dart:200-217,282-309,422-435` | https + pontos host + 443 a token előtt; méretkorlát `asset.size`-ból; temp takarítás; újra-hash | S | ◦ |
| SEC-16 | Alacsony | Drive appData sima JSON, a levelek feladója nincs hitelesítve, az `updatedAt` megbízott (jövőbeli bélyeg minden későbbi szerkesztést elnyom) | `finance_mailbox.dart`, `finance_repository.dart:281-304` | `updatedAt` lefogása (most + 1 nap); opcionális AES-GCM boríték (kulcs QR-ral/jelszóval) | S–M | ◦ |
| SEC-17 | Alacsony | Export fájlok (pénzügyi JSON, .ics) titkosítatlanok, a MIME `text/calendar` a JSON-ra is; nincs alkalmazászár; a pénzügyi képernyő látszik a legutóbbi alkalmazások közt | `backup_io.dart:20-25`, `MainActivity.kt` | figyelmeztetés + opcionális jelszavas export; `FLAG_SECURE` a Pénzügyek fülön; opcionális biometrikus zár | S–M | ◦ |
| SEC-18 | Alacsony | Helyi release-build csendben debug-kulcsra esik vissza ✔; a `flutter stable` rögzítetlen; nincs Gradle checksum; `ci.yml`-ben nincs `permissions`; a release nem függ a tesztektől; a keystore-workflow (egyszer futott, artifact lejárt) a repóban maradt | `build.gradle.kts:56-60`, `build.yml`, `ci.yml`, `android-keystore.yml` | CI-n kulcs nélkül hiba; `flutter-version` rögzítés; `distributionSha256Sum`; `permissions: contents: read`; release ← tesztek; a keystore-workflow törlése a titkok titkosított offline másolata után | S | ✔ |
| SEC-19 | Info | A `.gitignore` `secrets*` mintája a `secrets.example.json`-t is elrejti, amire a README hivatkozik; `deviceId` csak 32 bit; `update.log` a `%TEMP%`-ben | `.gitignore:3`, `record_repository.dart:24` | minta pontosítása; README | S | ◦ |

**Adatfolyam-tábla (mi hagyja el az eszközt)**

| Funkció (kapcsoló) | Hová | Mit | Kikapcsolva |
|---|---|---|---|
| Asszisztens (események, feladatok, check-in, pénzügy, időjárás – mind alapból BE) | Gemini / Groq / Mistral / OpenRouter / OpenAI / egyéni (SEC-2!) | kérésed; rendszerprompt = szabályok + **teljes kézikönyv** (kapcsoló nincs); események: cím ≤ 80, helyi idő, forrás (jegyzet/hely nem); feladatok; check-in ≤ 30 nap (megjegyzés ≤ 120); pénzügy: összegek, keretek, célok, utolsó 15 tétel; időjárás: hely-címke + előrejelzés | „kikapcsolva” blokk, de lásd SEC-8 |
| Kulcs-ellenőrzés / modelllista | ugyanaz a host | csak az API-kulcs (fejléc) | n/a |
| Előrejelzés | `api.open-meteo.com` | szél./hossz. 2 tizedesre kerekítve, 14 nap, csak asszisztens-futáskor | nincs hívás |
| Városkeresés | `geocoding-api.open-meteo.com` | beírt város | csak gombra |
| GPS | sehová | durva helyzet → kerekített hely | csak gombra |
| Szinkron | Google Calendar („Naptar”) | cím, jegyzet, hely, idő, RRULE, szín, UUID, AI-jelölő | kijelentkezés |
| Szinkron | Drive appData | feladatok, check-in (megjegyzéssel), kézikönyv, pénzügyi levelek (új társnak a teljes előzmény), jelenlét 12 óránként | levelek csak társ esetén |
| Frissítés-keresés | `api.github.com` + CDN | token, IP | csak kézi indításra |

### B2. Megbízhatóság, szinkron, adatintegritás, teljesítmény
| ID | Súly | Megállapítás | Hely | Javítás | Munka | Ell. |
|---|---|---|---|---|---|---|
| REL-1 | Magas | Egyetlen nem támogatott/hibás RRULE (pl. `WKST=SU` – a `rrule` csomag csak MO-t fogad ✔, kódunk sehol nem kezeli ✔) kivételt dob az `expand()`-ban; az `occurrences()` nem véd ✔; a nézetek `.value ?? {}`-t használnak, `.when`/`hasError` sehol ✔ → **minden nézet és emlékeztető csendben üres**, minden eszközön | `recurrence.dart:98-100`, `event_repository.dart:222-224`, `month_view.dart:24`, `time_grid.dart:82` | szabály-normalizálás az éleken (.ics import, Google pull: `WKST` kezelése), eseményenkénti try/catch + „N hibás esemény” sáv, `AsyncError` megjelenítése; teszt: `WKST=SU` import és Google pull | S | ✔ |
| REL-2 | Közepes | Az első alkalommal látott kivétel-példány (Google-felületen szerkesztve) iCalUID/appEventId alapján a *mester* sorát írhatja felül → a sorozat eltűnik (a feltevés élő ellenőrzést kér) | `reconcile.dart:36-45`, `sync_engine.dart:144-170` | `originalStart`-os eseményt csak link vagy (mester, originalStart) alapján párosítani; valós alakú JSON-fixture | S–M | ? |
| REL-3 | Magas | A Calendar/Drive HTTP-hívásoknak nincs időkorlátja ✔ (a `TimeoutException`-ágak halottak), a `SyncEngine` mutexe miatt egy lefagyott kérés örökre blokkol; a 60 mp-es időzítő várakozókat halmoz ✔ | `google_calendar_remote.dart:427`, `google_drive_remote.dart:243`, `sync_engine.dart:37-50`, `sync_controller.dart:137,179` | kliens-burkoló ~30 s időkorláttal; `syncNow` koaleszcencia (`_again` jelző); „Szinkronizál…” védelem | S | ✔ |
| REL-4 | Magas | A teljes újraszinkron (410 után) tükörtörli a helyi, linkelt eseményeket, amiket a 31 napos ablak (`timeMin`) miatt nem listáz ✔ → a 31 napnál régebbi történet helyben eltűnik; a szinkronállapot nincs fiókhoz/naptárhoz kötve (fiókváltás/újralétrehozott naptár → vegyes adat) | `sync_engine.dart:92-103`, `google_calendar_remote.dart:30,113-115`, `sync_controller.dart:114-121` | fiók + valódi calendarId a meta-ban, eltérésnél explicit újrakötés (megerősítés); tükör csak az ablakon belülre; tömeges törlés megerősítéssel; „Szinkron alaphelyzetbe” gomb. *0. fázis: legalább az ablakon kívüli események védelme* | M | ✔ |
| REL-5 | Közepes | Pénzügyi postaláda: a > 180 napja néma társ a `known`-ban marad ✔ → visszatérve nem kap teljes pillanatképet, tartósan eltér | `finance_mailbox.dart:116-131,191-209,262` | nem aktív társ kivétele a `known`-ból; túl nagy `seen`-hézag = új társ | S | ✔ |
| REL-6 | Közepes | Visszaállított/klónozott DB ugyanazt a `deviceId`-t használja (a levelek véletlenszerűen elfogyasztódnak); a visszagörgetett DB nem kapja újra a már elfogyasztott deltákat | `record_repository.dart:19-28` + SEC-5 | telepítés-azonosító a DB-n kívül; eltérésnél új társ; `allowBackup=false` | S–M | ◦ |
| REL-7 | Magas | Újrapróbálás: a `quotaExceeded`/`calendarUsageLimitsExceeded` „végleges”-nek számít ✔ (csak a „ratelimit” a átmeneti), nincs backoff/Retry-After; 5 próba után az elem csendben meghal, a `lastError` sehol sem látszik; a műszakgenerátor ≈ 90 elem × ≈ 2 hívás | `google_calendar_remote.dart:408-430`, `sync_engine.dart:176-211` | átmeneti: 403 usageLimits, 429, 5xx, IO/TLS; exponenciális backoff + jitter + Retry-After; push ütemezés; kézi szinkronnál próbaszám-nullázás; determinisztikus kliens-azonosító (nincs listázó hívás); hibás elemek listája a Diagnosztikában | M | ✔ |
| REL-8 | Közepes | Lekérdezési költség: idle ciklus ≥ 5 hívás/perc (≈ 7 200/nap), a történettel nő (postaláda: teljes `files.list` + társonkénti GET); nincs háttér-szinkron; folytatáskor feltétel nélküli szinkron | `sync_controller.dart:72-74,137,256`, `finance_mailbox.dart:87,194-198` | adaptív intervallum (aktív 60 s → 3/5/10 perc tétlenül), postaláda a `changes.list` jelzésre, `modifiedTime` a társ-jegyzetekhez, elhalt jegyzetek törlése, hátterben szünet, folytatáskor csak > 30 s után | M | ◦ |
| REL-9 | Közepes | Utolsó-író-nyer eszközórákkal: óraeltérés vagy jövőbeli bélyeg tartósan elnyomja a későbbi szerkesztéseket; a pénzügy rekordszintű | `finance_repository.dart:105-114,281-304`, `sync_record.dart:53-65` | `max(now, meglévő+1)`; bejövő bélyeg lefogása | S | ◦ |
| REL-10 | Közepes | A lehúzás nem hibaizolált: törölt Naptar-naptár → percenként `Instance of 'SyncTokenExpired'` és a push sosem fut; egy ismeretlen tz-azonosítós vagy hibás EXDATE-es esemény leállítja az egész lehúzást; `timeMin` oldalanként újraszámolva | `google_calendar_remote.dart:50-53,113-115,154-161` | „naptár eltűnt” állapot, eseményenkénti try/catch + kihagyott darab, `timeMin` egyszer | S | ◦ |
| REL-11 | Közepes | `events.update` (PUT) törli a Google-oldali mezőket (emlékeztetők, résztvevők, Meet-link, átlátszóság, RDATE) minden app-szerkesztésnél | `google_calendar_remote.dart:222-224,306-334` | `patch` vagy get+merge `If-Match`-csel | S–M | ◦ |
| REL-12 | Közepes | A távoli törlés elnyeli a fel nem töltött helyi szerkesztést; az elavult etag 412-t okoz örökké; a lehúzás szerkesztés közben felülír | `sync_engine.dart:77-89,118-119`, `event_editor.dart:60-70,325-345` | szerkesztő a tranzakción belül újraolvas; 412 → `events.get` + etag átvétel; outbox-sor esetén ne írjon felül | M | ◦ |
| REL-13 | Közepes | .ics import/export: az import felülírja az újabb helyi módosítást; az UNTIL lebegő+Z alakban nincs konvertálva; a törölt kivételek nem exportálódnak; O(n²) sor-összefűzés; méret- és időtartam-korlát nélkül (DTEND 9999 lefagyasztja a UI-t); UI-szálon fut | `ics.dart:89,169,174-180,302`, `backup_ops.dart:55-67`, `day_utils.dart:24-28` | UNTIL konvertálás, korlátok, isolate, „újabb nyer / megerősítés” | M | ◦ |
| REL-14 | Közepes | A többlépéses írások nem tranzakciósak (műszak-generálás ≈ 90 külön tranzakció, sorozat-törlés, import, levél alkalmazása); minden írás újra-emittálja a teljes táblás streameket | `shift_page.dart:116-176`, `delete_ops.dart:29-54`, `backup_ops.dart:50-68` | `db.transaction` + batch metódusok + diff-alapú újragenerálás | M | ◦ |
| REL-15 | Közepes | Olvas-módosít-ír versenyek: `edit` vs `applyRemote`, `saveTx` vs `applyIncoming`; az első `deviceId()` két azonosítót is létrehozhat | `record_repository.dart:19-28,64-73`, `finance_repository.dart:105-114` | tranzakció; memoizált future | S | ◦ |
| REL-16 | Közepes | Nincs formátum-verziókapu: a `v:1` íródik, de nem olvasódik; az újabb levél ismeretlen `kind`-ja eldobódik és a levél törlődik; régi app újabb DB-t megnyitva visszaírja a `user_version`-t; a backup `format/version` mezőjét figyelmen kívül hagyja | `finance_mailbox.dart:99-104,164-172`, `finance_repository.dart:395-477`, `drive_sync_engine.dart:166` | verzióellenőrzés (újabb → megtartás + „frissíts” üzenet); nyers JSON megőrzése; DB-downgrade őr | M | ◦ |
| REL-17 | Közepes | A migráció nem tranzakciós (a `onUpgrade` közvetlenül hívódik ✔), romboló (`from<2` töröl), alig tesztelt (csak v3→v4 szimuláció) | `db.dart:102-126` | tranzakció + `table_info` őr + DB-fájl másolat migráció előtt + v1–v3 fixture tesztek | S–M | ✔ |
| REL-18 | Közepes | Korlátlan növekedés és hiányzó indexek: a tombstone-ok sosem takarítódnak (feladat, pénzügy), nincs index `dirty/deleted/outbox.event_id/fin_rows` | `record_repository.dart:76-83`, `finance_repository.dart:171-258`, `db.dart:6-87` | tombstone-takarítás max(180 nap, aktív társak `seen`); indexek | S–M | ◦ |
| REL-19 | Közepes | Emlékeztetők: minden esemény-/check-in stream-emisszióra `cancelAll` + ≤ 60 `zonedSchedule` ✔ (nem atomi csere); Androidon `inexactAllowWhileIdle` ✔ (késhet); **Windowson egyáltalán nincs emlékeztető** (`NoopReminderScheduler`) ✔ | `reminders.dart:173-194,198-201,226-263` | terv-aláírás összevetés + debounce + diff; opcionális pontos riasztás (`USE_EXACT_ALARM`, naptár-kategória); Windows: 4. fázis | S–M | ✔ |
| REL-20 | Közepes | `expand()` minden tickre minden sorozatot az elejétől járja, példányonként 3× zónaszámítás; a 20 000-es plafon csendben vág; az időtartam a mester első előfordulásából jön (DST-éjszakán 1 óra eltérés) | `recurrence.dart:8,42-126` | `from-2d` előtti példányok átugrása, falióra-időtartam, cache | S | ◦ |
| REL-21 | Közepes | Időzóna: a kijelzés Europe/Budapesthez kötött, a „ma” az eszköz zónájából jön; nincs éjféli frissítés; a check-in emlékeztető fix 20:00 Budapest | `day_utils.dart:3,32-36`, `providers.dart:71-74`, `reminders.dart:86` | egy megjelenítési zóna beállítás + éjféli ticker | S–M | ◦ |
| REL-22 | Közepes | Nincs összeomlás-/hibarögzítés ✔ (`FlutterError.onError`/`runZonedGuarded` nincs), 13 nyelt kivétel ✔, a felület angol osztály-dumpokat mutat (`Naptár: $e`), a Drive-hiba oka elvész, az outbox `lastError` nem látszik, nincs diagnosztika-export | `main.dart:12-21`, `sync_controller.dart:196,213,239`, `drive_sync_engine.dart:123,219` | fájl-alapú gyűrűs napló + **Diagnosztika** oldal (utolsó hibák, függő sor, kérésszámláló, verzió) + „Másolás/Mentés”; magyar hiba-leképezés | S–M | ✔ |
| REL-23 | Alacsony | Bootstrap-szinkron O(N²) és mindent-vagy-semmit (a Drive-token csak a végén mentődik) | `sync_engine.dart:112`, `drive_sync_engine.dart:115` | oldalankénti haladás, egyszeri indexelés | M | ◦ |
| REL-24 | Alacsony | Wallet: a natív sor kiolvasáskor azonnal törlődik ✔, a könyvelés előtt → hiba/összeomlás elveszti a fizetéseket | `WalletNotificationListener.kt:71-78`, `wallet_ingest.dart:103,147` | nyugtázás: kiolvas → könyvel → töröl (commit után) | S | ✔ |
| REL-25 | Alacsony | Windows: nincs egypéldányos védelem ✔ (második példány ugyanazt az azonosítót használja), DB a Documentsben | `windows/runner/main.cpp` | named mutex; `%LOCALAPPDATA%` | S | ✔ |
| REL-26 | Alacsony | Postaláda-apróságok: társ nélkül a rekordok dirty maradnak és percenként dekódolódnak; duplikált társ-jegyzet duplikált levél; egy nem átmeneti hiba megszakítja a küldést | `finance_mailbox.dart:96-137` | „teljes küldés kell” jelző, társ-dedup, levelenkénti try/catch | S | ◦ |
| REL-27 | Alacsony | Indítás: a teljes `latest_all` tz-adatbázis szinkron dekódolása; az `IndexedStack` a Pénzügyek oldalt is felépíti induláskor (összes tétel betöltése); `DateFormat` buildenként; nem `autoDispose` családok | `time.dart:1,9-13`, `root_shell.dart:61-64` | `latest.dart` (ellenőrizendő a történeti lefedettség), lusta pénzügyi oldal | S | ◦ |
| REL-28 | Info | Tesztek: valós idejű várakozások (10 helyen), 28 `DateTime.now()` a kódban → óra-injekció; kockázatos, tesztelés nélküli ágak: hibás RRULE, fiókváltás, lefagyott kérés, kimerült újrapróbálás, valós Google-JSON | `reminders_test.dart:156-186`, `controller_test.dart:123` | `Clock` injekció, stream-várakozás alvás helyett, fixture-ök | S–M | ✔ |

### B3. AI: token, adat, kimenet
**Token-költség (becslés; magyar ÷3,0, JSON ÷3,4–3,5; élő mérés kell)**

| Rész | Kb. token |
|---|---|
| Beépített utasítások (`buildSystemPrompt`) | ≈ 1 140 |
| Kézikönyv (6 fájl, ≈ 6 000 karakter) | ≈ 1 950 |
| Eszköz-sémák (6 eszköz; `propose_events` 2/3-a) | ≈ 1 080 |
| **Fix rész (minden kérés, minden kör)** | **≈ 4 170** |
| Első üzenet: terv-kérés / alap (7 nap) / törlés / csak pénz | ≈ 1 575 / 1 100 / 510 / 905 |
| **Terv-kérés (jövő hét) összesen** | **≈ 5 750** (5,3–6,4 k) + 0,65–1,0 k válasz (plafon 2 048) |
| **Törlés-kérés összesen** | **≈ 4 700** |
| Javítási kör / eszközkör többlete | +0,65 k / +0,35–0,6 k, de a teljes előzmény újraküldődik: 2. kör ≈ 6,4 k, 3. ≈ 7,1 k |

→ A Groq 8 k TPM-ből egy terv-kérés 72–85 %; egy javítási körrel ≈ 13,7 k = a keret 171 %-a.

| ID | Súly | Megállapítás | Hely | Javítás / megtakarítás | Munka | Ell. |
|---|---|---|---|---|---|---|
| AI-1 | Magas | Nincs tartalék a 8 k TPM keretben: egy terv-kérés ≈ 5,75 k + max 2 048 válasz; a 2. hívás 429-et ad, a 3. kör (≈ 7,1 k) nem fér be | `assistant_service.dart:306-318,421-441`, `openai_provider.dart:21,57-60` | helyi becslő (karakter/3), szolgáltatónkénti keret-presetek, automatikus szűkítés (időjárás → ablak → feladatok → kézikönyv sorrendben), keret fölött javítás helyett kódbeli javítás | M | ◦ |
| AI-2 | Magas | A fix rész a terv-kérés 72 %-a; ugyanazok a szabályok 2–3×: korlátok `rules.md:5-8,13` + élő prompt `:413-418`; törlés/áthelyezés `:407` + `rules.md:9-10` + eszközleírás; mezőformátum `:408` + `output-format.md` + séma; üres sablonsorok | `assistant_context.dart:396-421`, `assets/handbook/*` | egyetlen forrás (a beépített prompt), a kézikönyv csak felhasználó-specifikus; `tzid` ki a sémából; eszköz-részhalmaz scope szerint. **−1,3…−1,6 k + −0,35…−0,96 k** | S–M | ◦ |
| AI-3 | Magas | A javítási kör mindent újraküld, és a hibás `ref`/`deletions`/`moves` problémái nem jutnak vissza a modellhez (üres lista → általános „nem érkezett javaslat”) | `assistant_service.dart:310-352,654-668,710-718` | a parse-problémák a visszajelzésbe; kódbeli automatikus javítás (illesztés/elvetés); a modellnek csak kérdés marad. **−6,4…−7 k / elkerült kör** | M | ◦ |
| AI-4 | Magas | Csonka tool-hívás (`finish_reason=length`) „argumentum nélküli”-vá válik → vak javítás → újra csonka (≈ 13 k); a Geminin nincs `maxOutputTokens` | `openai_provider.dart:127-155`, `gemini_provider.dart:57` | `length`+tool_calls = csonkolás; a teljes tételek mentése; `reason` ≤ 12 szó (−25 % kimenet); Gemini plafon | M | ◦ |
| AI-5 | Magas | A `hard` a modell állítása; jövőbeli napra `hard:true` mindig elutasított (`no_data_hard`, mert csak ma van check-in) ✔ → a modell `hard:false`-ra szorul, ezzel a **`shift_rest`, 48 órás és energia-kapuk ki vannak kapcsolva** | `rules.dart:135-168` ✔, `assistant_models.dart:169` | a nehézséget kód származtassa (sport, ≥ 60 perc, cím); műszak-puffer minden ≥ 45 perces edzésre; a „3/5 feltételezés” megvalósítása vagy a `hard` kivétele | M | ✔ |
| AI-6 | Magas | A heti plafon és a 48 órás szabály csak az adott javaslat blokkjait számolja; kérésenként újra 5 edzés; a `kind` hamisításával megkerülhető | `rules.dart:226-256` | meglévő AI- és sportcímes események átadása a validátornak; cím-regex | S–M | ◦ |
| AI-7 | Közepes | A javaslatok száma/horizontja korlátlan, mind előre kijelölt: egy koppintás ment+szinkronizál mindent | `assistant_models.dart:128-191`, `ai_providers.dart:248` | ≤ 20 tétel, ≤ 2/nap, [most, +60 nap], alapból kijelöletlen | S | ◦ |
| AI-8 | Közepes | Cache-ellenes sorrend: perc-pontos „MAI IDŐ” a rendszerprompt ≈ 96. karakterén ✔, a kérés az adat előtt → a stabil prefix 96 karakter ≈ 12,9 k helyett | `assistant_context.dart:396-398` ✔ | időbélyeg + kérés a végére, a rendszerprompt és az eszközök bájtra azonosak (akár −4,2 k cache-elt token, szolgáltatófüggő) | S | ✔ |
| AI-9 | Közepes | A `usage` (prompt/output token, `finishReason`) parse-olva, de eldobva; a számláló kéréseket számol (429-es próbákat is, helyi éjfélre, nem szolgáltatónként); nincs előzetes becslés | `openai_provider.dart:156-165`, `ai_settings.dart:185-198`, `settings_page.dart:456-459` | napi token-összeg szolgáltatónként, utolsó kérés költsége, küldés előtti becslés + „mit küldünk” előnézet | S | ◦ |
| AI-10 | Közepes | 413 / „Request too large” / `tool_use_failed` / paraméter-400 nincs kezelve, az „Újrapróbál” ugyanazt küldi | `openai_provider.dart:266-290` | felismerés + egyszeri szűkített újrapróbálás | S–M | ? |
| AI-11 | Közepes | Nincs újrapróbálás hálózati/5xx hibára, nincs globális határidő, Mégse gomb, az oldal elhagyásakor a kérés fut tovább; legrosszabb eset ≈ 25 perc várakozás | `assistant_service.dart:421-441`, `openai_provider.dart:199`, `assistant_page.dart:105` | 1–2 próba (1,5 s, 4 s), ≈ 90 s határidő, Mégse | M | ◦ |
| AI-12 | Közepes | **Hiba:** a várakozási állapot („Limit miatt várok N másodpercet…”) sosem látszik: `copyWith` nem adja át a `status`-t ✔ (és az `askWhy`/`habitSaved`-et sem) | `ai_providers.dart:130-157,168` ✔ | két sor + teszt | S | ✔ |
| AI-13 | Közepes | Fix `temperature 0.4` minden szolgáltatónál (egyes OpenAI-modellek elutasítják); az OpenRouter alapmodell az ábécé szerinti utolsó `:free` (valószínűleg eszköz nélkül); nincs paraméter-400 tartalék | `openai_provider.dart:52-64`, `provider_catalog.dart:73-86` | szolgáltatói presetek + egyszeri újrapróbálás a paraméter nélkül | S–M | ? |
| AI-14 | Közepes | `scopeFor` törékeny: ékezet nélküli szavak, tagadás („ne töröld”), vegyes kérés („told át és tervezz”), hamis pozitív (`költ`→költözés, `fizet`→fizetésnap); az alap-scope a legdrágább; „hónap” = 21 nap | `assistant_context.dart:125-179` | ékezetfosztás, halmaz-szándékok, alap = csak események, ma/holnap = 1 napos ablak, `get_weather` eszköz, tesztek | S–M | ◦ |
| AI-15 | Közepes | A törlés/áthelyezés akkor is feldolgozódik, ha a felhasználó nem kért ilyet: a `scopeFor().edit` csak az adat méretét szabja ✔; egy esemény-cím a modellt törlés-kártyára tereli (gomb még kell) | `assistant_service.dart:328-341,447` ✔ | `deletions`/`moves` eldobása `edit` szándék nélkül | S | ✔ |
| AI-16 | Közepes | A jóváhagyott változtatás végleges: elfogadáskor nincs újraellenőrzés, a dupla koppintás duplikál (az állapot a ciklus után változik), nincs visszavonás | `ai_providers.dart:287-383` | busy jelző, újra-validálás, 10 s-es visszavonási ablak | M | ◦ |
| AI-17 | Közepes | Adatminimalizálás: alapból 15 tétel (kereskedő, jegyzet, pontos összeg), check-in jegyzet, hely-címke megy az LLM-nek | `assistant_context.dart:236-243,300-304,375` | alap: kategória-összeg + keret; részlet kérésre/eszközzel; jegyzet és `helyszin` ki; opcionális kereskedő-álnevesítés, 500 Ft-ra kerekítés (−0,4…−0,5 k) | S | ◦ |
| AI-18 | Közepes | Időjárás: soros (≤ 8 s várakozás az LLM-hívás előtt), cache nélkül, mindig 14 nap, nincs hozzá eszköz | `assistant_service.dart:370-377,524-544`, `weather_service.dart:14-45` | TTL-cache (≈ 3 óra), párhuzamos lekérés, csak az alkalmatlan napok küldése | S | ◦ |
| AI-19 | Közepes | Statikus alvási sáv vs 12 napos ciklus: az alvás-teszt csak a kezdetet és a vég−1 percet nézi (22:00–08:00 átmegy); éjszakás műszak után 07:00–17:45 szabadnak látszik | `rules.dart:96-99`, `free_slots.dart:49-58` | intervallum-átfedés; műszakból levezetett napi alvás | M | ◦ |
| AI-20 | Közepes | Kézikönyv: ellentmondások (`rules.md:17` vs `:19`; `output-format.md:14` vs eszközök; `calendar-semantics.md` nem küldött mezőkre hivatkozik), sablonsorok (`profile.md`), hiányzik: 12 napos ciklus és műszakidők, alvás éjszaka után, napi 1 edzés, tipikus hossz | `assets/handbook/*` | átírás (rövidebb, ≈ −0,9 k); javasolt tömör `rules.md` ≈ 1 100 karakter a 2 785 helyett | S | ◦ |
| AI-21 | Alacsony | Minden naptár-esemény címe megy; tervezésnél elég a foglaltság (cím csak műszak/AI/egésznapos) | `assistant_context.dart:47-93` | −0,15…−0,2 k | S | ◦ |
| AI-22 | Alacsony | A felhasználói kérés hossza korlátlan; a hely-címke szűretlen | `assistant_page.dart:69-91`, `weather.dart:125` | maxLength ≈ 500; szűrés | S | ◦ |
| AI-23 | Alacsony | Kikapcsolt adatforrásnál is elmegy a kérés, csak azért, hogy „nem engedi” (≈ 5 k token) | `assistant_context.dart:55-60` | helyi válasz | S | ◦ |
| AI-24 | Alacsony | Szolgáltató-higiénia: duplikált transport-/redakciókód; kérésenként új `http.Client`, nincs bezárva; modell-tartalék csak Geminin | `gemini_provider.dart` vs `openai_provider.dart`, `assistant_service.dart:423` | közös transport, kliens bezárás, tartalék-lista | S–M | ◦ |
| AI-25 | Alacsony | Csendes csonkolás (`slots.take(40)` jelző nélkül); a `learned.md` akár ≈ 2 k token (30 × ≤ 202 karakter) | `assistant_service.dart:615`, `handbook_store.dart:58-82` | `levagva` jelző; ≤ 12 szabály, ≤ 100 karakter | S | ◦ |

**Jó irány (megtartandó):** minden írás gombhoz kötött, a refek és `taskId`-k valós adathoz validáltak, a műszak nem törölhető/mozgatható, kérésenként ≤ 20 törlés/áthelyezés, tömör JSON, helyi idő, rövid alias-ok (e1…), a kapcsolók ténylegesen megállítják az adatot (SEC-8 kivételével).

### B4. Kezelhetőség, használhatóság, hozzáférhetőség (a felület szerkezete és célzott olvasások alapján; futtatás nélkül)
| ID | Súly | Megállapítás | Hely | Javítás | Munka | Ell. |
|---|---|---|---|---|---|---|
| UX-1 | Közepes | A fő funkciók (Feladatok, Asszisztens, Beosztás, Beállítások) < 1000 px-en egy lenyíló menüben vannak ✔; az alsó/oldalsáv csak Naptár \| Pénzügyek | `home_page.dart:73,181-200`, `root_shell.dart:49-56` | alsó navigáció: Naptár, Feladatok, Asszisztens, Pénzügyek, Több (Beosztás, Beállítások); a FAB kontextusfüggő | M | ✔ |
| UX-2 | Közepes | Nincs visszavonás sehol ✔ (nincs `SnackBarAction`); a törlés csak megerősítő párbeszéd | `delete_ops.dart`, `tasks_page.dart:157`, `finance_editors.dart:266` | törlés → „Visszavonás” snackbar (késleltetett commit): esemény, feladat, pénzügyi tétel | M | ✔ |
| UX-3 | Közepes | Nincs keresés, nincs napirend/lista nézet („következő 14 nap”), nincs gesztus (hónap-/hétváltás húzással), nincs húzással áthelyezés a hét/nap rácson ✔ | `home_page.dart`, `time_grid.dart` | keresés (cím, jegyzet, feladat, tétel), napirend nézet, vízszintes húzás, hosszú nyomás + húzás | M–L | ✔ |
| UX-4 | Közepes | Billentyűparancs csak a szerkesztőben (Ctrl+S, Esc) ✔; Windowson nincs N (új), T (ma), ←/→, 1/2/3 (nézet), Ctrl+F, F5 | `event_editor.dart:548-558` | `Shortcuts`/`Actions` a főoldalon + súgó-lap | S | ✔ |
| UX-5 | Közepes | Hibaüzenetek: angol osztály-dumpok (REL-22); fejlesztői szöveg a felületen („secrets.json… flutter run”); a hiba nem visz akcióra | `sync_status.dart:27-32`, `sync_controller.dart:196` | magyar hibakatalógus + „Mit tegyek?” gomb (Belépés, Újrapróbálás, Diagnosztika) | S–M | ✔ |
| UX-6 | Közepes | A Beállítások egyetlen hosszú oldal (≈ 720 sor: AI, pénzügy, Wallet, emlékeztetők, mentés, kézikönyv, frissítés) | `ai/settings_page.dart` | csoportok: Fiók és szinkron · Asszisztens · Emlékeztetők · Pénzügy és Wallet · Mentés · Névjegy; állapot-összefoglaló felül | M | ◦ |
| UX-7 | Közepes | Nincs első indítási vezetés: belépés, API-kulcs, hely, értesítés-engedély, Wallet-hozzáférés (+ „korlátozott beállítások” lépés) mind külön, felfedezéssel | — | egyszeri ellenőrzőlista „kész / hiányzik” állapottal | M | ◦ |
| UX-8 | Közepes | Hozzáférhetőség: a hónaprács és az időrács szinte Semantics nélkül (month_view 1, time_grid 0) ✔; a státusz színre épül (zöld/narancs/piros); nincs 200 %-os betű-, kontraszt- és képernyőolvasó-teszt | `month_view.dart`, `time_grid.dart`, `finance_page.dart:119-183` | Semantics (nap, darabszám, esemény idő+cím), ikon+szöveg a színek mellé, golden tesztek nagy betűvel + sötét témával | M | ✔ |
| UX-9 | Alacsony | Téma: csak rendszerkövetés, fix indigó; 11 kemény `Colors.green/orange` | `main.dart:33-38`, `finance_page.dart` | témabeállítás (rendszer/világos/sötét), szemantikus színek | S | ✔ |
| UX-10 | Alacsony | Windows ablak: induló 1280×720, minimális méret nincs beállítva (win32_window nem ellenőrizve); nincs ablakméret-memória | `windows/runner/main.cpp:29` | min 480×640, méret/pozíció megjegyzése | S | ◦ |
| UX-11 | Alacsony | A hosszú műveletek (műszak-generálás ≈ 90 elem feltöltése) nem mutatnak haladást; a szinkron-állapot nem ad „Újrapróbálás most”-t hiba esetén | `sync_status.dart` | „N/M feltöltve”, hiba esetén gomb | S | ◦ |
| UX-12 | Info | Kemény magyar szövegek, nincs l10n (ARB) – személyes, magyar appnál elfogadható; többnyelvűség esetén drága kinyerés | — | nem cél | — | ✔ |
| UX-13 | Info | Jó: eseményszerkesztő (megerősítés, ismétlődés-szerkesztő, 24 órás idő, színválasztó), nézetváltó, „+N további”, „Ma”, induláskor görgetés a mostanra, mind a 35 `IconButton`-nak van tooltipje | — | megtartandó | — | ✔ |

### B5. Kompatibilitás
| ID | Súly | Megállapítás | Javítás | Munka | Ell. |
|---|---|---|---|---|---|
| CMP-1 | Közepes | Flutter `stable` rögzítetlen a CI-ben; a lock `dart ≥ 3.13.7 / flutter ≥ 3.44.0` ✔ → egy új stable törhet buildet | `flutter-version` rögzítése, havi tudatos frissítés | S | ✔ |
| CMP-2 | Közepes | Android: minSdk/targetSdk a Flutter alapértelmezése (24/36); pontos riasztás nincs; a merged manifest, az R8 és az **Android 16 KB oldalméret** a natív könyvtárakra nem ellenőrzött | CI: `apkanalyzer manifest print`, `zipalign -c -P 16`; Android 8/10/13/14/15 eszközteszt (kérdés: milyen eszközeid vannak) | S–M | ? |
| CMP-3 | Közepes | Windows: csak x64; a VC++ futtatókörnyezet függősége nem ellenőrzött; aláíratlan (döntés: nem cél) | VC redist DLL-ek csomagolásának ellenőrzése; ARM64 csak igény esetén | S | ? |
| CMP-4 | Közepes | Adatformátum-kompatibilitás verziók között (lásd REL-16) | verziókapu + fixture-ök (régi app × új rekord) | M | ◦ |
| CMP-5 | Közepes | Google/ICS-valóság: `WKST`, RDATE, többszörös RRULE (dokumentált korlát), PUT-mezőtörlés, kivétel-példányok; Apple/Outlook .ics (UNTIL, VTIMEZONE, `X-` mezők) | valós minták fixture-ként (Google API JSON, Apple/Outlook export) | M | ? |
| CMP-6 | Alacsony | Függőségek: a `pub outdated`/advisory itt nem futtatható; drift_flutter `+eol` stubok | CI-ben ütemezett ellenőrzés | S | ? |
| CMP-7 | Alacsony | Töréspontok szétszórva (760 / 820 / 900 / 1000 px) három fájlban; tablet/összehajtható/fekvő nézet nem tesztelt | közös töréspont-osztály + golden képek | S–M | ◦ |
| CMP-8 | Info | iOS/macOS/Linux nincs célozva (nem kért) | nem cél | — | — |

### B6. Kiadás, CI, minőség, karbantarthatóság
| ID | Súly | Megállapítás | Javítás | Munka |
|---|---|---|---|---|
| QA-1 | Közepes | A README elavult (állapot-tábla, „Turbo mód következő lépés”, nem említi a Pénzügyeket, Wallet-et, időjárást, Beosztást; hivatkozik a nem létező `secrets.example.json`-ra) ✔ | README + CHANGELOG + rövid architektúra-ábra + üzemeltetési útmutató („Mit tegyek, ha…”) | S |
| QA-2 | Alacsony | Nagy fájlok: `assistant_service.dart` 929, `event_editor.dart` 875, `finance_tabs.dart` 782, `settings_page.dart` 723, `shift_page.dart` 653 sor ✔ | szétbontás csak az érintett területeken (nem külön kör) | M |
| QA-3 | Közepes | Teszthiányok: hibás RRULE, valós Google-JSON, fiókváltás, lefagyott kérés, kimerült újrapróbálás, Windows-életciklus, nagybetűs golden; flaky/valós idejű várakozások | lásd REL-28; minden javításhoz regressziós teszt | folyamatos |
| QA-4 | Közepes | CI-ben nincs lefedettség-jelentés, formázás-ellenőrzés, függőség-/titokellenőrzés; a release nem függ a tesztektől | A3. kapuk | S–M |
| QA-5 | Info | Nincs telemetria/összeomlás-napló (szándékos adatvédelem) → a helyi diagnosztika (REL-22) pótolja | — | — |

### B7. Ellenőrizve rendben van
- Titkok: biztonságos tárolóban (OAuth, LLM-kulcsok), fejlécben utaznak, 0 `print`/log/telemetria ✔; a repóban nincs titok.
- OAuth: loopback + PKCE + `state`; csak `calendar` és `drive.appdata`.
- Frissítő: https, idegen hosztra a token nélkül követi az átirányítást, kötelező SHA-256, zip-slip védelem, atomi csere + visszaállítás, csak újabb build, csak kézi indításra.
- Android: csak a launcher és a listener exportált (BIND-engedéllyel, csomag-engedélylistával), durva helyzet, `POST_NOTIFICATIONS` késleltetve.
- Szinkron: `appEventId` alapú idempotens outbox, lapozás, 410/412 kezelés, auth-lejárat felismerés; postaláda „alkalmaz-majd-töröl”, `fin-` fájlok kétszeres kizárása; ismeretlen Drive-mezők megőrzése.
- Idő: DST-szabály, 12 napos ciklus faliórán, hétfő első nap / ISO-hét, 42 cellás hónaprács, 31./szökőnap vágás.
- Tesztek: ≈ 405 app + 173 mag, széles a boldog ágakra.

### B8. Korlátok és ami kódból nem ellenőrizhető
- **Nem futtattam az appot**: a UX/hozzáférhetőség/teljesítmény megállapítások szerkezeti olvasásra és grep-re épülnek; a 3. fázis eleje képernyőképes bejárás.
- **Élő viselkedés (?):** Groq/Gemini tényleges token-számolás (TPM-ben számít-e a `max_tokens`, 413/`tool_use_failed`), a kivétel-példányok iCalUID/extended property öröklődése a Google-ben, Calendar 403 `reason` stringek és Retry-After, idegen syncToken státusza (400 vs 410), a Google a `WKST`-t kibocsátja-e, `calendar.app.created` működése naptárlista nélkül.
- **Eszköz (?):** a doze-késés, háttér-időzítők, az Auto Backup tényleges feltöltése, OneDrive-átirányítás, a valódi magyar Wallet-szövegek, `localhost` IPv4/IPv6 a Windowson.
- **Beállítások (?):** Google Cloud OAuth-képernyő állapota (Testing → 7 napos token), GitHub token hatóköre/lejárata, alapértelmezett `GITHUB_TOKEN` jog, secret scanning, installált GitHub App-ok, merged APK manifest, pub.dev advisory-k.

---

## C. FEJLESZTÉSI TERV

**Elvek:** kicsi, tesztelhető lépések; minden javításhoz regressziós teszt; minden fázis végén `[build]` commit → CI → Build → rövid „mit próbálj ki” lista; az ellenőrzési eredményeket a felhasználó jóváhagyása előtt nem merge-eljük. A PR #3 marad a gyűjtő, amíg jóváhagyod; utána fázisonként külön PR (a kijelölt ág a merge után a legfrissebb `main`-ről indul újra). **A terv jóváhagyása a 0. fázis megkezdésére szól;** minden fázis végén megállok a build + kipróbálási lista után, és a jelzésedre lépek tovább (kérheted, hogy menjek végig megállás nélkül is).

### 0. fázis – Azonnali javítások (1–2 build)
| Tétel | Mi | Fájlok (példák) | Teszt |
|---|---|---|---|
| SEC-13 | `isAuthExpired` csak HTTP 400 + `invalid_grant`; kijelentkezéskor revoke; belépési időkorlát | `sync_controller.dart`, `google_auth_service.dart` | 5xx/429 nem jelentkeztet ki; `invalid_grant` igen |
| SEC-2, SEC-11 | `baseUrl` csak `custom`; váltáskor törlés; https/LAN-szabály | `ai_providers.dart`, `ai_settings.dart`, `provider_catalog.dart`, `settings_page.dart` | régi custom URL nem szivárog Groq-ra |
| AI-12 | `copyWith` átadja `status`, `askWhy`, `habitSaved` | `ai_providers.dart` | várakozási szöveg látszik |
| AI-15, SEC-12, AI-7 | törlés/áthelyezés csak `edit` szándékkal; alapból kijelöletlen; ≤ 20 tétel, [most, +60 nap]; Cf/C1/bidi szűrés | `assistant_service.dart`, `assistant_models.dart`, `assistant_context.dart`, `ai_providers.dart` | hostile cím nem hoz törlés-kártyát |
| SEC-8 | kapcsoló-tudatos, szűrt szabály-visszajelzés | `rules.dart`, `assistant_service.dart` | kikapcsolt forrás → 0 cím a kérésben |
| SEC-5, REL-6 | `allowBackup=false` + `dataExtractionRules`; telepítés-azonosító a DB-n kívül | `AndroidManifest.xml`, `res/xml/`, `record_repository.dart` | manifest-ellenőrzés; azonosító-teszt |
| SEC-7, REL-24 | Wallet: Kotlinban maszkolás/rövidítés, TTL, auto-off → ürítés; nyugtázásos drain | `WalletNotificationListener.kt`, `wallet_ingest.dart`, `wallet_parser.dart` | bővített maszk-minták; összeomlás nem veszít |
| REL-1 | RRULE-normalizálás az éleken + eseményenkénti try/catch + „N hibás esemény” sáv | `recurrence.dart`, `rrule_convert.dart`, `ics.dart`, `event_repository.dart`, nézetek | `WKST=SU` import/pull: a többi esemény látszik |
| REL-3 | ~30 s időkorlát minden Calendar/Drive hívásra; `syncNow` koaleszcencia | új `sync/timeout_client.dart`, `sync_controller.dart` | lefagyó hamis kliens → nem blokkol |
| REL-4 (minimum) | a tükörtörlés csak az ablakon belüli eseményekre; tömeges törlés védelme | `sync_engine.dart` | 410 után a régi események megmaradnak |
| REL-5 | `known` tisztítás nem aktív társra | `finance_mailbox.dart` | visszatérő társ teljes pillanatképet kap |
| SEC-1, SEC-18 | release csak `main`/`v*`; más ág prerelease; Flutter-pin; CI kulcs nélkül hiba; `permissions` | `build.yml`, `ci.yml`, `build.gradle.kts` | CI-futás ellenőrzése |
| QA-1 | README/CHANGELOG frissítés | `README.md` | — |

*Kimenet a felhasználónak:* a beállítások (D. rész: OAuth „In production”, GitHub Environment) és egy rövid kipróbálási lista.

### 1. fázis – Megbízhatóság és adatbiztonság (2–3 build)
- **1a – szinkron:** REL-4 (fiók-/naptárkötés, „Szinkron alaphelyzetbe”), REL-7 (osztályozás, backoff, Retry-After, próbaszám-nullázás, determinisztikus kliens-azonosító), REL-2, REL-10, REL-11, REL-12, REL-8 (adaptív intervallum), REL-9, SEC-16 (bélyeg lefogás).
- **1b – adatréteg:** REL-13…REL-18 (import-korlátok, tranzakciók, verziókapu, biztonságos migráció + DB-másolat, tombstone-takarítás, indexek), REL-19 (terv-aláírás + diff; opcionális pontos riasztás), REL-20, REL-21, SEC-6 + REL-25 (DB-út `%LOCALAPPDATA%`, egypéldányosság).
- **1c – diagnosztika:** REL-22: gyűrűs naplófájl, `Diagnosztika` oldal (utolsó hibák, függő sor és kimerült elemek, kérésszámláló, verzió, „Másolás/Mentés”), magyar hibakatalógus (UX-5).
- Tesztek: hamis HTTP hibainjektálás (lefagyás, 5xx, quota, 410, fiókváltás), v1–v3 migrációs fixture-ök, régi×új formátum, valós Google-JSON fixture-ök, óraeltérés.

### 2. fázis – AI: token és adat takarékosság (3–4 build)
- **2a – méret:** AI-2 (prompt-diéta, egyetlen forrás, kézikönyv-átírás AI-20), AI-8 (cache-barát sorrend), kompakt adatkódolás, scope-szerinti eszköz-részhalmaz, AI-21/AI-25. Cél: terv-kérés ≈ 3,0 k.
- **2b – robusztusság:** AI-3, AI-4 (csonkolás-kezelés, részleges mentés), AI-10, AI-11 (újrapróbálás, határidő, Mégse), AI-13 (presetek, paraméter-tartalék), AI-24.
- **2c – mérés és átláthatóság:** AI-9 (token-napló, utolsó kérés költsége, becslés), „mit küldünk” előnézet, SEC-9 (beleegyezés-ablak, kézikönyv-kapcsoló), AI-17 (adatminimalizálás), AI-22.
- **2d – szabálymotor és kapuk:** AI-5 (nehézség kódból), AI-6, AI-19 (alvás intervallumként, műszakból levezetve), AI-14 (scope), AI-18 (időjárás-cache + párhuzamos + eszköz), AI-16 (újra-validálás + visszavonás), AI-23 (helyi válasz).
- Tesztek: token-méret határérték-tesztek (a prompt nem nőhet a keret fölé), 50 elemes injekciós korpusz, tulajdonság-alapú tesztek a `validateProposal`-ra, scope-táblázat tesztek (ékezet, tagadás, vegyes kérés).

### 3. fázis – Kezelhetőség és hozzáférhetőség (3 build)
Először: képernyőképes bejárás a fő feladatokra (a felhasználóval), utána UX-1 (navigáció), UX-2 (visszavonás), UX-3 (keresés, napirend, gesztus, húzás), UX-4 (billentyűparancsok + súgó), UX-6/7 (Beállítások csoportok, első indítási lista), UX-8 (Semantics, nagy betű, golden képek), UX-9/10/11 (téma, ablak, haladás).

### 4. fázis – Plusz funkciók (csomagonként 1–2 build)
**Kiválasztva az első körbe: A, B, C, D, E, F. A G és H későbbre marad.** Belső sorrend: 4.1 F + A (adatbiztonság és Windows) → 4.2 B → 4.3 E → 4.4 C → 4.5 D. Az A–F mind az 1b (biztonságos migráció, tranzakciók, diff-alapú emlékeztető) után indul.

| Csomag | Tartalom | Érték | Munka | Függ |
|---|---|---|---|---|
| A | **Windows emlékeztetők**: értesítés + tálca + automatikus indítás (amíg fut az app) | magas (jelenleg nincs) | M | 1b |
| B | **Napi összefoglaló** értesítés (események, időjárás, feladatok) + **magyar ünnep-/munkanap-naptár** (offline táblázat, áthelyezett munkanapokkal) + **Android főképernyő-widget** (mai események, következő műszak) | magas | M–L | 1b |
| C | **Edzésnapló és haladás** (megcsináltam / kihagytam, heti volumen), **check-in trendek** (energia, hangulat, alvás grafikon), heti összefoglaló | közepes–magas | M | 2d |
| D | **Pénzügy+**: hónap-/évtrend grafikon, CSV-export, bank-CSV import (OTP/K&H/Erste/Revolut formátumok), keret-túllépés értesítés, előfizetés-felismerés, többpénznem (EUR utazáshoz), műszakpótlék-/bérbecslés a beosztásból | magas | L | 1b |
| E | **Gyors felvitel** szövegből (helyi értelmező: „holnap 18:00 edzés”), Androidon hangbevitel; feladat: részfeladat, ismétlődő feladat | közepes | M | 3 |
| F | **Automatikus mentés**: forgó helyi + titkosított Drive-mentés, visszaállítási előnézet | magas (adatbiztonság) | M | 1b |
| G *(későbbre)* | **Zár és titkosítás**: alkalmazászár (biometrikus), `FLAG_SECURE`, titkosított DB, Drive-boríték | közepes | M–L | 1b |
| H *(későbbre)* | **Helyi tartalék-tervező** (szabad idősáv + szabályok + sportforgás, LLM nélkül, ha a limit elfogyott), majd heti automatikus terv | közepes | L | 2d |

**Csomag-megjegyzések (kockázat, függés):**
- **A – Windows emlékeztetők:** a `flutter_local_notifications` Windows-ütemezése nem biztos; a munka elején rövid megvalósíthatósági próba. Ha nem megy, alkalmazáson belüli időzítő + Windows-toast (csak amíg fut). Tálca-ikon + automatikus indítás beállításban kapcsolható, alapból ki. Az „emlékeztető csak futó appnál megy” korlátot a felületen ki kell írni.
- **B – Napi összefoglaló + ünnepnapok + widget:** az ünnep-/áthelyezett munkanap-táblázat beépített (2026–2028), évente az app-kiadással frissül (a hivatalos rendelet nem kérdezhető le ingyen, kulcs nélkül megbízhatóan: ellenőrizendő). A widget natív Kotlin (`AppWidgetProvider`), az adat SharedPreferences-en át megy; a Kotlin-fordítást a CI ellenőrzi.
- **C – Edzésnapló és trendek:** új tábla (séma v5, az 1b biztonságos migrációjára épül) + Drive-rekord szinkron a meglévő `DriveSyncEngine`-nel; check-in trend-grafikon saját rajzolóval (nincs új csomag).
- **D – Pénzügy+:** a bank-CSV importhoz bankonként 1–1 anonimizált minta kell; minta nélkül csak általános oszlop-megfeleltető varázsló készül. Többpénznem és bérbecslés a beosztás adataiból (pótlék-szabályok a felhasználótól).
- **E – Gyors felvitel szövegből:** helyi magyar idő-/dátumkifejezés-értelmező (≈ 100 mondatos tesztkorpusz), bizonytalan eredménynél megerősítő előnézet; Androidos hangbevitel külön kapcsoló mögött.
- **F – Automatikus mentés:** a kulcskezelés (jelszó vagy QR) közös alap a SEC-16 borítékkal; visszaállítási előnézet a REL-13 „újabb nyer” szabályával.

### 5. fázis – Kompatibilitás, kiadás, karbantarthatóság (2 build)
CMP-1…7, SEC-3 (Ed25519-aláírt frissítés – döntés szerint), SEC-4 (marad a privát repó + token; lejárat-emlékeztető és a token cseréjének leírása), SEC-10 (hatókör szűkítése – élő ellenőrzéssel), SEC-14/15, QA-2…4 (CI-kapuk A3 szerint, lefedettség, szétbontás az érintett fájloknál), kiadási csatornák (stabil / előzetes), dokumentáció és döntési napló.

### Elfogadott sorrend (a felhasználó döntése)
**0 → 2 → 1 → 3 → 4 → 5.** Indok: a 0. fázis a legolcsóbb kockázatcsökkentés; a 2. fázis hat a mindennapi használatra (Groq-keret, megbízhatóbb javaslatok); az 1. fázis ritka, de adatvesztő eseteket zár; a 3. és 4. fázis a kényelem és a bővítés; az 5. a hosszú távú rend.

---

## D. Teendők tőled
1. **Google Cloud Console → OAuth consent screen / Audience → Publishing status: „In production”** (különben 7 naponta lejár a bejelentkezés). Kulcsot/titkot ne küldj.
2. **GitHub:** Settings → Code security → *secret scanning* + *push protection* be; *Environments* → `release` (kötelező jóváhagyó: te) és az aláíró/frissítő titkok áthelyezése oda; ellenőrizd az `UPDATE_TOKEN` hatókörét (csak ennek a repónak *Contents: read*) és **jegyezd fel a lejáratát** (lejárata után a frissítő megáll, kézi telepítés kell); az `android-keystore.yml` törlése, *miután* a keystore titkosított offline másolata megvan.
3. **Wallet-értesítés minták** (2–3 db) a Beállítások → Wallet → Legutóbbi értesítések → Másolás gombbal.
4. A PR #3 funkcióinak kipróbálása (törlés/áthelyezés, feladat-ütemezés, tanult szokások, műszak-szerkesztés, .ics mentés, időjárás/GPS, Pénzügyek, postaláda a telefon és a PC között), majd jóváhagyás a merge-hez.
5. Mondd meg, milyen Android-eszközök/verziók vannak (CMP-2), és hogy a Dokumentumok mappa OneDrive-ra mutat-e a PC-n (SEC-6).
6. **Pénzügy+ (D csomag), a 4. fázis idején:** ha a bank-CSV import kell, 1–1 anonimizált mintafájl a használt bank(ok) exportjából (dátum/összeg/leírás oszlopok elég, nevek és számlaszámok nélkül). Értesítés-szöveg minták a Wallet-hez (3. pont) ugyanide tartoznak.

## E. Döntések (rögzítve)
1. **Frissítés (SEC-3/4):** marad a privát repó + csak olvasó token, és bekerül az Ed25519-aláírás.
2. **Plusz csomagok az első körbe:** A (Windows emlékeztetők), B (napi összefoglaló + ünnepnapok + widget), C (edzésnapló + check-in trendek), D (Pénzügy+), E (gyors felvitel szövegből), F (automatikus mentés). G (zár és titkosítás) és H (helyi tartalék-tervező) későbbre.
3. **Sorrend:** 0 → 2 → 1 → 3 → 4 → 5.
4. **Még nyitott, nem blokkoló:** Windows tálca-ikon + automatikus indítás (alapértelmezés: beállításban kapcsolható, alapból ki); bank-CSV formátumok (1–1 anonimizált minta kell a használt bankodtól).

## F. Nem cél
Windows-kódaláírás (korábbi döntés), saját szerver / „turbo mód”, iOS/macOS/Linux, többnyelvűség, Play Store.

## G. Ellenőrzés (minden fázisra)
- Mag: `cd packages/kvantum_core && dart analyze && dart test`; app: `cd apps/kvantum_app && flutter analyze && flutter test` – mind zölden, új regressziós tesztekkel (a fázis táblái szerint).
- `[build]` commit → CI zöld → a Build Windows + Android csomagja elkészül (Android: Kotlin/manifest miatt kiemelten); PR frissítése.
- A fázis kézi listája (A2 megfelelő része) a felhasználónak; élő modell-, Google- és eszköz-viselkedést csak ő tud kipróbálni, ezt minden fázis végén külön kimondom.
- A fázis akkor kész, ha: a hozzá tartozó mérőszám (A4) teljesül vagy a hiány okát leírtam, és semmi nem romlott a meglévő tesztekben.

---

## H. VÉGREHAJTÁSI NAPLÓ

### 0. fázis (azonnali javítások) – kész, a build után kipróbálandó

Tesztek: mag 194 (volt 173), app 441 (volt 405), az elemzők tiszták. Minden javításhoz regressziós teszt készült; az új tesztek a javítás nélküli kódon elbuknak (ellenőrizve).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| SEC-13 | kész | `isAuthExpired` csak `invalid_grant`; a bejelentkezés 10 perc után feladja és jelzi, ha a böngésző nem nyílt meg. **Nem készült el:** a kijelentkezéskori token-visszavonás (`/revoke`): nem tudni, a másik eszköz belépését is érvényteleníti-e, élő ellenőrzés kell. |
| SEC-2, SEC-11 | kész | cím csak „Egyéni” szolgáltatónál; `https` kötelező, kivéve saját gép/hálózat (figyelmeztetéssel); használatkor is ellenőrzi |
| AI-12 | kész | a várakozási állapot és a „miért” kártya jelzői is megmaradnak `copyWith`-nél |
| AI-15, AI-7, SEC-12 | kész, eltérésekkel | törlés/áthelyezés csak kifejezett kérésre; ≤ 20 javaslat; [most, +60 nap]; Cf/C1/bidi/hasonmás-zárójel szűrés, azonosítók szűrése. **Eltérés a tervtől:** a javaslatok előre kijelöltek maradtak (kényelem; a darab- és időkorlát védi), és a „≤ 2/nap” korlát elmaradt (a feladat-ütemezést tévesen tiltaná). |
| SEC-8 | kész | a modellnek szánt visszajelzés kapcsoló-tudatos és tisztított |
| SEC-5 | kész | `allowBackup=false` + `dataExtractionRules` |
| REL-6 | részben | a fő kiváltó ok (mentés-visszaállítás) lezárva; a telepítés-azonosító DB-n kívüli tárolása későbbre marad (kézi DB-másolat esete) |
| SEC-7, REL-24 | kész, eltéréssel | kikapcsolt automatikus felvételnél a sor ürül; ≥ 11 számjegyű számok a sorba tétel előtt maszkolódnak (Kotlin); nyugtázásos kiolvasás; erősebb naplómaszk. **Eltérés:** az elavulási idő 30 nap (a terv 14-et írt), hogy a ritkán megnyitott app fizetései ne vesszenek el. A Kotlin-kód fordítását csak a CI ellenőrzi. |
| REL-1 | kész | tűrő `parseRule` (`WKST`), eseményenkénti védelem, „Nem olvasható ismétlődés” sáv |
| REL-3 | kész | 30 s válasz- és 30 s tétlenségi határidő minden Google-hívásra; egyszerre egy szinkron, a közben érkezők egy követő futásba olvadnak |
| REL-4 (minimum) | kész | az időablak előtti, helyi történet nem törlődik újraszinkronnál; a fiók-/naptárkötés az 1. fázisban |
| REL-5 | kész | |
| SEC-1 | részben, a CI-oldal visszavonva | az appban kész a kapcsoló az előzetes verziókhoz. A munkaági build előzetes kiadássá tétele elkészült, de **visszavontam**: a Build 34 kiadása 403-at kapott (lásd lent). **Marad a felhasználónak:** GitHub Environment a titkokhoz (D. rész 2.). |
| SEC-18 | elhalasztva | a Flutter 3.47.9 rögzítése, a `permissions` és a `concurrency` elkészült, de a workflow-fájlok visszaálltak a `main` változatára (lásd lent). Elmaradt: Actions SHA-pin (hálózat kell a feloldáshoz), Gradle `distributionSha256Sum`; a debug-kulcsos visszaesés a CI-ben nem kerül kiadásba (`SIGNED` kapu), ezért a Gradle-t nem módosítottam. |
| QA-1 | kész | README, CHANGELOG, ez a dokumentum; a `secrets.example.json` mostantól követett (a `.gitignore` nem rejti el) |

**Átállás az előzetes csatornára:** a 0. fázis buildje még „latest” kiadásként jelenik meg (hogy a mostani app megtalálja). Ezután a munkaági buildek előzetesek; a Frissítés ablakban az „Előzetes verziókat is keressen” kapcsoló alapból BE van, így a tesztelés ugyanúgy megy.

### A Build 34 kiadási hibája (403)

A Windows- és az Android-build is sikeres volt (a Kotlin-kód lefordult, az APK aláírt), de a **kiadás lépése** `Resource not accessible by integration` (403) hibával elbukott, kétszer is (újrafuttatva is). A token jogai (`Contents: write`), a runner és az action-verzió megegyezett a sikeres Build 33-éval. Az egyetlen különbség: ez volt az első build, amelynek workflow-fájljai (`build.yml`, `ci.yml`) eltértek a `main`-étől; a korábbi munkaági buildeké azonos volt, és a `main`-en a build-13 (amely a workflow-fájlokat adta a `main`-hez) sikerült. **Az ok nem bizonyított**, de a munkaág workflow-fájljait visszaállítottam a `main` változatára, és a következő build ezzel indul.

**Tanulság:** a workflow-fájlok módosítását külön lépésben kell a `main`-be juttatni (külön PR, `[build]` nélkül), és csak utána szabad rájuk épülő munkaági buildet indítani. A CI-szigorítás (előzetes csatorna, Flutter-rögzítés, jogosultságok) ezen az úton jön vissza.

### 2a (kisebb asszisztens-kérés) – kész, a build után kipróbálandó

Tesztek: mag 216 (volt 194), app 469 (volt 441), az elemzők és a formázás tiszták. A mérés a `test/token_budget_test.dart`-ban fut (rögzített mintanaptár, a ténylegesen mellékelt kézikönyv, 3 karakter = 1 token). Az új tesztek 12 szándékos elrontással (más sorrend, minden kérés ugyanazt az eszközlistát kapja, a törlés is a teljes kézikönyvet kapja, hivatkozás a tervezésben, a régi alapszöveg „testreszabott” marad, a feladat-alias nem fejtődik vissza, az alapértékek kiíródnak, az időjárás-sor mindig kiír mindent …) próbára téve: mindegyiket elkapják.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| AI-2, AI-20 | kész | a kézikönyv alapszövegei átírva, ismétlés nélkül; `compactHandbook` kiszedi a sablonsorokat; régi alapszövegek felismerése (SHA-1) |
| AI-8 | kész | nincs óra a rendszerpromptban; adat → idő → kérés |
| AI-14 (rész) | kész | eszközök a kérés fajtája szerint; a hatókör-felismerés javítása (ékezet, tagadás, vegyes kérés) a 2d-ben marad |
| AI-21, AI-25 | részben | a tömör alak mindenhol; a „cím csak műszak/AI/egész napos esetén” és a tanult szokások korlátja a 2c/2d-ben |
| token-cél | teljesült, becsléssel | terv ≈ 3,0 k (cél ≤ 3,2 k), törlés ≈ 1,4 k (cél ≤ 2,2 k), állandó rész ≈ 2,0 k (cél ≤ 2,3 k), pénz ≈ 0,5 k. A „pénz helyi válasz = 0” a 2d-ben jön. |
| **Eltérés a tervtől** | | A rendszerprompt a kérés fajtája szerint három változatú (terv / törlés-áthelyezés / pénz); a terv azt írta, hogy minden kérésnél bájtra azonos. Azonos fajtájú kérések között az (cache-barát), a különböző fajták között nem; a törlés és a pénzügyi kérdés így lényegesen kisebb. |

### 2b (robusztusság) – kész, a build után kipróbálandó

Tesztek: mag 220 (volt 216), app 540 (volt 469), az elemzők és a formázás tiszták. 29 szándékos elrontás (nincs újrapróbálás, nincs határidő, a megszakítás nem hat, a csonka válasz javítókörbe megy, a hivatkozás-hiba nem megy vissza, nincs paraméter-tartalék, nincs 413-felismerés, a kliens nem zár, a kulcs nem redaktálódik, a Mégse után is elmegy a kérés …) mindegyikét elkapják a tesztek; két hiányt ez a próba hozott felszínre és javítottam (a modell-felderítés alatti Mégse hamis hibaüzenetet adott volna; a feldolgozás közbeni Mégse után egy kérés még elindulhatott).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| AI-4 | kész | csonka tool-hívás → érthető üzenet, nincs vak javítókör; Gemini `maxOutputTokens` (4096; a terv 2048-at írt, a „gondolkodás” is beleszámít, az túl szűk lett volna). A csonka JSON töredékének mentése (a teljes tételeké) **nem készült el**: a hibátlan tételek csak akkor maradnak meg, ha a hívás ép JSON volt; félbeszakadt JSON-nál üzenet jön. |
| AI-3 | kész | a visszajelzés a törlés/áthelyezés parse-hibáit is tartalmazza; javítható hivatkozás-hibánál (érvénytelen, nem található, ütközés) a hátralévő javítókörökig visszamegy a modellhez, elutasításnál nem |
| AI-10 | kész | 413 / „request too large” / context length → `LlmTooLarge`, egyszeri szűkített újrapróbálás (≤ 4 nap, csak események); `tool_use_failed` / `MALFORMED_FUNCTION_CALL` ugyanígy; paramétert nevező 400 → egyszeri (legfeljebb kétszeri) újrapróbálás a paraméter nélkül, modellenként megjegyezve |
| AI-11 | kész, eltéréssel | 2 újrapróbálás 1,5 s és 4 s múlva; **teljes határidő 90 s**; Mégse gomb, az oldal elhagyása is megszakít. **Eltérés:** a 500 és 529 is újrapróbálandó (a terv 502/503/504-et írt), a „nincs kapcsolat” nem |
| AI-13 | kész | a katalógus presetjei: hőmérséklet 0,2, válaszkorlát (Groq 2048, a többi 4096), `reasoning_effort` a Groq gpt-oss-hoz; a `tokenBudget` a 2c-ben jön, ahol használjuk |
| AI-24 | részben | közös HTTP-réteg (`llm_http.dart`: redakció, hibatérkép, JSON-kezelés), kérésenként egy kapcsolat, bezárva. A modell-tartalék lista (más szolgáltatókra) nem készült el. |

### 2c (mérés, átláthatóság, adatminimalizálás) – kész, a build után kipróbálandó

Tesztek: mag 226 (volt 220), app 588 (volt 540), az elemzők és a formázás tiszták. 24 szándékos elrontás (a költség nem összegződik, a hívás nem kerül a naplóba, a szolgáltatók összekeverednek, nincs költségvetés-őr, rossz sorrend, a haszontalan lépés is kiíródik, az előnézet nem szűkít, a feladatok nem sürgősség szerint, a címek / a check-in megjegyzés / a hely neve visszakerül, a kérés nem tisztított, a visszajelzés elárulja a címet, a Kézikönyv-kapcsoló nem hat, nincs beleegyezés-ablak, az elutasítás is elmenti a kulcsot, nincs 500 karakteres korlát, nincs „Utolsó kérés” sor, nincs előnézet-panel …) mindegyikét elkapják a tesztek (egy elrontást csak a magtesztek fogtak meg, a másik tesztfájl-választás volt a hiba). A tesztek közben egy valódi hibát találtak: az előnézet `setState`-je egy `Future`-t adott vissza (debug módban kivétel).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| AI-9 | kész | szolgáltatónként / modellenként / naponként tokenek (be, ki, gondolkodás, gyorsítótár); csak a megválaszolt hívás számít; Beállítások-sor és „Utolsó kérés” sor; becslés „≈”-jellel, ha a szolgáltató nem közöl számot |
| előnézet | kész | `AssistantService.preview` + összecsukható panel; ugyanaz a `_prepare`, mint a valódi kérésé (teszt: az előnézet = az elküldött); frissítés gombbal (időzítő nélkül) |
| költségvetés-őr | kész | `ProviderInfo.tokenBudget` (Groq 5 500, többi 20 000); sorrend: időjárás, szabad idősáv, 8 legsürgősebb feladat, ablak 14→7→4, Tanult szokások; csak a ténylegesen spóroló lépés kerül a jelzésbe |
| SEC-9 | kész | beleegyezés-ablak az első kulcs mentése előtt, szolgáltatónként egyszer; Kézikönyv-kapcsoló; a pénzügy alapból BE (a te döntésed). **Nem kérdez** a már mentett kulcsoknál. Szolgáltatói feltételekről általános figyelmeztetés, konkrét állítás nélkül. |
| AI-17 | kész | pénz: nincs egyes tétel az alap blokkban; check-in megjegyzés ki; hely neve ki |
| AI-21 | kész, finomítva | tervezésnél a kézzel felvett rövid esemény címe „foglalt”; **eltérés a tervtől:** a ≥ 4 órás események címe megmarad (utazás, konferencia: a „hosszú utazás napján nincs edzés” szabályhoz kell) |
| AI-22 | kész | a kérés ≤ 500 karakter (mező + szolgáltatás), a kérés szövege tisztítva megy |
| AI-23 | 2d | a kikapcsolt forrás helyi válasza a 2d-ben |


### 2d (szabálymotor, hatókör, helyi válaszok) – kész, a build után kipróbálandó

Tesztek: mag 335 (volt 226), app 627 (volt 588), az elemzők és a formázás tiszták. 33 szándékos elrontás (a 60 perc nem nehéz, a könnyű cím nem könnyű, a műszak-puffer csak a nehézre, a check-in nélküli nap 0 energia, az alvás csak a kezdetet nézi, a heti plafon és a 48 óra nem számolja a naptárban lévőt, a tagadott ige is kérés, az ékezet nélküli kérés nem érthető, a költözés pénz, nincs vegyes kérés, a helyi felismerés túl tág, rossz összeg a költségkeretben, nincs időjárás-gyorsítótár, nem párhuzamos az előrejelzés, a helyi válasz a kapcsoló nélkül is a modellhez megy …) mindegyikét elkapják a tesztek.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| AI-5 | kész, **döntéssel** | a nehézség kódból: 60 perctől (a „könnyű / nyújtás / mobilitás / séta” cím mindig könnyű; a modell `hard` jelzése egy szavazat); a műszak-puffer minden ≥ 45 perces edzésre. **Döntés:** check-in nélküli nap = 3/5 feltételezés (`PlanRules.assumedEnergy`) – a régi „check-in nélkül csak könnyű” a 60 perces nehézséggel minden jövő napot kizárt volna; a minimum emelésével visszajön |
| AI-6 | kész | a naptárban lévő edzések (cím-alapú felismerés, a `kind` megkerülése ellen is) beleszámítanak a heti plafonba és a 48 órába; a lekérdezési ablak az ISO-hetekre és ±2 napra bővült |
| AI-19 | részben | az alvás intervallum-átfedéssel; a műszakból levezetett alvás (éjszakás műszak után) nem készült el |
| AI-14 | kész | `scopeFor` v2: ékezet nélkül, tagadás, hamis találatok (költözés, fizetésnap, törölköző, „mozgás”), megnevezett nap szűkíti az ablakot, a kérdés csak az eseményeket kapja, vegyes kérés (`AskScope.plan`). 60 mondatos táblázatos teszt |
| AI-18 | kész, eltéréssel | előrejelzés-gyorsítótár (3 óra) + az adatbetöltéssel párhuzamos lekérés; **eltérés:** a `get_weather` eszköz nem készült el (a validátor kóddal úgyis ellenőrzi a szabadtéri tételeket, az eszköz minden tervkérésnél további tokeneket költene) |
| AI-23 | kész | kikapcsolt forrásnál a program rögtön magyarázza, mit kapcsolj be (pénzügyi kérdés kikapcsolt pénzügynél; törlés / áthelyezés kikapcsolt eseményeknél) |
| helyi válaszok | kész | költségkeret és napirend modell nélkül, teljes mondatra horgonyzott mintákkal; jelölt kártya + „További kérdés”; a helyi válasz szövege csak engedélyezett forrásnál kíséri a további kérdést |
| AI-16 | nincs a 2d-ben | az újra-validálás + visszavonás a jóváhagyott 2d tervnek nem része; a 3. fázisban (UX-2 visszavonás) jön |

### 2e (edzés utáni visszajelzés és tanulás) – kész, a build után kipróbálandó

Tesztek: mag 417 (volt 335), app 693 (volt 627), az elemzők és a formázás tiszták. 31 szándékos elrontás (a címek ékezettel olvasódnak, nincs sportkulcs, a szigorítás küszöbe vagy a mintaszám rossz, a sáv széle rossz, jóváhagyás nélkül lazít, az új nehéz visszajelzés nem veszi vissza az igent, a „nem” nem jegyződik meg, az energia-sor újra `>` jelet használ, a kihagyott alkalom is tanít, a tanult határ nem számít a javaslatnál / a naptárban lévő edzésnél / a promptban, az új rekordfajta nem szinkronizálódik, a műszak / a régi / a megválaszolt edzésre is rákérdez, a „Később” nem hat, az „igen” nem írja a szokást, az üres űrlap mentődik, az időzítő nem áll le, visszatéréskor nem néz újra, a skála-feliratok kilógnak …) mindegyikét elkapják a tesztek.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| edzés-visszajelzés (a felhasználó kérése) | kész | új szinkronizált rekordfajta `workoutlog` (nincs új helyi tábla); sáv a főoldalon + űrlap öt skálával; a Beállításokban kapcsolható; a Drive fájlnév-mintája egyetlen forrásból jön (`syncedKinds`), eddig négy helyen volt beégetve |
| AI-5 (nehézség kódból) folytatása | kész | a határokat a felhasználó visszajelzései finomítják: szigorítás magától (45–59 perces típus, legutóbbi 3 alkalom ≥ 4/5), lazítás csak jóváhagyásra (60–89 perces típus, legutóbbi 5 alkalom ≤ 2/5 → „Tanult szokások” jelölt sor, 90 percig könnyű); az új nehéz visszajelzés visszaveszi |
| AI-9/AI-17 kapcsolat | kész | a modell az utolsó 10 visszajelzés rövid sorait kapja (≈ +175 token); cím és megjegyzés soha; a Napi check-in kapcsolóval együtt kapcsol; a költségvetés-őr a Tanult szokások előtt hagyja el |
| UX-8 (hozzáférhetőség) – részben | részben | a napi check-in űrlap skála-feliratai kilógtak volna nagy betűnél / keskeny képernyőn: javítva, tesztelve (a check-in sávnak és űrlapnak eddig nem volt tesztje). A nagy betű / Semantics / golden körút a 3. fázisban jön |
| ikertelenség / eltérések | – | **Eltérés a tervtől:** a kérdés a „legutóbb véget ért” edzésre szól (nem egy listára), mert a kártya egyszerre egy kérdést tesz fel; a nem-kötelező megjegyzés nem megy a modellhez; a tanulás a *legutóbbi* 3 / 5 alkalmat nézi (nem a teljes sáv átlagát), mert különben a régi könnyű alkalmak elnyomnák az új nehezeket |

### 1a (a szinkron a hibákat az okuk szerint kezeli) – kész, a build után kipróbálandó

Tesztek: mag 422 (volt 417), app 865 (volt 693), az elemzők és a formázás tiszták. 61 szándékos elrontás (a használati korlát újra végleges hiba, az átmeneti hiba elhasználja a próbát, nincs parkolás / kézi nullázás / feltöltés-plafon / szünet, bármely fiókot elfogad, eltérésnél mégis szinkronizál, a távoli törlés elnyeli a helyi szerkesztést, az örökölt azonosító felülírja a sorozatot, a várakozó törlés visszajön, a régi etag visszakerül, sima felülírás az összefésülés helyett, hibás visszalépés / Retry-After / korlát, a háttérben is fut az időzítő, a postaláda mindig vagy soha, az alaphelyzet nem vág kapcsolatot / nem nulláz / nem sorol, az óra-bélyeg …) mind elbukik a tesztekkel.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| REL-7 (osztályozás, visszalépés, Retry-After, próbaszám) | kész | `sync/api_errors.dart`: a 403-as használati korlátok / 429 / 5xx átmeneti, a tétel-hiba külön; `sync/retry_after_client.dart` kinyeri a fejlécet; a motor az átmeneti hibával nem fogyasztja a próbát, a tétel-hiba 5 után „feladott”, a kézi szinkron nulláz; `sync/sync_pacer.dart`: 1→2→4→8→15 perc ±20 %, napi keret ≥ 30 perc, soha nem hamarabb, mint a szerver kéri. **Eltérés:** nincs determinisztikus Google-azonosító (nem ellenőrizhető élőben), helyette ütemezés (200 ms) és futásonként ≤ 150 feltöltés |
| REL-8 (kevesebb lekérdezés) | kész | egyszeri időzítő a periodikus helyett; tétlenül 3→5→10 perc; háttérben nincs időzítő; a postaláda a Drive-jelzésre / saját módosításra / minden 5. futásnál / kézi kérésre |
| REL-4 (fiók-/naptárkötés, alaphelyzet) | kész | `RemoteCalendar.identity` (az elsődleges naptár azonosítója = a fiók címe, extra jogosultság nélkül), `sync.binding` meta, `SyncBindingMismatch` → semmi nem húz/tölt/töröl; három kimenet; „Szinkron alaphelyzetbe…” |
| REL-2 (kivétel-példány) | kész | a `reconcile` példány-szabályai (a sorozat azonosítói nem párosítanak), ütközés-őr az új sor azonosítójánál |
| REL-10 (lehúzás-izoláció) | kész | eseményenkénti try/catch, `PullResult.skipped`, eltűnt naptár (`CalendarGoneError`, a gyorsítótár ürül); a `timeMin` már a 0. fázisban egyszer számolódik |
| REL-11 (olvasás + összefésülés) | kész | `events.get` → saját mezők → `events.update` a friss `etag`-gel, 412-nél újraolvas; RDATE / EXRULE megmarad |
| REL-12 (törlés vs. szerkesztés, etag) | kész | a helyi szerkesztés nyer a távoli törlés felett; a lehúzás eseményenként tranzakció; `saveLocal` megőrzi a tárolt Google-kapcsolatot. **Nem készült:** a szerkesztő mezőszintű összefésülése (a felhasználó mentése egészében érvényes) |
| REL-9 (időbélyeg) | kész | `max(óra, felváltott+1)`; óraeltérés-észlelés a Diagnosztikához. **Eltérés:** SEC-16 (bejövő bélyeg lefogása) nincs – az eszközök eltérő lefogott értéket tárolnának, és a Drive-fájl oda-vissza íródna |
| UX-5 (magyar hibák) – első rész | részben | `sync/error_catalog.dart` a szinkron-állapotokra; a teljes katalógus és az „akció” gombok az 1c-ben |

### 1b (az adatréteg megbízhatósága) – kész, a build után kipróbálandó

Tesztek: mag 456 (volt 422), app 974 (volt 865), az elemzők és a formázás tiszták. 54 szándékos elrontás (az átállás nem egy egység / a visszafelé-„frissítés” őre / hiányzó index / nincs vagy túl sok mentés / a kampó és a fájlellenőrzés átengedi az újabb fájlt / az áthelyezés ellenőrzés nélkül, sorszám-összevetés nélkül, azonnali törléssel vagy a régi tisztítása nélkül / a Windows-hely; a kötegelt írások nem egy egység / a kettős eszköz-azonosító; az újabb levél, Drive-fájl, rekord és pénzügyi mentés törlése, felülírása, elfogadása; az .ics UNTIL és EXDATE oda-vissza, a hossz-, méret- és év-korlátok; a kérdés nélküli felülírás, a „csak az újak” felülír, a nagy fájl a képernyőszálon; az ismétlődés-átugrás napnyi hibája és a DST-időtartam, a szabály-gyorsítótár; az emlékeztető mindent újraütemez / nem töröl / nem mozdít / nem kapcsolja le a várakozást / nincs várakozás; a „ma” az eszköz napja / korai időzítő / nincs új időzítő / nem követi / nem frissít visszatéréskor; a takarítás: egy hónap, minden nap, marad a Drive-fájl, feltöltetlen jelölő törlődik, árva sorok, nem indul); a próba az adatbázis-megnyitó kampó „újabb fájl” elutasítása és az áthelyezés ellenőrzése (sorszám / séma-verzió / táblák) nem volt tesztelve – mindkettő kapott tesztet (ehhez a másolás cserélhetővé vált); a visszaállításnál a Google-kapcsolat külön másolása felesleges volt (a mentés megtartja), ezt egyszerűsítettem.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| REL-17 (migráció) | kész | tranzakciós `onUpgrade`; `from > to` → `NewerDatabaseError`; a nyers adatbázison futó `setup` kampó `VACUUM INTO` másolatot készít (`kvantum.sqlite.bak-v<régi>`, legutóbbi 2); indulás előtt `checkDatabaseFile`; magyar indulási képernyő. **Eltérés a tervtől:** nincs v5 – az indexek (`beforeOpen`, `IF NOT EXISTS`) séma-verzióváltás nélkül jönnek, ezért nincs mit visszaállítani és a `db.g.dart` sem változott |
| REL-18 (indexek, takarítás) | kész | 6 index; naponta egyszer, az első kép után: 365 napnál régebbi jelölők (rekordok a Drive-fájllal, pénzügy), a félbeszakadt törlések újrasorba állítása, árva sorbejegyzések. **Eltérés:** a Google-hivatkozású, sor nélküli törlést nem eldobja, hanem újra sorba állítja (a felhasználó törölt); a takarítás eredménye a meta táblában (`housekeepingLast`) |
| REL-14/15 (tranzakciók) | kész | `saveAll`/`deleteAll`/`atomically`; műszak-generálás, sorozat-törlés, szerkesztő, .ics import egy egység; a rekordok és a pénzügy olvas-módosít-ír tranzakcióban; `deviceId` memoizált és tranzakciós |
| REL-16 (verziókapu) | kész | rekord/levél `v`, `NewerFormatException`, az újabb levél és Drive-fájl megmarad, ismeretlen fajtájú levél tételeinek ismert része alkalmazódik; a pénzügyi mentés `version`; a szinkron-állapot jelzi |
| REL-13 (.ics) | kész | UNTIL oda-vissza, törölt előfordulás `EXDATE`-ként, korlátok (5 M karakter, 366 / 3 660 nap, 1970–2100), pufferelt összefűzés, előnézet + megerősítés, `Isolate` 200 000 karakter fölött. **Eltérés:** nincs „újabb nyer” (a fájlban nincs eseményenkénti idő) |
| REL-20 (ismétlődés-bővítés) | kész | időtartam egyszer, ablak előtti példányok zónaszámítás nélkül, korlátos szabály-gyorsítótár; a régi megvalósítás (`test/support/reference_expand.dart`) a referencia: 6000 véletlen összevetés mezőről mezőre azonos. **Nem készült:** a 20 000-es plafon jelzése (az 1c naplójába kerül) |
| REL-19 (emlékeztetők) | kész | `diffReminders` + `syncReminders`: az eszköz tényleges (függő) listájához képest csak a különbség; az idő a payloadban utazik; 1,5 s-es sűrítés (a várakozás a provider újraépülésekor lekapcsolódik) |
| REL-21 („ma”, zóna) | kész | `todayIn` + `todayProvider` (éjféli időzítő, előtérbe visszatéréskor frissít), a naptár / feladatok / check-in / pénzügy a megjelenítési zóna napját használja; `appClockProvider` a teszteknek (REL-28 első lépése) |
| SEC-6 / REL-25 (Windows) | kész, csak fordításig ellenőrzött | `%LOCALAPPDATA%\KvantumNaptar`, kétlépcsős áthelyezés ellenőrzéssel; elnevezett mutex (`Local\KvantumNaptar.SingleInstance`), az ablak előtérbe hozása, 3 s várakozás a frissítőre |
| CMP-1 / SEC-18 (rögzítetlen Flutter) – **tapasztalat** | részben | a CI `channel: stable` beállítása miatt a 3.50.0 (2026-11-09) megtörte az 1b első két buildjét (Android: AGP ≥ 9.1.1, Kotlin ≥ 2.4.10; elemzés: a Material-import elavult). **Javítva:** AGP 9.1.1 + Kotlin 2.4.10 (a Gradle 9.3.1 marad), `deprecated_member_use: ignore`. A Flutter ajánlott hármasával (9.3.1 / 2.4.20 / 9.5.0) a Build 60 Android-lintje összeomlott JDK 17 alatt (`List.removeLast()` csak JDK 21-ben van). **Beolvadt (PR #4, 2026-11-12):** a Flutter 3.50.0 / Dart 3.14.0 rögzítése és a `setup-java` 21 a workflow-kban (a merge-push nem épített; a feladatágon a `.github` újra azonos a `main`-nel). **Nyitva:** az ajánlott verziókra lépés (AGP 9.3.1 / Kotlin 2.4.20 / Gradle 9.5.0, a JDK 21 mellett); az áttérés a `material_ui`-ra (5. fázis) |

### 1c (diagnosztika) – kész, a build után kipróbálandó

Tesztek: mag 459 (volt 456), app 1121 (volt 974), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 86 szándékos elrontás (nincs forgatás vagy a forgatás eldobja a múltat; kivételt dobó vagy a sort leállító napló; kikapcsolt árvízvédelem, percenkénti plafon, összegző sor; a tisztítatlan vagy objektumokat átengedő adatmező; korlátlan vagy elvesző előpuffer; többször író „egyszeri” bejegyzés; a kulcs, az e-mail, a webcím-lekérdezés, a felhasználónév, a hosszú szám és az SQL-paraméter benne marad a hibaszövegben; a három hibakampó és az átadás a régi kezelőnek; a kérésszámláló nem számol, rosszul osztályoz, felülír, nem metsz, elveszti a hibás írás számait, nem látja a még nem tároltat; az újabb-formátum jelzés ideje minden futásnál lép, a nulla nem töröl, a nem vizsgált csatorna törlődik, soha nem íródik; a katalógus nyers szöveget mutat, a hibakód a szöveget idézi; az „Elvetés” nem törli a sort, a törlési jelölőt otthagyja vagy az eseményt is törli; nem kérdez; az „Újrapróbálás” nem kézi futás; a külső őr nem őr, nem állítja vissza a „szinkronizál” jelzést, nyers szöveget mutat, nem naplóz; a csatorna elfelejti az utolsó jó időt; a plafon-jelzés nem megy ki, a bővítő nem kapja a naplót; a jelentés címet tartalmaz; a figyelmeztetések valamelyike hiányzik; a másolt szöveg nem a jelentés) mind elkapva (a próba két hiányt hozott felszínre: az „olvashatatlan ismétlődés” figyelmeztetésnek és a naptármotor naplója címmentességének nem volt tesztje – mindkettőhöz új teszt készült; az időjárás-lekérés hibáinak naplózása is ekkor került be, további három elrontással)

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| REL-22 (napló) | kész | `diag/diag_log.dart`: JSON-soros fájl az adatbázis mellett, 256 KB-os forgatás (2 fájl), aszinkron sor, kivételmentes, indulási előpuffer (≤ 100), árvízvédelem (azonos hiba 60 s-onként egyszer, ≤ 30 sor/perc, összegző sor); `diag/redact.dart`: `safeErrorText` (típus + első sor, titok → személyes adat → csonkítás, az SQL-paraméterek levágva); `diag/guarded.dart`: `FlutterError.onError`, `PlatformDispatcher.onError`, `runZonedGuarded` (az `ensureInitialized` ugyanabban a zónában); `main.dart` |
| REL-22 (Diagnosztika oldal) | kész | `diag/diag_snapshot.dart` (tiszta pillanatkép + `renderReport`, cím nélkül) és `ui/diagnostics_page.dart`: figyelmeztetések, alkalmazás, szinkron csatornánként, elutasított módosítások (Újrapróbálás / Elvetés), kérések (ma / tegnap), napló (100), Másolás / Mentés fájlba / Napló törlése; belépő: Beállítások → A program és a szinkron-menü; `BackupIo.save` MIME-típusa megadható (a jelentés `text/plain`) |
| UX-5 (magyar hibák) – befejezés | kész | `errorInfoFor` (kód + cím + teendő + akció), `signInFailedText`, `outboxErrorText`; a nyers `$e` kicserélve a felületen (szerkesztők, asszisztens, beállítások, frissítő, hálózati réteg, indulási képernyő, bejelentkezés); a fejlesztői szöveg („secrets.json”, „flutter run”) semlegesre cserélve, az útmutató a README-ben |
| REL-7 kiegészítés (hibás elemek) | kész | az outbox `lastError` stabil kód (`conflict`, `transient[:limit\|:daily]`, `rejected:<státusz>:<ok>`, `unexpected:<típus>`); `failedOutbox()` / `discardOutbox(seq)` (a sorban álló törlésnél a törlési jelölőt is viszi, különben a napi takarítás újra sorba állítaná) |
| REL-8 kiegészítés (kérésszámláló) | kész | a `RetryAfterClient` számol (a szolgáltatás az `url.path` előtagjából), a `RequestStats` 7 napot tart a meta táblában (`diag.req`), a futás végén olvad. A tokenfrissítés más rétegben fut, nincs benne |
| REL-4/9/16/20 jelzései | kész | a Diagnosztika mutatja: kötés-eltérés, óraeltérés (> 2 nap), tartós „újabb formátum” (`diag.newerFormat`, a Drive feltöltési ága is számol), olvashatatlan ismétlődés, a 20 000-es plafon (`expand(onCapped)` a magban; eseményenként egyszer naplózva). **Az 1b-ben „nem készült” tétel pótolva.** |
| külső őr (REL-3 folytatása) | kész | `syncNow`: bármi, ami a három csatornaőrön kívül dob (adatbázis, hiba), naplózódik, a „szinkronizál” jelzés visszaáll, a következő futás a szokott ütemben jön |
| eltérések | – | **Eltérés a tervtől:** az „Elvetés” a sorbeli műveletet dobja el (az esemény az eszközön marad), nem az eseményt; a jelentés a címet nem tartalmazza (a képernyő igen, a hibás tételek listájában); a tokenfrissítés kérései nem számolódnak; a napló az adatbázis mellett él (nincs új `path_provider`-hívás) |

### 3a (navigáció, fejléc, hónap-pöttyök, billentyűparancsok, ablak) – kész, a build után kipróbálandó

Tesztek: mag 459 (változatlan), app 1172 (volt 1121), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 53 szándékos elrontás (a töréspontok értékei és határai; a „Több” helye; a hiányzó vissza-kezelés; a rejtett oldal fókusza és animációi; a megszakítás elmaradása fülváltáskor, illetve a már látszó fül újraválasztásakor; gépelés közben induló parancsok; felcserélt nyilak, számok és billentyűk; a súgó hiányos listája; a cím rövidítése, skálázása és helye a gombok mellett; a pöttyök küszöbe, darabszáma és színe; a kilógó, nem levágott cellatartalom; a 48 px-es koppintási cél; a szerkesztő párbeszéd-küszöbe; az oldalpanel küszöbe) mind elbukik a tesztek valamelyikén. **A próba három hiányt hozott felszínre**, mindhárom pótolva: nem volt teszt az oldalpanel 900 px-es küszöbére, a pöttyök színére és arra, hogy a cella levágja a nem férő tartalmat. (A szerkesztő párbeszéd/oldal 760 px-es küszöbére a próba előtt készült teszt.)

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| UX-1 (navigáció) | kész | `ui/shell_tab.dart` (`ShellTab`: Naptár, Feladatok, Asszisztens, Pénzügyek) és `ui/root_shell.dart`: alsó sáv / oldalsín + „Több” lap (Beosztás, Beállítások); az oldalak `IndexedStack`-ben élnek, az első megnyitáskor épülnek, a nem látszó `ExcludeFocus` + `TickerMode(enabled: false)` alatt áll; `PopScope`: Vissza → Naptár → kilépés; az Asszisztens elhagyásakor a futó kérés megszakad. A naptár fejléce: nézetváltó, előző, Ma, következő, szinkron |
| UX-4 (billentyűparancsok) | kész | `ui/shortcuts.dart`: `Shortcuts` + `Actions` a naptár oldalon (N, T, ← →, 1 2 3, F5, F1 / ?), a `PageAction` letiltja magát, ha egy szövegmező szerkeszt (`isEditingText`); a naptár fülváltáskor visszakapja a fókuszt; súgó-párbeszéd + gomb a Beállítások „A program” részében. A Ctrl+F és a „4” (Napirend) a 3c-ben |
| UX-10 (Windows ablak) | kész, **csak fordításig ellenőrizve** | `windows/runner/win32_window.cpp`: `WM_GETMINMAXINFO` (480 × 640 logikai px, DPI-vel skálázva, a képernyő munkaterületére korlátozva); az ablak a normál téglalapját követi (`WM_MOVE` / `WM_SIZE`), `WM_CLOSE`-nál a rendszerleíróba menti (`HKCU\Software\KvantumNaptar\WindowState`: téglalap képernyő-koordinátában + maximalizált-e); induláskor a legközelebbi képernyő munkaterületére igazítva áll vissza, a nézet létrehozása előtt (az első képkocka már jó méretű). **Ellenőrzés:** `x86_64-w64-mingw32-g++ -fsyntax-only -Wall -Wextra -Wshadow -Wconversion` az alapállapothoz képest új figyelmeztetés nélkül; a `/W4 /WX` éles fordítás a CI Windows-jobja |
| CMP-7 (töréspontok) | kész | `ui/breakpoints.dart`: sín 760, teljes vezérlők 820, oldalpanel 900, rövid cím 400, pöttyös cella 64; a `root_shell`, a `home_page`, a `month_view` és az `event_editor` ezt használja (a szerkesztő párbeszéd/oldal küszöbe is 760). Golden képek nincsenek (a tesztek az Ahem betűtípussal futnak): a határokat táblázatos és geometriai tesztek rögzítik |
| a felhasználó képernyőképei | kész | a hónap címe nem vágódik le („202…”: 400 px alatt rövid alak, és `FittedBox(scaleDown)`); a szöveges hónap-sávok helyett keskeny cellában pöttyök („18:0…”, „+2 tov…”); a szinkron-gomb ≥ 48 × 48 px (UX-8 egy része) |
| megfigyelések útközben | nyitva | (1) a tesztek Ahem betűtípusa alatt a hét nézet napfejléce (kétjegyű dátumok) 360 px-en, a Beosztás oldal 360 px-en vízszintesen túlcsordul – valódi betűtípussal nem biztos, hogy előfordul, a 3d betűméret-körben valós méréssel (és szükség esetén javítva) tisztázandó; (2) a törlés-kártya indoklását a modell angolul is adhatja – a kártya a 3b-ben a *kérésed* szövegét mutatja majd (áthelyezésnél marad az indoklás); (3) a 3b visszavonási üzenetsávja a közös üzenetkezelőn jelenik meg a gomb fölött (nem fülenként, ahogy a terv írta) |
| eltérések | – | **Eltérés a tervtől:** a „Több” mindkét elrendezésben alulról felcsúszó lap (nem külön felugró menü a sínen); a pöttyök legfeljebb 4 (3 + „+N”); a húzással áthelyezés – a kérésed szerint – kimaradt |

### 3b-1 (visszavonás) – kész, a build után kipróbálandó

Tesztek: mag 459 (változatlan), app 1260 (volt 1172), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 52 szándékos elrontás (a tartás számlálása és sorozat-kulcsa; a motor ellenőrzése, számlálója és a megtartott tétel feltöltése; a `markPushed` őr; a változáshalmaz őrei, verzió-emelése, sorrendje, kapcsolat-vágása, egyesítése és aláírása; a sáv `persist`, csere, hibaüzenet, biztonsági időzítő, margó és szélesség; a sorozat-hatókörök; a feladat és a pénzügy azonosság-őre; az összetett törlések egységessége; a kategória-tartalék; a bélyeg) mind elbukik a tesztek valamelyikén.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| UX-2 (visszavonás) | kész | `ui/undo_service.dart` (`UndoService`, `UndoSite`, `run` / `offer`): egyetlen aktív sáv, 10 mp, `persist: false`, biztonsági időzítő, idempotens lezárás (tartás oldása + `requestSync`), hiba → magyar üzenet + napló. A megerősítő ablakok (esemény, Beosztás-műszak, feladat, pénzügyi tétel, ismétlődő tétel, cél) kikerültek; a sorozat-hatókör kérdés marad |
| tartás (új) | kész | `sync/sync_hold.dart` (`SyncHold`, számlálós, sorozat-kulcsos, memóriabeli), `SyncEngine(isHeld)` + `SyncReport.held` (nem `deferred`, hogy a szinkron-ütem ne higgye elfoglaltnak), a vezérlő bekötése; a tartást a változtatás **előtt** kell megszerezni (`UndoService.run`) |
| `markPushed` őr | kész | a `delete` ág csak a sírkövet törli (`deleted==true`): egy repülő törlés közben visszahozott esemény megmarad, a következő lehúzás `unlink`-kel és újrafeltöltéssel öngyógyít (`_apply`) |
| változáshalmaz | kész | `data/event_change.dart` (`EventChangeSet`, `RowSig`): `tracked` (előképek a tranzakción belül, aláírások a végén), `undoChange` (minden-vagy-semmi; a „sírkő eltűnt” nem szerkesztés; mester elöl; `version = max+1`; kapcsolatvágás, ha nincs sor), `seriesKeysOf`, `clearLinks`, `merge` (korai kép, késői aláírás) |
| közös, atomi törlés | kész | `delete_ops.deleteEvent` (a szerkesztő eddig nem atomi, pillanatképből dolgozó `_delete`-je helyett); az asszisztens `deleteOccurrence`-e ezt hívja (az asszisztens-visszavonás a 3b-2-ben jön) |
| feladat | kész | `RecordRepository.undelete` (`get()?.deleted` őr: kitisztított soron az `edit` üres szellem-rekordot hozna létre) |
| pénzügy | kész | `DeletedRef` + `FinanceRepository.undelete` (csak ha a sor még pontosan az a sírkő; egy tranzakcióban az összetartozókkal; a halott kategóriájú tétel „Besorolatlan” lesz); a törlő metódusok `List<DeletedRef>`-et adnak; `deleteCategory` atomi |
| Flutter 3.50 | megfigyelés | a gombos `SnackBar` alapból nem záródik be (`persist = persist ?? action != null`) – ezért kell a `persist: false`; teszt őrzi |
| megfigyelések útközben | nyitva | (1) régi rés, amelyet a tartás kiszélesít: egy `appEventId` nélküli, Google-ban szerkesztett esemény lehúzása a tartás alatt élő duplikátumot hozhat a sírkő mellett (`_apply` csak élő sorokhoz párosít); (2) feltöltés utáni visszavonásnál a Google-oldali mezők (emlékeztető, vendég, Meet) elvesznek – a tartás miatt csak versenyben fordul elő; (3) a `rebindKeepLocal` eldobja a sírköveket, ez a visszavonást az „eltűnt sír” ágra viszi (új Google-esemény) |
| eltérések | – | **Eltérés a tervtől:** az audit „késleltetett commit”-ot írt; helyette azonnali törlés + visszaállítás + szinkron-tartás. A Beosztás-generálás visszavonása a tervhez képest *bővítés* (ugyanaz a keret adja) |

### 3b-2 (az asszisztens jóváhagyása és a haladásjelzők) – kész, a build után kipróbálandó

Tesztek: mag 462 (volt 459), app 1340 (volt 1260), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 63 szándékos elrontás (mind elbukik; a próba két hiányt hozott felszínre: a kérdés-őr tesztje nem vette észre a mégis elinduló kérdést, és az áthelyezés feltöltés-tartását semmi sem ellenőrizte – mindkettőre szigorúbb teszt készült).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| AI-16 (jóváhagyás védelme) | kész | `ai/approval.dart`: `assistantApplyingProvider` (külön a `busy`-tól: a `busy`-t minden kézzel épített `AssistantState` nullázza); `applyNew` / `applyDeletions` / `applyMoves` egy-egy `repo.atomically`-ban: élő előfordulás (`liveOccurrence`: a szolgáltatás `_resolveDeletions` mintája), `sameOccurrence` (mag) az összevetéshez, `clashes` (a `validateProposal` `conflict` / `bad_range` kódja, mint a `_resolveMoves`-ban), a kimaradók (`Skipped`, `SkipReason`) a figyelmeztető sávban (`skippedNotice`). Az `AssistantController` az állapotot az await-ek **után**, az élő állapotból építi (`copyWith`: új `notice`, `deletedCount`, `movedCount`, `askWhy`, `habitSaved` paraméterek), `dismiss` helyett négy célzott `dismiss…`, a `_settle` az üres oldalt adja vissza, ha az utolsó kártya záródott; `AssistantOutcome.withoutItems()` |
| visszavonás az asszisztensnél | kész | minden jóváhagyás `UndoService.run`-on megy (`newIds` / `holdIds` a tartáshoz), a változáshalmaz a 3b-1 `tracked` / `merge`-jével készül (egy kártya = egy halmaz); `moveOccurrence` `EventChangeSet?`-et ad (sorozat egy napjánál `created: [új kivétel-azonosító]`) |
| `moveOccurrence` | javítva | a sírkövet (`byId` megtalálja) nem támasztja fel: `isTombstone` őr; eddig egy törölt, még fel nem töltött esemény áthelyezése visszahozta és törölte a sorban álló törlést |
| törlés-kártya szövege | kész | `AssistantState.prompt` (max. 3 sor) a modell `reason` helyett; az áthelyezésnél marad az indoklás |
| UX-11 (haladás) | kész | Beosztás: `Stack` + `AbsorbPointer` + `ExcludeFocus` + pörgettyű a `_busy` alatt, a `_from` a gombnyomáskor rögzítve; Beállítások: `_FileJob` (a megnyomott gomb pörgettyűs, mind a négy várakozik; a fájlválasztó **után** kezdődik, `endOfFrame` a feldolgozás előtt; a felülírás-kérdés nem „munka”); szinkron-gomb: `SyncEngine.onProgress` → `SyncState.upload` (`syncing: false` törli), „Feltöltés N/M”, hiba a súgóban, „Újrapróbálás most”, az első menüsor |
| megfigyelések útközben | nyitva | (1) az áthelyezés a modell idejét a szolgáltatás zónájában (Budapest) értelmezi, de az esemény saját `tzid`-jében írja – más zónájú eseménynél a falióra-idő eltolódhat (az ütközés-ellenőrzés már az esemény zónájában számol); (2) az „elakadt” (menü) és a „feladva” (Részletek, Diagnosztika) ugyanaz – egységesítés a 3d szöveg-körében; (3) a `pending` a futás végén frissül (a tartott tételek miatt a tartás alatt „1 függőben” látszik – ez igaz); (4) a Drive-rekordoknak és a pénzügyi leveleknek nincs feltöltés-számlálójuk |
| eltérések | – | **Eltérés a tervtől:** a terv a megerősítés után egy `assistantApplyingProvider`-t és `saveAll`-t írt; ehhez jött a mostani naptár elleni újraellenőrzés a törlésnél / áthelyezésnél *és az új eseményeknél* (lejárt, ütköző kimarad), mert ugyanaz a kártya-állapot-hiba okozta mindhármat. A szinkron-gombon a „Szinkron most” a hibás / elakadt állapotban „Újrapróbálás most” nevet kap (egy tétel, nem kettő) |

### 3c (keresés, napirend, húzás, a Beállítások csoportjai) – kész, a build után kipróbálandó

Tesztek: mag 490 (volt 462), app 1448 (volt 1340), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 90 szándékos elrontás (a keresés magja, a kereső lap, a napirend, a húzás és az előtöltés, a fejléc és a töréspontok, a Beállítások csoportjai és a „Google-fiók” kártya, a közös szinkron-összegzés) – mind elbukik. A próba két hiányt hozott felszínre: a keresés a lemondott kivétel-példányt nem adta át az `expand()`-nek (a lemondott következő előfordulás is „következő” lett volna), és az egér-húzás tesztje túl gyenge volt (egyetlen nagy mozdulat nem húzás: most kontroll-húzás is van). Két elrontás egyenértékű (egy lemondott önálló esemény – az `expand` úgyis üresen adja –, és egy nappal hosszabb tartomány – a nézet csak a 14 napot listázza), azokat nem számoltam.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| UX-3 (keresés) | kész | `kvantum_core/src/search.dart`: `searchTerms` (foldHu, ≥ 1 kétbetűs szó), `searchEvents` (sorozatonként egy találat, a következő nem-átnevezett előfordulás; a múltbeli sorozat az utolsó; önálló példány-találat; a műszak-jelölő jegyzete nem keresett; közelgő előre, múltbeli utána; 50), `searchTasks` (30), `searchTx` (30; kereskedő, megjegyzés, kategórianév, számjegyes szó = összeg). `ui/search_page.dart`: autoDispose szolgáltatók (a kérdés a lappal együtt tűnik el, az események a `watchAll` folyamból, nem adatbázis-olvasás billentyűnként), találat → szerkesztő, „Ugrás a naptárban”, Esc. Belépő: nagyító a fejlécben, Ctrl+F a naptár-parancsok között |
| UX-3 (napirend) | kész | `CalView.agenda` (visszafelé kompatibilis mentett érték), `agendaRangeProvider` (14 nap a kijelölt naptól), `ui/agenda_view.dart` (relatív napnevek, egésznapos előre, határidős feladatok a napjukon, „Késésben” ha a tartomány tartalmazza a mait, éjfélen átnyúló esemény „→” / „folyt.”), 4 billentyű, nézetváltók |
| UX-3 (gesztus) | kész | `ui/swipe_nav.dart` (`swipeDirection`: ≥ 400 px/s vagy ≥ 64 px; csak érintés / toll); a hónap rácsa a hónapot, a nap-panel a napot, a hét / nap / napirend az időszakot lépteti; a szomszédos tartományok előtöltése (`ref.listen`); `monthOccurrencesProvider` közvetlen átadás (nincs plusz aszinkron lépés) |
| hónap-léptetés | javítva | a kiválasztott nap a látható hónapban marad (`sameDayIn`); eddig a nap-panel a régi hónap napját mutatta |
| fejléc | módosítva | < 440 px-en nincs ‹ ›, képernyőolvasóval van; új töréspontok: `stepArrows` 440, `fullControls` 820 → 860, `syncLabel` 1000; a naptár oldal a *saját* szélessége szerint dönt (`LayoutBuilder`), nem az ablakéból |
| UX-6 (Beállítások) | kész | `ai/settings/account_card.dart`: `SettingsGroupHeader` (címsor-szemantika), `AccountSyncBody` („Google-fiók” kártya: belépés / kilépés, állapot a közös `syncSummary`-val, utolsó siker, következő próba, függő / elakadt, hiba, Szinkron most ↔ Újrapróbálás most, kötés-döntés, Diagnosztika, alaphelyzet); csoportok: Fiók és szinkron · Asszisztens · Értesítések · Adatok · Névjegy |
| hét címe | javítva | kettős pont két hónapot átfogó hétnél, hiányzó második év évhatáron (`_range`) |
| `syncSummary` | új | a szinkron-gomb és a kártya közös szövege / hangszíne (`SyncTone`), a szinkron-óra (`syncClockProvider`) injektálható |
| megfigyelések | nyitva | (1) a Ctrl+F csak a naptár oldalon él; a Feladatok / Pénzügyek oldalon nincs nagyító; (2) a húzás küszöbei valódi telefonon hangolandók; (3) a `settings_page.dart` szétbontása külön körre marad |

### 3d (hozzáférhetőség, nagy betű, téma, első indítás) – kész, a build után kipróbálandó

Tesztek: mag 490 (változatlan), app 1643 (volt 1448), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0, friss klónon is). 72 szándékos elrontás (71 elbukik; az AM3 egyenértékű: két `button` jelzésű szemantika-csomópont nem olvad össze). A próba négy tesztelési hiányt hozott felszínre – a fél órás blokk címe, a legrövidebb blokk és a színes sáv magassága nagy betűnél (a mérés a `Material` ősöket nézte, ezért ment át a rövidre vágott változat), a napi panel címe alacsony telefonon –, mindegyikre szigorúbb teszt készült; egy első kísérletben nem fordítható változat javítva.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| UX-8 (képernyőolvasó) | kész | `ui/a11y.dart` (`spokenDay`, `spokenCount`, `spokenCell`, `spokenEvent`, `spokenBudget`, `spokenShare`: egy dolog egy mondat); hónap-cella (`container`, `button`, `selected`, a napszám és a pöttyök kizárva), az esemény-sáv külön megálló, „+N további”; hét / nap: napfejléc, esemény-blokk, egésznapos sáv a nappal együtt, az óra-feliratok kizárva; napirend-sorok; költségkeret-sor egy mondat, a nyilak „Bevétel” / „Kiadás”; folyamatjelzők címkéi; a cél sávja kizárva. A szabály: `Semantics(container: true, …)` + a belső vizuális tartalom `ExcludeSemantics`-ben; az `InkWell`-t nem szabad `ExcludeSemantics`-be tenni (elveszti a koppintás-műveletet) |
| UX-8 (szín + jel) | kész | költségkeret: ikon + szó a szín mellé (`levelIcon`, `budgetHint`) |
| UX-8 (kontraszt) | kész | `ui/theme.dart`: `contrastRatio` (átlátszó szín a háttérrel keverve), `StatusColors` (`ThemeExtension`: ok / warn, világos és sötét, ≥ 4,5 : 1 minden felületen; a „túllépve” a téma hibaszíne), `statusColorsOf`; a 11 kemény `Colors.green` / `orange` cseréje; a halvány szöveg `onSurfaceVariant`; `onEventColor` a jobb kontrasztút választja (mind a 12 szín ≥ 4,5 : 1) |
| UX-8 (nagy betű) | kész | `ui/text_scale.dart` (`scaled`, `textFactor`, `textWidth`, `GridLabelScale`): az idősáv órája a betűvel nő (≤ 1,6×), a blokk tartalma a sormagasságból dől el + `ClipRect` / `OverflowBox` háló, a napfejléc és az óra-feliratok ≤ 1,3×, keskeny oszlopban nincs idő, az egésznapos sáv ≤ fél hely és görget, a napi panel címe ≤ fél panel; a hónap-cella sorai a szöveghez igazodnak, „•” jelzés pötty helyett; a naptár tetején a sávok ≤ a magasság harmada (görget); alsó sáv: ≥ 1,3× csak a kijelölt felirat; pénzügyi összesítő és keret-sor átrendeződik; szerkesztő-sorok, Beosztás, Beállítások, asszisztens gombjai `Wrap`-ben; napirend idő-oszlop. Teszt: `text_scale_test` (75 jelenet) + `layout_scale_test` (méretek) **valódi Roboto-val** (`test/support/real_fonts.dart`), `KVANTUM_SHOTS` képernyőképekkel |
| UX-9 (téma) | kész | `ThemeModeNotifier` (meta `themeMode`), `appTheme(Brightness)`, `KvantumApp` → `ConsumerWidget`, választó a Beállítások „A program” kártyáján |
| UX-7 (első indítás) | kész | `ui/setup_guide.dart` (`SetupStep`, `SetupFacts`, `nextSetupStep`, `SetupFlagsNotifier`: `setup.dismissed`, `setup.skip.<lépés>`, `setupFactsProvider`: csak olvas), `ui/setup_card.dart`: egy lépés egyszerre „x/y” számolással; Belépés / AI-kulcs / Hely / Emlékeztetők (Android) / Wallet (Android); Megnyitás · Nem kell · Elrejtés; a Beállításokból és az alkalmazásba visszatérve újra megnézi; „Első lépések újra” gomb. Kapcsoló: `setupGuideProvider` (a `main.dart` kapcsolja be; tesztben alapból ki) |
| hét / nap „ma” | javítva | a `TimeGrid` a valódi órát használta (`DateTime.now()`), nem az `appClockProvider`-t |
| esemény-blokk 1,0-nál | javítva | valódi betűvel egy 45 perces blokk 3 képpontot lógott (a teszt-betű alacsonyabb volt) |
| megfigyelések | nyitva | (1) a hét nézet telefonon 200 %-os betűnél szűk (hét oszlop 44 px-en): a nap / napirend nézet ajánlott; egy 3 napos vagy görgethető hét külön átalakítás; (2) az Android 14 nemlineáris betűskálája a lineáris teszttől kissé eltérhet; (3) Windowson a betű Segoe UI (a mérés Roboto-val történt); (4) a kulcs mentése a Beállításokban újra-nézésre készteti a kártyát (`setupFactsProvider` érvénytelenítése), de ezt a gombnyomás-folyam tesztje nem fedi (a kártya saját visszatérés-ellenőrzése fedi a gyakori utat) |
| eltérések | – | **Eltérés a tervtől:** a kártya egyszerre egy lépést mutat (nem listát), a „Hely” és a „Wallet” nem kötelező, a kapcsoló saját (`setupGuideProvider`, nem `googleConfigured`); az „Első lépések újra” gomb terven felüli; az 1,0-s betűnél talált blokk-túlcsordulás és a hét / nap „ma” óra javítva |

### 4.1/F (automatikus mentés és visszaállítás) – kész, a build után kipróbálandó

Tesztek: mag 490 (változatlan), app 1792 (volt 1643), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 93 szándékos elrontás (mind elbukik; a próba tizenkét tesztelési hiányt hozott felszínre – nem UTF-8 rész, törölt rekordok a számolásban és a mentésben, a naptár olvasási hibái a visszaállításban, csak-rekord változás, a visszaállított frissítés feltöltésre sorolása, a pénzügyi előnézet írása frissítésnél, egyszerre egy mentés, olvashatatlan beállítások, idegen nevek a Drive-listában, a Drive-mentés a teszt-módban, a jelszó-párbeszéd görgetése –, mindre szigorúbb teszt készült).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| mentés-fájl | kész | `backup/backup_bundle.dart`: zip (`meta.json`, `calendar.ics`, `finance.json`, `records.json`); AES-256 jelszó az `archive` 4.6.0-val (új függőség nincs); a hibák (`BackupProblem`: nem mentés / jelszó kell / hibás jelszó / újabb verzió / sérült) magyar üzenettel; a zip lustán olvasódik: a jelszó hibája a tartalom olvasásakor derül ki, ezért ott is `ArchivePasswordException`-t kell fogni; az újabb `version` elutasítva (nem félig beolvasva) |
| mappa és megőrzés | kész | `backup/backup_store.dart`: `FileBackupStore` (a `.part` fájl átnevezése, a név nem léphet ki a mappából), `MemoryBackupStore`, `backupsToDelete` (7 nap + 4 hét; csak a saját nevű fájlokat nevezi meg; a jövőbeli fájl mai napnak számít) |
| szolgáltatás | kész | `backup/backup_service.dart`: `create` (isolate-ban csomagol; a build száma nélkül is elkészül), `open`, `preview` (semmit nem ír: `FinanceRepository.importJson(dryRun)`, `RecordRepository.restoreRecords(dryRun)`), `restore(overwrite)`; soha nem töröl |
| napi mentés | kész | `backup/auto_backup.dart`: 20 óránként, a kapcsoló és az utolsó idő / hiba a `meta` táblában (`backup.auto`, `backup.last`, `backup.error`), egyszerre egy fut (a második kérés csatlakozik), a hiba nem kivétel; indul: `RootShell._housekeeping` után és visszatéréskor; a tesztekben ki van kapcsolva (`autoBackupRunsProvider`), a `main.dart` kapcsolja be |
| Drive-másolat | kész | `backup/drive_backup.dart`: `kvbackup-<dátum>.zip.b64`, 6 nap 20 óránként, az utolsó 3 marad (csak a saját nevűek törölhetők), ≈ 4 MB-os korlát (a Drive egyszerű feltöltése 5 MB), azonos másodpercű másolat felülírja az előzőt; a jelszó a `BackupKeyStore`-ban (`flutter_secure_storage`, a `main.dart` adja; tesztben memória); `SyncController.driveRemote()`; a `RootShell` a belépéskor (`ref.listen`), induláskor és visszatéréskor próbálja |
| felület | kész | `backup/backup_card.dart` (`BackupBody` a Beállítások „Adatok” csoportjában), `backup_dialogs.dart` (jelszó-kérdések, visszaállítási előnézet, Drive-lista), `backup_file_io.dart` (bájt-alapú fájlmentés / -választás, külön a szöveges `BackupIo`-tól, hogy a meglévő hamisítványok ne törjenek) |
| tesztek tanulsága | javítva | a Beállítások oldala magasabb lett: három meglévő teszt ablaka 4200 → 6400 képpont; az idő a fájlnévben az eszköz órája szerinti (nem a megjelenítési zóna), a kártya ugyanígy mutatja |
| megfigyelések | nyitva | (1) a visszaállítás a feladatokat és a pénzügyeket nem hozza vissza törölt állapotból (rekordonkénti „újabb nyer”) – az események igen; ha ez zavar, „törölt elemek visszahozása” opció külön körben; (2) a helyi mentések az eszközön maradnak (Android automatikus mentése ki van kapcsolva), az eszközvesztés ellen a fájlmentés és a Drive-példány véd; (3) a Drive-példány nincs háttér-szolgáltatásra bízva: indításkor / visszatéréskor / belépéskor fut; (4) az AES-zip megnyitása más programokkal (7-Zip, WinRAR) és a valódi Drive élőben nem ellenőrzött |
| eltérések | – | **Eltérés a tervtől:** a Drive-példány jelszava nem az API-kulcsok tárolójába, hanem külön `BackupKeyStore`-ba kerül (a bejegyzések eltérő élettartama); a méretkorlát a Drive egyszerű feltöltéséhez igazított, nem folytatható feltöltéshez; a visszaállítási előnézet a naptárra külön „módosult” kategóriát ad, a többi adatnál rekordszintű egyesítés van |

### 4.1/A (emlékeztetők Windowson) – kész, a build után kipróbálandó

Tesztek: mag 490 (változatlan), app 1867 (volt 1792), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 76 szándékos elrontás (az ütemező és a feljegyzés, a próba-értesítés, az indítási bejegyzés (`reg.exe`) és állapotai, az önjavítás, a kapcsoló és a próba-gomb, a lekicsinyített ablak szinkronja, a Beállítások elrendezése; 75-öt elkapnak a tesztek, egy egyenértékű (a `TZDateTime` hash-e a natív pillanaté, ezért a hash így is azonos); a próba négy tesztelési hiányt hozott felszínre – a feljegyzés törlése levételkor, a hibás feljegyzés mellett a jó megmaradása, a rendszer `reg.exe`-jének útvonala, a próba-gomb kétszeri megnyomása – és egy halott kódot (a Windowson nem olvasott `payload`), mindre szigorúbb teszt vagy javítás készült). A Windows-runner C++ kódját `mingw-w64`-gyel szintaxis-ellenőriztem (új figyelmeztetés nincs); az éles `/W4 /WX` fordítást a Build végzi.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| REL-19 (Windows) | kész | `notify/windows_reminders.dart`: `ToastBackend` (init, a Windows listája, levétel, átadás) a `flutter_local_notifications_windows` 3.1.1 köré (`PluginToastBackend`: ütemezett toast, a program neve „Kvantum Naptár”, azonosító `Kvantum.Naptar`, GUID rögzítve; a Windows az ütemezést a program zárva is megjeleníti); `WindowsReminderScheduler` a meglévő `ReminderScheduler` / `syncReminders` különbség-alapú ütemezésén: az átadott tervet saját feljegyzésben őrzi (`rem.win.plan`, a Windows csak azonosítót ad), a Windows listájával metszi; feljegyzés nélkül nem kérdez a Windowstól (nem regisztrálja magát, aki sosem kapcsolt be emlékeztetőt), az első átadás leveszi a feljegyzés nélküli értesítéseket (a próbát nem); előbb levesz, aztán átad (az azonos azonosító megduplázna); 20 másodpercen belüli esedékest nem ad át; a feljegyzés a hibánál is megíródik |
| választó | kész | `reminderSchedulerFor(android, windows, …)` (jelzőkkel, bármely gépen kipróbálható), `reminderSchedulerProvider` lusta adatbázis-hozzáféréssel; Windowson támogatott → az „Első lépések” kártya is felajánlja |
| próba-értesítés | kész | `TestableReminders` + `ReminderTestButton`: fél perces ütemezett értesítés, nem kerül a tervbe / feljegyzésbe (azonosítója a tervek fölött van, a `pending()` elrejti) |
| indítás a Windows-szal | kész | `notify/windows_autostart.dart`: `reg.exe` (a rendszer saját példánya) a `HKCU\…\Run` kulcson, `"<program>" --minimized`; állapot: ki / be / a Windows letiltotta (`StartupApproved\Run`); az induláskor önjavítás (csak meglévő bejegyzésnél, ékezet- és kisbetű-érzéketlen összevetéssel, a Windows letiltását nem oldja fel); `autostart_tile.dart`: kapcsoló, hiba magyarul és a naplóban kóddal; `windows/runner`: `--minimized` → `SW_SHOWMINNOACTIVE` a `SetWindowPlacement`-en át (a visszaállítás a korábbi méretre / teljes méretre visz), a Windows által indított második példány csendben kilép |
| szinkron lekicsinyítve | kész | `SyncController`: számítógépen a `hidden` (lekicsinyítve) nem állítja le az időzítőt (telefonon igen); `paused` / `detached` mindenhol leállítja |
| PlannedReminder `==` | javítva | az időzóna-csomagos (`TZDateTime`) és a sima `DateTime` azonos pillanata nem volt egyenlő → a check-in emlékeztetők minden futásnál „változottnak” látszottak, törlődtek és újra ütemeződtek (Androidon is); mostantól a pillanat (`microsecondsSinceEpoch`) számít, a hash is |
| Beállítások keskenyen | javítva | 360 px-en, 200 %-os betűvel a három legördülő (alvás kezdete / vége, emlékeztető, téma) és az API-kulcs állapotsora kilógott: `isExpanded` / `Flexible` |
| megfigyelések | nyitva | (1) hogy az aláíratlan, zipből kicsomagolt program ütemezett toastját a Windows zárt programnál is megjeleníti-e, csak valódi gépen derül ki (a Próba-értesítés erre való); (2) tálca-ikon nincs; (3) az értesítés ikonja általános; (4) a program a Windows beállításaiban kikapcsolt értesítést nem látja; (5) a C++ kódot csak a Build fordítja éles beállítással |
| eltérések | – | **Eltérés a tervtől:** a „Windows-értesítés + tálca + automatikus indítás” csomagból a tálca-ikon kimaradt (az ütemezett toast nem igényli, és nem ellenőrizhető itt); a **Próba-értesítés**, a **lekicsinyített ablak szinkronja** és az **önjavító bejegyzés** terven felüliek |

### 4.2/B (ünnepnapok, reggeli összefoglaló, főképernyő-widget) – kész, a build után kipróbálandó

Tesztek: mag 532 (volt 490), app 1992 (volt 1867), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 167 szándékos elrontás (166 elbukik, egy egyenértékű (az egésznapos esemény kezdete csak a sorrendhez kell, és az eltolás mindet egyformán érinti); a próba tizenöt tesztelési hiányt hozott felszínre – köztük két „az új nap újratervez” tesztet, amely a késői adatérkezés miatt véletlenül ment át –, mindre szigorúbb teszt készült). A Kotlin a valódi Android API ellen lefordítva, a tartalom-logika JVM-en futtatva (91 ellenőrzés, az igazi Dart-pillanatképpel); az AAPT-összekötést és a kirajzolást a Build / az eszköz mutatja.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| ünnepnapok, munkanapok | kész | `kvantum_core/src/hu_calendar.dart`: `HuDayKind` (munkaszüneti nap / áthelyezett pihenőnap / áthelyezett munkanap), `HuDay` (`isDayOff`, `shortLabel`, `label`), `easterSunday` (Gauss–Meeus), `huHolidays(év)` (szabály: rögzített dátumok, húsvét-alapúak, nagypéntek 2017-től, **Szenteste 2026-tól**), a 2026-os áthelyezések kis táblázata (`_decreed`), `huDayInfo(dátum)`; `huCalendarCheckedOn` = 2026-11-13. A 2027-ben nincs áthelyezés, a 2028-tól nincs táblázat |
| összefoglaló szöveg | kész | `daily_summary.dart`: `buildDaySummary` (ünnep, időjárás, események [egész naposak elöl; „HH:MM-ig” a tegnap kezdődöttre; „+N további”], feladatok [„lejárt”], a címek `sanitizeText`-tel, 40 karakterre); null, ha nincs mit mondani (az időjárás egyedül nem elég) |
| összefoglaló terv | kész | `notify/summary_plan.dart`: `dayContents` (egy nap: események, feladatok, ünnep – a widget is ezt használja), `summariesFor` (az időjárás-sorral); `reminders.dart`: `summaryMinutes` (6:00–9:00, fél óránként, `rem.summary`), `planReminders(summaries:)` (nyolc nap, az azonosító 1 600 000 000 + nap), Androidon BigText, a szinkron-szolgáltató a `todayProvider`-t, a feladatokat és az AI-beállítást is figyeli |
| nézetek | kész | hónap-cella (piros szám, ünnepnév széles cellában, `Align` keskenyen: nem lóg ki 360 px-en 200 %-os betűvel sem), napi panel, napirend (az üres ünnep is), hét/nap fejléc, képernyőolvasó (`spokenCell(special:)`) |
| widget – Dart | kész | `widget/widget_data.dart` (pillanatkép: hét nap, ünnep, sorok, három műszak, JSON, időbélyeg nélkül, hogy az azonos naptár azonos szöveg legyen), `widget_bridge.dart` (`kvantum/widget`: `isPlaced`, `update` → igaz, ha egy widget átvette), `widget_sync.dart` (1,5 s sűrítés, soros futások, ismétlés-mentes, `widgetKickProvider` visszatéréskor), `home_page.dart` figyeli, `root_shell.dart` lökés visszatéréskor, `settings_page.dart` szakasz (csak Androidon) |
| widget – Android | kész (kirajzolás nélkül) | `TodayWidgetContent.kt` (tiszta: melyik nap, legfeljebb 7 sor, következő műszak, mikor évül el, „Frissítve”), `TodayWidgetStore.kt` (privát SharedPreferences, ≤ 64 KB), `TodayWidgetProvider.kt` (`AppWidgetProvider`; rajzolás; koppintás → app; **pontatlan, nem ébresztő** riasztás a nap végére / a műszak kezdetére; leváltáskor a szöveg és a riasztás törlődik), `MainActivity.kt` csatorna, erőforrások (elrendezés csak `LinearLayout` / `TextView` / `FrameLayout`; a színek az XML-ből, hogy a sötét téma kövesse), manifest: nem exportált `receiver` |
| megfigyelések | nyitva | (1) a kirajzolás és az `AlarmManager` / `PendingIntent` működése valódi telefonon, több Android-verzión; (2) az AAPT-összekötést a Build végzi; (3) az ünnepnapok forrása csak keresési összefoglaló; (4) a widget frissülése az app futásához kötött |
| eltérések | – | **Eltérés a tervtől:** a widget a feladatokat, az ünnepnapot és a „Frissítve” sort is mutatja, és hét napot ír előre (az új napra az app nélkül is vált); a reggeli összefoglaló nyolc napra előre készül (az értesítés szövege az ütemezéskor rögzül) |

### 4.3/E (gyors felvitel szövegből, részfeladatok, ismétlődő feladatok) – kész, a build után kipróbálandó

Tesztek: mag 746 (volt 532), app 2104 (volt 1992), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 174 szándékos elrontás (169 a végső listán, mind elbukik; 4 elrontás felesleges kódot talált, ezt töröltem (a soha nem illeszkedő `ketheten` szóalak, a 24 mint a „fél / negyed” órája, az önmagára mutató részfeladat külön ellenőrzése, a soha el nem érhető „elfogyott a szám” ág), 1 egyenértékű (a havi szabály 31. napja a másik ágon ugyanazt adja). A próba 26 tesztelési hiányt hozott felszínre, mindre új teszt készült: az értelmezőben a „to-do:” és „találkozó:” jelölő, a hétvégi és a második / harmadik napi ismétlődés, a mai dátum év nélkül, a „holnapig”, a hónap végi „1 hónap múlva”, a december–január átfordulás, az éjfélen átnyúló „fél óra múlva”, a „hajnal 12” és „délután 12”, az „éjjel 6”, a 25:00 és a 24:30, az éppen mostani óra, a havi szabály napja és elmúlt órája, a kis- és nagybetű a részfeladatok sorrendjében; az alkalmazásban a kipipált feladat visszanyitása, az ismétlődő feladat részfeladatainak újrakezdése az oldalon, a részfeladat visszanyitása, a helyi válasz részfeladat-szűrése, az újra megadott határidő szabálya és a sikertelen felvétel tartása).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| szövegértelmező | kész | `kvantum_core/src/quick_entry.dart`: `parseQuickEntry(sor, now:)` → `QuickEntry` (fajta, cím, nap, óra, hossz, egész napos, `rrule`, az ismétlődés szavai, **feltételezések** magyarul); ékezetfosztott, 1:1 hosszú szöveg + kitakarás (a már megértett rész nem érthető meg újra); a bizonytalan 1–6 órát délutáninak veszi és kimondja; szigorú hétköznap-alakok (a „Szombathely” nem szombat); 183 teszt (mondat-táblázat + határesetek + a megjegyzések nyelvhelyessége) |
| feladat-szerkezet | kész | `kvantum_core/src/task_structure.dart`: `topLevelTasks` / `checklists` (egy szint mély; a hiányzó / törölt szülő, a hurok és az önmagára mutató részfeladat önálló marad, így semmi nem tűnik el), `nextRound` (a következő kör a határidő és a mai nap későbbikétől; `COUNT` fogy; az `RRULE:` előtag tűrt), `describeRepeat`; `models.dart`: `TaskView.parentId` / `pos` / `repeatRule`, `taskFields(parent:, pos:, repeat:)` ellenőrzésekkel (ismétlődő feladatnak határidő kell; részfeladat nem ismétlődhet; olvashatatlan szabály elutasítva) |
| feladat-műveletek | kész | `data/task_ops.dart` (`TaskOps`: `complete` [ismétlődő: ugyanaz a feladat a következő határidővel, a részfeladatok újra kipipálatlanok, a visszavonás mindent visszaír], `setDone`, `addItem`, `renameItem`, `delete` / `undelete` a részfeladatokkal); `providers.dart`: `tasksProvider` (csak az önálló feladatok), `checklistsProvider`; az asszisztens két feladat-olvasása (`get_tasks`, helyi válasz) is az önálló feladatokból dolgozik |
| feladat-oldal | kész | `ui/tasks_page.dart`: `_TaskTile` (határidő, ismétlődés szavakkal, „2/5 részfeladat”), `_ItemTile` (közvetlenül kipipálható), a szerkesztő **Ismétlődés** + **Részfeladatok** része (a be nem fejezett sor mentéskor hozzáadódik), a sáv („Kész – következő: …”, „Feladat és részfeladatai törölve”); a `TaskEditor` / `openTaskEditor` kitöltött vázlatot fogad |
| gyors felvitel | kész | `ui/quick_entry_dialog.dart` (párbeszéd: élő előnézet, Esemény / Feladat választó, feltételezések, Mégse · Szerkesztés… · Felvesz, Enter; `showQuickEntry`, `looksLikeQuickEntry`), `ui/quick_entry_ops.dart` (`quickEvent`, `quickWhen`, `QuickEntryOps.create`: az esemény a `tracked` változáshalmazzal + **feltöltés-tartással**, a feladat a rekordtárba; mindkettő minden-vagy-semmi visszavonással); belépők: **Q** (`QuickEntryIntent`, súgó), **Több → Gyors felvitel**, a Feladatok oldal villám ikonja, a Keresés „Felvétel: …” kártyája; `event_editor.dart`: `EditTarget` / `openEditor` kitöltött vázlatot fogad (cím, vége, egész napos, szabály) |
| hangbevitel | megoldva | a rendszer billentyűzetének diktálása (Android: mikrofon-gomb; Windows: Win+H) – nincs új csomag, nincs külön engedély; a súgó kimondja |
| visszavonó sáv nagy betűnél | javítva | a gomb 200 %-os betűnél keskeny telefonon kilógott: `undo_service.dart`: a szöveg és a gomb törő sorban, a sáv betűmérete 1,5×-nél megáll, a gomb színe a sötét sávhoz készült (≥ 4,5 : 1 mindkét témában); új tesztek |
| megfigyelések | nyitva | (1) a szabályalapú értelmező nem ért mindent („a hónap utolsó péntekén”, „kb. 6 körül”): a cím marad, a Szerkesztés… segít; (2) régi appverziók a részfeladatot önálló, az ismétlődő feladatot egyszeri feladatnak látják; (3) a diktálás minősége a billentyűzeten múlik; (4) a Q, a telefonos párbeszéd (billentyűzettel) és a sáv új kinézete valódi eszközön nincs kipróbálva; (5) a Mentés és visszaállítás a részfeladatokat önálló feladatként számolja |
| eltérések | – | **Eltérés a tervtől:** (1) hangbevitel: nincs saját, a billentyűzet diktálása szolgál (a terv Androidra külön kapcsolót említett); (2) a párbeszéd telefonon is párbeszéd (görgethető, a billentyűzet fölé tolódik), nem külön lap; (3) a részfeladatok sorrendje a hozzáadásé, húzással átrendezés nincs; (4) az Esemény / Feladat választó csak az adott szövegre érvényes (új szövegnél visszaáll a megértettre) |

### 4.4/C (haladás: edzésnapló és trend-grafikonok) – kész, a build után kipróbálandó

Tesztek: mag 794 (volt 746), app 2203 (volt 2104), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 337 szándékos elrontás (a végső listán mind elbukik; az első menetben 69 átment: 68 tesztelési hiány – a számítási rétegben 12, a rajzolókban 4, az oldalon 52 –, mindre szigorúbb teszt készült, egy egyenértékű volt (a skála alsó határának elágazása): az elágazás kikerült).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| számítás | kész | `kvantum_core/src/progress.dart`: `checkInSeries` (tartomány, törölt és válasz nélküli nap kimarad, rendezett), `trailingAverage` (az utolsó 7 nap, a válasz nélküli nap nem nulla), `mean` (üresre `null`, soha nem 0), `weeklyVolumes` (a hetek hétfőtől, az üres hét is ott van, a kihagyott edzés külön számol), `WeekVolume` (percek sportonként, átlagos nehézség / energia / élmény, `energyDrop`), `weekSummary` (magyar mondatok; az ítélet egész tizedekben: `trendTenths = 3`), `buildProgress` (1–52 hét, az előző hét átlaga csak ha a tartomány eléri); 42 teszt |
| diagramok | kész | `ui/charts.dart`: saját rajzoló, nincs új csomag; a helyzet számítása külön, tiszta függvényekben (`plotRect`, `niceMinutesMax`, `barRects`, `dayX`, `valueY`, `scaleValues`) és a feliratok adatként (`ChartLabel`, `barLabels`, `lineLabels`), a `BarChartPainter` / `LineChartPainter` csak követi őket; alakjelek (`LineMarker`: kör, négyzet, háromszög, rombusz), hogy a jelentés ne csak a színen múljon; a feliratok a rendszer betűméretét 1,3×-ig követik; a képhez mondatos `Semantics(image: true)` leírás; a tesztek a rajzolás hívásait vizsgálják (`TestRecordingCanvas`: vonalak, sávok, körök, útvonalak csúcsai, feliratok helye és hossza, sorrend), és a `shouldRepaint` minden mezőjét |
| oldal | kész | `ui/progress_page.dart`: időszak-választó (4 hét · 12 hét · Fél év), „Ez a hét” kártya, heti edzésmennyiség, napi közérzet (mutatónként kapcsolható, alapból fizikai energia + alvás), az edzések nehézsége, „Adatok szövegesen”, üres állapot; a leírások a képernyőolvasónak (`barsLabel`, `linesLabel`); a jelmagyarázat 200 %-os betűnél törik; a szín a témából jön (`StatusColors` az ok / warn színekhez) |
| szakaszcímek | javítva | a képernyőolvasós csomópont összeolvadt a mellette álló magyarázó szöveggel (a „Heti edzésmennyiség” és a „Percek hetenként…” egyetlen címsor volt): `Semantics(container: true, header: true)`; teszt: minden szakaszcím önálló, címsor-jelölésű csomópont |
| mutató-chipek | javítva | a kirajzolt kép (valódi betűtípussal) mutatta ki, hogy a kijelölt chipen a pipa eltakarta az avatarként elhelyezett alakjelet; az alakjel most a chip feliratában áll (`Row`: jel + név), a pipa mellette; teszt: a jel és a színe a feliratban van, avatar nincs |
| belépő | kész | **Több → Haladás** (`root_shell.dart`, ikon: `show_chart`), alsó sávban és oldalsínben is |
| megfigyelések | nyitva | (1) a diagramok kinézete valódi eszközön nincs kipróbálva (a Roboto-val kirajzolt képeken átnéztem: világos / sötét téma, 390 és 900 px, 1,0× és 1,6× betűméret); (2) a képernyőolvasók felolvasása a diagramokról; (3) a sportonkénti bontás (`minutesBySport`) számolva van, de a felületen még nincs; (4) nincs export / megosztás és fél évnél hosszabb időszak; (5) az „energia az edzések alatt” csak a két végén is értékelt edzésekből számol |
| eltérések | – | **Eltérés a tervtől:** (1) a belépő a **Több** alatt van, nem külön fül (az alsó sávban négy fül és a Több fér el); (2) a „trend” az utolsó 7 nap átlaga (nem simító görbe, nem regresszió) – érthető és ellenőrizhető; (3) a szöveges összefoglaló az előző héthez mér, és csak „javult / romlott / nagyjából ugyanannyi” szavakat használ, értelmezést nem; (4) nincs sportonkénti oszlop-bontás (az adat megvan, a felület később kaphatja) |

### 4.5/D-1 (pénzügyi trend, előfizetés-felismerés, CSV-export) – kész, a build után kipróbálandó

Tesztek: mag 877 (volt 794), app 2260 (volt 2203), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 353 szándékos elrontás (az első menetben 350-ből 318 bukott el, a 32 átmenő: 27 tesztelési hiány – a számítási rétegben 18, az oldalon és a rajzolóban 9 –, 4 felesleges kód (egyszerűsítve: az átlag első őre, a napon belüli azonosító szerinti rendezés az előfizetés-felismerőben, a törölt ismétlődő szabály szűrése) és 1 egyenértékű (a 60 karakteres név levágásának küszöbe); a végső listán az egyenértékű kivételével mind elbukik).

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| számítás | kész | `kvantum_core/src/finance_trends.dart`: `monthlyTotals` (a hónapok az utolsóig, az üres hónap nullákkal, törölt tétel kimarad, 1–60 hónap), `averageMonth` (csak a teljes, nem üres hónapok; a mostani kimarad; üresre `null`), `topExpenseCategories` (azonos összegnél az azonosító dönt), `buildTrend` (magyar mondatok, `TrendData`); `compactHuf` (`finance.dart`: „500 e Ft”, „1,5 M Ft”, a 999 950 már millió) |
| előfizetés-felismerés | kész | `subscriptions.dart`: `subscriptionKey` (ékezet nélkül, csak betű és szám, a számot tartalmazó szó – referencia, kártyaazonosító – kimarad), `detectSubscriptions` (havi: ≥ 3 tétel, 24–38 nap; éves: 2 tétel, 350–380 nap; az összegek aránya ≤ 1,25; él: ≤ 45 / ≤ 400 nap; ismétlődő tételből jött és ismert kereskedő kimarad; havi összeg szerint rendezve), a következő díjnap a hónap hosszára vágva |
| CSV | kész | `finance_csv.dart`: `exportTxCsv` (BOM, `;`, CR LF, ISO dátum, előjeles egész összeg, törölt tétel nélkül, napokra szűrhető), `csvCell` (képlet-injektálás elleni aposztróf: `= + - @ \t \r`, idézőjelbe tett pontosvesszős / idézőjeles / soremeléses cella) |
| diagram | kész, javítva | `charts.dart`: `niceMoneyMax` (finomabb lépcső: a legmagasabb oszlop ≥ a kép kétharmada), `BarChart.color`, **`labelWidth` + `plotLeftFor` + `BarChartPainter.plotLeft`**: a skálafelirat nem vágódik le a kép szélén (a kirajzolt kép valódi betűvel mutatta ki; a teszt a rajzolás hívásain mér: sehol sem lóg ki balra) |
| fül | kész | `ui/finance/finance_trend_tab.dart` (`TrendTab`), a `FinancePage` hat fülön (Áttekintés · **Trend** · Tételek · Keretek · Ismétlődők · Célok); a „Felvétel ismétlődőként” a meglévő `saveRecurring` + `ensureRecurring` útján megy; az export a meglévő `BackupIo.save`-en (`text/csv`) |
| szövegek | javítva | az üres hónap a szöveges táblázatban „nincs rögzített tétel” (nem „0 Ft”); a „Felvétel ismétlődőként” gombját a képernyőolvasó a kereskedő nevével kapja; felesleges kód kikerült (az átlag első őre, a napon belüli azonosító szerinti rendezés az előfizetés-felismerőben, az üres kulcs és a törölt szabály szűrése az ismétlődő szabályok kulcsainál: a szándékos elrontások próbája mutatta ki, hogy semmire nem hatottak) |
| tesztek javítva | javítva | két teszt 2×-es betűmérettel a táblázat megnyitása nélkül ment át (a koppintás célt tévesztett): most előbb látótérbe hozza és a megnyílt sort is ellenőrzi |
| megfigyelések | nyitva | (1) a diagramok és a kártyák kinézete valódi eszközön; (2) a CSV megnyitása valódi táblázatkezelőben; (3) az előfizetés-felismerés a valódi tételeken; (4) a Trend fül sebessége több ezer tétellel; (5) csak forint |
| eltérések | – | **Eltérés a tervtől:** (1) a hónap-/évtrend két külön oszlopdiagram, nem egy kettős: a kiadás és a bevétel skálája jelentősen eltérhet, és a közös skála az egyiket összenyomná; (2) az éves előfizetéshez nincs „Felvétel ismétlődőként” (az ismétlődő tétel csak havi); (3) a CSV-export mostani hónap / időszak / minden tétel, szűrő (kategória, kereső) nélkül; (4) a többpénznem a D-2-be, a bank-CSV import a D-3-ba, a keret-értesítés és a bérbecslés a D-4-be kerül |

### 4.5/D-2 (külföldi pénznem) – kész, a build után kipróbálandó

Tesztek: mag 909 (volt 877), app 2305 (volt 2260), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). 197 szándékos elrontás: az első menetben 191 bukott el, a 6 átmenő mind tesztelési hiány volt (a magban három: a magányos zárójel, a többször előforduló elválasztó, az árfolyam fél-kerekítése; az oldalon három: a nulla összeg a forintérték-sorban, a forint mentése nem jegyez meg árfolyamot, a Törlés gomb távolsága), mindre új teszt készült; a végső listán mind elbukik, egyenértékű nincs.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| modell | kész | `kvantum_core/src/finance_currency.dart`: `FinForeign` (pénznem, összeg századokban, árfolyam; `==`, `toJson` / `fromJson`: a használhatatlan rekord `null`), `forintsFor` (a század × az árfolyam, egész forintra kerekítve), `normalizeCurrency` (három nagybetű, nem HUF), `commonCurrencies`; `FinTx.foreign` + `copyWith(foreign, clearForeign)`; a JSON-kulcs `fx` (`cur`, `c`, `r`), a régi olvasó figyelmen kívül hagyja, az ismeretlen forrás kézi lesz |
| olvasás, írás | kész, javítva | `parseCents` (előjeles század; tizedesvessző / -pont, ezres-elválasztók: szóköz, nbsp, aposztróf, pont / vessző; mínusz-jelek, zárójel; pénznem-jelek elhagyva), `parseRate` (négy tizedes, > 0, ≤ 100 000; **az egyedüli elválasztó mindig tizedes**), `plainCents`, `formatForeign` (nbsp), `formatRate`, `foreignLine`; **javítva:** az árfolyam „2,512” alakját ezresnek (2512) olvasta, így a kiírt árfolyam visszaolvasása is elromlott (új tesztek: kimondott esetek + körút) |
| szerkesztő | kész | `finance_editors.dart`: Pénznem-választó (Ft, 13 gyakori, Másik pénznem…), összeg a pénznemben, árfolyam-mező, forintérték-sor; váltáskor tiszta átmenetek (forint ↔ pénznem ↔ pénznem); a késve érkező „utolsó árfolyam” a saját pénznemének jár, és nem írja felül a beírtat; elutasítás: nem szám, nulla / negatív, hiányzó árfolyam, < 1 Ft, túl nagy |
| tár | kész | `FinanceRepository.lastRate` / `rememberRate` (meta `fin.rate.<KÓD>`; csak az eszközön, nem megy levélben) |
| felület | kész | a tételek listája és a keresés találata: `foreignLine` az összeg mellett (az eredeti összeg és az árfolyam) |
| CSV | kész | három új oszlop (*Eredeti összeg*, *Pénznem*, *Árfolyam (Ft)*), a fejléc 10 oszlopos |
| útközben javítva | javítva | a tétel-szerkesztő gombsora keskeny telefonon vagy nagy betűnél túlcsordult (117 képpont 360 px-en, 2×-es betűmérettel; keskenyebb telefonon 1×-nél is; a korábbi kódon is megvolt): sortörő, jobbra zárt gombsor |
| megfigyelések | nyitva | (1) a szerkesztő kinézete valódi eszközön; (2) a tizedesvessző / -pont a valódi telefon-billentyűzeteken; (3) a régi appverzió az `fx` kulcsot nem őrzi meg szerkesztéskor; (4) csak kézzel beírt árfolyam |
| eltérések | – | **Eltérés a tervtől:** (1) az árfolyamot nem kérdezi le a hálózatról (nincs ingyenes, kulcs nélküli, megbízható forrás; a tétel azt őrzi, amit beírtál); (2) a Wallet külföldi összegét továbbra sem veszi fel magától; (3) az ismétlődő tételek csak forintban; (4) a többpénznem nem jelent többpénznemű keretet vagy összesítőt – minden összeg a forintértékben számol tovább |

### 4.5/D-3 (bank-kivonat importálása) – kész, a build után kipróbálandó

Tesztek: mag 1376 (volt 909), app 2403 (volt 2305), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). Szándékos elrontás: a magon 428 (mind elbukik), az alkalmazás oldalán 210: az első menetben 207-ből 171 bukott el; a 36 nem elbukó közül 1 érvénytelen volt (nem fordult), 35 átment: 27 tesztelési hiány (mindre új teszt készült) és 8 felesleges kód (egyszerűsítve; egyikről – az üres fejléc őréről – a második menetben derült ki, hogy felesleges); a második menetben (92 elrontás: a túlélők és az átírt kód) még egy tesztelési hiány derült ki (az üres árfolyam-mező még nem hiba), és a végső listán mind elbukik.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| fájl | kész | `kvantum_core/src/text_decode.dart`: `decodeText` (UTF-16 bájtsorrend-jel → UTF-16; különben szigorú UTF-8; ha az nem megy, Windows-1250: `windows1250High`); `csv_parse.dart`: `detectDelimiter` (`;` tabulátor `,` `|`; idézőjeleken kívül, a leggyakoribb darabszámú sorok), `parseCsv` (idézőjelek, kettőzött idézőjel, sortörés a cellában, a BOM nem része az első cellának; `maxRows`) |
| oszlopok | kész | `bank_mapping.dart`: `BankField`, `DateOrder`, `BankMapping` (JSON: `fromJson(…, szélesség)` a használhatatlan emléket `null`-ra veszi), `findHeaderRow`, `headerFields`, `guessMapping` (fejlécszavak a legtelibb elöl; az, amit a fejléc nem mond, a cellákból: dátum ≥ 80 %, összeg ≥ 80 %, kereskedő / megjegyzés szöveges oszlop; az irány-oszlop csak ha az összegek előjel nélküliek és a cellák irányt neveznek), `parseBankDate` (ISO, `2026.11.13.`, `2026. 11. 13.`, `13.11.2026`, `13/11/2026`, `11/13/2026` a megadott sorrend szerint, `13.11.26`, `20261113`; az idő elhagyva), `guessDateOrder`, `looksLikeAmount`, `directionOf`, `headerSignature` (a fejléc ékezet- és kisbetű-független ujjlenyomata), `currencyOf` / `badCurrency` |
| terv | kész | `bank_import.dart`: `planBankImport` (soronként dátum, összeg – egy oszlop előjellel / „irány” oszlop / terhelés + jóváírás –, pénznem; kimaradó sorok `ImportIssue`-val: a dátum nem olvasható, az összeg nem olvasható, nulla, 1 Ft alatt, túl nagy, mindkét oldal, nincs irány, ismeretlen pénznem, nincs árfolyam), `ImportRow.id` = `imp-<ujjlenyomat>-<hányadik az azonos sorok között>` (**stabil: a `fingerprint` soha nem változhat**, golden-tesztek őrzik), `ImportRow.toTx`, `fingerprint` (két 32 bites hash, 16 hexa jegy), `findDuplicates` (`known`: a könyvelésben van – a törölt is –; `similar`: ugyanolyan fajta és összeg, ≤ 3 nap, nem importált, egy tétel egy sornak) |
| tár | kész | `FinanceRepository.allTxIds` (a törölt is), `merchantCategories` (a még létező kategóriák, kereskedőkulccsal), `addImported` (egy tranzakció; ami már a könyvelésben van, kimarad; egyszer kér szinkront), `undoImport` (mind vagy semmi, csak ha minden sor még az, amit az import írt: azonos `updatedAt`), `bankMapping` / `rememberBankMapping` (meta `fin.bank.<ujjlenyomat>`, csak az eszközön); `ImportMark`; `FinSource.imported` (CSV-ben: `import`; a régi olvasó kézinek látja) |
| felület | kész | `lib/ui/finance/bank_import_page.dart`: három lépés (fájl · oszlopok · áttekintés), a vissza-nyíl és a rendszer-vissza egy lépést lép vissza; a „Tovább” és az „Importálás” alsó sávban; legördülők (fejléc-sor, az összeg módja, oszlopok, a dátum alakja); az első három sor; kategória-párbeszéd kereskedőnként; árfolyam-mezők; „Kimaradó sorok”; `Visszavonás` a közös sávon; Pénzügyek-oldal feltöltés-ikon; bank-ikon a tételek listájában |
| határok | kész | 5 MB, 20 000 sor, a lista lusta, a kereskedő 80, a megjegyzés 200 karakter; a fájl a gépen marad |
| útközben javítva | javítva | „Befizetés” = bevétel (a „fizet” szótő nem kiadás); az Excel- / zip- és PDF-jel négy bájtos (a „Partner;…” CSV bemegy); a „Terhelés és jóváírás” váltó legördülő lett (2× betűnél szétcsúszott); a „Tovább” alsó sávban; az árfolyamra váró sor nem „kimarad”; a második koppintás a „Tovább”-on és az „Importálás”-on nem indít újat; a „hasonló” keresése keresőtáblából dolgozik (20 000 × 20 000: 6,2 s → 0,2 s; a tábla a fajtára és az összegre / a pénznemre és a külföldi összegre kulcsol, és a találat sorrendje a könyvelésbeli sorrend) |
| megfigyelések | nyitva | (1) valódi bankfájl nem volt; (2) a valódi fájlválasztók (Android SAF, Windows) és a kinézet valódi eszközön; (3) csak UTF-8 / UTF-16 / Windows-1250; (4) 20 000 sor sebessége telefonon; (5) a saját számlák közti átutalás két tétel; (6) a „hasonló” 3 napos ablaka becslés |
| eltérések | – | **Eltérés a tervtől:** (1) nincs bankonkénti beépített minta (egy sem volt kéznél) – általános oszlop-megfeleltető varázsló készült, amely megjegyzi a választást; (2) a PDF- és Excel-kivonat nem olvasható (CSV kell); (3) a Visszavonás a 10 másodperces sávon él, utána egyenként törölhetők a tételek |

### 4.5/D-4 (keret-értesítés és bérbecslés) – kész, a build után kipróbálandó

Tesztek: mag 1459 (volt 1376), app 2470 (volt 2403), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). Szándékos elrontás: a magon 142, az alkalmazás oldalán 101: az első menetben a magon egy (PL3: a „rec-” előtagot az azonosító bármely helyén szabálynak vette – ezt a teszt nem ellenőrizte), az alkalmazás oldalán egy (SC29: a kártya adatvédelmi mondatának tartalmát nem ellenőrizte teszt) ment át, mindkettőre szigorúbb teszt készült; a bérbecslés kártya képernyőolvasó-mondataira utólag írt kilenc további elrontás elsőre elbukott; a végső listákon mind elbukik, egyenértékű nincs.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| keret-értesítés – mag | kész | `kvantum_core/src/budget_alerts.dart`: `planBudgetAlerts` (a szint a `BudgetStatus.level`; csak az emelkedés hír; a memória a legutóbb látott szint, hónaponként; az ismétlődő szabályok (`rec-…` azonosító) okozta szint nem hír), `currentBudgetLevels` (bekapcsoláskor a fennálló szint csendes alapállapot), `budgetAlertMessages` (3-nál több átlépés egy listában, 6 sor + „…és még N”), `encode/decodeBudgetMemory`, `budgetMonthKey` |
| keret-értesítés – app | kész | `notify/budget_notify.dart` (`BudgetNotifier` külön interfész; Android csatorna `budget`; Windows `ToastBackend.show`; `budgetNotificationId` FNV-1a), `notify/budget_alerts.dart` (`budgetAlertsProvider` 1,5 s sűrítéssel a főoldalról; meta `bud.alerts` / `bud.alert.<év-hó>`, csak az eszközön; engedélykérés bekapcsoláskor); Beállítások → Értesítések → Költségkeret (csak ahol az eszköz tud értesítést mutatni) |
| bérbecslés – mag | kész | `pay_estimate.dart`: `estimatePay` (percre pontos szakaszolás: esti 18–22, éjszakai 22–6; napfajta a perc naptári napja szerint: ünnepnap > vasárnap > szombat; összeadódik; soronként kerekítve), `PaySettings` (JSON, tűrő olvasás, értékhatárok 1 000 000 Ft/óra és 1000 %) |
| bérbecslés – app | kész | `ui/shift_pay_card.dart`: kártya a Beosztás oldalon a havi összesítő alatt, beállító párbeszéd; meta `pay.settings`, csak az eszközön (nincs szinkron, nincs az asszisztensnek, nincs a mentésben; forrásőr-teszt) |
| útközben javítva | javítva | a szünetelő stream-szolgáltatók (Riverpod 3) miatt a bekapcsolás és a nevek az adatbázistól kérdeznek; a `ToastBackend` közös a Windows-os emlékeztetők és értesítések közt; a Beosztás-oldal tesztjei a lejjebb került listához igazítva |
| megfigyelések | nyitva | (1) az értesítések megjelenése valódi Androidon / Windowson; (2) a bérbecslés a te beosztásoddal és szerződéseddel; a törvényi pótlékokat nem állítom (a számok a felhasználóéi); (3) két eszközön mindkettő jelezhet; (4) a Wallet-tétel értesítése az app megnyitásakor jön |
| eltérések | – | **Eltérés a tervtől:** az esti sáv 18–22 (a terv 14–22-t írt) – a webes keresés szerint a törvényi műszakpótlék-ablak 18–6, és ez a te 06–18 / 18–06 beosztásodhoz is illik; „Szokásos értékek betöltése” gomb nincs (a szabályokat nem tudtam hitelesen megerősíteni) |

## 5. fázis, 2. rész (biztonság és kiadás)

### SEC-3, SEC-15, SEC-4, SEC-14 és a kiadási folyamat – kész, a build után (és a workflow-PR beolvasztása után) kipróbálandó

Tesztek: app 2627 (volt 2470), mag 1459 (változatlan), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0). Szándékos elrontás a frissítő kódján: **168**; az első menetben 166-ból 156 bukott el; a többi 10: 3 felesleges kód (a base64-olvasó átfedő ágai – törölve), 5 tesztelési hiány (az ellenőrző összeg fájljának kétféle elrendezése, a takarítás pontos időhatára, a konfiguráció kulcs-olvasása és az indításkori takarítás Androidos mappája – mindre új teszt), 1 egyenértékű (a takarítás `followLinks: false` argumentuma: nem rekurzív listázásnál nincs hatása) és 1 érvénytelen elrontás (átírva, elbukik); a végső listán 164 elbukik, a maradék négy közül három a törölt kódra írt, egy egyenértékű

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| SEC-3 aláírt frissítés | kész (fokozatos) | `update/update_signature.dart` (`updateSignatureMessage`, `decodeLenientBase64`, `parseUpdatePublicKeys`, `decodeUpdatePublicKeys`, `verifyUpdateSignature` – sosem dob), `ed25519_edwards` 0.3.2; háromállapotú döntés a `download()`-ban (nincs kulcs → a régi; kulcs + `.sig` → érvényes kell; kulcs, `.sig` nélkül → átmegy, amíg `UPDATE_REQUIRE_SIGNATURE` nincs); kulcs nélkül a kötelezés zárt irányba hibázik; több kulcs vesszővel; a `.sig` a csomag előtt jön, ≤ 4096 bájt; a teszt-vektorokat valódi OpenSSL készítette (RFC 8032 TEST 1–3 is); útmutató: `docs/alairt-frissites.md` |
| SEC-15 a frissítő megerősítése | kész | `isUpdateApiUrl` (https + hoszt + port; a token csak a GitHub API-nak), titkosítatlan cím / átirányítás megtagadva, kézi átirányítás ≤ 5, a csomag ≤ 400 MB (`maxPackageBytes` – a teszteknek állítható), a jelzett és a kapott méret egyezik, a letöltés megszakad, ha többet kapna, a félbemaradt letöltés törlődik; `UpdateService.recheck(File)` közvetlenül a telepítés előtt (a letöltéskor ellenőrzött összeget memóriában tartja; idegen vagy megváltozott fájl: megtagadva és törölve); `cleanupUpdateLeftovers` (24 óránál régebbi, az `update.log` marad; induláskor, nem blokkol); zip: ≤ 10 000 fájl, ≤ 600 MB kibontva (deklarált méretekből, írás előtt) |
| SEC-4 kulcs-lejárat | kész | `parseTokenExpiry` (a `github-authentication-token-expiration` fejléc: `ÉÉÉÉ-HH-NN ÓÓ:PP:MM UTC`, ISO, eltolás, csak dátum; hibás / hiányzó = nincs), `tokenExpiryWarning` (14 nap, „lejárt” külön szöveg), a Frissítés ablak ikonnal és szöveggel jelzi (az app órájából számol); `docs/frissito-kulcs.md` |
| SEC-14 Android-engedélyek | kész, részben | a `READ_EXTERNAL_STORAGE` és a `READ_MEDIA_*` (az `open_filex` hozza) `tools:node="remove"`-val kikerül; szöveges teszt (`android_manifest_test.dart`) a várt engedély-halmazra és a letöltési mappa helyére; **a `FileProvider` `root-path`-ja marad** (a telepítés rá épül, Androidot itt nem tudok fordítani) |
| SEC-1 / SEC-18 csatornák | kész, a beolvasztás a tulajdonosé | külön workflow-PR (#5, `ci/release-hardening`, piszkozat): `main` / `v*` → stabil (a CI zöld rajta, legföljebb 25 perc várakozás), minden más ág → előzetes; **a PR beolvasztása után a feladatági `[build]` kiadások előzetesek lesznek** |
| CMP-2, CMP-3 | tanácsadó | PR #5: `zipalign -c -P 16`, engedély-lista és minSdk / targetSdk a futás összegzésében; Windows VC++ DLL-ek a kiadási mappában – nem buktatnak, amíg egyszer nem láttam zölden |
| CMP-6, QA-4 CI-sorok | kész (PR #5) | heti `pub outdated` (`deps.yml`), a CI-ban `dart format` ellenőrzés, lefedettség-összegzés (tanácsadó), `permissions: contents: read`, `concurrency` (a `main` nem szakad meg) |
| útmutatók | kész | `docs/alairt-frissites.md` (kulcspár OpenSSL-lel, titok és változó, ellenőrzés, kötelezővé tétel, kulcscsere, hibaelhárítás), `docs/frissito-kulcs.md` (a token, a lejárat, a csere) |
| útközben javítva | javítva | (1) a Frissítés ablak „Frissítés keresése…” sora túlcsordult 2× betűnél keskeny telefonon (a korábbi kódon is): `Expanded`; (2) az ablak tartalma 2× betűnél hosszabb a képernyőnél: görgethető; (3) a figyelmeztető ikon a betűvel nő; (4) a mutációs próba felesleges kódot talált, amely törölve / egyszerűsítve: a base64-olvasó két átfedő ága (a Dart olvassa az URL-biztos írásmódot, és az aláírás hosszát a könyvtár ellenőrzi), a token-dátum redundáns feltételei (egyetlen próbával, hogy a hónap létezik-e), a takarítás felesleges `existsSync` őre (a kivétel úgyis elnyelődik), az órára tett felesleges `.toUtc()`; (5) a `_isApi` nyilvános, táblázatosan tesztelhető függvény lett (`isUpdateApiUrl`) |
| megfigyelések | nyitva | (1) a kiadási folyamat a valódi GitHub-futtatón (az Actions akadt): `gh`, `apkanalyzer`, `zipalign`, a PowerShell-lépés, a kiadás-feltöltő action; (2) aláírt kiadás valódi frissítésen (Windows-csere, Android-telepítő): a kulcspár és a titok beállítása után az első két aláírt kiadás; (3) a `github-authentication-token-expiration` fejléc megléte a te kulcsodnál; (4) az összevont Android-manifest valódi buildben; (5) a Frissítés ablak kinézete valódi eszközön; (6) a `UPDATE_PUBLIC_KEY` / `UPDATE_REQUIRE_SIGNATURE` define a valódi `flutter build`-ben (a tesztekben nincs define, ezért ott a szöveges őr és egy egyszeri próba fedi) |
| eltérések | – | **Eltérés a tervtől:** (1) a `READ_EXTERNAL_STORAGE` is kikerül (a terv meghagyta); (2) a zip-védelem deklarált méretekre épül, a memóriahasználat átírása (folyamatos olvasás) nem készült; (3) `UPDATE_REQUIRE_SIGNATURE` kulcs nélkül zárt irányba hibázik, és a workflow ilyenkor a buildet is leállítja; (4) a `maxPackageBytes` a tesztekhez állítható; a titkos kulcsot a program nem látja, nem kéri, nem hozza létre (a kulcspárt te készíted az útmutató szerint) |


## 5. fázis, 3. rész (minőség és rend)

### CMP-4/5, QA-2, QA-3, QA-4 helyi része, lint, dokumentáció – kész, a build után kipróbálandó

Tesztek: app 2 705 (volt 2 627), mag 1 553 (volt 1 459), az elemzők és a formázás tiszták (Flutter 3.47.9 és 3.50.0, friss klónon is); a teljes csomag zöld négy időzónában, véletlen sorrendben és terhelés alatt is. Szándékos elrontás: **108** (a végső lista 91 elrontása + 17 utólagos). A végső lista (91): 29 az `.ics`-kezelés és az időzónák magjában, 23 a mentés-előnézetben, a fájl beolvasásában, a szinkron szünetében, az import értesítésében, a hibasávban és a Frissítés ablakban, 10 az őrző-tesztben, 29 a lefedettségi eszközben; ehhez jön 17 az utólagos ellenőrzésben (a Google-lehúzás EXDATE-elágazása 2, az egy óra bekötései 13, a Beállítások kártyáinak keep-alive-ja 2); **a végső kódon, friss másolatokon mind a 108 elbukik.** Az első menetben 95-ből 80 bukott el; a 14 túlélő közül 11 tesztelési hiány volt (mind pótolva: a hétkezdet-figyelmeztetés csak heti szabálynál, az egyszavas IANA-zónanév, az „RRULE:” előtagos szabály, a nem átváltható szabály előtag nélküli visszaesése, az átrakott nap sorának párosítása és új azonosítója, a hibasáv színe, az őrző-teszt kivételének hatóköre, az lcov-összeadás, a „lib/” útvonal, a jelentés fájl-száma), 3 felesleges kód (törölve: az üres zónanév külön ága, a Google-lehúzás EXDATE `VALUE=DATE` paraméter-vizsgálata, a lefedettségi eszköz soha nem használt alapértékei); 1 érvénytelen elrontás (nem fordult) átírva.

| Tétel | Állapot | Megjegyzés |
|---|---|---|
| CMP-5 minták (.ics, Google JSON) | részben | `packages/kvantum_core/test/fixtures/ics/` (Apple-, Outlook-, Google-stílus), `apps/kvantum_app/test/fixtures/google/` (7 JSON); **kézzel írt minták, nem valódi exportok** – a CMP-5 addig „részben”, amíg valódi exportot nem küldesz; a `.gitattributes` (`*.ics -text`) bájtpontosan őrzi a CRLF-et és a BOM-ot |
| ① ② ②b ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ | kész | ① az `.ics`-mentés sosem dob; ② + ②b a mentés-előnézet kanonikus szabály- és kiesett nap-összevetése; ③ + ⑥ Windows-zónanevek és minden időpont a saját zónájában (`ianaZoneOf`, `windowsZoneNames`); ④ `STATUS:CANCELLED`; ⑤ `EXDATE;VALUE=DATE-TIME`; ⑦ a Google fájlja = az eszköz eseménye (iCalUID); ⑧ az árva átrakott nap önálló esemény; ⑨ az áthajtott többbájtos betű (`decodeCalendarBytes`); mind egy-egy commit, a javítás nélkül bizonyítottan piros teszttel |
| figyelmeztetések | kész | RDATE, EXRULE, `RANGE=THISANDFUTURE`, WKST ≠ MO több napos kétheti szabálynál, UTC-ben rögzített sorozat; az import értesítése az első problémát szó szerint is mutatja |
| QA-2 szétbontás | részben | `assistant_service.dart` 1 670 → 708 sor (`part` + privát kiterjesztés, a régi fájl újra-exportál; a sorok halmaza egyezik), `settings_page.dart` 1 187 → 574 sor (két állapotos kártya `AutomaticKeepAlive`-val és a beleegyezés-ablak külön fájlban; `settings_split_test`); nem része: `quick_entry` 1 085, `assistant_page` 921, `bank_import_page` 908, `event_editor` 908 |
| QA-3 várakozások és órák | kész | 36 valós várakozás (≈ 11 s) → az eseményhurok fordulói / `FakeAsync` / beinjektált szünet és óra; három falióra-állítás kikerült (`SyncEngine.pause`); őrző-teszt (`no_real_waits_test`); egy óra (`appClockProvider`; a szolgáltatók, a tárak bélyege, a mentés `DTSTAMP`-je, a mentés-fájlok neve, a feladat-lista sorrend-alapja, a cél határidő-választója); a „most”-ra támaszkodó tesztek rögzített órán |
| QA-4 helyi rész | kész | `dart tool/coverage.dart` (+ `tool/lcov.dart`, 28 teszt a magban): app **93,4 %** (13 637 / 14 606 sor, 137 fájl), mag **97,1 %** (3 963 / 4 083 sor, 40 fájl) sorfedettség; a generált kód nem számít; lint: 21 új szabály mindkét csomagban |
| `material_ui` próba | kész (nem épül be) | külön másolaton a csomag + `dart fix --apply`: 203 javítás 95 fájlban (98 fájl, +134 / −131 sor), a `GlobalMaterialLocalizations` ütközés három fájlban kézzel; Flutter 3.50.0-n a próba idején mind a 2 699 app-teszt zöld volt, 3.47.9-en az elemzés tiszta; a beépítés külön döntésre vár (lásd `docs/verzio-frissites.md`) |
| dokumentáció | kész | `docs/ARCHITEKTURA.md`, `docs/DONTESI-NAPLO.md`, `docs/verzio-frissites.md`, a README és a CHANGELOG frissítve; ez a záró átnézés |
| útközben javítva | javítva | (1) a Frissítés ablak „Letöltés… 100%” sávja sikertelen telepítés után az üzenet mellett maradt – most eltűnik (`update_security_test`); (2) a `unawaited_futures` lint egy valódi hibát talált: a `gemini_test` helyi `fail` függvénye eltakarta a teszt-keretrendszerét; (3) a mentés-előnézet az eszköz saját mentését „módosultnak” mutatta (②, ②b) |
| megfigyelések | nyitva | (1) valódi Apple / Outlook / Google export még nem volt kéznél; (2) a Beállítások kártyáinak viselkedése valódi eszközön; (3) a `material_ui`-ra áttérés (csak próba); (4) a lefedettségi eszköz Windowson (Linuxon próbáltam); (5) a legkevésbé fedett fájlok (`main.dart`, `google_auth_service.dart`, `wallet_bridge.dart`, `db.dart` migrációs ága) a rendszerre épülő rész: valódi eszközön próbálhatók |
| eltérések | – | **Eltérés a tervtől:** (1) a Beállítások-oldal szétbontása három részt emelt ki (két kártyát és a beleegyezés-ablakot; a terv ≈ 590 sort írt, lett 574); (2) a `RetryAfterClient` kérésszámlálója és a Google-lehúzás időablaka nem kapott órát (a számláló / ablak a valódi időt méri); (3) a `DateTime.now()` marad a gyökér-órában, a napló időbélyegében, a frissítő fájlnév-utótagjaiban és a fájl-mtime alapú takarítás tesztjeiben (indokolt) |

## I. ZÁRÓ ÁTNÉZÉS (a teljes kör vége: 2026-11-14)

A 98 azonosító (SEC 19, REL 28, AI 25, UX 13, CMP 8, QA 5) állapota a végrehajtási napló és a kód átnézése alapján: **77 kész**, **14 részben**, **3 halasztva**, **2 nem cél**, **2 információ** (nem teendő).

**Nem része a körnek (kimondva):** SEC-10 (az OAuth-hatókör szűkítése – élő ellenőrzés kell), a **G** csomag (alkalmazászár, titkosított adatbázis), a **H** csomag (helyi tartalék-tervező), a Windows kódaláírás (korábbi döntés), a Pénzügy+ bank-formátum-minták (valódi bankfájl nincs). **A te teendőid:** a GitHub Actions / Billing rendbetétele és az „Re-run all jobs”; a workflow-PR (#5) átnézése és beolvasztása; az aláíráshoz kulcspár + titok + változó; az új funkciók élő kipróbálása; valódi Apple / Outlook / Google export és bankfájl küldése mintának.

| Azonosító | Állapot | Mi az, és mi lett |
|---|---|---|
| SEC-1 | részben | A feature-ági [build] is „latest” kiadás: minden eszköz jóváhagyatlan … – a csatornák (stabil / előzetes) a workflow-PR-ban (#5, piszkozat; a beolvasztás a tiéd); az app „Előzetes verziók” kapcsolója kész; Environment-jóváhagyás, SHA-pin, CODEOWNERS nem készült |
| SEC-2 | kész | Elavult egyéni URL felülír minden OpenAI-kompatibilis szolgáltatót: a … – 0. fázis |
| SEC-3 | kész | Frissítés: integritás igen, hitelesség nem (a SHA-256 ugyanabból a … – fokozatos Ed25519; élesítés: kulcspár + titok + változó + a workflow-PR beolvasztása + új build (a tiéd) |
| SEC-4 | kész | A beégetett UPDATE_TOKEN és Google client secret kinyerhető a … – lejárat-figyelmeztetés + útmutató; a token a binárisban marad (döntés) |
| SEC-5 | kész | Android Auto Backup: nincs allowBackup/dataExtractionRules → a DB … – 0. fázis |
| SEC-6 | részben | SQLite titkosítatlan; Windowson Documents\kvantum.sqlite … – a Windows-adatbázis a %LOCALAPPDATA%-ban; a titkosítás (G csomag) kizárva |
| SEC-7 | kész | Wallet-értesítések nyersen és korlátlan ideig maradnak a … – 0. fázis |
| SEC-8 | kész | A szabálysértési visszajelzés megkerüli a megosztási kapcsolókat és a … – 0. fázis |
| SEC-9 | kész | Az AI-alapértelmezések mind BE ; a kézikönyv (profil: sérülések, célok) … – 2c: beleegyező párbeszéd, Kézikönyv-kapcsoló |
| SEC-10 | halasztva | A calendar hatókör az összes naptárat eléri; a tulajdonos-szerepű, … – élő ellenőrzés kell (`calendar.app.created` naptárlista nélkül); nem része a körnek |
| SEC-11 | kész | Az egyéni végpont http:// és bármely host lehet; a Gemini hibaszöveg … – 0. fázis |
| SEC-12 | kész | Modell-jogosultság és injekció-rések: új javaslatok előre kijelöltek; … – 0. fázis |
| SEC-13 | kész | Saját hiba: isAuthExpired a „failed to obtain access credentials” … – 0. fázis |
| SEC-14 | kész | open_filex felesleges média-engedélyeket és root-path FileProvidert … – az engedélyek törölve; a FileProvider marad (maradék-kockázat) |
| SEC-15 | kész | Frissítő finomságok: a token hozzáadása csak host-egyezésen múlik … – zip-védelem deklarált méretekre; a memóriahasználat átírása nem készült |
| SEC-16 | részben | Drive appData sima JSON, a levelek feladója nincs hitelesítve, az … – óraeltérés-észlelés + max(óra, meglévő + 1); a bejövő bélyeg lefogása nincs (döntés) |
| SEC-17 | részben | Export fájlok (pénzügyi JSON, .ics) titkosítatlanok, a MIME … – a jelentés `text/plain`, az automatikus mentés jelszavas zip lehet; a kézi export titkosítatlan; zár és FLAG_SECURE: G csomag (kizárva) |
| SEC-18 | részben | Helyi release-build csendben debug-kulcsra esik vissza ; a flutter … – Flutter-pin kész (PR #4); a CI-kapuk, jogosultságok, release ← tesztek a workflow-PR-ban (#5) |
| SEC-19 | részben | A .gitignore secrets* mintája a secrets.example.json-t is elrejti, … – a minta és a `secrets.example.json` rendben; a `deviceId` 32 bites marad |
| REL-1 | kész | Egyetlen nem támogatott/hibás RRULE (pl. WKST=SU – a rrule csomag csak … |
| REL-2 | kész | Az első alkalommal látott kivétel-példány (Google-felületen … – 1a; élő Google-viselkedés nem ellenőrizve |
| REL-3 | kész | A Calendar/Drive HTTP-hívásoknak nincs időkorlátja (a … |
| REL-4 | kész | A teljes újraszinkron (410 után) tükörtörli a helyi, linkelt … |
| REL-5 | kész | Pénzügyi postaláda: a > 180 napja néma társ a known-ban marad → … |
| REL-6 | kész | Visszaállított/klónozott DB ugyanazt a deviceId-t használja (a levelek … |
| REL-7 | kész | Újrapróbálás: a quotaExceeded/calendarUsageLimitsExceeded … |
| REL-8 | kész | Lekérdezési költség: idle ciklus ≥ 5 hívás/perc (≈ 7 200/nap), a … – adaptív ütemezés; háttér-szinkron nincs |
| REL-9 | kész | Utolsó-író-nyer eszközórákkal: óraeltérés vagy jövőbeli bélyeg tartósan … |
| REL-10 | kész | A lehúzás nem hibaizolált: törölt Naptar-naptár → percenként Instance … |
| REL-11 | kész | events.update (PUT) törli a Google-oldali mezőket (emlékeztetők, … |
| REL-12 | részben | A távoli törlés elnyeli a fel nem töltött helyi szerkesztést; az … – a szerkesztő mentése egészében érvényes (nincs mezőszintű összefésülés); a kapcsolat megmarad, a távoli törlés nem viszi el a függő szerkesztést |
| REL-13 | kész | .ics import/export: az import felülírja az újabb helyi módosítást; az … |
| REL-14 | kész | A többlépéses írások nem tranzakciósak (műszak-generálás ≈ 90 külön … |
| REL-15 | kész | Olvas-módosít-ír versenyek: edit vs applyRemote, saveTx vs … |
| REL-16 | kész | Nincs formátum-verziókapu: a v:1 íródik, de nem olvasódik; az újabb … |
| REL-17 | kész | A migráció nem tranzakciós (a onUpgrade közvetlenül hívódik ), romboló … |
| REL-18 | kész | Korlátlan növekedés és hiányzó indexek: a tombstone-ok sosem … |
| REL-19 | kész | Emlékeztetők: minden esemény-/check-in stream-emisszióra cancelAll + ≤ … – különbség-alapú ütemezés, Windowson is; pontos riasztás (USE_EXACT_ALARM) kimarad |
| REL-20 | kész | expand() minden tickre minden sorozatot az elejétől járja, … |
| REL-21 | kész | Időzóna: a kijelzés Europe/Budapesthez kötött, a „ma” az eszköz … |
| REL-22 | kész | Nincs összeomlás-/hibarögzítés (FlutterError.onError/runZonedGuarded … |
| REL-23 | halasztva | Bootstrap-szinkron O(N²) és mindent-vagy-semmit (a Drive-token csak a … – alacsony súly: a bootstrap-szinkron oldalankénti haladása nem készült |
| REL-24 | kész | Wallet: a natív sor kiolvasáskor azonnal törlődik , a könyvelés előtt → … |
| REL-25 | kész | Windows: nincs egypéldányos védelem (második példány ugyanazt az … |
| REL-26 | részben | Postaláda-apróságok: társ nélkül a rekordok dirty maradnak és … – a verziókapu és a postaláda-kapu kész; a levelenkénti hibaelkülönítés nem |
| REL-27 | halasztva | Indítás: a teljes latest_all tz-adatbázis szinkron dekódolása; az … – alacsony súly: a tz-adatbázis szinkron dekódolása és a lusta pénzügyi oldal nem készült |
| REL-28 | kész | Tesztek: valós idejű várakozások (10 helyen), 28 DateTime.now() a … – 3/C: egy óra, várakozás helyett fordulók, őrző-teszt |
| AI-1 | kész | Nincs tartalék a 8 k TPM keretben: egy terv-kérés ≈ 5,75 k + max 2 048 … – 2a–2e |
| AI-2 | kész | A fix rész a terv-kérés 72 %-a; ugyanazok a szabályok 2–3×: korlátok … – 2a–2e |
| AI-3 | kész | A javítási kör mindent újraküld, és a hibás ref/deletions/moves … – 2a–2e |
| AI-4 | kész | Csonka tool-hívás (finish_reason=length) „argumentum nélküli”-vá válik … – 2a–2e |
| AI-5 | kész | A hard a modell állítása; jövőbeli napra hard:true mindig elutasított … – 2a–2e |
| AI-6 | kész | A heti plafon és a 48 órás szabály csak az adott javaslat blokkjait … – 2a–2e |
| AI-7 | kész | A javaslatok száma/horizontja korlátlan, mind előre kijelölt: egy … – 2a–2e |
| AI-8 | kész | Cache-ellenes sorrend: perc-pontos „MAI IDŐ” a rendszerprompt ≈ 96. … – 2a–2e |
| AI-9 | kész | A usage (prompt/output token, finishReason) parse-olva, de eldobva; a … – 2a–2e |
| AI-10 | kész | 413 / „Request too large” / tool_use_failed / paraméter-400 nincs … – 2a–2e |
| AI-11 | kész | Nincs újrapróbálás hálózati/5xx hibára, nincs globális határidő, Mégse … – 2a–2e |
| AI-12 | kész | Hiba: a várakozási állapot („Limit miatt várok N másodpercet…”) sosem … – 2a–2e |
| AI-13 | kész | Fix temperature 0.4 minden szolgáltatónál (egyes OpenAI-modellek … – 2a–2e |
| AI-14 | kész | scopeFor törékeny: ékezet nélküli szavak, tagadás („ne töröld”), vegyes … – 2a–2e |
| AI-15 | kész | A törlés/áthelyezés akkor is feldolgozódik, ha a felhasználó nem kért … – 2a–2e |
| AI-16 | kész | A jóváhagyott változtatás végleges: elfogadáskor nincs újraellenőrzés, … – 2a–2e |
| AI-17 | kész | Adatminimalizálás: alapból 15 tétel (kereskedő, jegyzet, pontos … – 2a–2e |
| AI-18 | kész | Időjárás: soros (≤ 8 s várakozás az LLM-hívás előtt), cache nélkül, … – 2a–2e |
| AI-19 | kész | Statikus alvási sáv vs 12 napos ciklus: az alvás-teszt csak a kezdetet … – 2a–2e |
| AI-20 | kész | Kézikönyv: ellentmondások (rules.md:17 vs :19; output-format.md:14 vs … – 2a–2e |
| AI-21 | kész | Minden naptár-esemény címe megy; tervezésnél elég a foglaltság (cím … – 2a–2e |
| AI-22 | kész | A felhasználói kérés hossza korlátlan; a hely-címke szűretlen – 2a–2e |
| AI-23 | kész | Kikapcsolt adatforrásnál is elmegy a kérés, csak azért, hogy „nem … – 2a–2e |
| AI-24 | kész | Szolgáltató-higiénia: duplikált transport-/redakciókód; kérésenként új … – 2a–2e |
| AI-25 | kész | Csendes csonkolás (slots.take(40) jelző nélkül); a learned.md akár ≈ 2 … – 2a–2e |
| UX-1 | kész | A fő funkciók (Feladatok, Asszisztens, Beosztás, Beállítások) < 1000 … |
| UX-2 | kész | Nincs visszavonás sehol (nincs SnackBarAction); a törlés csak … |
| UX-3 | kész | Nincs keresés, nincs napirend/lista nézet („következő 14 nap”), nincs … – keresés, napirend, húzás; a húzással áthelyezés nincs (döntés) |
| UX-4 | kész | Billentyűparancs csak a szerkesztőben (Ctrl+S, Esc) ; Windowson nincs N … |
| UX-5 | kész | Hibaüzenetek: angol osztály-dumpok (REL-22); fejlesztői szöveg a … |
| UX-6 | kész | A Beállítások egyetlen hosszú oldal (≈ 720 sor: AI, pénzügy, Wallet, … |
| UX-7 | kész | Nincs első indítási vezetés: belépés, API-kulcs, hely, … |
| UX-8 | kész | Hozzáférhetőség: a hónaprács és az időrács szinte Semantics nélkül … |
| UX-9 | kész | Téma: csak rendszerkövetés, fix indigó; 11 kemény Colors.green/orange |
| UX-10 | kész | Windows ablak: induló 1280×720, minimális méret nincs beállítva … |
| UX-11 | kész | A hosszú műveletek (műszak-generálás ≈ 90 elem feltöltése) nem mutatnak … |
| UX-12 | nem cél | Kemény magyar szövegek, nincs l10n (ARB) – személyes, magyar appnál … – kemény magyar szövegek, nincs l10n |
| UX-13 | info | Jó: eseményszerkesztő (megerősítés, ismétlődés-szerkesztő, 24 órás idő, … – jó, megtartandó |
| CMP-1 | kész | Flutter stable rögzítetlen a CI-ben; a lock dart ≥ 3.13.7 / flutter ≥ … – a Flutter 3.50.0 / Dart 3.14.0 / Java 21 rögzítve; havi ellenőrzőlista: `docs/verzio-frissites.md` |
| CMP-2 | részben | Android: minSdk/targetSdk a Flutter alapértelmezése (24/36); pontos … – a workflow-PR-ban (tanácsadó kapu: zipalign, engedély-lista) |
| CMP-3 | részben | Windows: csak x64; a VC++ futtatókörnyezet függősége nem ellenőrzött; … – a workflow-PR-ban (VC++ DLL-ek az app mellé) |
| CMP-4 | kész | Adatformátum-kompatibilitás verziók között (lásd REL-16) – verziókapu + kézzel írt minták (3/A) |
| CMP-5 | részben | Google/ICS-valóság: WKST, RDATE, többszörös RRULE (dokumentált korlát), … – kézzel írt Apple / Outlook / Google minták; valódi export még nincs |
| CMP-6 | részben | Függőségek: a pub outdated/advisory itt nem futtatható; drift_flutter … – a workflow-PR-ban (heti `deps.yml`) |
| CMP-7 | kész | Töréspontok szétszórva (760 / 820 / 900 / 1000 px) három fájlban; … – a töréspontok egy helyen: `lib/ui/breakpoints.dart` |
| CMP-8 | nem cél | iOS/macOS/Linux nincs célozva (nem kért) – iOS / macOS / Linux |
| QA-1 | kész | A README elavult – 0. fázis; a README minden körben frissül |
| QA-2 | részben | Nagy fájlok (assistant_service, settings_page …) – az `assistant_service` (1 670 → 708 sor) és a `settings_page` (1 187 → 574 sor) szétbontva; a `quick_entry` (1 085), `assistant_page`, `bank_import_page`, `event_editor` (~ 900) marad |
| QA-3 | kész | Teszthiányok; valós idejű várakozások – 3/C |
| QA-4 | részben | CI: lefedettség, formázás, kapuk – helyi rész kész: `tool/coverage.dart`, lint; a CI-sorok a workflow-PR-ban |
| QA-5 | info | Nincs telemetria / összeomlás-napló (szándékos) – szándékos; a helyi diagnosztika pótolja |
