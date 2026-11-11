# Változások

A build-számok a GitHub-kiadások (`build-<szám>`) számai. A legfrissebb elöl.

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
