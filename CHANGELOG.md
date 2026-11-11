# Változások

A build-számok a GitHub-kiadások (`build-<szám>`) számai. A legfrissebb elöl.

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
