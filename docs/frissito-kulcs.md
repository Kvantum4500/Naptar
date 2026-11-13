# A frissítő kulcs (UPDATE_TOKEN): mi ez, mikor jár le, hogyan cseréld

## Mi ez

A Kvantum Naptár privát GitHub-tárolóban van, ezért a kiadásokat (a Windows-zipet és az Android-APK-t) csak hozzáféréssel lehet letölteni. Az app a „Frissítés keresése” gombbal ezt egy **csak olvasó GitHub-kulccsal** (`UPDATE_TOKEN`) teszi. A kulcs **be van építve az appba**, ezért aki az app fájljait megnyitja, kiolvashatja. Ezért:

- a kulcs **csak olvashat** (Contents: Read-only), és **csak ezt az egy tárolót** éri el: ha valaki kiolvassa, a tároló tartalmát (forráskód, kiadások) elolvashatja, de írni és törölni nem tud, a többi tárolódat nem éri el;
- **lejár** (a GitHub finomhangolt kulcsai általában legföljebb egy évig élnek; a tárolóra vagy szervezetre vonatkozó szabály ezt szűkítheti), ezért időnként cserélni kell.

## Mi történik, ha lejár

A telepített appok a régi, lejárt kulcsot hordozzák, ezért utána **nem találnak új verziót** („A frissítés hozzáférési kulcsa érvénytelen vagy lejárt”). Új kulccsal készült buildet ilyenkor **kézzel** kell telepíteni minden eszközre. Ha viszont a kulcsot **a lejárat előtt** cseréled, és egy új buildet még a régi kulcs lejárta előtt kiadsz, az appok maguktól frissítenek rá, és már az új kulcsot hordozzák – semmit nem kell kézzel telepíteni.

## Az app figyelmeztet a lejárat előtt

A GitHub a lejáró kulccsal kapott válaszokban megadja a lejárat idejét. A **Frissítés keresése** ablak ezt kiolvassa, és ha a kulcs **14 napon belül** lejár (vagy lejárt), ezt írja ki, jellel és szöveggel:

> A frissítő kulcs 9 nap múlva lejár; utána az app nem talál új verziót. Új kulcs kell hozzá, és az appot utána egyszer kézzel kell újratelepíteni (leírás: docs/frissito-kulcs.md).

Fontos tudni:

- a figyelmeztetés csak akkor jelenik meg, ha **megnyitod** a Frissítés ablakot (a program nem keres magától);
- csak akkor van rajta, ha a GitHub ezt a fejlécet ténylegesen elküldi – ezt élőben még nem láttam, ezért **ne csak erre építs**: írd fel a kulcs lejáratát a saját naptáradba, **két héttel előbbre** emlékeztetővel.

## A kulcs cseréje (lépésről lépésre)

1. **Új kulcs készítése.** GitHub → a profilképed → *Settings* → *Developer settings* → *Personal access tokens* → *Fine-grained tokens* → *Generate new token*.
   - Név: `kvantum-naptar-frissites`
   - *Expiration*: a leghosszabb, amit a GitHub enged (általában egy év); a lejáratot jegyezd fel.
   - *Resource owner*: a saját felhasználód.
   - *Repository access*: **Only select repositories** → csak a `Naptar`.
   - *Permissions* → *Repository permissions* → **Contents: Read-only** (a *Metadata: Read-only* magától bekerül); semmi más.
   - *Generate token*, majd másold ki a kulcsot (csak egyszer látszik).
2. **A titok átírása.** A tároló oldalán *Settings* → *Secrets and variables* → *Actions* → *Secrets* → `UPDATE_TOKEN` → *Update* → illeszd be az új kulcsot.
3. **Új build.** Egy `[build]` jelölésű commit vagy a **Build apps** futás kézi indítása. Az új build már az új kulcsot hordozza.
4. **Telepítés.** Amíg a régi kulcs él, az appok a *Frissítés keresése* gombbal maguktól átállnak az új buildre. Ha a régi kulcs már lejárt: a kiadás oldaláról (a GitHubon belépve) töltsd le a zipet / az APK-t, és telepítsd kézzel (Windows: kicsomagolás előtt a zip tulajdonságainál a **Feloldás** négyzet).
5. A régi kulcsot a GitHubon *Settings* → *Developer settings* alatt **töröld**, miután minden gép az újon van.

## Ha nem szeretnéd, hogy az app a tárolót kulccsal érje el

A kulcs kényelmi ár: a privát tároló kiadásainak elérése kulcs nélkül nem megy. Két lehetőség van (egyik sem kell most):

- **Nyilvános kiadási tároló**: a csomagok egy külön, nyilvános tárolóba kerülnek (forráskód nélkül), és az app kulcs nélkül tölt le. Ekkor nincs mit kiolvasni, nincs lejárat. A kiadás ellenőrzését az [aláírt frissítés](alairt-frissites.md) adja.
- **Az aláírás bekapcsolása**: ha a kulcsot valaki mégis kiolvassa, csak olvasni tud; az aláírt kiadást nem tudja hamisítani. Lásd: [alairt-frissites.md](alairt-frissites.md).
