# A frissítő kulcs (UPDATE_TOKEN): már nem kell

## Röviden

A Kvantum Naptár tárolója **nyilvános** (2026-11-14 óta), ezért a kiadások kulcs nélkül is elérhetők. Az ezután készülő buildek **nem tartalmaznak** frissítő kulcsot (az első ilyen a [`build-88`](https://github.com/Kvantum4500/Naptar/releases/tag/build-88); a csomagjaiban nincs GitHub-kulcs alakú szöveg, ellenőrizve), és az app névtelenül kérdezi le a kiadásokat a *Frissítés keresése* gombbal. Ennek ára egyetlen korlát: a GitHub névtelen kérésekből **óránként 60-at** enged egy hálózati címről (egy közös hálózaton, pl. hotspoton mások is fogyasztják). Ha eléri, az app megmondja („A GitHub átmenetileg korlátozza a kérések számát”), és az **Újrapróbál** gombbal később ismét próbálható. Az ellenőrzés csak kézi indításra fut, így ez ritkán jön szóba.

## A régi buildekről (a 85-ösig)

A korábbi buildekbe csak olvasó GitHub-kulcs (`UPDATE_TOKEN`) volt építve, mert a tároló akkor privát volt. Mivel a kiadások most nyilvánosak, **ez a kulcs a letölthető csomagokból bárkinek kinyerhető**. A hatásán a *hatóköre* múlik:

- a jó beállítás: *Fine-grained token*, *Repository access* = csak a `Naptar`, *Contents: Read-only* (a *Metadata: Read-only* magától bekerül), semmi más. Ilyen kulccsal egy kinyerő is csak azt olvashatja, ami már nyilvános;
- ha ennél több (pl. más tárolók, írási jog, *Tokens (classic)*): **azonnal vond vissza** (lent), mert más privát tárolóidat is megnyithatja.

Ellenőrzés: GitHub → profilkép → *Settings* → *Developer settings* → *Personal access tokens* → *Fine-grained tokens* → a `kvantum-naptar-frissites` kulcs.

## A kulcs megszüntetése: a sorrend számít

A régi appok a kulcsukat küldik minden kéréssel, és a GitHub a **visszavont** kulcsot akkor is elutasítja (401), ha az adat nyilvános. Ezért:

1. A tároló oldalán *Settings* → *Secrets and variables* → *Actions* → *Secrets* → az `UPDATE_TOKEN` titkot **töröld** (a build ilyenkor üres kulcsot épít be).
2. Új build (egy `[build]` jelölésű commit vagy a **Build apps** futás kézi indítása).
3. Telepítsd az új buildet **minden eszközödre** (a régi kulccsal még működő *Frissítés keresése* gombbal, vagy kézzel a kiadások oldaláról; Windows: kicsomagolás előtt a zip tulajdonságainál a **Feloldás** négyzet).
4. **Csak ezután** vond vissza a GitHub-kulcsot: *Settings* → *Developer settings* → a kulcs → *Delete* / *Revoke*.

Ha a kulcsot már előbb visszavontad (vagy lejárt): a régi app az „érvénytelen vagy lejárt” üzenetet mutatja, és nem talál új verziót. Ilyenkor töltsd le a legújabb csomagot a kiadások oldaláról, és telepítsd kézzel; az már kulcs nélkül frissít.

## Az app figyelmeztetése (csak a régi buildeken)

Az a build, amelyikbe kulcs van építve, a GitHub válaszából kiolvassa a kulcs lejáratát (`github-authentication-token-expiration` fejléc), és 14 nappal előtte a *Frissítés keresése* ablakban figyelmeztet:

> A frissítő kulcs 9 nap múlva lejár; utána az app nem talál új verziót. Új kulcs kell hozzá, és az appot utána egyszer kézzel kell újratelepíteni (leírás: docs/frissito-kulcs.md).

A kulcs nélküli buildekben ez a figyelmeztetés soha nem jelenik meg (a GitHub csak a lejáró kulccsal kapott válaszokban küldi a fejlécet).

## Mi védi most a frissítést?

Kulcs nélkül is ugyanaz a védelem érvényes, mint eddig: a csomag mérete és SHA-256 összege egyezik, a letöltés legföljebb 400 MB, és telepítés előtt újra-hash fut. A **hitelességet** (hogy tényleg te adtad ki) az [aláírt frissítés](alairt-frissites.md) adná; ez kész, de te kapcsolod be. Addig a frissítés biztonsága a GitHub-fiókodén múlik: legyen rajta passkey / kétlépcsős belépés.
