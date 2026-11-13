# Változások

A build-számok a GitHub-kiadások (`build-<szám>`) számai. A legfrissebb elöl.

## 4. fázis, 4.1/A – emlékeztetők Windowson (A csomag)

**Emlékeztetők Windowson is** (Beállítások → Értesítések → **Emlékeztetők**: a műszak előtti és a napi check-in emlékeztető, ugyanaz a két kapcsoló, mint Androidon)
- Windowson az emlékeztetők **ütemezett Windows-értesítések (toast)**: az ütemezést a **Windows tartja, és a kitűzött időben akkor is megjeleníti, ha a program be van zárva**. A program akkor frissíti az ütemezést, amikor fut (induláskor, szinkron után, a beosztás vagy a check-in változásakor, 1,5 másodperces sűrítéssel, és csak a különbséget küldi el, mint Androidon). Legfeljebb 60 emlékeztető, 14 napra előre. Nem megy el hozzá adat sehová.
- A Windows az ütemezett értesítésről csak az azonosítót árulja el (a szöveget és az időt nem), ezért a program **maga írja fel**, mit adott át (a `rem.win.plan` bejegyzés a beállítások táblában), és a Windows listájával csak azt vetíti össze, melyik jelent már meg. **Ha semmit nem adott át, a Windowstól nem is kérdez** (aki sosem kapcsolt be emlékeztetőt, annak a program nem regisztrálja magát az értesítési rendszerben csak azért, mert elindult). Ha egy értesítésről nincs feljegyzés (elveszett a beállítás, régebbi változat), a következő ütemezés lecseréli vagy leveszi, és az első átadás a feljegyzés nélküli értesítéseket (a próba kivételével) leveszi.
- Egy már átadott emlékeztetőt a program **előbb leveszi, aztán adja át újra** (a Windows az azonos azonosítójú ütemezést nem cserélné, hanem megduplázná). Ami **20 másodpercen belül** esedékes, azt nem adja át (a Windows a múltbeli időt elutasítja); a megjelenés előtti utolsó pillanatban a program nem is tud mit tenni.
- A program a Windowsnál **„Kvantum Naptár”** néven jelentkezik be (az értesítési központban és a Windows értesítési beállításaiban ez a név látszik; az azonosítója és a GUID-ja soha nem változhat). A Windows nem kér külön engedélyt; ha a „Ne zavarjanak” / Fókusz mód be van kapcsolva, az értesítés csendben a központba kerül.
- Az első indítási kártya („Első lépések”) mostantól Windowson is felajánlja az emlékeztetők bekapcsolását (eddig csak Androidon).

**Próba-értesítés** (Windowson, ugyanott)
- A **„Próba-értesítés (fél perc múlva)”** gomb egy értesítést ütemez fél percre, és megmondja, mit tegyél, ha nem jelenik meg (Windows Beállítások → Rendszer → Értesítések → Kvantum Naptár, „Ne zavarjanak”). **Be is zárhatod a programot addig**: így közvetlenül látod, hogy a zárt programnál is megjönnek az emlékeztetők. A próba nem kerül a tervbe és a feljegyzésbe, ezért a valódi emlékeztetők frissítése nem veszi le.

**Indítás a Windows-szal** (alapból ki; Beállítások → Értesítések → Emlékeztetők alatt)
- Bekapcsolva a program **bejelentkezéskor magától elindul, lekicsinyítve a tálcára**, nem kér fókuszt, szinkronizál, és frissíti az emlékeztetőket. A bejegyzés a felhasználó saját indítási listájába kerül (`HKCU\...\Run`, `KvantumNaptar`, parancs: `"<a program>" --minimized`), rendszergazdai jog és új függőség nélkül (a Windows `reg.exe` eszközével, a rendszer saját példányával).
- **Tálca-ikon nincs** (az ütemezett értesítéshez nem kell); a lekicsinyített program a tálcán látszik. A háttérben futó program memóriát foglal (egy Flutter-programnál több tíz, akár száz MB), ezért van alapból kikapcsolva. Egy **második indítás** (parancsikon, kézi) továbbra is a már futó ablakot hozza elő; a Windows által `--minimized` kapcsolóval indított második példány viszont csendben kilép.
- Ha a felhasználó a Windows saját indítási listájában (Beállítások → Alkalmazások → Indítás, vagy Feladatkezelő) kikapcsolta, a kapcsoló ezt mondja ki („A Windows letiltotta”), és a bekapcsolása újra engedélyezi. Ha a program mappája elköltözött, vagy régebbi változat írta a bejegyzést, a program induláskor **kijavítja** (csak ha a bejegyzés már megvan; nem hoz létre újat, és a Windows letiltását nem oldja fel).
- A **lekicsinyített ablak** számítógépen **tovább szinkronizál** a lassú ütemében (eddig a „rejtett” állapot az időzítőt leállította, mint a telefonon a háttér), különben a lekicsinyítve induló program nem frissítene semmit; a telefon viselkedése változatlan.

**Útközben javítva**
- **Emlékeztetők összehasonlítása:** a `PlannedReminder` két időpontját a `==` akkor sem tartotta azonosnak, ha ugyanaz a pillanat volt, ha az egyik időzóna-csomagos (`TZDateTime`, ilyen a napi check-in emlékeztető), a másik sima `DateTime` (ilyet ad vissza az eszköz) – így a program **minden futásnál „megváltozottnak” látta a check-in emlékeztetőket, törölte és újra ütemezte őket** (Androidon is). Mostantól a pillanatot hasonlítja (és a hash is azt).
- **Beállítások keskeny ablakban, a legnagyobb betűvel:** az „Alvás kezdete / vége”, az „Emlékeztető a műszak előtt” és a „Téma” legördülő, valamint az API-kulcs állapotsora kilógott (200 %-os betűnél és 360 px-en); mostantól kitöltik a helyüket / tördelnek.

Tesztek: app 1867 (volt 1792), mag 490 (változatlan), az elemzők és a formázás tiszták; a Flutter 3.47.9-en és a 3.50.0-n is zöld. 76 szándékos elrontás (az ütemező és a feljegyzés, a próba-értesítés, az indítási bejegyzés (`reg.exe`) és állapotai, az önjavítás, a kapcsoló és a próba-gomb, a lekicsinyített ablak szinkronja, a Beállítások elrendezése; 75-öt elkapnak a tesztek, egy egyenértékű (a `TZDateTime` hash-e a natív pillanaté, ezért a hash így is azonos); a próba négy tesztelési hiányt hozott felszínre – a feljegyzés törlése levételkor, a hibás feljegyzés mellett a jó megmaradása, a rendszer `reg.exe`-jének útvonala, a próba-gomb kétszeri megnyomása – és egy halott kódot (a Windowson nem olvasott `payload`), mindre szigorúbb teszt vagy javítás készült). A Windows-runner C++ kódját (a `--minimized` kapcsoló) ezen a gépen nem lehet futtatni: `mingw-w64`-gyel szintaxis-ellenőrizve (új figyelmeztetés nincs), az éles `/W4 /WX` fordítást a Build végzi.

**Nem ellenőrizhető itt (a Windows-os próba rád vár):** hogy a Windows az **aláíratlan, nem telepített** (zipből kicsomagolt) program ütemezett értesítéseit valóban megjeleníti-e **zárt program mellett** is (a program a `HKCU\Software\Classes\AppUserModelId\Kvantum.Naptar` kulcsot és egy COM-azonosítót regisztrál, Start menü-parancsikon nélkül; ez a plugin működési módja) – erre való a **Próba-értesítés**; az értesítés kinézete (általános ikon, mert nincs külön ikonfájl), a kattintás hatása, a „Ne zavarjanak” / Fókusz mód és a Windows-értesítési beállítások hatása; a pontosság (percre); az **indítás a Windows-szal** (a bejegyzés megjelenik-e a Beállítások → Alkalmazások → Indítás listában, a bejelentkezés utáni lekicsinyített indulás, a visszaállítás a tálcáról: a korábbi méret / teljes méret megmarad-e); a `--minimized` a futó példány mellett.

**Eltérések a tervtől és ismert korlátok:** **tálca-ikon nincs** (az ütemezett értesítés nem igényli; külön körben lehet); az értesítésnek nincs saját ikonja; ha a felhasználó a Windows beállításaiban az alkalmazás értesítéseit kikapcsolja, a program ezt nem látja (a Próba-értesítés ezért van); a program **zárt állapotban nem frissíti** az ütemezést (az indítás a Windows-szal ezt oldja meg: bejelentkezéskor frissít, utána a lekicsinyített program szinkronizál); a megjelent értesítést a program nem törli a Windows központjából (csomagolatlan alkalmazásnál a Windows ezt nem engedi); a próba-értesítés azonosítója (2 000 000 001) a tervek azonosítói fölött van (a műszakoké az 1970 óta eltelt percek, a check-iné 1 500 000 000 + nap).

## 4. fázis, 4.1/F – automatikus mentés és visszaállítás (F csomag)

**Teljes mentés egyetlen fájlban**
- A mentés egy **zip-fájl**, amelyben minden benne van, amit a program tárol: a naptár (`calendar.ics`), a pénzügyek (`finance.json`), a feladatok, a napi check-inek, a kézikönyv és az edzésnapló (`records.json`), és egy `meta.json` (mikor készült, melyik buildből, mennyi mi van benne). Bármely tömörítőprogram megnyitja. **Jelszóval is lezárható** (AES-256 zip, az `archive` csomaggal – új függőség nincs); jelszó nélkül, rossz jelszóval, nem mentés-fájllal, újabb verzió fájljával és sérült fájllal is érthető magyar üzenet jön (nem „félig beolvasott” siker).
- **Vigyázz a jelszóval:** a fájlba a program nem teszi bele a jelszót, és nem tudja visszafejteni; ha elfelejted, a fájl nem nyitható meg – ezt a párbeszéd is kimondja.

**Napi automatikus mentés az eszközön** (Beállítások → Adatok → **Automatikus mentés**)
- A program indulásakor, és ha napokig nyitva marad, a visszatéréskor is: legfeljebb **20 óránként** egy mentés az adatbázis melletti `backups` mappába (Windowson `%LOCALAPPDATA%\KvantumNaptar\backups`, Androidon az app privát mappája). Közben a felület nem fagy le: a becsomagolás külön szálon (isolate) megy; a fájl először `.part` néven készül, és csak kész állapotban kapja meg a nevét.
- **Megőrzés:** az utolsó 7 nap mindegyikéről a legfrissebb, előtte 4 hétre hetente egy; a többi törlődik. A nem a program által elnevezett fájlokhoz soha nem nyúl.
- A kártyán: kapcsoló, „Utolsó mentés: …” (vagy az utolsó hiba oka magyarul), **Mentés most**, **Mentés fájlba…** (jelszóval is), **Visszaállítás fájlból…**, és a mentések listája mérettel; soronként Visszaállítás… / Mentés fájlba… / Törlés… (a törlés megerősítéssel).
- A hiba nem zavarja az appot: a sikertelen mentés a kártyán és a Diagnosztikában látszik, a következő indításkor újra próbálja.

**Visszaállítás előnézettel**
- Mielőtt bármit írna, megmutatja, mi történne: a naptárban hány esemény új, hány változatlan, **hány módosult azóta ezen az eszközön** (a nevekkel); a pénzügyeknél és a többi adatnál hány új, hány frissül, hány azonos; a fájl olvashatatlan részei.
- A módosult eseményekre kérdez: **„A módosultak nélkül”** (csak ami hiányzik) vagy **„Mindent, felülírással”** (a mostani módosításaid elvesznek). Ha nincs mit visszaállítani, ezt mondja.
- **Soha nem töröl.** A naptárban a mentés óta törölt események visszajönnek; a feladatoknál, a check-ineknél és a pénzügyeknél mezőnként / rekordonként az újabb nyer, és amit a mentés óta töröltél vagy átírtál, az marad (ezt a párbeszéd kimondja). Ami visszajön, az feltöltésre kerül (Google, Drive): a visszaállítás után a program szinkront kér.
- Zárolt fájlnál a jelszót megkérdezi (hibás jelszónál újra).

**Titkosított másolat a Google Drive-ban** (ugyanott, a kártya alsó része)
- **Hetente** (6 nap 20 óra) egy teljes mentés kerül a Drive **rejtett app-mappájába** (csak ez a program látja), **a te jelszavaddal titkosítva** (legalább 8 karakter, kétszer kell beírni), `kvbackup-<dátum>.zip.b64` néven; az utolsó **3** marad meg. Ez az eszköz elvesztése ellen is véd, amit a helyi mentések nem.
- A jelszót a program az operációs rendszer **biztonságos tárolójában** őrzi (Windows: DPAPI, Android: Keystore); sem az adatbázisba, sem a Drive-ra, sem a naplóba, sem a mentésbe nem kerül. A kapcsoló addig nem kapcsolható, amíg nincs jelszó és nem vagy belépve; bekapcsoláskor azonnal elkészül az első példány, nem egy hét múlva. A jelszó törlése kikapcsolja a másolást (a Drive-on lévők maradnak).
- **Visszaállítás a Drive-ról…:** a példányok listája (legfrissebb elöl); a tárolt jelszóval magától próbálja; ha az nem jó (például másik eszközön), megkérdezi – és ezt nem nevezi „hibás jelszónak”, csak a beírt jelszó hibáját. Új eszközön tehát elég belépni és ugyanazt a jelszót beírni.
- A másolat feltöltése a belépés után is megtörténik (ha az indításkor még nem volt belépés), és visszatéréskor is megnézi, esedékes-e; a méretkorlát ≈ 4 MB (a Drive egyszerű feltöltése 5 MB-ig megy); ennél nagyobb mentés nem megy fel, és ezt kimondja. A program a Drive-mappa többi fájljához (`task-…`, `fin-…` levelek) nem nyúl.

**Útközben**
- A szinkron-vezérlő kiadja a belépett fiók Drive-mappáját (`driveRemote()`), a kijelentkezés eltünteti.
- A Beállítások oldala magasabb lett; a kapcsolódó (nagy ablakos) tesztek ablaka 6400 képpont magas.

Tesztek: app 1792 (volt 1643), mag 490 (változatlan), az elemzők és a formázás tiszták; a Flutter 3.47.9-en és a 3.50.0-n is zöld. 93 szándékos elrontás (a fájlformátum, a mappa és a megőrzés szabályai, a mentés / előnézet / visszaállítás, a napi és a Drive-mentés időzítése és őrei, a kártya és a párbeszédek, az indítás / visszatérés / belépés kapcsolók) – mind elbukik. A próba **tizenkét tesztelési hiányt** hozott felszínre – egy nem UTF-8 szövegű rész a mentésben, a törölt rekordok a számolásban és a mentésben, a naptár olvasási hibái a visszaállítás jelentésében, a csak rekordot érintő változás az előnézetben, a visszaállított frissítés feltöltésre sorolása, a pénzügyi előnézet írása frissítésnél, az egyszerre egy mentés, az olvashatatlan beállítások, az idegen nevek a Drive-listában, a Drive-mentés tiltása a teszt-módban és a jelszó-párbeszéd görgetése rövid ablakban –, mindegyikre szigorúbb teszt készült; egy elrontás elsőre nem fordult le (javítva). Tanulság: a párbeszédek görgetésének kihagyása csak akkor látszik, ha a teszt a párbeszéd megnyitása után rövidre veszi az ablakot.

**Nem ellenőrizhető itt:** a fájlmentés és -választás valódi eszközön (Android: a rendszer fájlkezelője; Windows: mentés / megnyitás párbeszéd); a **valódi Drive** (a tesztek hamis Drive-ot használnak: a tényleges feltöltés, a listázás, az 5 MB-os korlát, a kvóta); hogy a más programok (7-Zip, WinRAR, Windows Intéző) megnyitják-e az AES-titkosított zip-et; a mentés időtartama és memóriaigénye nagy adatbázisnál (az ICS-kimenet a fő szálon készül, a becsomagolás külön szálon); a jelszó-tár valódi eszközön (Android Keystore, Windows DPAPI); az érintés- és billentyűérzet.

**Eltérések a tervtől és ismert korlátok:** a **program beállításai** (AI-szolgáltató és -modell, téma, kapcsolók) és a **belépési adatok, API-kulcsok** nincsenek a mentésben (az utóbbiak az eszköz biztonságos tárolójában vannak, és ott is maradnak); a helyi mentések az eszközön maradnak (az Android automatikus mentése ki van kapcsolva, ez szándékos), ezért az eszköz elvesztése ellen a „Mentés fájlba” és a Drive-példány véd – ezt a kártya kimondja; a visszaállítás a feladatokat és a pénzügyeket nem hozza vissza törölt állapotból (a rekordonkénti „újabb nyer” szabály miatt) – az események igen; a Drive-példány a jelszó megadása nélkül nem készül; az időzítés nem háttérszolgáltatás, hanem indításkor / visszatéréskor / belépéskor fut (a háttérben futó alkalmazás nem ébreszti fel magát).

## 3d. fázis – hozzáférhetőség, nagy betű, téma, első indítás (UX-7, UX-8, UX-9)

**Képernyőolvasó (UX-8)**
- **Hónap:** egy nap egy megálló („csütörtök, 2026. november 12., 3 esemény, ma”; más hónap napjánál „másik hónap”; a kijelölt nap kijelöltként), a cellában lévő események külön megállók („Fogorvos, 14:00–15:00”, „Szabadnap, egész nap”, éjfélen átnyúlónál „tart tovább, 02:00-ig”), a „+N további” hivatkozás egy mondat („5 további esemény, a nap megnyitása”); a napszám és a pöttyök nem külön megállók.
- **Hét és nap:** a napfejléc („csütörtök, 2026. november 12., ma”), az esemény-blokk és az egésznapos sáv kimondja a napot is („Fogorvos, csütörtök, 2026. november 12., 14:00–15:00”); az óra-feliratok (10:00, 11:00 …) nem megállók. **Napirend:** minden sor egy megálló („Feladat: …, határidő: …”, „Késésben lévő feladat: …”).
- **Pénzügyek:** egy költségkeret-sor **egy mondat** („Élelmiszer: 3 000 Ft a 10 000 Ft keretből (30%), Maradt: 7 000 Ft”; keret nélküli sor: „Közlekedés: 4 500 Ft, a kiadások 20%-a”), nem öt külön megálló; a bevétel- és kiadás-nyíl szóban is megvan („Bevétel” / „Kiadás”); a folyamatjelzők címkét kaptak („Betöltés”, „A beosztás készül”, „Letöltés” …). A cél sávja kimarad (a mellette álló szöveg ugyanazt mondja).
- **Szín mellett jel és szó:** a költségkeret-sor ikont és szöveget is kapott („Maradt: …” / „Közel a kerethez – maradt: …” / „Túllépve: …”), nem csak színt.

**Kontraszt (UX-8)**
- **Új, közös állapotszínek** (`ui/theme.dart`, `StatusColors`): a „rendben” és a „vigyázz” szín világos és sötét témában is **legalább 4,5 : 1** a téma minden felületéhez (a régi sima `Colors.green` 2,6 : 1, a `Colors.orange` 2,1 : 1 volt a világos felületen); a „túllépve” a téma hibaszíne. A 11 kemény szín helyén ezek vannak; számolt kontraszt-teszt őrzi (`contrastRatio`, átlátszó szín esetén a háttérrel keverve).
- **A halvány szöveg** a téma `onSurfaceVariant` színe (≥ 4,5 : 1); az `outline` (4,27 : 1) már nem szöveg.
- **Az eseményszín szövegszíne** a jobb kontrasztú (fehér vagy fekete), nem fényesség-küszöb szerint: mind a 12 szín ≥ 4,5 : 1 (a flamingó színen a fehér 2,8 : 1 volt).

**Nagy betű (UX-8)** – a program a rendszer betűméretét követi, **200 %-ig tesztelve** (új `text_scale_test`: 75 jelenet, világos és sötét téma, 360 × 640, 360 × 800 és 1280 × 900 px; a fő oldalak, a szerkesztők és a párbeszédek). A mérés **valódi Roboto betűvel** történik (a tesztek addigi Ahem betűje szélesebb és alacsonyabb, ezért rejtette el éppen a fix magasságok hibáit; ez az 1,0-s betűméretnél is mutatott egy túlcsordulást: egy 45 perces esemény-blokk 3 képpontot lógott). Amit a mérés talált és javítottunk:
- **Idősáv (hét, nap, a hónap napi panelje):** az óra magassága a betűvel nő (legfeljebb 1,6-szoros), az esemény-blokk tartalmát a sorok *tényleges* magassága dönti el (egy órás blokk: kétsoros cím + idő; 45 perces: két sor; fél órás: egy sor), a legrövidebb blokk is elég magas a cím egy sorához; a napfejléc és az óra-feliratok legfeljebb 1,3-szorosra nőnek (hét oszlop 44 px-en); a keskeny oszlopban (telefonon a hét nézet) az időt a program elhagyja (korábban darabokra tört); az egésznapos sáv legfeljebb a hely felét foglalja és görget; a hónap napi panelének címe legfeljebb a panel felét (görget).
- **Hónap:** a cella sorai a betűvel nőnek (a napszám saját sort kap, a színes sáv a szöveg magasságát); ha egy rövid cellában nincs hely a pöttyöknek, a napszám után „•” jelzi, hogy van esemény.
- **Naptár tetején a sávok** (első lépések, napi check-in, edzés utáni kérdés) együtt legfeljebb a képernyő **harmadát** foglalják, és görgethetők (200 %-nál két sáv korábban 276 px-et, a képernyő 35 %-át vitte el).
- **Alsó sáv:** 1,3-szoros betűtől csak a kijelölt hely felirata látszik (öt felirat nem fér el, „Feladato/k” szétesett); a többit a képernyőolvasó felolvassa, a hosszú nyomás súgót ad.
- **Pénzügyek:** az összesítő három kártyája egy kártya három sorában, ha az összeg nem fér el az egyben; a keret-soron az összegek a név alá kerülnek, ha nem férnek mellé; a havi ismétlődő tétel és a cél szerkesztőjének sorai, a Beosztás sorai (műszakidők, kezdőnap, „Következő műszakok”), a Beállítások szolgáltató-menüje és kulcs-sora, az asszisztens gombjai és gyors javaslatai (a chip törik, nem vágódik le) – mind alá-, illetve túlcsordulás nélkül.
- **Szerkesztő:** a „Kezdés” / „Befejezés” címke és a dátum a betű alatt (a címke szó közepén tört, a dátum négy sorba); **napirend:** az idő-oszlop a betűvel szélesedik (a „07:00” darabokra tört).

**Téma (UX-9)**
- **Rendszer szerint / Világos / Sötét** választó (Beállítások → A program → Téma), a választás megmarad (`themeMode`). A világos és a sötét ugyanaz a téma két fényességben (`appTheme`), az állapotszínekkel együtt.

**Első indítás (UX-7)**
- **„Első lépések” kártya** a naptár tetején: egyszerre **egy** teendő „x/y” számolással – Belépés a Google-fiókkal (ha a buildben vannak Google-kulcsok), AI-kulcs, Hely (nem kötelező), Emlékeztetők (csak Androidon), Wallet-fizetések (csak Androidon, nem kötelező). Gombok: **Megnyitás** (a belépésnél **Belépés**), **Nem kell** (az adott lépést félreteszi), **Elrejtés** (az egész kártyát). Ha minden kész vagy félretéve, magától eltűnik; a félretétel és az elrejtés megmarad. A kártya **csak megnézi** az állapotot (kulcs van-e, belépve vagy-e, helyszín, emlékeztető-beállítás, Wallet-hozzáférés és -felvétel): nem kér engedélyt és nem nyit meg semmit, amíg nem nyomsz gombot; a Beállításokból visszatérve és az alkalmazásba visszatérve újra megnézi. A Beállítások → A program → **Első lépések újra** gombbal az elrejtett kártya visszahozható. Tesztekben alapból ki van kapcsolva (`setupGuideProvider`), a `main.dart` kapcsolja be.

**Útközben javítva**
- A hét- és napnézet (és a hónap napi panelje) a *valódi* órát használta a „ma” jelöléséhez és a piros „most” vonalhoz, nem az alkalmazás közös óráját (`appClockProvider`), mint a többi nézet; most azt.
- Az esemény-blokk tartalma 1,0-s betűmérettel is túlcsordulhatott (45 perces esemény, 3 képpont) – lásd fent.

**Tesztelő eszközök**
- `test/support/real_fonts.dart`: a Flutter SDK Roboto és MaterialIcons betűjének betöltése tesztben (ha az SDK-ban nincs meg, az érintett tesztek kimaradnak, nem buknak). `KVANTUM_SHOTS=<mappa> flutter test test/text_scale_test.dart` minden jelenetről **képernyőképet** ment (valódi betűvel és ikonokkal), így az ellenőrzés nem csak a túlcsordulás-hibákat nézi.

Tesztek: app 1643 (volt 1448), mag 490 (változatlan), az elemzők és a formázás tiszták; a Flutter 3.47.9-en és a 3.50.0-n is zöld (friss klónon is). 72 szándékos elrontás (a felolvasott szavak, a cella / blokk / sáv / sor megállói, a színek és a téma, az idősáv és a hónap méretei, a nagy betűnél átrendeződő sorok, az első lépések logikája, tárolása és bekötése) – mind elbukik, kivéve egy egyenértékű változatot (az esemény-sáv megállója a hónap cellájában: két `button` jelzésű szemantika-csomópont nem olvad össze, ezért ott a módosítás nem látszik). A próba **négy tesztelési hiányt** hozott felszínre – a fél órás blokk címe, a legrövidebb blokk magassága és a színes sáv magassága nagy betűnél (a mérés a `Material` ősöket nézte, amelyek közt mindig volt elég magas, ezért a rövidre vágott változat is átment) és a napi panel címe alacsony telefonon –; mindegyikre szigorúbb teszt készült (a magasságok most a kisegítő-lehetőségek fáján mért, tényleges megállón), egy első kísérletben nem fordítható változat pedig javítva lett.

**Nem ellenőrizhető itt:** a képernyőolvasók tényleges működése (TalkBack / Narrator – a tesztek a Semantics-fát ellenőrzik, nem a felolvasást); a rendszer betűméret-skálája valódi telefonon (a tesztek 200 %-ig lineáris skálát használnak, az Android 14 nemlineáris skálája kicsit másképp nő); a Roboto-méréstől eltérő betűk (Windowson Segoe UI); a kártya viselkedése valódi Google-belépéssel és valódi Wallet-hozzáféréssel; a kártya megjelenése és az „Első lépések” sáv érzete telefonon.

**Ismert korlát:** a **hét nézet telefonon** 200 %-os betűnél szűk (hét oszlop 44 px-en: az esemény-blokkban csak a cím első betűi látszanak, az idő nem); ott a nap- vagy a napirend nézet ajánlott. Egy 3 napos vagy görgethető hét nézet külön, nagyobb átalakítás.

**Eltérések a tervtől:** a „Hely” és a „Wallet” lépés nem kötelező (a kártya ezt ki is mondja); a lépéseket egyenként mutatja, nem listaként (egy lista telefonon, nagy betűnél az egész képernyőt elvinné); az első indítás kapcsolója a `googleConfigured` helyett saját (`setupGuideProvider`), hogy a Google-kulcs nélküli buildben is látszhasson, és a tesztek ne függjenek a Google-beállítástól; az „Első lépések újra” gomb a terven felüli kiegészítés (az elrejtésnek legyen visszaútja); a betűméret-vizsgálat a tervezett egyszerű túlcsordulás-teszten túl képernyőképekkel is történt.

## 3c. fázis – keresés, napirend nézet, húzás a lapozáshoz, a Beállítások csoportjai (UX-3, UX-6)

**Keresés (UX-3)**
- **Új kereső lap:** a naptár fejlécében a nagyító („Keresés”), Windowson **Ctrl+F**. Az eseményekben (cím, hely, jegyzet), a feladatokban (cím, jegyzet) és a pénzügyi tételekben (kereskedő, megjegyzés, kategória neve) keres; kis- és nagybetűre, ékezetre nem kényes („fogorvos” megtalálja a „Fogórvos”-t); minden szónak szerepelnie kell, sorrendtől függetlenül; legalább egy két betűs szó kell hozzá (egyetlen betű szinte mindent találna). Számjegyekből álló szó a pénzügyi tétel összegére is illeszkedik („5000” a 25 000 Ft-ot is megtalálja).
- **Események:** egy ismétlődő sorozat **egy** találat – a legközelebbi következő előfordulása (egy még tartó esemény is „következő”), lezárt sorozatnál az utolsó; az önállóan átnevezett példány csak akkor külön találat, ha csak az egyezik a kereséssel. A Beosztás-generátor jegyzet-jelölője nem keresett szöveg (a műszak neve igen). A közelgők elöl (legközelebbi először), utánuk a múltbeliek (legutóbbi először); legfeljebb 50 esemény, 30 feladat és 30 tétel, alattuk „és még N találat – pontosítsd a keresést”.
- **Használat:** koppintásra az esemény / feladat / tétel szerkesztője nyílik (a lap a háttérben marad, bezárás után a találatok ott vannak); az esemény sorában az **„Ugrás a naptárban”** gomb a napjára viszi a naptárt és bezárja a keresést; az Esc bezárja a lapot. A lista élő (a nyitott lap követi az adatot), a keresett szöveg a lap bezárásával elfelejtődik. Az események a lap nyitvatartása alatt a memóriában vannak: egy billentyű-leütés nem olvassa újra az adatbázist.

**Napirend nézet (UX-3)**
- A negyedik nézet a Hónap · Hét · Nap mellett (billentyű: **4**): a kijelölt naptól **14 nap** naponként, a napok relatív nevével („Ma · szerda, nov. 11.”, „Holnap”, „Holnapután”); az egésznapos előre, utána kezdés szerint; a nyitott, határidős feladatok a határidejük napján; ha a lista a mai napot is tartalmazza, a **lejárt, nyitott feladatok** „Késésben” címmel elöl. Az a nap, amelyre semmi nem esik, kimarad; üres időszaknál üzenet áll. Egy lépés (nyíl, billentyű, húzás) 14 nap; a cím a tartományt mutatja („2026. nov. 11. – 24.”). Az éjfélen átnyúló esemény mindkét napon ott van („22:00 →”, majd „folyt.”). A választás a többi nézettel együtt megmarad.

**Húzás (UX-3)**
- **Vízszintes húzás** (érintés vagy toll; egérrel nem, hogy egy kattintás-húzás ne mozgassa a naptárt): balra a következő, jobbra az előző hónap / hét / nap / 14 nap; hónapnézetben a rács a hónapot, az alatta (vagy mellette) lévő nap-panel a *napot* lépteti. Egy gyors pöccintés rövid úton is elég (≥ 400 px/s), lassú húzásnál 64 px kell. A függőleges görgetés és a koppintás (új esemény egy üres órára) érintetlen.
- **Nincs üres villanás:** az előző és a következő tartomány előre betöltődik, így a lépés kész adatot talál (eddig egy-két képkockára üres hét / nap látszott; a hónapnál a lépés után egy plusz képkocka telt el, mert a hónap adata saját aszinkron lépést tett – most közvetlenül a tartomány állapotát adja tovább).
- **A hónap léptetésekor a kiválasztott nap vele megy** (azonos napszám, a hónap hosszára vágva: január 31. → február 28.), nyílra, billentyűre és húzásra egyaránt – eddig a rács alatti nap-panel a *régi* hónap napját mutatta.
- **Keskeny fejléc (< 440 px, álló telefon):** a ‹ › nyilak kimaradnak (a húzás lépteti), hogy a keresés ikon elférjen és a hónap címe több helyet kapjon (360 px-en kb. 104 → 152 px). 440 px-től vannak; **képernyőolvasóval** (TalkBack) a telefonon is megmaradnak, mert azzal nem lehet húzni. A szinkron-gomb felirata 1000 px-től, a teljes vezérlők (négy szegmens, „Ma” felirat) 860 px-től jelennek meg (a negyedik nézet és a keresés miatt kellett följebb vinni). A naptár oldal a *saját* szélessége szerint dönt, nem az ablakéból (az oldalsín mellett a lap keskenyebb az ablaknál; ez eddig csak a küszöbök közelében volt gond).

**Beállítások (UX-6)**
- A Beállítások **csoportfejlécekkel** tagolt egyetlen lista (a fejlécek képernyőolvasónak címsorok): **Fiók és szinkron** · **Asszisztens** (AI-asszisztens, Mit láthat az asszisztens?, Időjárás és helyszín, Alvási sáv, Edzés utáni visszajelzés, Kézikönyv) · **Értesítések** (Emlékeztetők, Google Wallet értesítések) · **Adatok** (Mentés és visszaállítás) · **Névjegy** (A program). A kártyák tartalma változatlan; az első beviteli mező továbbra is az API-kulcs.
- Új **„Google-fiók” kártya** legfelül (a bejelentkezés eddig csak a naptár fejlécének menüjéből volt elérhető): be vagy-e lépve, az állapot ugyanazokkal a szavakkal, mint a szinkron-gombon (közös `syncSummary`), az utolsó sikeres szinkron, a következő automatikus próba, a függő / elakadt módosítások, a hiba magyarul; gombok: **Belépés** (lejárt belépésnél „Belépés szükséges”), **Szinkron most** ↔ **Újrapróbálás most**, a kötés-döntés („Másik fiók / naptár: döntés kell…”), **Diagnosztika**, **Szinkron alaphelyzetbe…**, **Kilépés a Google-fiókból**. Google nélküli buildben a kártya ezt mondja.

**Útközben javítva**
- A hét címe két hónapot átfogó hétnél kettős ponttal végződött („2026. nov. 30. – dec. 6..”), évhatáron pedig nem nevezte meg a második évet. Most: „2026. nov. 30. – dec. 6.”, „2026. dec. 28. – 2027. jan. 3.”.

Tesztek: app 1448 (volt 1340), mag 490 (volt 462), az elemzők és a formázás tiszták; a Flutter 3.50.0-n is zöld. 90 szándékos elrontás (a keresés magja, a kereső lap, a napirend, a húzás és az előtöltés, a fejléc és a töréspontok, a Beállítások csoportjai és a „Google-fiók” kártya, a közös szinkron-összegzés) – mind elbukik. A próba két hiányt hozott felszínre: a keresés a lemondott kivétel-példányt nem adta át az `expand()`-nek (a lemondott következő előfordulás is „következő” lett volna), és az egér-húzás tesztje túl gyenge volt (egyetlen nagy mozdulat nem húzás: most kontroll-húzás is van). Két elrontás egyenértékű (egy lemondott önálló esemény – az `expand` úgyis üresen adja –, és egy nappal hosszabb tartomány – a nézet csak a 14 napot listázza), azokat nem számoltam.

**Nem ellenőrizhető itt:** a húzás érzete és küszöbei valódi telefonon (a tesztek szintetikus mozdulatokkal futnak); a keresés sebessége több ezer eseménnyel; a keskeny fejléc tényleges kinézete a nyilak nélkül; a „Google-fiók” kártya valódi belépéssel; a Ctrl+F valódi Windowson; a képernyőolvasós működés (TalkBack / Narrator: a 3d-ben jön).

**Eltérések a tervtől:** a `settings_page.dart` nem lett szétbontva (nem kellett a csoportosításhoz; csak az új kártya és a fejléc-segéd került külön fájlba: `ai/settings/account_card.dart`); a csoportok közül a „Pénzügy és Wallet” és az „Emlékeztetők” egy **Értesítések** csoportba kerültek, a „Mentés” helyett **Adatok** a fejléc (egy „Mentés” szöveg a párbeszédek gombjaival ütközne); a Ctrl+F csak a naptár oldalon működik (mint a többi billentyűparancs), a Feladatok és a Pénzügyek oldalon nincs nagyító.

## 3b-2. fázis – az asszisztens jóváhagyása védett és visszavonható; haladásjelzők (AI-16, UX-11)

**Az „Engedélyezem” / „Elfogadom” egyszer, és a mostani naptár ellen történik (AI-16)**
- **Dupla koppintás nem duplikál.** Eddig a gyors második koppintás kétszer vitte végig a jóváhagyást: az új események kétszer kerültek be, egy sorozat egy napjának áthelyezése két kivétel-sort hozott létre. Mostantól egy jóváhagyás fut egyszerre: amíg tart, a kártya gombjai, a jelölőnégyzetek, a szűkítés-választó, a gyors javaslatok és a küldés is várnak, és új kérdés nem indul.
- **Egy tranzakció.** Az elfogadott új események egyetlen írással, a saját azonosítóikkal kerülnek be (eddig egyenként, külön tranzakcióban: egy megszakadás részleges tervet hagyhatott); a törlés- és az áthelyezés-kártya is egy egység. Ha valami hibára fut, **semmi nem változik**, rövid magyar üzenet jelenik meg, a hiba a helyi naplóba kerül, a kártyák megmaradnak.
- **Újraellenőrzés a gombnyomáskor.** A kártya órákig várhat az oldalon, a naptár közben változhat. Minden tételt a *mostani* naptárban keres meg a program, összeveti azzal, amire a javaslat készült, és csak azt hajtja végre, ami még érvényes:
  - **törlés / áthelyezés:** ami közben eltűnt, elmozdult, átneveződött, más időre került, egész naposra vagy ismétlődővé (vagy egyszerivé) vált, **kimarad**; a már törölt (de még fel nem töltött) esemény **nem támad fel** (az áthelyezés eddig feltámasztotta a törölt eseményt); a sorozat-hatókör a mostani előfordulásra vonatkozik;
  - **áthelyezés:** az új idő a *mostani* naptárral is ütközésmentes (az éppen áthelyezett esemény saját régi helyével és a törlésre javasolt eseményekkel nem ütközik; egy, ugyanezen a kártyán korábban áthelyezett eseménnyel igen); az esemény saját időzónájában ellenőriz;
  - **új események:** ami már véget ért, vagy ami közben felvett eseménnyel ütközik, kimarad.
  - A kimaradtakat az oldal megnevezi, okuk szerint csoportosítva: „Kimaradt, mert közben eltűnt vagy elmozdult: „Fogorvos”.” (legfeljebb 4 név, utána „és még N”).
- **A kártyák nem törlik egymást.** Az állapot a gombnyomás *végén*, az élő állapotból épül újra (eddig a gombnyomás elején rögzített képből: egy közben megnyomott „Mégse” visszaállt). Az „Elfogadom a kijelölteket” után a vele érkezett törlés-kártya megmarad (eddig elveszett, pedig az új események arra számítottak, hogy a törlendő esemény megszűnik), az „Elvetem” után is; a „Rendben” csak a saját eredmény-kártyáját zárja. Ha a lezárt kártya volt az utolsó, az oldal üres, mint eddig.
- **A törlés-kártya a te kérésedet mutatja** („A kérésed: „töröld a fogorvost””, legfeljebb 3 sor) a modell indoklása helyett (az gyakran angol volt, és nem te mondtad). Az áthelyezésnél az indoklás marad.
- **Minden jóváhagyás visszavonható** (10 másodperc, a 3b-1 sávja): új események („N esemény hozzáadva” – a visszavonás eltávolítja őket), törlés („N esemény törölve”), áthelyezés („N esemény áthelyezve” – a régi időre, sorozat egy napjánál a létrehozott kivétel-sor törlésével). Egy kártya = egy sáv = egy visszavonás. A feltöltés a 10 másodperc alatt tartva van, mint a 3b-1-ben; a visszavonás után az eredmény-kártya is eltűnik.

**Haladásjelzők (UX-11)**
- **Beosztás generálása:** az oldal a munka alatt zárolt (nem kapnak koppintást, billentyűfókuszt), a tetején pörgettyű: „A beosztás készül…”. A törlendő tartományt a gomb megnyomásakor érvényes kezdőnap adja (eddig a közben átállított kezdőnap más tartományt érinthetett).
- **Fájlműveletek a Beállításokban:** a négy gomb (Mentés fájlba, Visszaállítás fájlból, Pénzügyek mentése, Pénzügyek visszaállítása) a munka alatt várakozik, és a megnyomott gombon kis pörgettyű forog. A fájlválasztás után kezdődik a „munka” (a rendszer saját párbeszédei és a felülírásról szóló kérdésed nem számítanak annak), és egy képkocka kimarad a nagy fájl feldolgozása előtt, hogy a pörgettyű látsszon.
- **Szinkron-gomb:** feltöltés közben „**Feltöltés N/M**” (a naptár eseményeinek feltöltése; legfeljebb a futás határa, a tartott és a feladott tételek nélkül); hibánál a gomb súgója (hover / hosszú nyomás) **kimondja az okot** (eddig csak a Részletek ablakban volt); a menü első sora **„N módosítás vár feltöltésre (M elakadt)”**; hiba vagy elakadt tétel esetén a „Szinkron most” helyén **„Újrapróbálás most”** áll (ugyanaz a kézi futás: elfelejti a korábbi elutasításokat).

**Egyéb**
- `moveOccurrence` változáshalmazt ad vissza, és a törölt eseményt nem támasztja fel; új: `ai/approval.dart` (`applyNew` / `applyDeletions` / `applyMoves`, `skippedNotice`), a magban `sameOccurrence`.
- A „Szinkron most” a Részletek ablak szövegében „Újrapróbálás most” (a feladott tételeknél).

Tesztek: app 1340 (volt 1260), mag 462 (volt 459), az elemzők és a formázás tiszták; a Flutter 3.50.0-n is zöld. 63 szándékos elrontás (a jóváhagyási kör, az újraellenőrzés minden ága, a tranzakciós és az „egyszer” védelem, a kártyák egymástól függetlensége, a visszavonás-bekötés, a gombok tiltása, a pörgettyűk, a feltöltés-számláló, az „Újrapróbálás most”) – mind elbukik. A próba két tesztelési hiányt hozott felszínre – a „küldés tiltva alkalmazás közben” teszt nem vette észre, ha a vezérlő mégis elindított egy kérdést, és az áthelyezés feltöltés-tartását semmi sem ellenőrizte –, mindkettőre szigorúbb teszt készült.

**Nem ellenőrizhető itt:** az asszisztens jóváhagyása valódi modellválasszal és valódi naptárral (a tesztek a hamis modellt használják); a pörgettyűk és a letiltott gombok érzete telefonon és Windowson; a „Feltöltés N/M” felirat ~90 eseményes valódi feltöltéssel (a tesztek a hamis Google-t használják); a hibaok-súgó megjelenése hosszú nyomásra Androidon.

**Ismert, nem javított:** az áthelyezés a modell idejét a szolgáltatás zónájában (Budapest) értelmezi, de az esemény saját időzónájában írja le – más zónájú eseménynél a falióra-idő eltolódhat (régi rés; az ütközés-ellenőrzés most már az esemény zónájában számol). A „feladva” (régi, a Részletekben és a Diagnosztikán) és az „elakadt” (új, a menüben) ugyanazt jelenti; a szóhasználat egységesítése a 3d szöveg-körében jön.

## 3b-1. fázis – visszavonás: törlés után 10 másodpercig „Visszavonás” (események, feladatok, pénzügy, Beosztás)

**Visszavonás (UX-2)**
- Eddig sehol nem volt visszavonás: a törlés csak megerősítő ablakkal ment, és végleges volt. Mostantól a törlés **azonnal megtörténik, és alul 10 másodpercig „Visszavonás” gomb áll.** A megerősítő ablakok kikerültek (esemény, Beosztás-műszak, feladat, pénzügyi tétel, ismétlődő tétel, cél). Az ismétlődő eseménynél a „Csak ez az esemény / Ez és a következő események / Az összes esemény” választás marad: az nem megerősítés, hanem döntés.
- **Visszavonható:** egy esemény; egy sorozat egy előfordulása, a sorozat vége vagy az egész sorozat a kivételeivel; egy Beosztás-műszak törlése és a **Beosztás generálása / újragenerálása** (a régi terv visszajön, az új eltűnik); egy feladat; egy pénzügyi tétel; egy kategória (a keretével együtt); egy keret; egy ismétlődő tétel; egy cél (a befizetéseivel együtt).
- **Egyszerre egy sáv van:** ha újabb törlést végzel, az előző véglegessé válik. A sáv a lebegő gomb fölött jelenik meg (nem takarja), széles ablakban legfeljebb 560 px széles.
- **Nem ír felül semmit:** ha a törlés óta a törölt dolog (vagy a sorozata) megváltozott – átnevezted, másik eszköz módosította, egy másik törlés érintette –, a visszavonás nem történik meg („A visszavonás már nem lehetséges: közben megváltozott.”), és a törlés a szokott módon feltöltődik. A visszavonás mindig mindent együtt hoz vissza, vagy semmit.

**A törlés addig nem megy fel a Google-be, amíg visszavonható (szinkron-tartás)**
- A törölt esemény – sorozatnál a teljes sorozat és a kivételei – a 10 másodperc alatt **nem töltődik fel**; így a visszavonás a Google-ban semmit nem mozdít, és az esemény Google-oldali mezői (emlékeztető, vendégek, Meet-link) sem vesznek el. A sáv eltűnésekor a törlés a szokott módon feltöltődik (a program ekkor magától elindítja a szinkront). Ha az app a 10 másodperc alatt bezárul, a törlés később feltöltődik (a biztonságos irány). A tartás csak memóriában él.
- **Verseny a sáv utolsó pillanatában:** ha a törlés már úton volt a Google felé, amikor visszavontad, az esemény **megmarad** (a feltöltés vége csak a törlési jelzést törli, az élő sort nem), és a következő szinkron újra létrehozza a Google-ban. Ha a törlés már fel is töltődött, a visszavonás az eseményt **új Google-eseményként** hozza vissza (a Google-oldali plusz mezők ilyenkor elvesznek; ez csak versenyhelyzetben fordulhat elő).
- Feladatnál és pénzügynél nincs tartás: a visszaállítás feltöltés után is ártalmatlan (nagyobb bélyeggel nyer minden eszközön); a másik eszköz egy pillanatra láthatja a törlést, aztán a visszaállítást.

**Egyéb**
- **Flutter 3.50:** a *gombos* üzenetsáv alapból nem záródik be magától, ezért a sáv kifejezetten időzített (`persist: false`), és külön biztonsági időzítő is szabadítja fel a tartást, ha a sáv sosem jelenne meg.
- **Atomi törlés:** a szerkesztő törlése eddig nem volt atomi (1…N+1 külön írás, a megnyitáskor készült pillanatképből dolgozott); mostantól egy tranzakció, friss olvasással, ugyanaz a függvény, mint az asszisztens törlésénél. A kategória törlése (kategória + keret) szintén egy tranzakció.
- **Ha a visszavonás hibára fut,** rövid magyar üzenet jelenik meg, a hiba a helyi naplóba kerül (cím és adat nélkül), a törlés pedig a szokott módon feltöltődik.

Tesztek: app 1260 (volt 1172), mag 459, az elemzők és a formázás tiszták; a Flutter 3.50.0-n is zöld. 52 szándékos elrontást (a tartás számlálása, a sorozat-kulcs, a motor ellenőrzése és számlálója, a `markPushed` őr hiánya, a változáshalmaz őrei és a verzió-emelés, a mester-előre sorrend, a Google-kapcsolatok elvágása, az egyesítés, a sáv időzítése és a 3.50-es `persist`, a biztonsági időzítő, a csere, a hiba üzenete, a sorozat-hatókörök, a feladat és a pénzügy azonosság-őre, az összetett törlések egységessége, a kategória-tartalék, a bélyeg) mind elkapnak a tesztek.

**Szándékos eltérés az audit szövegétől:** az audit „késleltetett commit”-ot írt (a törlés csak 10 másodperc múlva történne). Helyette azonnali törlés + visszaállítás + memóriabeli szinkron-tartás készült: nincs mit kiírni kilépéskor, a képernyők azonnal frissülnek, a sorozatokra is működik, és a Google felé a tartás védi a törlést.

**Nem ellenőrizhető itt:** a sáv helye és érzete telefonon és Windowson (gesztusvezérlő sáv, billentyűzet; a tesztek az Ahem betűtípussal futnak); a visszavonás valódi Google-szinkronnal (a tartás alatt és a feltöltés utáni versenyben); a másik eszközön látszó villanás feladatnál és pénzügynél; a Beosztás-visszavonás ~90 elemmel valódi eszközön.

## 3a. fázis – kezelhetőség: alsó sáv, tiszta fejléc, hónap-pöttyök, billentyűparancsok, az ablak mérete

**Navigáció (UX-1)**
- **Öt cél az alsó sávban** (telefon) vagy az **oldalsínen** (760 px-től széles ablak): **Naptár · Feladatok · Asszisztens · Pénzügyek · Több**. A „Több” alulról felcsúszó lapot nyit a **Beosztás** és a **Beállítások** oldallal. Eddig a Feladatok, az Asszisztens, a Beosztás és a Beállítások a naptár fejlécében lévő ikonok voltak, keskeny képernyőn egy „Menü” mögött; a sáv csak a Naptárt és a Pénzügyeket tartalmazta.
- **A négy fő oldal életben marad váltáskor:** a naptár nézete, hónapja és görgetési helye megmarad; az oldalak az első megnyitáskor épülnek (nem indításkor). Amelyik nem látszik, az nem kap billentyűfókuszt, és nem futtat animációt.
- **Vissza** (Android vissza-gomb vagy -gesztus): bármely oldalról a Naptárra visz, onnan lép ki az alkalmazásból.
- **Az Asszisztens fülről való váltás megszakítja a futó kérést** (eddig ezt az oldal elhagyása tette: senki nem várja a választ, a kérés csak tokent fogyasztana). Ha az éppen látszó fület választod újra, nem szakad meg.
- A naptár fejléce kitisztult: nézetváltó, előző, Ma, következő, szinkron-gomb.

**Fejléc és hónapnézet** (a saját telefonos képernyőképeid alapján)
- **A hónap címe nem vágódik le többé** („202…”): 400 px alatt rövid alak áll („2026. nov.”), és ha a gombok mellett az sem fér, **kisebbre skálázódik**; sosem lóg rá a gombokra.
- **A szinkron-gomb koppintási célja legalább 48 × 48 px** (eddig kb. 34 px magas volt).
- **Keskeny hónap-cellában színes pöttyök** a levágott szöveges sávok helyett („18:0…”, „+2 tov…”): naponta legfeljebb 4 pötty (ha több esemény van: 3 pötty + „+N”); a kiválasztott nap eseményeit a rács alatti napi lista nevesíti. 64 px-nél szélesebb cellában szöveges sáv áll, az idő a cím előtt csak 92 px-es cellától látszik. Ha egy cella a tartalmához túl alacsony (kis ablak, nagy betű), a tartalom **levágódik, nem lóg ki**, és nincs túlcsordulási hiba.

**Billentyűparancsok (UX-4)** – Windows, billentyűzetes táblagép
- A naptár oldalon: **N** új esemény · **T** ugrás a mai napra · **← →** előző / következő hónap, hét vagy nap (a nézet szerint) · **1 2 3** hónap / hét / nap nézet · **F5** szinkron most · **F1** vagy **?** súgó. A szerkesztőben a **Ctrl+S** (mentés) és az **Esc** (bezárás) változatlan.
- **Gépelés közben egyik sem indul el** (egy „n” betű a címben nem nyit új szerkesztőt), és megnyitott párbeszéd mögött sem. Átváltáskor a naptár visszakapja a billentyűfókuszt, így kattintás nélkül működnek.
- A súgó (a parancsok listája) a **Beállítások → A program → Billentyűparancsok** gombbal is elérhető. (A keresés billentyűje, a Ctrl+F és a „4” a Napirend nézethez a 3c-ben jön.)

**Egységes töréspontok (CMP-7)**
- Eddig három fájlban szétszórt számok (760 / 820 / 900 / 1000 px) döntöttek az elrendezésről; most egy helyen vannak (`ui/breakpoints.dart`): sín 760, teljes vezérlők 820, oldalpanel 900, rövid cím 400, pöttyös cella 64. Az eseményszerkesztő párbeszéd/oldal küszöbe ugyanaz a 760. Az 1000 px-es „Menü”-küszöb a menüvel együtt megszűnt.

**Windows ablak (UX-10)**
- **Legkisebb méret 480 × 640** logikai pixel (a képernyő DPI-jéhez skálázva, de sosem nagyobb, mint amennyi a képernyőből látszik). Eddig tetszőlegesen kicsire lehetett húzni.
- **Az ablak mérete, helye és „maximalizált” állapota megmarad** a következő indításra (`HKEY_CURRENT_USER\Software\KvantumNaptar`, `WindowState`). Ha a mentett hely már nem fér rá a képernyőre (lecsatlakoztatott monitor, másik felbontás), a legközelebbi képernyő munkaterületére igazodik. Első indításkor a szokásos 1280 × 720.
- **Csak fordításig ellenőrizhető:** a C++ kódot itt nem futtattam (a mingw-fordító szintaxis- és figyelmeztetés-ellenőrzése tiszta; az éles fordítás a Windows-build).

Tesztek: app 1172 (volt 1121), mag 459, az elemzők és a formázás tiszták; a Flutter 3.50.0-n is zöld. 53 szándékos elrontást (rossz töréspont-érték, a „Több” rossz helye, hiányzó `PopScope`, fókuszt vagy animációt tartó rejtett oldal, a megszakítás elmaradása fülváltáskor, gépelés közben induló parancs, felcserélt nyilak és számok, hiányzó F5/F1/?, a súgó hiányos listája, a cím rövidítése és skálázása, a pöttyök küszöbe és darabszáma, a levágás helyett kilógó tartalom, a 48 px-es koppintási cél, a szerkesztő párbeszéd-küszöbe, az oldalpanel küszöbe) mind elkapnak a tesztek; a próba három hiányt hozott felszínre (az oldalpanel küszöbe, a pöttyök színe, a cellák levágása), ezekhez új teszt készült.

**Szándékos eltérések a tervtől:** a „Több” mindkét elrendezésben lap (nem külön felugró menü a sínen); a pöttyök legfeljebb 4 (nem 3); a visszavonás üzenetsávja (3b) a közös üzenetkezelőn jelenik meg a gomb fölött, nem fülenként; a húzással áthelyezés, amelyet kértél kihagyni, nincs.

**Nem ellenőrizhető itt:** az érintés- és húzásérzet, a sáv / sín és a pöttyök tényleges kinézete valódi eszközön (a tesztek az Ahem betűtípussal futnak, amelyben minden betű négyzet, tehát a szélességek pesszimisták); a billentyűparancsok valódi Windowson; a Windows ablak minimális mérete és megjegyzett helye több monitoron, eltérő DPI-n és felső / bal oldali tálcával; a képernyőolvasók (Narrator, TalkBack) – ezek a 3d-ben jönnek.

## 1c. fázis – látni, mi romlott el: hibanapló, Diagnosztika oldal, magyar hibaüzenetek

**Hibanapló (REL-22)**
- **Helyi napló, semmi nem megy sehova:** JSON-soros fájl az adatbázis mappájában (`diag/diag.log`: Windowson `%LOCALAPPDATA%\KvantumNaptar\diag`, Androidon az alkalmazás privát mappája). 256 KB-nál új fájl indul, a régi `diag.log.1` néven marad (az azelőtti eldobódik), így a napló legfeljebb ≈ 0,5 MB. Csak te viheted ki belőle valamit (a Diagnosztika „Másolás” / „Mentés fájlba” gombjával).
- **Mi kerül bele, és mi soha:** időpont, terület, rövid kód (`calendar.unexpected`, `push.rejected` …), számok, azonosítók, és a hiba **típusa + első sora** (≤ 160 karakter). **A program eseménycímet, jegyzetet, összeget, helynevet, e-mail-címet és kulcsot nem ír be:** a hiba szövegéből a kulcsok, az e-mail-címek, a 6 jegyű vagy hosszabb számsorok (számla-, kártya-, telefonszám), a webcímek lekérdezés-része és az elérési utakban lévő felhasználónév kiszűrődik; adatbázis-hibánál az SQL és a paraméterek lemaradnak, többsoros szövegből csak az első sor marad. (A kivétel első sorát a rendszer adja; nagyon ritkán idézhet egy rövid szövegrészt, ezért a jelentést küldés előtt érdemes átnézni: sima szöveg.)
- **Mit ír le:** a három csatorna (naptár, Drive, pénzügyi levelek) minden futásának kimenetelét; minden feltöltési hibát (művelet, próbaszám, kód); a bejelentkezés visszaállításának, lejáratának és hibájának tényét; a kihagyott és a sérült elemeket (azonosító + ok, fajtánként); a Drive-lapozó lejártát; az olvashatatlan ismétlődést (egyszer, azonosítóval); az ismétlődés **20 000-es plafonját** (eddig csendben vágott; most eseményenként egyszer jelzi); az asszisztens-kérés, az esemény- és műszakmentés, a beállítás-mentés és -visszaállítás, az emlékeztető-ütemezés, a takarítás, a Wallet-híd és -feldolgozás, az időjárás-lekérés (státusz, időtúllépés, a hiba típusa – a hely nélkül), a frissítő telepítésének hibáit; és mindazt, ami a keretrendszeren (`FlutterError.onError`), a platformon (`PlatformDispatcher.onError`) vagy az app zónáján (`runZonedGuarded`, benne fut az indulás is) átesik, és eddig nyomtalanul eltűnt.
- **Nem tud ártani:** a naplózás nem dob kivételt (megtelt lemez, zárolt fájl: a sor kimarad, a következő újra próbálkozik), és nem várakoztat senkit; az indulás előtti sorok memóriában várnak (≤ 100). **Árvízvédelem:** azonos hiba (terület + kód + a hiba eleje) 60 másodpercenként legfeljebb egyszer, összesen ≤ 30 sor/perc; az elhagyottak számát egy összegző sor mondja meg (egy képkockánként ismétlődő hiba így nem tölti meg a fájlt).

**Diagnosztika oldal** (Beállítások → A program → Diagnosztika, és a szinkron-gomb menüjében)
- **Figyelmeztetések** (csak ha van): másik Google-fiók / naptár vár döntésre; egy módosítás **2 napnál jobban a jövőben** van bélyegezve (óraeltérés: ennek vagy egy másik eszköznek az órája előrejár); **újabb verzió írt** elemek vannak; olvashatatlan ismétlődésű események; az ismétlődés 20 000-es plafonja; a Google ma korlátozta a kéréseket; többszöri próba után feladott módosítások.
- **Alkalmazás:** build, platform, adatbázis-séma és -méret, hány esemény / feladat / check-in / pénzügyi elem van.
- **Szinkron csatornánként** (naptár, Drive, pénzügyi levelek): utolsó próba, utolsó **sikeres** futás, mi ment át (le / fel / nem ment át), hiba esetén a magyar mondat és a rövid kódja; „Szinkron most”, „Szinkron alaphelyzetbe…”.
- **Elutasított módosítások:** a Google által nem fogadott feltöltések próbaszámmal és magyar okkal (az esemény címe itt, a képernyőn látszik; a jelentésben nem). **„Újrapróbálás most”** (kézi futás: visszaadja a próbákat) és soronként **„Elvetés”** (megerősítéssel: a sorban álló művelet eldobódik, az esemény az eszközön marad; elvetett törlésnél a törlési jelölő is eltűnik, így a napi takarítás nem állítja újra sorba, és az esemény a Google-ban marad).
- **Google-kérések** mára és tegnapra, szolgáltatásonként (naptár, Drive, egyéb): hány hívás, ebből hány ment át / lett elutasítva / korlátozva / szerverhiba / nem ért célba. 7 napot őriz, így látszik, a kvótát érted-e el. (A tokenfrissítés a kliens-lánc másik rétegében fut, abban nincs benne.)
- **Napló** (az utolsó 100 sor) és **Jelentés:** „Másolás” (vágólap), „Mentés fájlba” (`kvantum-diagnosztika-<dátum>.txt`, sima szöveg), „Napló törlése…” (megerősítéssel). A jelentés szakaszai: Alkalmazás, Szinkron, Elutasított módosítások (ok és kód, **cím nélkül**), Google-kérések, Figyelmeztetések, Napló.

**Magyar hibaüzenetek (UX-5)**
- Egyetlen hibakatalógus (`errorInfoFor`) minden kivételhez ad rövid kódot, magyar címet, „Mit tegyek?” tanácsot és akciót (Belépés / Újrapróbálás / Diagnosztika): hálózat, időtúllépés, TLS, Google-korlát, elutasított módosítás, fájlrendszer (hozzáférés, megtelt lemez, hiányzó fájl), SQLite, újabb formátum, rossz formátum, platform, programhiba, ismeretlen. **Nyers `$e` nincs többé a felületen** (esemény- és műszakszerkesztő, asszisztens, beállítások mentése / visszaállítása / ellenőrzése, frissítő, szolgáltatói hálózati hibák, indulási hiba, bejelentkezés): a részletek a naplóba mennek.
- A fejlesztői szöveg („secrets.json”, „flutter run”) helyett semleges magyar mondat áll („Nincs Google-hozzáférés …”); a fejlesztői útmutató a README-ben maradt.
- A feltöltési hiba az adatbázisban **stabil kód** (`conflict`, `transient`, `transient:limit`, `transient:daily`, `rejected:<státusz>:<ok>`, `unexpected:<típus>`; eddig szabad szöveg, amely az esemény adatait is idézhette); a katalógus fordítja magyarra, a régi szabad szövegű sor „korábbi hiba; újrapróbáláskor frissül”.

**Szinkron**
- **A kimenetel csatornánként látszik** (`SyncState.channels`): az egyik csatorna hibája nem takarja el, hogy a másik rendben van; az „utolsó sikeres” idő a hibás futások között is megmarad.
- **Külső őr:** ha a szinkron-futás bármely része a három csatornaőrön kívül dob (adatbázis, programhiba), a futás hibásnak számít, a „szinkronizál” jelzés nem ragad be, a következő futás a szokott ütemben jön, és a napló megkapja az okot. (Eddig kezeletlen kivétel maradt.)
- **Az újabb formátum tartósan látszik:** a futás végén a `diag.newerFormat` megjegyzi, melyik csatorna hány újabb verziójú elemet látott; a Diagnosztika figyelmeztet, és a jelzés eltűnik, ha az elemek eltűntek (frissítés után). Az idő óránként legfeljebb egyszer lép, hogy egy tartós helyzet ne írja percenként az adatbázist. A Drive feltöltési ága is számolja (eddig csak a letöltési).
- **Kérésszámláló:** a Google-kliens burkolója szolgáltatásonként és naponta számolja a hívásokat; a futás végén olvad a tárolt táblába (7 nap).

**Szándékos eltérések az audit szövegétől:** a napló az adatbázis mellett él (nincs új `path_provider`-hívás); az „Elvetés” a sorban álló műveletet dobja el, nem az eseményt; a jelentés a címeket nem tartalmazza (csak a képernyő mutatja); a tokenfrissítés kérései nem számolódnak; a napló nem szinkronizálódik és nem megy sehova.

Tesztek: mag 459 (volt 456), app 1121 (volt 974), az elemzők és a formázás tiszták; a Flutter 3.50.0-n is zöld. 86 szándékos elrontást mind elkapnak a tesztek (a napló forgatása, árvízvédelme, titokszűrése és kivételmentessége; a hibakampók; a kérésszámláló; az újabb-formátum jelzés; a katalógus; az „Elvetés” és az „Újrapróbálás”; a külső őr; a jelentés címmentessége; a figyelmeztetések; a Diagnosztika gombjai). A próba két hiányt hozott felszínre: nem volt tesztelve az „olvashatatlan ismétlődés” figyelmeztetés, és az sem, hogy a naptármotor naplója nem tartalmaz eseménycímet – mindkettőhöz új teszt készült; az időjárás-lekérés hibáinak naplózása is ekkor került be (státusz / időtúllépés / a hiba típusa, a hely nélkül), három további elrontással és tesztekkel.

**Nem ellenőrizhető itt:** a fájlmentés valódi eszközön (Android: a rendszer fájlkiválasztója `text/plain` típussal; Windows: mentés-párbeszéd); a napló mérete és sebessége hosszú használat után (a forgatás és a méretplafon tesztelt, de napokig tartó futás nem); a `runZonedGuarded` és az `ensureInitialized` együttműködése release-buildben (a hibák nem tűnnek-e el); a Windows-útvonal (`%LOCALAPPDATA%\KvantumNaptar\diag`) valódi gépen; hogy a valódi Google-hibák (kvóta, 403, 5xx) milyen kódokat adnak; a Diagnosztika oldal kinézete telefonon és nagy betűvel.

## Eszközlánc – a Flutter 3.50.0-hoz igazítás

- **Mi történt:** a CI rögzítetlen „stable” Flutter-t használ, és a 2026-11-09-én megjelent 3.50.0 két helyen megtörte a buildet (az 1b első két buildje, a Build 59 és a 60 emiatt csak a Windows-csomagot adta): **(1) Android** – az új Flutter legalább Android Gradle Plugin 9.1.1-et és Kotlin 2.4.10-et kér (nálunk 9.1.0 és 2.4.0 volt), és figyelmeztet, hogy a Gradle 9.3.1 támogatása hamarosan megszűnik; **(2) elemzés** – a Material kiköltözött a `material_ui` csomagba, ezért a `package:flutter/material.dart` minden importját elavultnak jelzi (43 jelzés), és a `flutter analyze` ilyenkor hibakóddal lép ki, így a CI `app` jobja a tesztek előtt megállt.
- **Javítás:** az Android-projekt a Flutter 3.50.0 *hibaküszöbére* lépett: **Android Gradle Plugin 9.1.1, Kotlin 2.4.10** (a Gradle marad 9.3.1); az elemzés „elavult használat” jelzése (`deprecated_member_use`) kikapcsolva az `analysis_options.yaml`-ban (a régi import továbbra is működik). Az app tesztjei a 3.50.0-n a CI-ben is mind zöldek (974). **Miért nem a Flutter ajánlott hármasa (AGP 9.3.1 / Kotlin 2.4.20 / Gradle 9.5.0):** a Build 60 ezzel próbálta, és az Android-lint összeomlott (`NoSuchMethodError: java.util.List.removeLast()` – ez a metódus JDK 21-ben jelent meg), a CI viszont JDK 17-et ad, és a workflow-fájlt az ágon nem módosíthatjuk. A Flutter ezért figyelmeztet, hogy az ajánlott verziók alatt vagyunk; ez csak figyelmeztetés.
- **Beolvadt a `main`-be (PR #4, 2026-11-12):** a CI és a build ezentúl rögzített **Flutter 3.50.0 / Dart 3.14.0**-val dolgozik, az Android-build **Java 21**-gyel (JDK 17 alatt omlott össze az Android Gradle-plugin 9.3-as lint-je); az ág-push nem épít, ha minden módosított fájl a `.github/` alatt van vagy az `analysis_options.yaml` (a PR merge-push-a ellenőrizve nem indított buildet). A `main` a feladatágba beolvasztva, a `.github` azonos. Az első build ezen az eszközláncon a Java 21 első éles próbája is.
- **Nyitva marad:** az áttérés a `material_ui` csomagra külön, szándékos feladat (új függőség, 40 fájl, harmadik fél csomagok áthidalása, témaellenőrzés); az ajánlott Android-hármasra (AGP 9.3.1 / Kotlin 2.4.20 / Gradle 9.5.0) lépés a JDK 21 mellett külön döntés.

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
