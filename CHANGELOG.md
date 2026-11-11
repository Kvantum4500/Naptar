# Változások

A build-számok a GitHub-kiadások (`build-<szám>`) számai. A legfrissebb elöl.

## Eszközlánc – a Flutter 3.50.0-hoz igazítás

- **Mi történt:** a CI rögzítetlen „stable” Flutter-t használ, és a 2026-11-09-én megjelent 3.50.0 két helyen megtörte a buildet (az 1b első két buildje, a Build 59 és a 60 emiatt csak a Windows-csomagot adta): **(1) Android** – az új Flutter legalább Android Gradle Plugin 9.1.1-et és Kotlin 2.4.10-et kér (nálunk 9.1.0 és 2.4.0 volt), és figyelmeztet, hogy a Gradle 9.3.1 támogatása hamarosan megszűnik; **(2) elemzés** – a Material kiköltözött a `material_ui` csomagba, ezért a `package:flutter/material.dart` minden importját elavultnak jelzi (43 jelzés), és a `flutter analyze` ilyenkor hibakóddal lép ki, így a CI `app` jobja a tesztek előtt megállt.
- **Javítás:** az Android-projekt a Flutter 3.50.0 *hibaküszöbére* lépett: **Android Gradle Plugin 9.1.1, Kotlin 2.4.10** (a Gradle marad 9.3.1); az elemzés „elavult használat” jelzése (`deprecated_member_use`) kikapcsolva az `analysis_options.yaml`-ban (a régi import továbbra is működik). Az app tesztjei a 3.50.0-n a CI-ben is mind zöldek (974). **Miért nem a Flutter ajánlott hármasa (AGP 9.3.1 / Kotlin 2.4.20 / Gradle 9.5.0):** a Build 60 ezzel próbálta, és az Android-lint összeomlott (`NoSuchMethodError: java.util.List.removeLast()` – ez a metódus JDK 21-ben jelent meg), a CI viszont JDK 17-et ad, és a workflow-fájlt az ágon nem módosíthatjuk. A Flutter ezért figyelmeztet, hogy az ajánlott verziók alatt vagyunk; ez csak figyelmeztetés.
- **Nyitva marad:** az áttérés a `material_ui` csomagra külön, szándékos feladat (új függőség, 40 fájl, harmadik fél csomagok áthidalása, témaellenőrzés); a Flutter-verzió rögzítése és a Java 17 → 21 a CI-ben, külön PR a `main`-be (audit CMP-1 / SEC-18), a felhasználó jóváhagyásával; utána léphetünk az ajánlott verziókra.

## 1b. fázis – az adatréteg megbízhatósága: biztonságos frissítés, egy egység az összetartozó írás, újabb formátum védelme

**Adatbázis és Windows**
- **A frissítés nem tud félúton megállni (REL-17):** az adatbázis-migráció egyetlen tranzakció (a hiba visszagörget, a verziószám marad), és **minden frissítés előtt biztonsági másolat készül** `kvantum.sqlite.bak-v<régi verzió>` néven (`VACUUM INTO`, a legutóbbi kettő marad). Eddig a lépések külön futottak, mentés nem volt.
- **Újabb alkalmazás adatbázisát nem rontja el a régebbi (REL-16):** ha az adatbázis egy újabb verzióé, ez a verzió **nem nyitja meg és nem „frissíti” visszafelé**, hanem érthető magyar képernyőt mutat (az adat érintetlen, telepíteni kell az újabb verziót). Sérült fájlnál nem nyúl hozzá, megnevezi a fájlt és a mentések helyét.
- **Gyorsabb keresések (REL-18):** a szinkron által soronként végzett keresésekhez indexek készülnek (induláskor, egyszer és ártalmatlanul; **nincs séma-verzióváltás**).
- **Windows: az adatbázis a `%LOCALAPPDATA%\KvantumNaptar` mappába költözik (SEC-6):** eddig a Dokumentumokban volt, amelyet a OneDrive tükrözhet. Az áthelyezés kétlépcsős: másolás → ellenőrzés (megnyílik, `integrity_check`, azonos séma-verzió, **azonos sorszám minden táblában**) → jelölőfájl; a régi fájl csak a **következő sikeres induláskor** törlődik, és bármi hiba esetén a régi hely marad használatban.
- **Windows: egyszerre egy példány fut (REL-25):** a második indítás a már futó ablakot hozza előre (a frissítő által indított új példány 3 másodpercet vár, amíg a régi kilép). Eddig két példány írhatta ugyanazt az adatbázist.

**Összetartozó írások egy egységben (REL-14/15)**
- A **műszak-generálás**, a **sorozat törlése**, a **szerkesztés ismétlődéssel** és az **.ics visszaállítás** egy tranzakció és egy képernyőfrissítés (eddig ≈ 90 külön írás: villogás, és félbeszakadva fél eredmény maradt).
- A feladatok / check-inek szerkesztése, törlése és a Drive-ról érkező változat olvas-módosít-ír tranzakcióban fut; az eszköz-azonosítót **egyszer** hozza létre (két egyidejű hívás nem csinál kettőt); a pénzügyi mentések bélyegzése és az érkező levelek (egy levél = egy tranzakció) is tranzakcióban vannak.

**Az újabb formátumot nem rontja el a régebbi verzió (REL-16)**
- A levél, a rekord és a Drive-fájl `v` mezőjét az app olvassa. Az **újabb formátumú levél nem törlődik** (megmarad, amíg ez a verzió frissül), az **újabb Drive-fájl nem íródik felül**, az ismeretlen fajtájú tételt tartalmazó levélből az ismert tételek alkalmazódnak, a levél marad. Újabb verzió pénzügyi mentése: magyar üzenet („frissítsd az alkalmazást”) a félig sikeres visszaállítás helyett. A szinkron állapota jelzi: „N elemet az alkalmazás egy újabb verziója írt; ezeket nem bántom…”.

**.ics (REL-13)**
- **Az ismétlődés vége helyes marad:** az importnál az UTC-ben megadott `UNTIL` a helyi időre (egész napos eseménynél a nap végére) alakul, exportnál vissza UTC-re (eddig a sorozat egy nappal korábban végződhetett, vagy az exportált `UNTIL` mást jelentett más naptárban).
- **A törölt előfordulás nem tér vissza:** exportnál a sorozat `EXDATE`-je lesz (eddig kimaradt, ezért visszaállítva az előfordulás újra megjelent).
- **Korlátok magyar jelentéssel:** fájl ≤ 5 millió karakter, időponthoz kötött esemény ≤ 366 nap, egész napos ≤ 3 660 nap, 1970–2100 közötti év (eddig egy 9999-es végű esemény lefagyaszthatta a felületet); a sok, hosszú összefűzött sor pufferben épül (nem négyzetes idő).
- **Visszaállítás előnézettel:** ha a fájlban olyan esemény van, amely az eszközön azóta módosult, a program **nem ír felül kérdés nélkül**: párbeszéd mutatja az érintett eseményeket, és kérdez: **Mind** (felülír) / **Csak az újak** / **Mégse**. (A fájlban nincs eseményenkénti módosítási idő, ezért az „újabb nyer” nem dönthető el.) A visszaállított esemény megtartja a Google-kapcsolatát. A 200 000 karakternél nagyobb fájlt külön szálon olvassa be.

**Ismétlődések, emlékeztetők, „ma”**
- **Gyorsabb ismétlődés-bővítés (REL-20):** az időtartam sorozatonként egyszer számolódik, az ablak előtti példányok zónaszámítás nélkül kiesnek, az elemzett szabályok gyorsítótárban vannak (legfeljebb 256). Egy valósághű terhelésen (30 évek óta futó sorozat, 6 hetes ablak) **kb. 3× gyorsabb**; az eredmény a régi megvalósítással **mezőről mezőre azonos** (6000 véletlen összevetés, DST-határokkal, többféle időzónával).
- **Az emlékeztetők nem íródnak újra feleslegesen (REL-19):** eddig minden naptárváltozás mindent letörölt és újraütemezett (és ha az app közben leállt, az emlékeztetők elvesztek). Most az app megnézi, mi van az eszközön, és **csak a különbséget** módosítja (új / elmozdult / megszűnt); a változásokat 1,5 másodpercig összegyűjti, így egy 90 eseményes szinkron egyetlen menet.
- **A „ma” a megjelenítési zóna (Budapest) napja (REL-21):** eddig az eszköz zónája, ezért külföldön vagy más zónára állított gépen elcsúszhatott a „Ma” gomb, a mai feladatok, a check-in dátuma és a pénzügyi hónap. Az app **éjfélkor magától átlép az új napra** (és előtérbe visszatéréskor is megnézi az órát, mert az időzítő alvás közben megállhat); aki a „mai” napot nézte, az új napra lép, aki másikat, ott marad.

**Takarítás (REL-18)**
- Naponta egyszer, az első kép után: az **1 évnél régebben törölt** feladat-, check-in- és napló-jelölők (a Drive-fájllal együtt, és csak ami már fel van töltve) és pénzügyi jelölők törlődnek; a félbeszakadt futás hátrahagyta sorok rendbe kerülnek: a Google-hivatkozású, de sorban nem lévő törlés **újra sorba kerül** (te töröltél), a hivatkozás nélküli jelölő törlődik, a nem létező eseményhez tartozó sorbejegyzés törlődik. A takarítás eredménye a helyi adatban megőrződik (az 1c Diagnosztikája mutatja).

**Szándékos eltérések az audit szövegétől:** nincs séma-verzióváltás (az indexek induláskor, idempotensen készülnek; a migráció tranzakciós és mentéses akkor is, ha később jön új verzió); az újabb formátumú elemet az app **meghagyja** (nem törli, nem írja felül) – a régi verzió ezért soha nem rongálja az újabb adatát; a 20 000-es ismétlődés-plafon eléréséről szóló jelzés az 1c-ben készülő naplóba kerül (itt még nincs napló); az .ics importnál nincs „újabb nyer” (nincs hozzá adat), helyette előnézet és megerősítés.

Tesztek: mag 456 (volt 422), app 974 (volt 865); 54 szándékos elrontást mind elkapnak a tesztek (a próba több hiányt hozott felszínre: az adatbázis-megnyitó kampó „újabb fájl” elutasítása és az áthelyezés ellenőrzése (sorszám / séma-verzió / táblák) nem volt tesztelve – mindkettő kapott tesztet (ehhez a másolás cserélhetővé vált); a visszaállításnál a Google-kapcsolat külön másolása felesleges volt (a mentés megtartja), ezt egyszerűsítettem).

**Nem ellenőrizhető itt:** a Windows-mutex és az ablak előtérbe hozása; az áthelyezés valódi, OneDrive-os Dokumentumokkal; a `VACUUM INTO` Android-eszközön; az emlékeztetők ütemezése doze-ban (az Android-natív rész csak a CI-fordításig ellenőrzött); a nagy .ics beolvasása külön szálon valódi eszközön; hogy a „ma” éjféli váltása alvó gépen is időben megtörténik-e (előtérbe visszatéréskor mindenképp).

## 1a. fázis – a szinkron a hibákat az okuk szerint kezeli

**Mit javít**
- **A Google korlátja nem „végleges hiba” (REL-7):** a tömeges feltöltés (pl. egy félévnyi műszak) a Google „használati korlát” hibáját váltotta ki (`calendarUsageLimitsExceeded`, `quotaExceeded`), amit az app eddig végleges hibának vett: 5 próba (≈ 5 perc) után az elem csendben feladódott. Most a korlát, a 429 és az 5xx megállítja a futást, az elem érintetlen marad, és az app **visszalép**: 1 → 2 → 4 → 8 → 15 perc (±20 % szórással; a szerver `Retry-After` fejlécénél soha nem hamarabb; napi keretnél legalább fél óra; hálózati hibánál legfeljebb 5 perc). Ha a Google magát az elemet utasítja el (hibás adat, jogosultság), az 5. elutasítás után az elem **„feladott”** (a Szinkron → Részletek mutatja), és a „Szinkron most” vagy az esemény szerkesztése újra megpróbálja. Két feltöltés közt 200 ms szünet, futásonként legfeljebb 150 feltöltés (a többi 5 másodperc múlva).
- **Ritkább kérés tétlenül (REL-8):** a percenkénti lekérdezés helyett egy percig él a ritmus, amíg van tennivaló, tétlenül 3 → 5 → 10 percre lassul; a háttérben nincs időzítő, visszatéréskor csak akkor néz rá, ha az utolsó futás több mint fél perce volt; a pénzügyi postaláda csak akkor kerül listázásra, ha a Drive jelezte (levél / törlés), van küldendő saját módosítás, vagy minden 5. futásnál. A „Szinkron most” mindig azonnal fut, és újraindítja a ritmust.
- **Másik fiók vagy naptár nem keveredik (REL-4):** az eszköz megjegyzi, melyik Google-fiók melyik „Naptar” naptárával szinkronizál. Ha más jön (új fiók, törölt és újra létrehozott naptár), a naptár-szinkron **megáll** („Döntés kell”; a Drive és a pénzügy megy tovább), és három út közül választhatsz: *a helyi események megtartása és feltöltése az új naptárba* (semmi nem törlődik), *üres indulás* (a helyi naptáresemények törlődnek, számmal megerősítve), *később*. A fiók a felületen maszkolva látszik (`a***@gmail.com`).
- **„Szinkron alaphelyzetbe…” (a szinkron menüjében):** az események kapcsolatait elfelejti, és újra sorba állít mindent (a feltöltés az esemény saját azonosítója alapján megtalálja a meglévő Google-eseményt, **nincs duplikátum**); a feladatok, check-inek és pénzügyi levelek szinkronja a nulláról indul. Semmi nem törlődik, a Google-ban sem; amit közben a Google-ban töröltél, azt visszateszi.
- **A szerkesztés nem törli a Google-oldali mezőket (REL-11):** az esemény módosítása eddig az egész eseményt felülírta (az emlékeztetők, vendégek, Meet-link, „szabad/foglalt” elvesztek). Most az app beolvassa a Google-beli eseményt, ráteszi a saját mezőit (cím, leírás, hely, szín, idő, ismétlődés + kivételek), és a friss `etag`-gel írja vissza (412-nél újraolvas); a nem szerkeszthető ismétlődés-sorok (RDATE, EXRULE) is megmaradnak. Szerkesztésenként +1 hívás.
- **Egy kivétel-példány nem írja felül a sorozatot (REL-2):** ha a Google-ban egyetlen előfordulást átírtál, az eddig a sorozat sorát is felülírhatta (a példány a sorozat azonosítóit viseli). Most a példányt csak saját kivétel-sorral párosítja.
- **A Google-ban törölt, de közben szerkesztett esemény visszakerül (REL-12):** a távoli törlés eddig elnyelte a fel nem töltött helyi szerkesztést; most a szerkesztés nyer. A lehúzás eseményenként egy tranzakcióban olvas és ír, így a közben végzett szerkesztést nem írja felül; a szerkesztő elavult pillanatképe nem teszi vissza a régi `etag`-et (örök „elavult” elutasítást okozott).
- **Egy olvashatatlan Google-esemény nem állítja meg a többit (REL-10):** ismeretlen időzónájú / hibás dátumú esemény kimarad, és a szinkron jelzi („N Google-esemény nem olvasható be”); az eltűnt naptár külön, érthető jelzést kap.
- **Az óraeltérés ne némítsa el a szerkesztést (REL-9):** az írás bélyege legalább 1 ms-mal a felváltott változaté után jön (rekordok és pénzügy), ezért ha egy másik eszköz órája előrejár, a rá épülő szerkesztés akkor is nyer. Az óraeltérést (2 napnál jövőbelibb bélyeg) az 1c Diagnosztikája jelzi majd.
- **Magyar állapotszövegek:** korlát, napi korlát, nincs kapcsolat, feladott módosítás, nem olvasható esemény, eltűnt naptár, váratlan hiba – a felületen nincs többé osztálynév. A Részletek mutatja a következő automatikus próbát és a feladott módosításokat.

**Szándékos eltérések az audit szövegétől:** nincs determinisztikus Google-esemény-azonosító (az azonosító-szabályok és a törölt azonosítók viselkedése élőben nem ellenőrizhető; helyette ütemezés + visszalépés); a bejövő időbélyeg lefogását (SEC-16) nem építettem be (két eszköz eltérő értéket tárolna, és a Drive-fájl oda-vissza íródna) – helyette a rá épülő szerkesztés nyer; az újrapróbálás állapota memóriában van (nincs séma-változás; az az 1b-ben jön).

Tesztek: mag 422 (volt 417), app 865 (volt 693); 61 szándékos elrontást mind elkapnak a tesztek.

**Nem ellenőrizhető itt:** a Google valódi hibakódjai és `Retry-After` fejlécei; hogy a Google kivétel-példánya örökli-e a sorozat `appEventId`-jét (a védelem mindkét esetben jó); a `conferenceData` sorsa az `events.update`-nél; a naptár törlésekor kapott pontos státusz; a valódi kvóta-küszöbök; a visszalépés és a háttér-szünet valódi telefonon / gépen.

## 2e. fázis – edzés utáni visszajelzés, és a program tanul belőle

**Mit kérdez**
- Egy edzés után (a **címéből** ismeri fel: Gym, Calisthenics, Street Workout, kajak, mászás, kerékpár, futás, úszás, CrossFit, „edzés” …; műszakot és egész napos eseményt nem) a főoldalon, a napi check-in alatt megjelenik: **„Hogy ment: Gym (18:00–19:00)?”** – *Később* / *Kitöltöm*. A kérdés a **legutóbb véget ért** edzésre szól (az elmúlt 36 órából), és csak akkor, ha még nincs rá visszajelzés.
- Az űrlap öt gyors skála (mind nem kötelező, legalább egyet meg kell adni): **fizikailag** és **mentálisan** mennyire volt nehéz (1 könnyű … 5 nagyon nehéz), **mennyi energiával kezdted** és **fejezted be** (1 kimerült … 5 tele), **milyen élmény volt** (1 rossz … 5 kiváló) + megjegyzés. A *Kihagytam* azt rögzíti, hogy az edzés nem volt meg; a *Később* az adott indításra elrejti.
- Az app visszatérésekor és 5 percenként újra ránéz, hogy az épp befejezett edzés is előkerüljön (háttér-értesítés nincs). **Beállítások → Edzés utáni visszajelzés kérése** (alapból BE) kikapcsolja.
- A visszajelzés új, szinkronizált rekordfajta (`workoutlog`, a Drive `appDataFolder`-ben, mint a check-in): mezőnkénti összefésüléssel, több eszközön; ugyanarra az edzésre (esemény + az előfordulás kezdete) egy visszajelzés van, egy ismétlődő edzésnek naponta egy.

**Mit tanul belőle (a határokat a kód méri, nem a modell szava)**
- **Szigorít magától:** ha egy 45–59 perces típus (pl. Gym) **legutóbbi 3 alkalma** átlagosan **≥ 4/5** nehéz volt, a program 45 perctől nehéznek veszi (energia-, műszak- és 48 órás kapu, heti plafon rá is érvényes). Az óvatosság nem kér engedélyt.
- **Lazít, de csak a jóváhagyásoddal:** ha egy 60–89 perces típus (pl. Calisthenics) **legutóbbi 5 alkalma** átlagosan **≤ 2/5** nehéz volt, a főoldalon kártya kérdezi: **„Megtanultam: a Calisthenics (60–89 perc) számodra könnyű … Annak vegyem?”** *Igen* → egy jelölt sor kerül a **Tanult szokások**-ba (`[könnyű: calisthenics] …`; a Kézikönyvben látod, szerkesztheted, törölheted = visszavonod, és a modell is látja), és a típus innentől **90 percnél** számít nehéznek. *Nem* → ezen az eszközön megjegyzi, és csak **+5 új alkalom** után kérdez újra.
- Az **új, nehéz visszajelzések azonnal visszaveszik** a megadott engedélyt (ha a 60–89 perces típus legutóbbi 3 alkalma ≥ 4/5), és a szigorítás mindig erősebb a lazításnál. A modell `hard` jelzése és a „nehéz / intenzív / HIIT” cím a lazítást felülírja, a „könnyű / nyújtás / mobilitás” cím mindig könnyű marad.
- A tanult határ a **javaslat besorolásába, a naptárban már lévő edzések besorolásába és az ellenőrző kapukba** is bekerül; a javaslat-kártya „nehéz” jelzése azt mutatja, amit a szabályok mértek (a modell szava helyett).

**Mi megy a modellnek**
- Tervezésnél és vegyes (törlés + tervezés) kérésnél, ha van visszajelzés és a **Napi check-in** kapcsoló be van kapcsolva: egy `edzes_naplo` blokk, **legfeljebb 10 sor, 60 napon belül**, soronként pl. `05-17 gym 60p nf4 nm2 e3/2 k4` (nap, sport, perc, nehézség fizikai / mentális, energia az elején / végén, élmény) vagy `05-15 gym 60p kihagyta`. **A cím és a megjegyzés soha nem megy ki**, csak az általános sportkulcs; a megjegyzés a Drive-on kívül sehova.
- A rendszerprompt új sorai: a jelmagyarázat, a használat („a nagyon nehéz vagy sok energiát elvevő edzéshez hasonlót rövidebben vagy könnyebben tervezz”) és – ha vannak – az egyedi nehéz-küszöbök. A törlés- és a pénzügyi kérés változatlan.
- Méret: tíz sor + a prompt-sorok ≈ **+175 token** (a mintanaptáron a „Tervezz edzést a jövő hétre” így is 3 300 alatt marad; visszajelzés nélkül nincs többlet). A költségvetés-őr az „edzésnapló”-t a Tanult szokások előtt hagyja el. Kikapcsolt check-in mellett a modell nem kap semmit, a kódban a tanult határok viszont érvényesek.

**Közben talált és javított:** a szöveg-tisztítás kiveszi a `>` jelet, ezért az energia-sor elválasztója `/`; a napi check-in és az új űrlap skála-feliratai nagy rendszerbetűnél vagy keskeny képernyőn kilógtak volna (most egyenlő részt kapnak, és törnek); a check-in sávnak és űrlapnak eddig nem volt tesztje.

Tesztek: mag 417 (volt 335), app 693 (volt 627); 31 szándékos elrontást mind elkapnak a tesztek.

**Nem ellenőrizhető itt:** a modellek viselkedése az `edzes_naplo` blokkal; hogy a küszöbök (3 alkalom / ≥ 4; 5 alkalom / ≤ 2; 45 és 90 perc) a te edzéseidre jól vannak-e beállítva (ha nem, egy sor átírni); hogy a kártya mikor jön fel a valódi használatban (nincs háttér-időzítő: megnyitáskor, visszatéréskor, 5 percenként); a cím-alapú felismerés a valódi naptáradon (egy „Edzői értekezlet” edzésnek számítana – a kérdést ilyenkor a *Később* vagy a *Kihagytam* lezárja); a Drive-szinkron két valódi eszköz között; az új sáv, űrlap és kártya kinézete valódi eszközön.

## 2d. fázis – szabálymotor, pontosabb hatókör, helyi válaszok

**A szabályokat a kód méri, nem a modell szava**
- **Nehéz edzés = 60 perctől** (vagy ha a cím annak mondja: „nehéz”, „intenzív”, „HIIT” …; vagy a modell is annak jelzi). A „könnyű”, „nyújtás”, „mobilitás”, „séta” … című tétel mindig könnyű. Eddig a modell `hard` jelzése döntött, és egy „mindent könnyűnek” mondó modell kikapcsolta az energia-, a műszak- és a 48 órás szabályt.
- **A műszak-puffer (8 óra)** minden 45 perces vagy hosszabb edzésre érvényes, nem csak a nehézre.
- **A naptárban már lévő edzések** (gépelt vagy korábbi terv: „Gym”, „Calisthenics”, „Street Workout”, kajak, mászás, kerékpár, futás, úszás, „edzés” …) beleszámítanak a **heti plafonba** és a **48 órás szabályba**; a szabályellenőrzés a javaslat ISO-heteit és ±2 napját is megnézi. Az „other” fajta + egyértelmű edzéscím nem kerüli meg a plafont.
- **Check-in nélküli nap = 3/5 feltételezés** (`PlanRules.assumedEnergy`): check-in csak mára és a múltra van, így a „check-in nélkül csak könnyű” szabály – a 60 perces nehézséggel együtt – minden jövő napot kizárt volna. A minimum emelésével (pl. 4) a szigorú viselkedés visszajön. *Ez szándékos változás: a hosszú edzés is javasolható check-in nélküli napra.*
- **Alvás-ellenőrzés intervallum-átfedéssel:** a 22:00–08:00-s blokk (kezdése és vége ébren, közben végig alvás) eddig átcsúszott.
- A szabálysértés visszajelzésében a modell által sosem látott, gépelt rövid esemény címe is „foglalt”.

**Pontosabb hatókör (mit kap a modell a kérésből)**
- Ékezet nélkül is érti („torold a holnapi edzest”); a tagadott ige nem kérés („ne töröld a fogorvost”); a hasonló szavak nem tévesztik meg (költözés, fizetésnap, törölköző, „mozgás”, keretrendszer).
- A megnevezett nap szűkíti az ablakot: ma 1, holnap 2, holnapután 3 nap, hétvége a vasárnapig hátralévő; törlésnél / áthelyezésnél legalább 3 nap (14 helyett, ha csak napot nevez meg).
- Ami nem tervezés és nem pénz („Mikor van a műszakom?”, „Szia”), csak az eseményeket kapja; szabad idősávot csak akkor, ha időpontot keres.
- **Vegyes kérés** („töröld a holnapi edzést és tervezz újat”): az események hivatkozásokkal, mellé a feladatok, a check-in és a szabad idősávok; a rendszerprompt a tervezés jelmagyarázatát és a kemény szabályokat is megkapja, a Kézikönyv a tervezési fájlokat is.

**Időjárás:** az előrejelzést 3 órára megjegyzi (ugyanarra a helyre, hosszra és helyi napra; két egyidejű kérés egy hálózati kérés; hiba nem marad meg), és az események, feladatok, szabad idősávok olvasásával egy időben kéri (eddig utánuk, sorban). A `get_weather` eszközt szándékosan nem építettem be: a szabadtéri tételeket a kód úgyis ellenőrzi az előrejelzés ellen, az eszköz minden tervkérésnél további tokeneket költene.

**Helyi válaszok – nem kell hozzá kulcs, modell és token**
- „Hogy állok a költségkerettel?” (és társai: „Mennyit költöttem?”, „Mennyi pénzem maradt?”, „Költségkeret” …): a hónap kiadása / bevétele / egyenlege, minden keret állapota a legrosszabbal kezdve, a keret nélküli kategóriák, a következő 14 nap esedékes tételei, a célok. A számok a modellnek menő pénzügyi blokk számai, így a kettő nem térhet el.
- „Mi lesz holnap?” (ma / holnap / holnapután / a héten, „a mai napirendem”, „mit csinálok holnap” …): az nap eseményei időrendben (egész napos elöl, az előző napról átnyúló műszak jelölve), a határidős és a késésben lévő feladatok, az időjárás-sor.
- Csak **ismert alakú, teljes mondat** számít helyinek (ékezet nélkül és köszönéssel is); bármi, ami többet kér, a modellhez megy. Az adat az eszközön van, ezért a megosztási kapcsolóktól függetlenül működik.
- A kártya **„Helyi válasz, modell nélkül”** jelölést kap; alatta **„További kérdés” + „Kérdezd a modellt is”**: a kérdés a modellhez megy, a helyi válasz szövege adatblokként kíséri – de csak ha az érintett adat megosztása be van kapcsolva (költségkeret: pénzügy; napirend: események és feladatok), a gépelt rövid események címe ilyenkor is „foglalt”, a szöveg tisztítva és korlátozva megy.
- Kikapcsolt forrásnál (pénzügyi kérdés kikapcsolt pénzügynél; törlés / áthelyezés kikapcsolt eseményeknél) nem megy el egy kérés csak azért, hogy a modell elmondja, nem engedett: a program rögtön magyarázza, mit kapcsolj be.
- Új gyorsgomb: „Mi lesz holnap?”.

Becsült kérésméretek (mintanaptár, 3 karakter = 1 token): tervezés a jövő hétre ≈ 2 970, tervezés holnapra ≈ 2 470, „Töröld a kézzel felvett programokat holnapra” ≈ 1 180 (volt ≈ 1 430), pénzügyi kérdés ≈ 460, vegyes kérés ≈ 3 250; a költségkeret kérdése 0 (helyi válasz).

Tesztek: mag 335 (volt 226), app 627 (volt 588); a 33 szándékos elrontást mind elkapják.

**Nem ellenőrizhető itt:** a modellek viselkedése a módosított szabályszöveggel (3/5 feltételezés, 60 perc, a vegyes kérés); a helyi válaszok mondat-lefedettsége a te megfogalmazásaiddal (ami nem ismert alak, az a modellhez megy, ez biztonságos irány); az új kártya kinézete valódi eszközön.

## 2c. fázis – átláthatóság: mit küld ki az asszisztens, és mennyibe kerül

**Látod, mit küldünk, és mennyi az**
- **„Mit küldünk a modellnek?”** összecsukható panel az Asszisztens oldalon: a kérés becsült mérete részekre bontva (utasítás, eszközök, adatblokkok), és maga a szöveg (adatok, idő, a kérésed; az utasítások). Ugyanaz a kód állítja össze, mint a valódi kérést, tehát amit itt látsz, azt küldjük; hálózati hívás és számlálás nélkül. A „Frissítés a beírt kéréssel” gombbal újraépíthető.
- **Használat:** a Beállításokban „Ma ennél a szolgáltatónál: N kérés · M token (be X · ki Y)” a szolgáltató saját számaiból (a rejtett gondolkodás és a gyorsítótár külön tartva); az Asszisztens oldalon „Utolsó kérés: …”, a szolgáltató adataival, ennek híján a program becslésével („≈”). Csak a **megválaszolt** hívás számít: egy 429-es vagy szerverhibás próba semmit sem használt el.
- **Költségvetés-őr:** ha a kérés becsült mérete meghaladná a kérésenkénti méretkeretet (Groq: 5 500 token a 8 000 tokenes percenkénti keretből, a válaszkeret levonása után; a többi: 20 000), a program sorban elhagy részeket: időjárás → szabad idősáv-lista (a `find_free_slots` eszköz marad) → a feladatok a 8 legsürgősebbre → az időablak 14→7→4 napra → a Tanult szokások. Csak azt sorolja fel, amivel tényleg spórolt, és a válasz mellett jelzi, mi maradt ki. Ha így sem fér, a kérés elmegy (413-ra a 2b szűkített újrapróbálása van).

**Mi megy ki, és mi nem**
- **Beleegyezés:** az első kulcs elmentésekor (szolgáltatónként egyszer, a mentés **előtt**) párbeszéd mondja el, mi megy a szolgáltatóhoz: a kérésed (legfeljebb 500 karakter) és a beépített szabályok mindig; a Kézikönyv és az adatkategóriák kapcsolóval. „Mégsem használom”: a kulcs nem mentődik. A már mentett kulcsoknál nem kérdez újra. A pénzügy alapból BE marad (a te döntésed), de itt látszik.
- **Kézikönyv-kapcsoló** (Beállítások → Mit láthat az asszisztens?): kikapcsolva csak a beépített szabályok mennek el.
- **Kevesebb személyes adat:** a pénzügyi alap blokkban nincs egyes tétel (kereskedő, megjegyzés), csak az összesítés, a keretek és a célok; egy hónap tételei csak akkor mennek, ha a modell azt kéri. A check-in szöveges megjegyzése nem megy ki. Az időjárás-blokkban nincs a helyszín neve. Tervezésnél a kézzel felvett, 4 óránál rövidebb események címe „foglalt” (a modellnek az időpont kell, nem az ok); a hosszabbaké (utazás, konferencia), a műszakoké, a saját javaslatoké és az egész napos eseményeké megmarad. Törlésnél / áthelyezésnél a nevek kellenek, ott látszanak. A szabálysértés visszajelzése sem árulja el a rövid események címét.
- A kérés szövege legfeljebb 500 karakter (a mező is korlátozza), és tisztítva megy.
- A feladatok sürgősség szerint rendezve mennek (késésben → határidő → prioritás).
- Szövegek igazítva (pénz-kapcsoló, időjárás-bekezdés).
- **Szövegek pontosítva (Build 43; a viselkedés nem változott):** a Beállítások és a beleegyezés-ablak most kimondja, hogy a kézzel felvett rövid események címe **tervezésnél** marad el, törlésnél és áthelyezésnél elmegy (a modellnek kell a név); hogy a pénzügyi tételeket a modell egy hónapra kérheti; hogy az időjárásból a napi előrejelzés megy el, a helyszín neve nem. A költségvetés-őr jelzése „méretkorlát”-ot említ („percenkénti keret” helyett, mert a keret kérésenkénti). A Feladatok kapcsolónál leírás áll.

Becsült kérésméretek (mintanaptár, 3 karakter = 1 token): tervezés ≈ 2 900, törlés ≈ 1 400, pénzügyi kérdés ≈ 460. A 2c a Build 42; a Build 43 csak a fenti szövegeket pontosítja.

**Nem ellenőrizhető itt:** a szolgáltatók valódi használat-mezői élőben (a feldolgozás a dokumentált alakra épül); hogy a „foglalt” címek mellett a modell jól tartja-e az utazás-szabályt; a becslés pontossága a szolgáltató saját számlálójához képest.

## 2b. fázis – az asszisztens kitartóbb, ha valami elromlik

**Mi történik most, ha valami elromlik**
- **Levágódott válasz** (a modell a hosszkeret miatt félbehagyta): nincs több vak javítókör (ez eddig akár 13 000 tokent is elégethetett, hogy az újabb próba megint levágódjon). Érthető üzenetet kapsz („kérj kevesebb napot vagy tételt”); ha a félbehagyott válaszban voltak hibátlan javaslatok, azok megmaradnak, és megjegyzés mondja, hogy a válasz levágódott.
- **Szerverhiba, időtúllépés** (500, 502, 503, 504, 529 vagy nincs válasz): a program kétszer újra próbálja, 1,5 és 4 másodperc múlva, az állapotsor jelzi. Kapcsolat nélkül, hibás kulcsnál, elfogyott keretnél nem vár feleslegesen.
- **90 másodperces teljes határidő:** a várakozások és az újrapróbálások együtt sem tarthatnak tovább; utána érthető üzenet jön, a kérés nem lóg a végtelenségig.
- **Mégse gomb** a munka-sorban. Az oldal elhagyása is megszakítja a kérést (nincs, aki várja, és csak tokent költene). A megszakítás azonnal hat: a kapcsolat lezárul, a későn érkező választ eldobja, és a Mégse után egyetlen kérés sem indul el.
- **Túl nagy kérés** (413, „request too large”, „context length”) **és hibás eszközhívás** (Groq `tool_use_failed`, Gemini `MALFORMED_FUNCTION_CALL`): a program egyszer újra próbálja kisebb adattal (a következő 4 nap eseményei, feladat / check-in / szabad idősáv / időjárás nélkül), és ezt jelzi a válasz mellett. Ha így sem megy, számokkal és teendővel magyarázza el (rövidebb Kézikönyv, kevesebb nap, másik modell).
- **A modell nem fogad el egy paramétert** (pl. `temperature`, `reasoning_effort`, `max_tokens`): egyszer újra próbálja nélküle (`max_tokens` helyett `max_completion_tokens`-szel is), és megjegyzi az adott modellhez, így a következő kérés rögtön helyesen megy.
- **Elrontott hivatkozás törlésnél / áthelyezésnél** (kitalált vagy összekevert esemény, illetve ütköző új időpont): a hiba okát visszaküldi a modellnek (legfeljebb kétszer), nem üres választ ad. Elutasítás (műszak, egész napos esemény, „csak kézzel felvett”, kikapcsolt eseménymegosztás) esetén nem kérdez vissza. A modellnek visszaküldött szöveg megtisztított.
- Egy kérés egy hálózati kapcsolatot használ, és a végén bezárja (eddig minden kérés újat nyitott, és sosem zárta).

**Szolgáltatónkénti alapbeállítások egy helyen (a katalógusban)**
- Tervezéshez alacsonyabb hőmérséklet (0,2; eddig mindenhol 0,4), hogy ugyanarra a kérésre közel ugyanaz a terv jöjjön.
- Válaszkorlát: Groq 2048 (a 8 000 tokenes percenkénti keret miatt), a többi 4096 (a gondolkodás is belefér); a Gemini eddig korlát nélkül ment, most 4096.
- Hibaüzenetekben a kulcs sosem jelenik meg: a használt kulcsot szó szerint kiszedi, a kulcsszerű mintákat és a hosszú azonosítókat is (a Gemini 4xx-üzenetei eddig nem voltak szűrve).

**Nem ellenőrizhető itt:** a valódi szolgáltatói hibaüzenetek pontos szövege (a felismerés a dokumentált alakra és a hibamezőkre épül, fixture-ökkel tesztelve); hogy a Groq 2048-as és a többiek 4096-os plafonja elég-e egy 20 tételes tervhez; a szolgáltató elszámolja-e a megszakított kérés már futó generálását.

## 2a. fázis – kisebb asszisztens-kérés (tokentakarékosság)

A modellnek küldött kérés mérete, **becsléssel** (3 karakter = 1 token, szándékosan óvatos), ugyanazzal a mintanaptárral (14 esemény, 6 feladat, 5 check-in, hely, előrejelzés) és a mellékelt kézikönyvvel, a régi és az új kódon mérve:

| Kérés | Előtte | Most |
|---|---|---|
| „Tervezz edzést a jövő hétre” | ≈ 6 100 | ≈ 3 000 |
| „Tervezz edzést” (7 nap) | ≈ 5 500 | ≈ 2 700 |
| „Töröld a kézzel felvett programokat holnapra” | ≈ 4 800 | ≈ 1 400 |
| „Hogy állok a költségkerettel?” | ≈ 4 450 | ≈ 500 |
| Állandó rész tervezésnél (rendszerprompt + eszközök) | ≈ 4 250 | ≈ 2 000 |

Ez a program saját becslése, nem a szolgáltató számlálója; a tényleges értéket a 2c lépés kijelzése fogja mutatni.

**Mi változott**
- A kérés fajtája (terv / törlés-áthelyezés / pénzügyi kérdés) dönti el, mit kap a modell: utasítást, kézikönyvet, adatot és eszközt. Törlésnél nem megy el az edzésszabály-gyűjtemény, pénzügyi kérdésnél sem a kézikönyv, sem a naptár.
- Az adat rövid kulcsokkal megy (a jelmagyarázat a rendszerpromptban van): az események naponként csoportosítva, a feladatok rövid azonosítóval (`t1`, `t2` …), a szabad idősávok naponként egy sorban, az időjárás napi egy rövid sor (csapadék és szél csak ha jelentős).
- Az eseményhivatkozás (`r`) csak törlésnél és áthelyezésnél megy; tervezésnél nincs is rá szükség. A tervezési kérés eszközei között nincs törlés/áthelyezés, és nincs `get_tasks` (az első üzenet már tartalmazza az összes nyitott feladatot). A törlés/áthelyezés kérés kap szabad-idősáv eszközt (egy áthelyezés gyakran „egy szabad időpontra” szól).
- A tervezési prompt csak akkor szól a pénzről (és csak akkor kapja a pénzügyi eszközt), ha a kérés pénzt is érint.
- Az eszközleírások rövidek, a `tzid` mezők kikerültek (alapzóna: a program ezt tölti ki).
- Az első üzenet sorrendje: adatok → pontos idő → a te kérésed. A rendszerprompt és az eszközlista nem tartalmaz órát, így azonos fajtájú kérések között bájtra azonos (a szolgáltatók előtag-gyorsítótárának kedvez).
- A kézikönyv alapszövegei rövidebbek, a szabályok tartalma ugyanaz (edzéstípusok, hobbisportok és évszakok, séta, időjárási küszöbök, `outdoor`); a számszerű korlátok (alvási sáv, puffer, 48 óra, heti plafon) csak egyszer, az élő beállításokból kerülnek a promptba. Új a 12 napos műszakciklus leírása (3 éjszaka 18–06, 3 szabad, 3 nappal 06–18, 3 szabad) és egy új alapfeltevés a Profilban: éjszakás műszak után aznap reggel/délelőtt nem tervez edzést (ha ez nálad nem igaz, javítsd a Beállítások → Kézikönyv → Profil fájlban). A „Naptár-jelentések” már nem hivatkozik olyan adatra, amit nem küldünk (résztvevők, belső jelölők). A sablonsorok (üres „Sérülések:” stb.) nem mennek el a modellnek.
- **A kézikönyv-migráció:** ha egy fájl mentett példánya pontosan a régi, mellékelt alapszöveg volt (sosem szerkesztetted), az új alapszöveg lép érvénybe. A ténylegesen szerkesztett fájlokhoz (pl. Profil, Tanult szokások) nem nyúl a program.
- Hiba javítva: a modell a feladat azonosítóját (`taskId`) csak a promptból tudta, a mezőleírásban nem szerepelt; most szerepel.
- Tervezési kérésnél a modell törlési/áthelyezési kísérlete kérésre sem indít felesleges javítókört; röviden elutasítódik („csak kifejezett kérésre”).

**Nem ellenőrizhető itt:** hogy a Groq, a Gemini és a Mistral modelljei ugyanolyan jól értik-e a rövid kulcsokat; ezt csak élő kipróbálással lehet látni. A javaslatot továbbra is teljes egészében a program ellenőrzi, a modell csak javasol.

## 0. fázis – a teljes ellenőrzés azonnali javításai

**Biztonság és adatvédelem**
- Az AI-szolgáltató egyéni címe csak az „Egyéni” szolgáltatóra érvényes: egy régebben mentett egyéni cím nem irányíthatja többé a Groq/Mistral/OpenRouter/OpenAI kulcsát és adatait másik szerverre. Nyilvános szerverhez `https://` kell (saját gépen/hálózaton az `http` engedett, figyelmeztetéssel).
- Az asszisztens szabálysértési visszajelzése tiszteletben tartja a megosztási kapcsolókat (kikapcsolt forrásból nem megy cím vagy energiaérték), és tisztított szöveget kap.
- A modellnek küldött szöveg tisztítása a láthatatlan, kétirányú és hasonmás-zárójel karaktereket is kiszűri; az azonosítók csak ártalmatlan karaktereket tartalmazhatnak.
- Android: az automatikus mentés/eszközátvitel kikapcsolva (a pénzügyi adatbázis nem kerül a Google-mentésbe).
- Wallet: kikapcsolt automatikus felvételnél a nyers értesítésszöveg nem gyűlik a telefonon; a hosszú számok (kártya, számla, telefon) már a sorba tétel előtt kimaszkolódnak, 30 napnál régebbi elem eldobódik; a sort az app csak a könyvelés után felejti el (összeomláskor semmi nem vész el); erősebb maszkolás a naplóban (IBAN, csoportosított számok, „…1234”).

**Megbízhatóság**
- Egyetlen olvashatatlan ismétlődési szabály (pl. más naptár `WKST=SU`-ja) már nem üríti ki az összes nézetet; a hibás esemény figyelmeztető sávban jelenik meg, egyszeri eseménnyé alakítható.
- Minden Google-hívásnak 30 másodperces határideje van, a szinkron egyszerre csak egyszer fut (a közben érkező kérések egy követő futásba olvadnak), így egy lefagyott kapcsolat nem blokkolja többé végleg a szinkront.
- A teljes újraszinkron (érvénytelen token után) nem törli a helyi, 31 napnál régebbi történetet.
- A pénzügyi postaláda: a hosszabb ideig (180+ nap) néma, majd visszatérő eszköz újra megkapja a teljes előzményt.
- Egy átmeneti Google-hiba a bejelentkezés frissítésekor már nem jelentkeztet ki (csak az `invalid_grant` számít lejárt belépésnek). A bejelentkezés 10 perc után feladja, és jelzi, ha a böngésző nem nyílt meg.

**Asszisztens**
- Törlést és áthelyezést csak akkor fogad el, ha a kérésedben kifejezetten szerepelt (egy eseménycím nem idézhet elő törlés-kártyát).
- Egyszerre legfeljebb 20 javaslat, és csak a mostantól számított 60 napon belül.
- Javítva: a „Limit miatt várok N másodpercet…” állapotsor sosem látszott.

**Kiadás**
- A Frissítés ablakban új kapcsoló: „Előzetes verziókat is keressen” (alapból be). Ha egy kiadás előzetes (pre-release), így is megtalálja.
- A CI-szigorítás (előzetes csatorna a munkaágaknak, rögzített Flutter 3.47.9, minimális jogosultság) elkészült, de **egyelőre nincs érvényben**: a Build 34 kiadás-lépése 403-mal elbukott, mert a workflow-fájljai eltértek a `main`-étől. A munkaág workflow-fájljai visszaálltak a `main`-ére; a szigorítás a `main`-en keresztül kerül vissza. A Build 34 csomagjai nem kerültek kiadásba, a következő build viszi a változásokat.
- README és dokumentáció frissítve.

## Korábbi állapot (Build 33-ig)

Naptár nézetek és szinkron, műszakbeosztás, feladatok és check-in, asszisztens több szolgáltatóval, áthelyezés/törlés jóváhagyással, feladat-ütemezés, tanult szokások, időjárás és GPS, Pénzügyek fül (napló, keretek, ismétlődők, célok, postalevél-szinkron, Wallet-értesítések), lejárt Google-belépés érthető kezelése, önfrissítés Windowson és Androidon.
