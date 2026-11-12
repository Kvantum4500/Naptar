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
| CMP-1 / SEC-18 (rögzítetlen Flutter) – **tapasztalat** | részben | a CI `channel: stable` beállítása miatt a 3.50.0 (2026-11-09) megtörte az 1b első két buildjét (Android: AGP ≥ 9.1.1, Kotlin ≥ 2.4.10; elemzés: a Material-import elavult). **Javítva:** AGP 9.1.1 + Kotlin 2.4.10 (a Gradle 9.3.1 marad), `deprecated_member_use: ignore`. A Flutter ajánlott hármasával (9.3.1 / 2.4.20 / 9.5.0) a Build 60 Android-lintje összeomlott JDK 17 alatt (`List.removeLast()` csak JDK 21-ben van). **Nyitva:** a Flutter-verzió rögzítése és a `setup-java` 17 → 21 a workflow-kban (külön PR a `main`-be, jóváhagyással), utána az ajánlott verziókra lépés; az áttérés a `material_ui`-ra (5. fázis) |

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
