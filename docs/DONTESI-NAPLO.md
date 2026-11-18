# Döntési napló

Miért olyan a Kvantum Naptár, amilyen. Minden bejegyzés: **döntés** · **miért** · **mi volt a másik út** · **mi következik belőle**. Dátum szerint, a legrégebbi elöl; a (felhasználó) jelzésű döntéseket te hoztad, a többit a kód és az ellenőrzések alapján én, és a jelentésben kimondtam. Az építés menetét a [CHANGELOG](../CHANGELOG.md), a hibák és javítások naplóját az [audit](audit-es-fejlesztesi-terv.md) tartalmazza; a felépítés az [architektúra-jegyzetben](ARCHITEKTURA.md) van.

## Alapok

### 2026-11-10 – Nincs saját szerver; a Google-fiók a szinkron közege
- **Miért:** ingyenes, nincs mit üzemeltetni, az adat a te fiókodban marad (Calendar az eseményeknek, a Drive rejtett `appData` mappája a többinek). A kiadási szabály is ez: nincs fizetős, nincs saját szerver.
- **Másik út:** saját háttérszolgáltatás vagy Firebase.
- **Következmény:** a Google kvótáival és hibáival kell együtt élni (osztályozás, visszalépés, tartás); szerveroldali mentés nincs, ezért a pénzügyi adatnál a rendszeres mentés a védelem.

### 2026-11-10 – Privát repó, csak olvasó token a frissítéshez (felhasználó)
- **Miért:** nincs nyilvános kiadási csatorna; a token csak olvas.
- **Másik út:** külön nyilvános kiadási repó (token nélkül).
- **Következmény:** a token a binárisból kinyerhető (csak olvas, de a privát repó kiadásait megnyitja) és lejár: figyelmeztetés 14 nappal előtte, útmutató a cseréhez ([`frissito-kulcs.md`](frissito-kulcs.md)); a hitelességet az aláírás pótolja (alább). **Felülírta:** [2026-11-15](#2026-11-15--a-repó-nyilvános-felhasználó-a-frissítő-kulcs-nélkül-működik).

### 2026-11-15 – A repó nyilvános (felhasználó); a frissítő kulcs nélkül működik
- **Miért:** a privát repó Actions-kerete elfogyott, nyilvános repón az Actions ingyenes; a biztonsági átvizsgálás (git-előzmény, Actions, az app támadási felülete) nem talált a repóban valódi titkot.
- **Másik út:** a repó privát marad, és a build a havi keretre vár vagy fizetős; vagy külön nyilvános kiadási repó.
- **Következmény:** a kiadások (és bennük a beépített Google-kliens kulcsai) bárkinek letölthetők és kinyerhetők; asztali appnál ezt a Google nem tekinti titoknak, a forgatás nem old meg semmit (az új build is tartalmazza), ezért csak visszaélésnél forgatunk. A frissítő **már nem használ kulcsot** (névtelen, óránként 60 kérés egy hálózati címre; a régi buildekbe épített token még működik). Sorrend a kulcs megszüntetésénél: az `UPDATE_TOKEN` titok törlése → új build → telepítés minden eszközre → **csak azután** a GitHub-kulcs visszavonása (különben a régi app nem frissül). A kulcs nélküli frissítő kizárja a „privát repó” feltevést; az aláírt frissítés (alább) továbbra is a hitelesség egyetlen valódi védelme.

### 2026-11-10 – Falióra-idő + IANA zóna; az ismétlődés falióra-időben fut; egy megjelenítési zóna
- **Miért:** így csinálja a Google; a nyári időszámítás magától helyes (a 12 napos műszakciklus is faliórán).
- **Másik út:** UTC + eltolás; eszköz-zóna beállítás.
- **Következmény:** a „ma” és a kijelzés Europe/Budapest-időben van, utazáskor is; az esemény időtartama valós eltelt idő (DST-éjszakán a névleges és a valós eltér, a bérbecslés névlegessel számol). Eszköz-zóna opció nincs: nincs rá csomag, és a nevet nem lehet megbízhatóan kinyerni.

### 2026-11-10 – Az egyeztetés (`reconcile`) sorrendje: tárolt link → `appEventId` → iCalUID → új
- **Miért:** a saját írás visszhangját és a más eszközön létrehozott példányt így ismeri fel duplikáció nélkül.
- **Másik út:** csak iCalUID, vagy determinisztikus Google-azonosító.
- **Következmény:** a kivétel-példányt csak link vagy (sorozat + eredeti kezdés) köti, a mester örökölt `appEventId`-je nem (a sorozat-felülírás ellen). Determinisztikus Google-azonosítót nem vezettünk be: élőben nem ellenőrizhető, és a valódi baj (a tömeges feltöltés kvótája) ütemezéssel oldódik.

## Szinkron és adatbiztonság

### 2026-11-11 – Az átmeneti hiba nem fogyasztja el a próbát; visszalépés; a végleges hiba 5 próba után „parkolt”
- **Miért:** a Google 403-as használati korlátai (`rateLimitExceeded`, `calendarUsageLimitsExceeded` …) korábban 5 perc alatt „véglegesek” lettek, és az elem csendben elhalt.
- **Másik út:** fix próbaszám és fix várakozás.
- **Következmény:** a vezérlő exponenciálisan lép vissza (a `Retry-After` alsó korlát), a parkolt elem látszik, a kézi „Szinkron most” újraindítja; az újrapróbálás állapota memóriában él (újraindításkor természetes újrapróba, séma-változás nélkül).

### 2026-11-11 – Fiók- és naptár-kötés; eltérésnél a program kérdez, nem szinkronizál csendben
- **Miért:** egy másik fiókba lépés vagy egy újralétrehozott naptár vegyes adatot és helyi történet-törlést okozhat.
- **Másik út:** automatikus tükrözés.
- **Következmény:** a naptárszinkron megáll, és három út van: helyi adat megtartása, üres indulás (megerősítéssel), később. A Google-oldalon a program soha nem töröl magától.

### 2026-11-11 – Szerkesztésnél olvasás + összefésülés (`get` → saját mezők → `update`), nem teljes PUT
- **Miért:** a teljes PUT minden szerkesztésnél törli a Google-oldali emlékeztetőt, vendéget, Meet-linket.
- **Másik út:** `patch` (az ismétlődés mezőinél nehezebben kezelhető).
- **Következmény:** +1 hívás szerkesztésenként; `If-Match` + 412 újrapróba; a Google-ban törölt, de közben helyben szerkesztett esemény visszakerül (a helyi szerkesztés nyer).

### 2026-11-11 – Időbélyeg: `max(óra, a meglévő + 1)` és óraeltérés-észlelés; a bejövő bélyeg lefogását nem építettük be
- **Miért:** a lefogás (az audit SEC-16 javaslata) oda-vissza írná a Drive-fájlt, mert a két eszköz eltérő lefogott értéket tárolna.
- **Másik út:** a bejövő `updatedAt` lefogása „most + 1 nap”-ra.
- **Következmény:** egy jövőbeli bélyeg ritkán elnyomhat egy későbbi szerkesztést; a Diagnosztika figyelmeztet, ha egy módosítás 2 napnál jövőbelibb. Az idő forrása egy: `appClockProvider`.

### 2026-11-11 – A migráció egy tranzakcióban, előtte `VACUUM INTO` másolat; újabb adatbázist nem nyitunk meg
- **Miért:** a régi migráció nem volt tranzakciós és romboló volt; egy régi app egy újabb adatbázist megnyitva visszaírta volna a verziót.
- **Másik út:** külön migrációs csomag.
- **Következmény:** `kvantum.sqlite.bak-v<régi>` (legfeljebb 2 marad); az indexek séma-váltás nélkül, indításkor jönnek létre (a séma 4-es).

### 2026-11-11 – Az újabb formátumú levél és Drive-fájl megmarad; nem írjuk felül, nem töröljük
- **Miért:** egy régebbi app ne rontsa el egy újabb app adatát.
- **Másik út:** eldobás és újraírás.
- **Következmény:** a program jelzi, hogy frissíts; a rekord „piszkos” marad, amíg a formátumot nem érti.

### 2026-11-12 – A törölt rekordok takarítása 365 nap után
- **Miért:** a sírkövek korlátlanul nőnének; de a hosszú ideig kikapcsolt eszköz ne támasszon fel törölt dolgot.
- **Másik út:** 180 nap, vagy az aktív társak alapján.
- **Következmény:** konzervatív: egy eszköz, amely egy évnél tovább ki volt kapcsolva, törölt elemet hozhat vissza (ritka, kimondott).

### 2026-11-12 – A törlés azonnal megtörténik, a visszavonás visszaállít; a Google-feltöltést memóriabeli tartás késlelteti (felhasználó: a visszavonás váltja ki a megerősítő ablakot)
- **Miért:** az audit „késleltetett commit”-ja kilépéskor elveszett törlést és megkésett képernyőket okozna; a visszaállítás + tartás ezt elkerüli, és a visszavont törlés a Google-ban semmit nem mozdít.
- **Másik út:** a törlés csak 10 mp után történik meg.
- **Következmény:** a tartás csak memóriában él (ha az app a 10 mp alatt bezárul, a törlés később feltöltődik: biztonságos irány); a visszavonás minden-vagy-semmi (ha közben bárki módosított, megtagadja); a megerősítő ablakok kikerültek, a sorozat-hatókör kérdése marad.

### 2026-11-13 – A bér csak az eszközön él; a százalékok 0-ról indulnak; nem bérszámfejtés
- **Miért:** adatvédelem és jogi óvatosság: a szerződésed mérvadó.
- **Másik út:** szinkronizált beállítás, törvényi alapértékekkel.
- **Következmény:** eszközváltásnál újra be kell írni; nincs a mentésben, a Drive-on és az asszisztensnek szánt adatban; a pótlékok összeadódnak, túlóra nincs.
- **Megfordítva (2026-11-16):** a bér szinkronizált beállítás lett (Drive `appData` és mentés), az asszisztensnek továbbra sem megy el; lásd lent.

### 2026-11-14 – Egy hibás levél vagy társeszköz nem állítja meg a pénzügyi postaládát; ami nem sikerült, azt nem törli
- **Miért:** eddig egy levél, amelyet nem lehetett alkalmazni (vagy egy társeszköz, amelyre az írás elbukott), megszakította az egész kört: a többi levél és társeszköz sem kapott semmit, és minden szinkron ugyanott akadt el.
- **Másik út:** a nem alkalmazható levelet törölni (adatvesztés: a levél a másik eszköz egyetlen példánya); az első hibánál leállni, mint eddig; korlátlanul újrapróbálni (a napló megtelne).
- **Következmény:** a hálózati hiba és a lejárt bejelentkezés továbbra is az egész kör kudarca (visszalépéssel újrapróbálja); minden más hibánál a levél a Drive-on marad, egy futásban legfeljebb 3 próbát kap (az app újraindításáig utána békén marad), a sikertelen társeszköz állapota és a piszkos jelzők nem változnak, így a következő kör újra küldi. A szinkron-állapot kimondja („Pénzügy: N levelet vagy társeszközt most nem tudtam kezelni; a többit elintéztem, ezt később újra próbálom.”), a napló az okot is tartalmazza (`mail`).

### 2026-11-16 – Étkezés és folyadék: havonta egy rekord, tételenként egy mező; nincs egészségügyi alapérték; kalória + makrók + saját ételek (felhasználó)
- **Miért:** a két eszközön egyszerre felvett tételek ne vesszenek el (mezőnként „utolsó író nyer”), és ne legyen évente több ezer Drive-fájl; a célokat te adod meg, a program nem találja ki (nincs „ajánlott” kalória: az egészségügyi állítás lenne, és az orvos vagy a szakember a mérvadó).
- **Másik út:** napi rekord listamezővel (két eszköz egyszerre írt tételei közül az egyik elveszne); tételenként egy rekord (évente több ezer fájl); ajánlott napi érték életkor és testsúly alapján.
- **Következmény:** rekordfajta `intake`, azonosító `yyyy-MM`, mezők `f.<azonosító>` (étel) és `w.<azonosító>` (ital), kompakt JSON-szöveggel; a törlés a mező törlése; a másik hónapra áthelyezett tétel a régiben törlődik, az újban megjelenik. A célok alapból üresek (csak összeg látszik), a haladás szóval is ki van mondva (nem csak színnel). A modellnek semmi nem megy el belőle (forrásőr-tesztek).

### 2026-11-16 – A Napló: bejegyzésenként egy rekord; a szöveg szinkronizál, a képek csak az eszközön vannak; `image` csomag, 1600 px, EXIF nélkül; a piszkozat a `meta`-ban (felhasználó)
- **Miért:** a szöveg legyen mindenhol (mint a check-in); a kép nagy és személyes: a mentés 4 MB-os Drive-korlátja és a 11 forgó másolat miatt a képek szinkronja külön, későbbi kör. A helyadatnak (EXIF) nem szabad a naplóba kerülnie.
- **Másik út:** a képek szinkronja most (nagy forgalom, mentés-méret, törlés-szabály); az eredeti fájl másolása (3–6 MB képenként, a helyadat a fájlban marad); JPEG-írás a motorral (nincs ilyen: csak PNG és nyers bájt); a piszkozat szinkronizált rekordként (egy félkész bejegyzés jelenne meg a másik eszközön).
- **Következmény:** `journal` rekord (azonosító: uuid; `at`, `title`, `text`, `photos`); a képek `journal/photos/<azonosító>.<kiterjesztés>` alatt, a fájlnév mindig azonosító, soha nem az eredeti név; új csomag: `image` (tiszta Dart, csak a JPEG-íráshoz; a dekódolást és a kicsinyítést a motor végzi, a JPEG-írás egy `Isolate`-ban fut); amit nem lehet átalakítani (pl. HEIC Windowson), az eredetiben marad, ha ≤ 40 MB; az árva képet a napi karbantartás 2 nap türelem után törli; a másik eszközön „Ez a kép a másik eszközön van.”. A piszkozat (csak új bejegyzésnél) a `meta`-ban él, a képválasztó megnyitása előtt és az app háttérbe lépésekor íródik, mert az Android a galéria alatt megölheti a háttérbe került appot.

### 2026-11-16 – A bér, a célok és a terv-kívánságok szinkronizált beállítás (a 2026-11-13-i és a 2026-11-15-i döntés megfordul) (felhasználó)
- **Miért:** eszközönként újra be kellett írni őket, és te kérted, hogy egyszer kelljen megadni a bért és a célokat (a Helyi terv kívánságait én vettem hozzá a tervhez, mert ugyanez volt velük a hiba; kifogás nélkül maradt). A rejtett Drive-mappa ugyanaz a hely, ahová a check-in is megy, a modellnek pedig továbbra sem megy el belőlük semmi.
- **Másik út:** maradjon az eszközön (újra beírás eszközönként); egyetlen rekord mindháromnak (két eszköz egy-egy mezője ütközne); törvényi alapértékek.
- **Következmény:** rekordfajta `settings`, három rekord (`pay`, `goals`, `plan`), mezőnként a későbbi nyer: ha az egyik eszközön az órabért, a másikon a vasárnapi pótlékot állítod át, mindkettő megmarad; a Helyi terv sportlistája egyetlen mező (a sorrend egyben marad). Az új build első indításakor a régi `meta` kulcsokból (`pay.settings`, `intake.goals`, `plan.local`) az érték egy tranzakcióban átkerül a rekordba (meglévő rekordot nem ír felül; a régi kulcs törlődik); ha a két eszközön más érték volt, az később átvett nyer. Alapértéket sosem írunk rekordba: egy eszköz, amelyik nem állított semmit, nem szoríthatja ki azét, amelyik igen. A mentésben is benne vannak. A bér és a célok mostantól elhagyják az eszközt (a rejtett Drive-mappába kerülnek), a modellnek továbbra sem megy el belőlük semmi (forrásőr-tesztek).

## Az AI

### 2026-11-11 – Az AI csak javasol; a szabályokat a kód méri
- **Miért:** a modell `hard` jelzése tévedhet vagy manipulálható; a nehéz edzést (60 perctől), a heti plafont és a 48 órát a program a naptárban lévő edzésekkel együtt méri; check-in nélküli napra 3/5 energiát feltételez (mert a jövőre nincs check-in).
- **Másik út:** a modell ítélete, a programra bízott ellenőrzés nélkül.
- **Következmény:** ami a szabályokat sérti, kimarad, és megmondja, miért; minden írás külön gombra történik, a jóváhagyás előtt újraellenőrzés az élő adaton.

### 2026-11-11 – A kérés fajtája szabja meg, mit kap a modell; költségvetés-őr szolgáltatónként
- **Miért:** az ingyenes szintek percenkénti keretébe (Groq: 8 000 token) a régi ≈ 5 750 tokenes terv-kérés két hívása nem fért; az állandó rész kétszer-háromszor ismétlődött.
- **Másik út:** minden kérés a teljes adatot kapja; vagy csak a szolgáltató hibájából tanulunk.
- **Következmény:** háromféle prompt (terv / törlés-áthelyezés / pénz), tömör adatblokkok, a változó rész (idő, kérés) a végén (cache-barát); a becslés 3 karakter = 1 token (inkább nagy); keret felett sorban elmarad: időjárás, szabad idősávok, feladatok, időablak, tanult szokások. A terv-kérés ≈ 5 750-ről ≈ 2 950 tokenre ment.

### 2026-11-11 – Adatminimalizálás alapból, beleegyező párbeszéd az első kulcsnál; a pénzügy alapból BE marad (felhasználó)
- **Miért:** a kézzel felvett rövid események címe („foglalt”), a check-in megjegyzése, a helyszín neve és az egyes pénzügyi tételek ne menjenek ki feleslegesen; de te kérted, hogy a pénzügyi összesítés alapból elérhető legyen.
- **Másik út:** minden BE vagy minden KI.
- **Következmény:** törlésnél és áthelyezésnél a címek kellenek (abból tudja a modell, melyik eseményről van szó), ezt a Beállítások kimondja; a kulcs csak a párbeszéd elfogadása után mentődik.

### 2026-11-11 – Helyi, modell nélküli válasz a költségkeretre és a napirendre
- **Miért:** a modell hívása felesleges, ha az adat helyben van; nem fogy token, nem megy ki adat, kulcs sem kell.
- **Másik út:** mindent a modell válaszol.
- **Következmény:** csak teljes mondatra illeszkedő mintákra válaszol (bizonytalan esetben a modellhez megy); jelölt kártya, és a „Kérdezd a modellt is” csak engedélyezett forrásnál visz el adatot.

### 2026-11-11 – Tanulás az edzés-visszajelzésekből: szigorít magától, lazít jóváhagyással
- **Miért:** a szigorítás biztonságos irány, a lazítás nem: azt a te szavaddal kell kérni.
- **Másik út:** mindkét irányban automatikus, vagy csak a modell összegzése.
- **Következmény:** a legutóbbi 3 / 5 alkalom számít (nem a teljes átlag, mert a régi könnyű alkalmak elnyomnák az újakat); a jóváhagyott lazítás a Kézikönyv „Tanult szokások” fájljába kerül, ott szerkeszthető és törölhető (= visszavonható).

### 2026-11-13 – Helyi, szabályalapú gyors felvitel; a hangbevitel a billentyűzet diktálása
- **Miért:** nincs hálózat, nincs modell, nincs új csomag, és a bizonytalan eredménynél megerősítő előnézet mondja ki, mit vett magától értetődőnek.
- **Másik út:** modell az értelmezésre; saját beszédfelismerő csomag.
- **Következmény:** a korpusz ≈ 180 mondat, de a te mondataid mások lehetnek – ezt élőben kell kipróbálni; hangbevitel: Android mikrofon-gomb, Windows Win+H.

### 2026-11-14 – Az éjszakás műszak utáni nappali alvás a műszakból következik, saját szabálykóddal (`shift_sleep`)
- **Miért:** az alvási sáv (alap 23:00–07:00) rögzített; egy éjszakás műszak után (reggel 6-ig dolgozol) a nappali alvás szabadnak látszott, így az asszisztens oda tett volna edzést vagy „szabad ablakot”.
- **Másik út:** második, rögzített alvási sáv a beállításokban (a 12 napos ciklusban nem igaz); a meglévő `sleep_window` kódot újrahasználni (akkor a modell és a hibaüzenet nem tudná, miért esik rossz időre a blokk).
- **Következmény:** éjszakás műszak = nem egésznapos műszak, amely a szokásos alvási sáv legalább felét lefedi (a valós időpontok szerint, falióra szerint, a nyári időszámítást is kiállja; a cím nem számít); az alvás a műszak vége + 1 óra (`shiftSleepDelayMinutes`) kezdettel a sáv hosszáig tart (18:00–06:00 után 07:00–15:00). Saját szabálykód (`shift_sleep`); a szokásos sáv előbbre való (egy blokkra sosem jön mindkettő); az események megosztásának kikapcsolásakor a modell általános mondatot kap. **Ismert hézag:** ilyenkor a `find_free_slots` eszköz üres foglaltságot kap, ezért nem tud a műszak utáni alvásról – a javaslatot viszont az ellenőrző a nem megosztott adaton is elutasítja. A rögzítő tesztek tudatosan frissültek (a műszak utáni oldalon most két szabálysértés van: `shift_sleep` és `shift_rest`).

### 2026-11-15 – A helyi tervező a szabályok oracle-jával ítél, nem a sajátjával; egy edzés naponta; a kívánságok csak az eszközön
- **Miért:** ha a modell nem elérhető (nincs kulcs, elfogyott a keret), az asszisztens eddig semmit nem tudott adni; a Kézikönyv szavai (naponta egy edzés, a forgás, a napszak, a szezon) kódban sehol nem voltak.
- **Másik út:** a szabályokat a tervezőben újraírni (két helyen nem ugyanazt mondaná, és az egyik elavulna); modell a tervhez egy „olcsó” hívással (épp a keret nincs); a tervezés a háttérben, magától (nincs kérés, nincs terv).
- **Következmény:** a `planWorkoutsLocally` csak jelölteket állít elő, és MINDEN jelöltet a `validateProposal` ítél meg, ugyanúgy, ahogy a modell javaslatait – ami átment, az minden szabálynak megfelel, és a tesztek a teljes tervet is újra megítéltetik. Az ablak holnaptól 7 nap (a mai nap fele elmúlt, a „nem a múltba” külön szabály). A sportok, a heti cél és a napszak a meta-táblában (`plan.local`) van: nem szinkronizálódik és nem kerül a mentésbe (a modell nem látja; ha egy napon a másik eszközön is kell, ez új döntés). A gomb csak tervkérésnél és csak valódi kiesésnél (nincs kulcs, visszautasított kulcs, nincs keret / egyenleg / napi korlát) jelenik meg a hibakártyán; a percnyi korlátot ki kell várni. A heti automatikus terv (a H csomag másik fele) nem készült.
- **Megfordítva (2026-11-16):** a sportok, a heti cél és a napszak is szinkronizált beállítás lett (`settings/plan`); lásd lent.

### 2026-11-14 – Ha a modellnek elfogyott a kerete vagy megszűnt, a szolgáltató következő modelljére vált – kimondva, megjegyezve
- **Miért:** a Groq, az OpenRouter és társai modellenként adják az ingyenes keretet, és rendszeresen kivonnak modelleket; eddig csak a Gemininél volt tartalék, a többinél a hiba a felhasználónál maradt.
- **Másik út:** mindig a hiba és a Beállítások; csendes váltás megjegyzés nélkül; számlázási hibánál is váltani (az minden modellre egyformán igaz, értelmetlen).
- **Következmény:** csak a nulla vagy napi keret és a „modell megszűnt” (`LlmModelGone`: 404, `model_not_found`, `model_decommissioned`, és a szolgáltatók szavai 400 / 404 / 410 állapotnál) vált; a jelöltek a katalógus kedvenc-sorrendjében jönnek (legfeljebb 3, egyszer-egyszer, nem csevegő modellek – guard, whisper, tts … – nélkül); a váltás kimondva és megjegyezve („Átváltottam a(z) X modellre, mert a(z) M-hez nincs szabad keret / már nem elérhető. A Beállításokban átállíthatod.”); az egyéni címnek nincs katalógusa, ott nincs váltás; ha egyik sem jó, az ELSŐ hiba látszik (a megszűnt modellnél „Beállítások” gombbal).

## Pénzügy

### 2026-11-13 – A forintérték az alap; a külföldi pénznem mellé kerül; az árfolyamot te írod be
- **Miért:** minden összesítő, keret, cél, trend és asszisztens-összegzés forintban számol, így semmi nem változik; nincs ingyenes, kulcs nélküli, megbízható árfolyam-forrás.
- **Másik út:** tételenként pénznem az összegben, árfolyam-lekérdezéssel.
- **Következmény:** az utolsó árfolyamot pénznemenként megjegyzi (csak az eszközön); az ismétlődő tételek és a Wallet-felvétel csak forintban.

### 2026-11-13 – A bank-CSV import általános oszlop-megfeleltető varázsló; a fájl a gépen marad
- **Miért:** bankonkénti minta nem volt; a fejléc szavaiból és a cellákból kitalál, te átírod, és megjegyzi.
- **Másik út:** bankonkénti elemzők (OTP, K&H, Erste …).
- **Következmény:** a sor azonosítója a tartalmából számolódik, így ugyanaz a fájl nem hoz duplát és a törölt tétel nem jön vissza; a „hasonló” kézi / Wallet tétel alapból kimarad; az import egy tranzakció, + Visszavonás. Valódi bankfájl még nem volt kéznél.

### 2026-11-13 – Saját diagramrajzoló, nincs új csomag; alakjel és szöveges táblázat a szín mellett
- **Miért:** a trendek egyszerűek, a „hol mi áll” tiszta függvényekben tesztelhető; a jelentés nem múlik a színen.
- **Másik út:** diagram-csomag.
- **Következmény:** a rajzoló hívás-szinten tesztelt (nincs golden kép); a képernyőolvasó mondatos leírást kap.

### 2026-11-13 – Offline ünnep-táblázat (szabály + a 2026-os áthelyezések), nincs hálózat
- **Miért:** a hivatalos rendelet nem kérdezhető le ingyen, kulcs nélkül megbízhatóan.
- **Másik út:** letöltött naptár.
- **Következmény:** 2027-ben nincs áthelyezés, 2028-tól bővítendő (évente az app-kiadással); a forrást csak keresési összefoglalókkal tudtam egybevetni.

## Felület és minőség

### 2026-11-12 – Alsó sáv: Naptár · Feladatok · Asszisztens · Pénzügyek · Több; húzással áthelyezés most nincs (felhasználó)
- **Miért:** a fő funkciók ≤ 3 koppintásra; a húzással áthelyezés a legkockázatosabb tétel.
- **Másik út:** menü mögött maradó Feladatok / Asszisztens; áthelyezés húzással.
- **Következmény:** a Több (Beosztás, Beállítások) lap; az asszisztens-fülről váltás megszakítja a futó kérést; a töréspontok egy helyen (`breakpoints.dart`).
- **Módosítva (2026-11-16):** az Asszisztens a „Több” menübe költözött, a sávba a Napló került; lásd lent.

### 2026-11-13 – Nincs golden kép; helyette szerkezeti tesztek
- **Miért:** a `flutter test` Ahem-dobozokat rajzol, a golden semmit nem mondana a valódi betűről.
- **Másik út:** golden képek valódi betűvel.
- **Következmény:** túlcsordulás-, Semantics-, kontraszt- és koppintáscél-tesztek; az új felületeket valódi betűvel kirajzolva átnéztem (képeket nem tárolunk).

### 2026-11-13 – Fokozatos Ed25519-aláírás (felhasználó)
- **Miért:** a frissítő integritást ellenőriz (SHA-256), de hitelességet nem; a kulcspárt te hozod létre, a titkos kulcs csak a GitHub titkai közt él, én soha nem látom.
- **Másik út:** azonnal kötelező aláírás.
- **Következmény:** kulcs híján semmi nem változik; a kötelezés kulcs nélkül zárt irányba hibázik (érthető üzenet); több kulcs vesszővel (kulcscsere); az aláírás addig nem lép életbe, amíg (1) a workflow-PR nem olvadt be, (2) a titok és a változó nincs beállítva, (3) egy új build nem készült. Útmutató: [`alairt-frissites.md`](alairt-frissites.md).

### 2026-11-13 – Az Android `FileProvider` marad, a `READ_*` engedélyek törlődnek; a zip-védelem deklarált méretekre szól
- **Miért:** az APK-telepítés a providerre épül, és Androidot itt nem fordíthatok; a frissítő APK-ja az app saját mappájában van, ahol az `open_filex` engedélyt sem kér. A zip-bomba védelem a deklarált méreteket nézi (600 MB / 10 000 bejegyzés); a memóriahasználat átírása (folyamatos olvasás) nem készült.
- **Másik út:** saját szűk provider; folyamatos kicsomagolás.
- **Következmény:** maradék-kockázat, amit a CI-ben az engedély-lista egybevetése (tanácsadó módban) figyel.

### 2026-11-13 – A workflow-módosítások külön PR-ban, build-jelölés nélkül; a feladatágon a `.github` a `main`-nel azonos
- **Miért:** a Build 34 kiadás-lépése 403-mal elbukott, amikor a build célcommitjának workflow-fájljai eltértek a `main`-étől.
- **Másik út:** a workflow-módosítás a feladatágon.
- **Következmény:** a csatornák (stabil / előzetes), az aláírás, a CI-kapuk a draft PR #5-ben (`ci/release-hardening`) vannak, a beolvasztás a tiéd; utána a munkaági `[build]` kiadások előzetesek.

### 2026-11-12 – A Flutter-verzió rögzítve (3.50.0 / Dart 3.14.0 / Java 21), és a `deprecated_member_use` figyelmeztetés kikapcsolva
- **Miért:** a rögzítetlen `stable` 3.50.0-ra lépett, és a build, valamint a `flutter analyze` is elbukott (a Material kiköltözött a `material_ui` csomagba; 43 elavulás-figyelmeztetés).
- **Másik út:** azonnali átállás `material_ui`-ra (40 fájl, új függőség, témaellenőrzés).
- **Következmény:** az átállás külön, szándékos döntés (a próbát lásd lent); a verzióemelés ellenőrzőlistája: [`verzio-frissites.md`](verzio-frissites.md).

### 2026-11-14 – Lint: csak olyan szabály kerül be, amely alatt a kód tiszta, vagy ≤ ≈ 20 gépies javítással azzá válik
- **Miért:** az app `flutter analyze`-a az infóra is bukik, ezért nulla tolerancia kell; a szárazfutás ≈ 90 jelöltet mért.
- **Másik út:** minden szabály vagy semmi.
- **Következmény:** 21 szabály bekerült (`unawaited_futures`, `cancel_subscriptions`, `close_sinks`, `directives_ordering` …; a `unawaited_futures` egy valódi hibát talált: egy teszt helyi `fail` függvénye eltakarta a keretrendszerét); kimaradt a sok találatú: `unnecessary_final`, `avoid_dynamic_calls`, `avoid_catches_without_on_clauses`.

### 2026-11-14 – Az ICS-minták kézzel írottak, nem valódi exportok; a CMP-5 „részben kész”
- **Miért:** valódi Apple / Outlook / Google exportom nincs; a minták az ismert alakot követik, a Google JSON típusai pontosan a Google-éi.
- **Másik út:** várni valódi exportra.
- **Következmény:** a minták csendes adatvesztést fedtek fel és javítottak (lemondott események, EXDATE-típus, saját `TZID`, Windows-zónanevek, a Google-ból lehúzott események az .ics-körúton, árva kivétel-példány, áthajtott többbájtos betű); a nem javított korlátok (RDATE, EXRULE, `RANGE=THISANDFUTURE`, `WKST` ≠ MO, UTC-ben rögzített sorozat) figyelmeztetésként látszanak és a „korlát” tesztek rögzítik. Küldj valódi exportot, és bekerül mintának.

### 2026-11-14 – QA-2: `part` + privát kiterjesztés az asszisztens-szolgáltatásnál; a Beállítások kártyái állapotos tartalmakba, `AutomaticKeepAlive`-val
- **Miért:** az `assistant_service.dart` 1 670, a `settings_page.dart` 1 187 sor volt; a szétbontás csak mozgatás, viselkedés-változás nélkül. A privát `extension` a `part` fájlban az osztály saját állapotát éri el, és semmi nem lett publikus (Dart 3.13.7 és 3.14.0 alatt is kipróbálva); a `setState` `@protected`, ezért a Beállítások állapotos kártyái saját `State`-et kaptak.
- **Másik út:** `part`-ba tett `State`-részek (a `setState` miatt nem megy); semmi.
- **Következmény:** 1 670 → 708 és 1 187 → 574 sor; a lista a kigörgetett kártya állapotát eldobná, ezért az új kártyák `AutomaticKeepAliveClientMixin`-t kapnak (a beírt kulcs, a futó fájlművelet kigörgetés után is megvan: `settings_split_test`, keep-alive nélkül elbukik). A többi 900 sor feletti fájl (`quick_entry` 1 085, `assistant_page` 921, `bank_import_page` 908, `event_editor` 908) nem volt része ennek a körnek – a 7. körben szétbontva (lásd lent).

### 2026-11-15 – QA-2, második kör: a `setState` helyett `_set`; a 750 soros értelmező lépésekre, a régi–új összehasonlítás ellenőrzi
- **Miért:** a négy megmaradt nagy fájl (`quick_entry` 1 085, `assistant_page` 949, `bank_import_page` 908, `event_editor` 908) olvashatatlanul hosszú volt; a `parseQuickEntry` egyetlen 750 soros függvény.
- **Másik út:** állapotos kártyákra szedni a két oldalt (mint a Beállításoknál; itt az állapot összefonódik, az átrajzolás következménye nagyobb); a függvényt egy állapotosztályra és mezőkre bízni (a mezők nem „promótálódnak”, minden használat után `!` kellene).
- **Következmény:** `part` + privát kiterjesztés, a kiterjesztés a védett `setState`-et nem hívhatja, ezért a két állapotos oldal kapott egy `_set` segédet (7 és 14 sor: az egyetlen szöveg-változás, a többi sor halmaza egyezik, ellenőrizve). Az értelmező lépésekre bomlott (`_takeRepeat`, `_takeDay`, `_takeMinutesFromNow`, `_takeDuration`, `_takeHour`, `_takeLengthAfterStart`: mindegyik helyi változókkal dolgozik, és egy kis rekordot ad vissza; a sorrend ugyanaz). A régi és az új értelmező ~ 1 millió elemzésen ugyanazt mondja (38 ezer valós és generált mondat × 7 „most”, plusz 103 ezer véletlen tokenkeverék × 7) – ez az ellenőrzés találta meg a „18:00 hetente” hibát is, amelyet külön commit javított (a szám nem lehet az óra perce, a nulla nem darabszám).

### 2026-11-14 – QA-3: a tesztek a dologra várnak, nem időre; egy óra
- **Miért:** a 36 nem nulla `Future.delayed` ≈ 11 s fix alvás volt, és lassú gépen ingadozott; három falióra-mérő állítás gépfüggő volt.
- **Másik út:** hosszabb várakozás.
- **Következmény:** `turnUntil` / `pumpUntil` (az eseményhurok fordulói, a hiba csak a kudarc határa), `FakeAsync`, beinjektált szünet (`SyncEngine.pause`) és óra; az `appClockProvider` az egyetlen óra (a szolgáltatók és a tárak ezt követik); az őrző-teszt (`no_real_waits_test`) a visszacsúszást megfogja. Indokolt kivétel: a `Stopwatch` a `pumpUntil` kudarc-határában, a fájl-mtime alapú takarítás tesztjei és az óra-teszt, amely épp a valódi órát mondja ki alapértéknek.

### 2026-11-14 – A szinkront hajtó teszt a feltöltések közti szünetet nullára állítja (a CI találta); őrző-teszt tartja
- **Miért:** a repó nyilvános lett, az Actions újra futott, és egy tesztet háromszor ugyanúgy bukott: a vezérlő két feltöltés között 200 ms ÓRA-időt vár (`syncPaceProvider`), a teszt viszont az eseményhurok fordulóira (`turnUntil`) vár – lassú gépen a szünet alatt elég forduló telt el, gyorson elfogytak. Heteken át átment, mert a felhős gép lassú volt; a CI sebessége más.
- **Másik út:** több forduló engedése (a hiba csak elbújna); valós várakozás (a QA-3 döntésével ellentétes).
- **Következmény:** a `controller_test` a szünetet nullára állítja (a többi szinkront hajtó teszt már így tett); a `no_real_waits_test` új őre megbuktat minden tesztet, amely `.signIn(` / `.syncNow(` hívással szinkront hajt, és nem említi a `syncPaceProvider`-t (a megjegyzések nem számítanak; az őr ideiglenes fájlokon önmagát is kipróbálja). A tanulság: a CI a második szem, más géppel és más sebességgel.

### 2026-11-15 – A Drive-ból érkező fájl külső bemenet: olvasási korlát, őrült jövőbeli bélyeg eldobása, lezáratlan zip elutasítása, kézikönyv-hosszkorlát
- **Miért:** a nyilvánossá tétel előtti átvizsgálás (az app a támadó szemével) négy rést talált azon, amit a program a Drive-ról olvas: nem volt méretkorlát; egy jövőbe bélyegzett rekord minden későbbi szerkesztést elnyomott volna; a jelszavas mentés sima zipre cserélhető volt (a visszaállítás a jelszót sosem kérte volna); a Drive-ból jövő kézikönyv nyersen, hossz nélkül ment a modellhez.
- **Másik út:** a bejövő bélyeg lefogása (az audit SEC-16 javaslata): oda-vissza írná a Drive-fájlt (a két eszköz más lefogott értéket tárolna), és az óraeltérésnél adatot veszítene; helyette csak a 365 napnál messzebbi bélyeget dobja el, a kisebb eltérést (a REL-9 döntése szerint) elfogadja. A naptár-választás szigorítása (SEC-10): élő Google-ellenőrzés kell hozzá, és a meglévő kötést törhetné, ezért kimaradt.
- **Következmény:** egy Drive-fájlból legföljebb 8 MB olvasható (`driveMaxReadBytes`; a nagyobb a pull-ban kimarad, a mentés-visszaállításnál „sérült”); a 365 napnál messzebbi bélyegű rekord (feladat, check-in, kézikönyv, pénzügyi levél) nem érvényesül; a jelszavas visszaállítás a lezáratlan zipet elutasítja (`BackupProblem.notLocked`); a kézikönyv a promptban legföljebb 12 000 karakter. Ismert maradék: egy 365 napnál kisebb, szándékos óra-előreállítás még elnyomhatja a későbbi szerkesztéseket (az óraeltérés-észlelés figyelmeztet).

### 2026-11-15 – A naplótisztító ismeri a GitHub- és Google-kulcsok alakját
- **Miért:** a Diagnosztika-jelentés és a napló hibasorai nyilvános helyre (hibajegy, üzenet) is kerülhetnek; a tisztító addig csak az `sk-`, `gsk_`, `AIza` előtagot és a 32+ karakteres hosszú sorozatot ismerte.
- **Másik út:** csak a hosszú sorozat szabálya (a rövidebb GitHub-kulcsokat és a Google-tokenek előtagos alakját elengedné).
- **Következmény:** új minták a `redactSecrets`-ben: `github_pat_`, `gh[pousr]_`, `GOCSPX-`, `ya29.` és a `1//0` frissítő-token előtag; a teszt azt is rögzíti, hogy a hasonló szavak és az előtag önmagában (`ghp_`, `GOCSPX-`) nem kulcs, és maradnak.

### 2026-11-15 – Rendezés a nyilvánossághoz: SECURITY.md, szigorúbb `.gitignore`, példa-címek, és a nyitott biztonsági részletek kikerülnek az audit-naplóból (felhasználó)
- **Miért:** a repó nyilvános. A naplóban a még nyitott tételek helye, támadási útja és javítási terve térkép volna annak, aki keresi őket; a tulajdonos döntése: „Kivesszük a nyitott részeket”.
- **Másik út:** minden marad (átlátható, de térkép); az egész napló kikerül (a kész tételek története is elvész).
- **Következmény:** a SEC-1, 6, 10, 16, 17, 18, 19 részletei külön fájlban a tulajdonosnál vannak (nem a tárolóban); a naplóban a státusz és „a részletek nem nyilvánosak” áll. A `.gitignore` titok- és adatmintái bővültek; a tesztekben a valódi tartományú példa-címek `example.com`-ra cserélődtek; `SECURITY.md` mondja meg, hogyan lehet privátban jelenteni, és mi nem hiba. A kézikönyv alapfájljai (`assets/handbook`) változatlanok.

### 2026-11-16 – Alsó sáv: Naptár · Feladatok · Napló · Pénzügyek · Több; az Asszisztens a „Több” menübe (felhasználó)
- **Miért:** a Napló új fő hely, amelyet gyakran használsz; a sáv így is öt gombos marad (a felirat-szabály és a 360 dp-s elrendezés nem romlik). Az Asszisztenst te jelölted ki arra, hogy a „Több” menübe költözzön.
- **Másik út:** hat gomb (keskeny telefonon nem fér el); a Napló a „Több” alatt (a mindennapi használathoz túl mély).
- **Következmény:** az Asszisztens a „Több” menü első eleme; ugyanúgy tovább él (az állapota megmarad, a futó kérés leáll, ha elhagyod); amíg rajta vagy, a „Több” gomb van kiemelve, a Vissza a Naptárra visz; a „Több” lap görgethető (öt elem 200 %-os betűvel nem férne el). A 2026-11-12-i bejegyzés ezzel módosul.

### 2026-11-16 – A „Napló” a Diagnosztikában „Hibanapló” lett
- **Miért:** a Napló fül a te bejegyzéseid helye; ha a Diagnosztika is „Napló”-t mondana, a kettő összekeveredne.
- **Másik út:** a fül kapjon más nevet; te „Napló” fület kértél.
- **Következmény:** a Diagnosztika oldal, a jelentés, a törlés párbeszéde és a dokumentáció „Hibanapló”-t ír; a kódban a `diag` / `DiagLog` név marad.

## Függő (próba, nem döntés)

### 2026-11-14 – A `material_ui`-ra áttérés: kipróbálva, nem épült be
- **Miért kipróbálva:** a Flutter 3.50 a Material-könyvtárat külön csomagba költözteti, az elavulási figyelmeztetést most kikapcsolva tartjuk; tudni kellett, mennyi az áttérés.
- **Eredmény:** külön másolaton `dart fix --apply` 203 javítást tett 95 fájlban, egy kézi lépéssel (`GlobalMaterialLocalizations`, három fájl); 98 fájl, +134 / −131 sor; az elemző tiszta mindkét SDK-n, a próba idején mind a 2 699 app-teszt zöld volt Flutter 3.50.0-n.
- **Miért nem épült be:** külön döntés kell hozzá (új függőség, a kinézet valódi eszközön nincs megnézve); részletek és a beépítés lépései: [`verzio-frissites.md`](verzio-frissites.md).
