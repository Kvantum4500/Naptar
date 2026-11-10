# Változások

A build-számok a GitHub-kiadások (`build-<szám>`) számai. A legfrissebb elöl.

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
- A munkaágak buildjei előzetes kiadások, a „latest” csak a `main`/`v*` buildje. A Frissítés ablak „Előzetes verziókat is keressen” kapcsolója dönt.
- A CI a Flutter 3.47.9-et használja rögzítve, minimális jogosultsággal.
- README és dokumentáció frissítve.

## Korábbi állapot (Build 33-ig)

Naptár nézetek és szinkron, műszakbeosztás, feladatok és check-in, asszisztens több szolgáltatóval, áthelyezés/törlés jóváhagyással, feladat-ütemezés, tanult szokások, időjárás és GPS, Pénzügyek fül (napló, keretek, ismétlődők, célok, postalevél-szinkron, Wallet-értesítések), lejárt Google-belépés érthető kezelése, önfrissítés Windowson és Androidon.
