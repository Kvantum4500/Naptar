# Biztonsági bejelentés

A Kvantum Naptár egyetlen ember személyes programja. Ha biztonsági hibát találsz benne (a programban, a kiadási folyamatban vagy a tárolóban), kérlek, **ne írd le nyilvánosan**: sem hibajegyben, sem pull requestben, sem megjegyzésben.

## Hogyan jelezd

1. Nyisd meg a tároló **Security** fülét, és válaszd a **Report a vulnerability** gombot (közvetlen cím: <https://github.com/Kvantum4500/Naptar/security/advisories/new>). Ez privát: csak te és a tulajdonos látja.
2. Írd le, **mit** találtál, **hogyan** lehet előidézni, melyik **verzión** (a build száma a **Frissítés keresése** ablakban látszik: „Telepített verzió”), és szerinted mi a **hatása**.
3. Ne küldj saját adatot (naptár, pénzügy, jelszó, kulcs). Ha a hibát valódi adat nélkül nem tudod bemutatni, írd le, milyen adat kellene hozzá.

Ha a gomb nem látszik, a tulajdonos még nem kapcsolta be a privát bejelentést: ilyenkor a GitHub-profilján megadott módon keresd, és a levélben csak annyit írj, hogy biztonsági bejelentésed van (a részleteket majd privátban kéri).

## Mire számíthatsz

Ez egy ember szabadidős projektje, ezért a válasz ideje változó; a javítás a következő buildben jön. Díjat vagy jutalmat nem tudok adni.

Támogatott verzió: **csak a legutolsó kiadás** ([Releases](https://github.com/Kvantum4500/Naptar/releases)); a program önfrissítő.

## Ami nem hiba (ismert és vállalt)

- A kiadásokban benne van a Google-bejelentkezés kliens-azonosítója és -titka: egy asztali („Desktop app”) OAuth-kliens adatai, amelyeket a Google nem tekint titoknak, és önmagukban senki adatához nem adnak hozzáférést (a belépés mindig a felhasználó saját Google-fiókjával és engedélyével történik).
- A Windows-program nincs kódaláírással ellátva (a Windows „ismeretlen kiadó” figyelmeztetést ad).
- A helyi adatbázis és a kézzel mentett exportok titkosítatlanok az eszközön; a védelmük a rendszer lemeztitkosítása. Az automatikus mentés jelszavas zip lehet.

Részletek: [README → Nyilvános repó](README.md#nyilvános-repó).
