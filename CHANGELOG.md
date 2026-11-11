# Változások

A build-számok a GitHub-kiadások (`build-<szám>`) számai. A legfrissebb elöl.

## 2a. fázis – kisebb asszisztens-kérés (tokentakarékosság)

A modellnek küldött kérés mérete, **becsléssel** (3 karakter = 1 token, szándékosan óvatos), ugyanazzal a mintanaptárral (14 esemény, 6 feladat, 5 check-in, hely, előrejelzés) és a mellékelt kézikönyvvel, a régi és az új kódon mérve:

| Kérés | Előtte | Most |
|---|---|---|
| „Tervezz edzést a jövő hétre” | ≈ 6 100 | ≈ 3 000 |
| „Tervezz edzést” (7 nap) | ≈ 5 500 | ≈ 2 700 |
| „Töröld a kézzel felvett programokat holnapra” | ≈ 4 800 | ≈ 1 300 |
| „Hogy állok a költségkerettel?” | ≈ 4 450 | ≈ 500 |
| Állandó rész tervezésnél (rendszerprompt + eszközök) | ≈ 4 250 | ≈ 2 050 |

Ez a program saját becslése, nem a szolgáltató számlálója; a tényleges értéket a 2c lépés kijelzése fogja mutatni.

**Mi változott**
- A kérés fajtája (terv / törlés-áthelyezés / pénzügyi kérdés) dönti el, mit kap a modell: utasítást, kézikönyvet, adatot és eszközt. Törlésnél nem megy el az edzésszabály-gyűjtemény, pénzügyi kérdésnél sem a kézikönyv, sem a naptár.
- Az adat rövid kulcsokkal megy (a jelmagyarázat a rendszerpromptban van): az események naponként csoportosítva, a feladatok rövid azonosítóval (`t1`, `t2` …), a szabad idősávok naponként egy sorban, az időjárás napi egy rövid sor (csapadék és szél csak ha jelentős).
- Az eseményhivatkozás (`r`) csak törlésnél és áthelyezésnél megy; tervezésnél nincs is rá szükség. A tervezési kérés eszközei között nincs törlés/áthelyezés, és nincs `get_tasks` (az első üzenet már tartalmazza az összes nyitott feladatot).
- Az eszközleírások rövidek, a `tzid` mezők kikerültek (alapzóna: a program ezt tölti ki).
- Az első üzenet sorrendje: adatok → pontos idő → a te kérésed. A rendszerprompt és az eszközlista nem tartalmaz órát, így azonos fajtájú kérések között bájtra azonos (a szolgáltatók előtag-gyorsítótárának kedvez).
- A kézikönyv alapszövegei rövidebbek, a szabályok tartalma ugyanaz (edzéstípusok, hobbisportok és évszakok, séta, időjárási küszöbök, `outdoor`); a számszerű korlátok (alvási sáv, puffer, 48 óra, heti plafon) csak egyszer, az élő beállításokból kerülnek a promptba. Új a 12 napos műszakciklus leírása (3 éjszaka 18–06, 3 szabad, 3 nappal 06–18, 3 szabad). A sablonsorok (üres „Sérülések:” stb.) nem mennek el a modellnek.
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
