# Kvantum Naptár

Személyes naptár- és életvezetési app (Windows + Android, Flutter), **saját szerver nélkül**: a Google Calendar, a Google Drive és (kérésre) egy általad választott AI-szolgáltató a háttér. Magyar felület.

## Mit tud

| Terület | Állapot |
|---|---|
| **Naptár** – hónap-, hét- és napnézet időskálával, színek, teljes ismétlődés-szerkesztő (kivételekkel), kétirányú szinkron a Google Calendar saját „Naptar” naptárával, offline sor, `.ics` mentés/visszaállítás | kész |
| **Kezelés** – alsó sáv (telefon) vagy oldalsín (széles ablak): Naptár · Feladatok · Asszisztens · Pénzügyek · Több (Beosztás, Beállítások); a hónap címe nem vágódik le, keskeny cellában színes pöttyök; Windowson billentyűparancsok (N, T, ← →, 1 2 3, F5, F1) és megjegyzett ablakméret / -hely (legkisebb 480 × 640) | kész |
| **Beosztás** – műszakciklus-generátor (pl. 3 éjszaka – 3 szabad – 3 nappal – 3 szabad), műszakcsere, extra műszak, havi összesítő | kész |
| **Feladatok, napi check-in és edzés utáni visszajelzés** – a Drive `appDataFolder`-ben, mezőnkénti összefésüléssel, több eszközön; az edzés után (a címéből ismeri fel) rákérdez, milyen nehéz volt, és ebből tanul: szigorít magától, lazítani csak a jóváhagyásoddal | kész |
| **Asszisztens** – Gemini / Groq / Mistral / OpenRouter / OpenAI / egyéni (OpenAI-kompatibilis) szolgáltató, szerkeszthető kézikönyv, javaslat → jóváhagyás; áthelyezés és törlés csak jóváhagyással; feladat-ütemezés; időjárás (Open-Meteo) és helyszín; a kemény szabályokat **kód** ellenőrzi, az AI csak javasol | kész, élő modellel a felhasználó próbálja |
| **Pénzügyek** – napló, havi keretek, ismétlődő tételek, megtakarítási célok; telefon ↔ gép „postalevél” szinkron a Drive-on; Google Wallet értesítések automatikus felvétele (Android) | kész |
| **Emlékeztetők** – műszak és napi check-in (Android) | kész (Windowson nincs) |
| **Hibák látása** – Diagnosztika oldal (Beállítások → A program): szinkron csatornánként, elutasított módosítások (újrapróbálás / elvetés), Google-kérések naponta, figyelmeztetések (óraeltérés, újabb verzió, olvashatatlan ismétlődés), helyi hibanapló; a jelentés másolható / menthető, és **nem tartalmaz** címet, összeget, jegyzetet, e-mail-címet vagy kulcsot | kész |
| **Önfrissítés** – Windows: csere + visszaállítás hibánál; Android: a rendszertelepítő; stabil és előzetes csatorna | kész |

A részletes ellenőrzés és a fejlesztési terv: [`docs/audit-es-fejlesztesi-terv.md`](docs/audit-es-fejlesztesi-terv.md). Változások: [`CHANGELOG.md`](CHANGELOG.md).

## Futtatás fejlesztéshez

Flutter **3.50.0** (Dart 3.14.0) a CI-ben és a kiadási buildben rögzített verzió; helyben a tesztek a 3.47.9-en is zöldek.

```bash
# mag (tiszta Dart)
cd packages/kvantum_core && dart pub get && dart analyze && dart test
# app
cd apps/kvantum_app && flutter pub get && dart run build_runner build --delete-conflicting-outputs && flutter analyze && flutter test
# titkok: másold, töltsd ki (a secrets.json git-ből kizárt)
cp secrets.example.json secrets.json
flutter run -d windows --dart-define-from-file=secrets.json   # vagy -d <android-eszköz>
```

A `secrets.json` kulcsai: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (Google Cloud OAuth-kliens), `UPDATE_TOKEN` (csak olvasó GitHub-token az önfrissítéshez). Ezek a buildbe kerülnek, ezért **soha** ne kerüljenek a repóba. Nélkülük a program fut, de a szinkron-gomb „Nincs Google” állapotot mutat („Nincs Google-hozzáférés”: ebben a buildben nincs beállítva a bejelentkezés); a kiadási csomagokban a kulcsok benne vannak.

## Fő tervezési döntések

- **Idő:** falióra + IANA zóna (mint a Google); az ismétlődés falióra-időben fut (DST-biztos), az esemény időtartama valós eltelt idő.
- **Duplikáció-védelem:** `reconcile()` sorrend: tárolt link → `appEventId` (saját írás visszhangja) → iCalUID → új.
- **AI:** a modell csak javasol. Minden írás (új esemény, áthelyezés, törlés, megjegyzett szokás) külön gombnyomásra történik; a szabályokat (alvás, puffer, energia, műszak, időjárás, határidő) a `validateProposal` kóddal ellenőrzi. A modellnek szánt szöveg adatként, jelölt blokkban megy, tisztítva. A kérés fajtája (terv / törlés-áthelyezés / pénzügyi kérdés) szabja meg, mennyi utasítást, adatot és hány eszközt kap a modell, hogy az ingyenes szintek percenkénti tokenkerete elég legyen; ha mégis túl nagy lenne, a program sorban elhagy részeket (időjárás, szabad idősáv, kevesebb feladat, rövidebb időablak). A „Mit küldünk a modellnek?” panel küldés előtt megmutatja a kérést, az első kulcsnál párbeszéd mondja el, mi megy ki; a kézzel felvett rövid események címe, a check-in megjegyzése, az egyes pénzügyi tételek és a helyszín neve alapból nem megy ki. A nehéz edzést (60 perctől), a heti plafont és a 48 órát a kód méri, a naptárban már lévő edzésekkel együtt; check-in nélküli napra 3/5 energiát feltételez. A határokat a te visszajelzéseid finomítják (egy típus nehezebb, mint amit a program feltételez → magától szigorít; könnyebb → csak a jóváhagyásoddal lazít, a Kézikönyv „Tanult szokások” fájljába írva, ahol törölhető); a modell az utolsó 10 visszajelzés rövid összegzését kapja (cím és megjegyzés nélkül, a Napi check-in kapcsolóval). A költségkeret és a napirend (pl. „Hogy állok a költségkerettel?”, „Mi lesz holnap?”) helyben, modell nélkül megválaszolódik (kulcs és token nélkül, jelölve), a további kérdés mehet a modellhez.
- **Adatok helye:** az események a Google Calendarban és a helyi adatbázisban; a feladatok, check-inek, edzés-visszajelzések, kézikönyv a Drive `appDataFolder`-ben; a pénzügyi adat **helyben**, a gépek között rövid életű „levelekkel” (a megérkezett levél törlődik). A Drive-ban a pénzügyről nincs teljes másolat: a rendszeres mentés (Beállítások → Mentés) fontos.
- **Titkok:** az eszköz biztonságos tárolójában (Windows DPAPI / Android Keystore); az API-kulcs csak fejlécben utazik; nincs telemetria, nincs naplózott kulcs.
- **Android:** az automatikus (felhő-/eszközátvitel) mentés ki van kapcsolva; az adat a Google-fiókból és a többi eszközről áll helyre.

## Kiadás és önfrissítés

- A `build.yml` megépíti a Windows-zipet és az Android-APK-t, SHA-256 összeggel, és GitHub-kiadást (`build-<szám>`) készít belőle.
- Jelenleg minden build „latest” kiadás, a `main`-é és a munkaágaké is. A **Flutter-verzió rögzítése** (3.50.0 / Dart 3.14.0, az Android-buildhez Java 21) már a `main`-en van (PR #4). Az **előzetes csatorna** (a munkaági buildek pre-release-ként, a „latest” csak a `main`/`v*` buildje) elkészült, de külön lépésben, a `main`-en keresztül kerül be: ha a build workflow-fájljai eltérnek a `main`-étől, a GitHub 403-mal elutasítja a kiadás létrehozását (ezt a Build 34 mutatta meg). Az app erre már fel van készítve: a Frissítés ablak „Előzetes verziókat is keressen” kapcsolója (alapból be) az előzetes kiadásokat is felkínálja.
- Az app „Frissítés keresése” menüpontja a csak olvasó `UPDATE_TOKEN`-nel kérdezi le a kiadásokat, ellenőrzi az összeget, és (Windowson) lecseréli magát, hibánál visszaállítja a régit. Az ellenőrzés csak kézi indításra fut.
- Az első indításnál a Windows figyelmeztet („ismeretlen kiadó”): a ZIP tulajdonságainál jelöld be a **Feloldás** (Unblock) négyzetet kicsomagolás előtt. A frissítések már nem figyelmeztetnek.
- Titkok (GitHub → Settings → Secrets → Actions): `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `UPDATE_TOKEN`; Androidhoz még `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (az **Android keystore (egyszeri)** workflow előállítja; a kulcsot **őrizd meg**, elvesztése után újra kell telepíteni az appot). Aláírt kulcs nélkül az APK nem kerül a kiadásba.

## Mit tegyek, ha…

- **Hol van a Feladatok, az Asszisztens, a Beosztás, a Beállítások?** Az alsó sávban (széles ablakban az oldalsávban) a Naptár, a Feladatok, az Asszisztens és a Pénzügyek áll; a **Beosztás** és a **Beállítások** a **Több** alatt. A Vissza gomb (Androidon a vissza-gesztus) bármelyik oldalról a Naptárra visz, onnan lép ki. Az Asszisztens oldalról átváltva a futó kérés megszakad.
- **A hónapnézetben pöttyöket látok a címek helyett:** szándékos. Egy keskeny cellában (álló telefonon kb. 50 px) a cím úgyis csak néhány betű lenne; a pötty az esemény színe (legfeljebb 4, utána „+N”), a kiválasztott nap eseményeit a rács alatti lista nevezi meg (egy napra koppintva választod ki), egy eseményre koppintva a szerkesztő nyílik. Fektetett telefonon vagy széles ablakban szöveges sávok vannak (az idő a cím előtt kb. 92 px-es cellától).
- **Billentyűparancsok (Windows):** a naptár oldalon **N** új esemény · **T** ma · **← →** előző / következő hónap, hét vagy nap · **1 2 3** hónap / hét / nap · **F5** szinkron most · **F1** vagy **?** súgó; a szerkesztőben **Ctrl+S** mentés, **Esc** bezárás. A lista a Beállítások → A program → **Billentyűparancsok** gombbal is megnyílik. Gépelés közben egyik sem indul el; ha mégsem reagál, kattints a naptárra.
- **Windows: az ablak mérete és helye:** a program megjegyzi (méret, hely, maximalizált-e), a legkisebb méret 480 × 640. Ha az ablak rossz helyre vagy mérettel nyílna, zárd be a programot, és töröld a `HKEY_CURRENT_USER\Software\KvantumNaptar` kulcs `WindowState` értékét (a rendszerleíróban); a következő indítás az alapméretet (1280 × 720) használja. Ha a mentett hely már nincs képernyőn, a legközelebbi képernyőre igazodik.
- **Valami nem működik, és nem tudom, miért:** Beállítások → A program → **Diagnosztika** (a szinkron-gomb menüjében is). Felül a figyelmeztetések, alatta a szinkron csatornánként (naptár, Drive, pénzügyi levelek): mikor volt az utolsó próba és az utolsó sikeres futás, és mi a hiba magyarul. Ha segítséget kérsz, a „Másolás” gombbal a vágólapra teszed a jelentést (vagy „Mentés fájlba”). **A jelentésben számok, kódok, magyar mondatok és a hibák rövid, megtisztított első sora van; esemény-cím, összeg, jegyzet, e-mail-cím és kulcs nem kerül bele.** (A hibák első sorát a rendszer adja; sima szöveg, küldés előtt átnézheted.) Te döntöd el, kinek mutatod meg.
- **Hol a napló, és mi van benne?** Az adatbázis mellett, a `diag` mappában (`diag.log` és a régebbi `diag.log.1`; Windowson `%LOCALAPPDATA%\KvantumNaptar\diag`, Androidon az app privát mappája), legfeljebb ≈ 0,5 MB, csak ezen az eszközön; semmi nem megy ki belőle magától. Soronként: idő, terület, rövid kód, számok, és a hiba típusa + első sora (megtisztítva). A program nem ír bele eseménycímet, jegyzetet, összeget, e-mail-címet, kulcsot. A Diagnosztika „Napló törlése…” gombja üríti; törlés után a hibakeresés nehezebb, ha valami ismétlődik.
- **„Elutasított módosítások” a Diagnosztikán:** ezeket a Google nem fogadta el, vagy nem sikerült feltölteni. **Újrapróbálás most:** új esélyt kapnak (a „Szinkron most” is ezt teszi). **Elvetés:** a feltöltés leáll; az esemény az eszközön marad (ha újra szerkeszted, újra sorba kerül; a „Szinkron alaphelyzetbe…” is visszahozza). Elvetett *törlésnél* az esemény a Google-ban marad.
- **Figyelmeztetés: „egy módosítás … a jövőben van bélyegezve”:** valamelyik eszköz órája több mint két nappal előrejár. Állítsd be az órát (automatikus idő). Addig a program az újabb szerkesztéseket a jövőbeli bélyeg után bélyegzi, hogy ne vesszenek el.
- **Figyelmeztetés: egy ismétlődő esemény „több mint 20 000 előfordulást adna”:** a szabálya (pl. évtizedekre előre napi ismétlés) túl hosszú, ezért a távoli jövőjét nem mutatja a program. Rövidítsd a szabályt (vége vagy darabszám).
- **A Google-kérések száma a Diagnosztikán:** naponta, szolgáltatásonként (naptár, Drive, egyéb) mutatja a hívásokat és azt, hány ment át, hány lett elutasítva vagy korlátozva. Ha a „korlátozva” sok, a program magától lassabban folytatja; teendőd nincs. A számok 7 napig maradnak.
- **„A Google-bejelentkezés lejárt”:** koppints a „Belépés szükséges” gombra (az adat megvan, a függő módosítások utána feltöltődnek). Ha hetente ismétlődik: a Google Cloud OAuth-hozzájárulási képernyő „Testing” állapotban van, állítsd „In production”-re.
- **A szinkron-gombnál „Döntés kell” áll:** másik Google-fiókba léptél be, vagy a „Naptar” naptárat törölték / újra létrehozták. A naptár-szinkron addig áll, hogy a két naptár eseményei ne keveredjenek (a feladatok és a pénzügy megy tovább). Koppints a gombra → „Másik fiók / naptár: döntés kell…”: *megtartom és feltöltöm* (a helyi események az új naptárba kerülnek, semmi nem törlődik), *üres indulás* (a helyi naptáresemények törlődnek, az új naptár eseményei jönnek), vagy *később*. Ha tévedésből léptél be másik fiókkal: Kilépés, majd belépés a régivel.
- **A szinkron „ideiglenesen korlátozza a kéréseket” vagy „nincs kapcsolat”:** nem kell tenned semmit; az app visszalépéssel (1, 2, 4, 8, legfeljebb 15 perc) magától újra próbálja, a módosításaid megvannak. A „Szinkron most” azonnal próbál. Sok esemény feltöltésekor (pl. egy félévnyi műszak) a Google néha korlátoz; az app lassabban, darabokban tölt.
- **„N módosítást a Google nem fogadott el” (feladott módosítás):** az adott esemény adata nem megfelelő a Google-nek. Nyisd meg, javítsd (a mentés újra sorba állítja), vagy koppints a „Szinkron most”-ra.
- **Valami nem egyezik a Google-naptárral, vagy duplikátumot sejtesz:** Szinkron → „Szinkron alaphelyzetbe…”. Semmit nem töröl; az események újra összekapcsolódnak a Google-eseményekkel (az azonosítójuk alapján), a feladatok, check-inek és pénzügyi levelek szinkronja a nulláról indul. Sok eseménynél eltarthat egy ideig.
- **A szinkron tétlenül ritkábban néz rá a Google-re:** szándékos (az akku miatt): egy perc, ha van tennivaló, tétlenül 3, 5, majd 10 perc; a háttérben nem fut időzítő, visszatérésre azonnal ránéz. A „Szinkron most” bármikor azonnal fut.
- **A naptár egyik eseménye nem látszik, sárga/piros sáv jelzi:** az ismétlődési szabálya nem olvasható; a sáv „Részletek” gombjával egyszeri eseménnyé alakítható, vagy kijavítható a Google Naptárban.
- **Az asszisztens „levágódott” vagy „túl nagy” üzenetet ad:** kérj kevesebb napot vagy tételt, rövidítsd a Kézikönyvet (Beállítások), vagy válassz másik modellt. A program a „túl nagy” esetben egyszer magától is próbál kisebb adattal.
- **Az asszisztens sokáig tart:** a „Mégse” gombbal megszakíthatod (az oldal elhagyása is megszakítja); 90 másodperc után magától abbahagyja, szerverhibánál kétszer újra próbálja.
- **Az asszisztens limitet jelez:** az ingyenes szintek percenkénti/napi tokenkerete kicsi (Groq: 8 000 token/perc); várj, vagy válts szolgáltatót a Beállításokban.
- **„Ez az adatbázis egy újabb alkalmazásverzióhoz tartozik”:** olyan verziót indítottál, amely régebbi annál, amelyik utoljára használta az adatot. Az adatod érintetlen; telepítsd az újabb verziót. Ha tudatosan régebbire akarsz visszamenni: az adatbázis mappájában a `kvantum.sqlite.bak-v…` fájl az egyes frissítések előtti állapot (legutóbbi kettő); az app bezárása után a fájl `kvantum.sqlite`-ra nevezésével visszaállítható.
- **„Az adatbázis-fájl nem olvasható (sérült lehet)”:** a program nem nyúlt hozzá. Ha mellette van `.bak-v…` végű másolat, azzal (az app bezárva, átnevezve) visszaállítható; a Google-naptár, a Drive-feladatok és a pénzügyi levelek úgyis újra lejönnek.
- **Windows: hol az adatbázis?** `%LOCALAPPDATA%\KvantumNaptar\kvantum.sqlite` (régebben a Dokumentumok mappában, amelyet a OneDrive tükrözhet). Az első indítás átmásolja és ellenőrzi; a régi fájl a következő sikeres induláskor törlődik. Ha az áthelyezés nem sikerül, a régi hely marad használatban, és semmi nem vész el.
- **Windows: a második indítás a már futó ablakot hozza előre:** szándékos, egyszerre egy példány futhat (kettő ugyanazt az adatbázist írná).
- **A visszaállítás (.ics) rákérdez:** ha a fájlban olyan esemény van, amely az eszközön azóta módosult, a **Mind** felülírja, a **Csak az újak** semmit nem ír felül (csak a hiányzókat adja vissza), a **Mégse** nem csinál semmit. A fájlban nincs eseményenkénti módosítási idő, ezért a program nem találgatja, melyik az újabb.
- **A „Ma” vagy a mai feladatok „elcsúsznak” külföldön:** a naptár a megjelenítési zóna (Budapest) napját mutatja, nem az eszközét; éjfélkor magától átlép az új napra.
- **Egy „újabb verzió írta” üzenet a szinkron-állapotban:** egy másik eszköz az alkalmazás újabb verzióját futtatja, és olyan elemet írt, amit ez a verzió nem ért; ezeket nem bántja (nem törli, nem írja felül). Frissítsd az alkalmazást ezen az eszközön is.
