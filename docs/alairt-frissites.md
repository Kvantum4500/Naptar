# Aláírt frissítés (Ed25519) – bekapcsolás lépésről lépésre

## Mire jó, és mit nem véd

A program frissítés előtt ellenőrzi a letöltött csomag SHA-256 összegét. Ez a **sérülés** ellen véd. Aki viszont a kiadást módosítani tudja (például egy ellopott GitHub-hozzáféréssel), az mellé az összeget is lecserélheti – ezért a kiadásnak **aláírása** is lehet. Az aláíró (titkos) kulcs csak a GitHub titkai között él; az app a beépített **nyilvános** kulccsal ellenőrzi, hogy a csomagot ezzel írták alá. A nyilvános kulcs nem titok.

Mit írunk alá: a `build-<szám>|<a csomag SHA-256-ja>` szöveget (Ed25519, „tiszta” változat: amit az `openssl pkeyutl -sign -rawin` csinál). A build száma benne van, ezért egy régi, sebezhető kiadás nem adható ki újnak az aláírásával.

**Nem véd** attól, aki a titkos kulcshoz hozzáfér (ezért ne kerüljön sehová máshová), és attól sem, aki magát az appot cseréli le kézzel. Az első telepítés a te kezed alól kerül ki, azt a program nem tudja ellenőrizni.

## Három állapot (fokozatos bevezetés)

| A buildben | A kiadáson | Mit csinál a frissítő |
|---|---|---|
| nincs nyilvános kulcs | akármi | a régi: csak az összeget ellenőrzi |
| van kulcs | van `.sig` fájl | az aláírásnak **érvényesnek kell lennie**, különben nem telepít, a letöltött fájlt törli |
| van kulcs | nincs `.sig` fájl | telepít (amíg a kötelezővé tétel nincs bekapcsolva) |

Amíg te nem teszel be kulcsot, **semmi nem változik**. A kötelezővé tételt (lent, az 5. lépés) te kapcsolod be, amikor már minden kiadás aláírt.

## Előfeltétel

A kiadás aláírása a `build.yml` `release` jobjában van, amelyet a külön workflow-pull request (`ci/release-hardening`) hoz be a `main`-be. Addig a kulcsok beállítása nem árt (nem történik semmi), de aláírt kiadás sem lesz. A változás a GitHubon: **Pull requests → a `ci/release-hardening` PR → Merge**.

## 1. Kulcspár készítése (egyszer, a saját gépeden)

Kell hozzá az `openssl` (Windowson a Git for Windows „Git Bash”-ében benne van; Linuxon is; macOS-en, ha a beépített nem ismeri az `ed25519`-et, `brew install openssl`). Egy üres mappában:

```bash
openssl genpkey -algorithm ed25519 -out kvantum-update-signing.pem
```

Ez a **titkos** kulcs (a fájl első sora `-----BEGIN PRIVATE KEY-----`). Soha ne tedd a repóba (a `*.pem` a `.gitignore`-ban van, de ne bízz csak abban), ne küldd el, és ne másold chatbe.

A hozzá tartozó **nyilvános** kulcs (44 karakter, `=`-re végződik):

```bash
openssl pkey -in kvantum-update-signing.pem -pubout -outform DER | tail -c 32 | base64 | tr -d '\n'
```

Ezt a 44 karaktert jegyezd fel (nem titok). Az eredmény például: `J3H9iwLK72oxxknoCmOmirzSLPyAg37R4RE0KUAUdNk=`.

## 2. A GitHubon (Settings → Secrets and variables → Actions)

1. **Secrets** fül → *New repository secret*: név `UPDATE_SIGNING_KEY`, érték: a `kvantum-update-signing.pem` **teljes tartalma** a `BEGIN` és `END` sorokkal együtt.
2. **Variables** fül → *New repository variable*: név `UPDATE_PUBLIC_KEY`, érték: az 1. lépés 44 karaktere.

Ennyi. (A `UPDATE_REQUIRE_SIGNATURE` változót most ne hozd létre.)

## 3. Új build

Egy `[build]` jelölésű commit vagy a **Build apps** futás kézi indítása. A workflow:

- ellenőrzi, hogy a titkos kulcs tényleg Ed25519-es, és hogy a nyilvános párja szerepel az `UPDATE_PUBLIC_KEY` változóban (különben megáll: az appok elutasítanák a kiadást);
- minden csomagra újraszámolja az SHA-256-ot, egybeveti a `.sha256` fájllal, és a `build-<szám>|<összeg>` szöveget aláírja;
- a kiadásba felteszi a `<csomag>.sig` fájlokat (base64, 88 karakter), a titkos kulcs fájlját pedig a lépés végén törli;
- a build a nyilvános kulcsot beépíti az appba (`UPDATE_PUBLIC_KEY`).

Ha csak a titkot adtad meg, a változót nem, a workflow aláír, de figyelmeztet („Nincs `UPDATE_PUBLIC_KEY` változó…”), és kiírja a kulcsot a futás összegzésében; így utólag is pótolhatod.

## 4. Ellenőrzés

- A kiadás oldalán minden csomag mellett van `.sig` fájl, a futás összegzésében „Aláírás”.
- Telepítsd az **új** buildet (egy régebbi build még nem ellenőriz). A következő frissítésnél a napló (`%TEMP%\naptar-update\update.log` Windowson) ezt mutatja: `download of build N: sha256 …, signature valid`.
- Próba: egy kiadás, amelynek a `.sig`-jét kicseréled, nem telepíthető: „A kiadás aláírása nem érvényes, ezért nem telepítem.”

## 5. Kötelezővé tétel (később, amikor már biztos)

Csak akkor, ha **legalább két egymás utáni** aláírt kiadás megvolt, és a frissítést legalább egy gépen végigpróbáltad. GitHub → Variables → `UPDATE_REQUIRE_SIGNATURE` = `true`, majd egy új build. Az ebből készült app **nem fogad el** aláírás nélküli kiadást.

**Figyelem:** innentől a frissítési lánc az aláíráson múlik. Ha a titkos kulcs elvész vagy a titok kikerül a GitHubról, az új kiadások aláírás nélkül jönnének – az appok elutasítanák őket, és újra kézi telepítés kellene (lásd: kulcscsere). Ezért őrizz meg egy **offline másolatot** a titkos kulcsról (jelszókezelő vagy titkosított pendrive).

Ha az `UPDATE_REQUIRE_SIGNATURE` igaz, de nincs `UPDATE_PUBLIC_KEY`, a build **leáll** (az app így semmilyen frissítést nem fogadna el), és ha mégis így építenéd az appot kézzel, az „A frissítés aláírása kötelező, de ebben a buildben nincs beépített kulcs…” üzenetet adja.

## Kulcscsere (ha a kulcs kikerült, vagy elvész)

A cél, hogy az egyik kulcsról a másikra úgy lépj át, hogy közben a már telepített appok folyamatosan frissüljenek.

1. Készíts új kulcspárt (1. lépés).
2. Az `UPDATE_PUBLIC_KEY` változó legyen **mindkét** nyilvános kulcs, vesszővel elválasztva: `régi,új`. A titok marad a **régi** titkos kulcs. Építs egy átmeneti buildet: ez már mindkét kulcsban megbízik, a régivel van aláírva.
3. Várd meg, amíg a gépeid frissítenek erre az átmeneti buildre.
4. A titkot cseréld az **újra**, a változót is lehet csak az újra szűkíteni. A következő build az új kulccsal íródik alá; az átmeneti build ellenőrzi.

Ha a régi kulcs **kikerült** (nem csak elveszett), a 2–3. lépés alatt az még aláírhat – ezért az átmeneti szakaszt tartsd rövidre.

Ha a kulcs **elveszett**, és nincs offline másolat, nincs átmenet: a `.sig` fájllal jövő kiadást az app, amelyik a régi kulcsot tartalmazza, nem tudja ellenőrizni, ezért elutasítja (akkor is, ha a kötelezővé tétel nincs bekapcsolva). Az új kulcsot tartalmazó buildet ilyenkor kézzel kell telepíteni minden gépre (Windows: a zip, Android: az APK, a GitHub kiadások oldaláról).

## Erősebb védelem (nem kötelező)

A titkot tedd egy GitHub **Environment**-be (Settings → Environments → `release`, *Required reviewers*: te), és a `release` job használja azt. Így a titokhoz csak a te jóváhagyásoddal fér hozzá egy futás, akkor sem, ha valaki egy másik ágon módosítja a workflow-t. A mostani workflow ezt még nem követeli meg; ha át akarsz állni, szólj.

## Ha valami nem megy

| Üzenet | Mit jelent, mit tegyél |
|---|---|
| „A kiadás aláírása nem érvényes, ezért nem telepítem.” | A `.sig` nem ehhez a csomaghoz / buildhez / kulcshoz tartozik. Nézd meg, hogy a build a kiadáson épp a jó titokkal készült-e, és hogy az `UPDATE_PUBLIC_KEY` a titkos kulcs párja. |
| „A kiadáshoz nincs aláírás, ezért nem telepítem.” | A kötelezővé tétel be van kapcsolva, de a kiadás aláíratlan: hiányzik vagy érvénytelen az `UPDATE_SIGNING_KEY`. |
| „Az aláírás nem tölthető le (…)” / „túl nagy” | A `.sig` fájl hiányos vagy nem a megszokott 88 karakteres (legföljebb 4096 bájt lehet). Futtasd újra a kiadás lépést. |
| a build leáll: „Az UPDATE_SIGNING_KEY nyilvános párja … nincs az UPDATE_PUBLIC_KEY változóban” | A változó nem a titkos kulcs párját tartalmazza. Javítsd a változót (kulcscserénél vesszővel mindkettő). |
| a build leáll: „… nem 32 bájtos Ed25519 kulcs” | A változó egyik kulcsa hibás (a 44 karakteres, `=`-re végződő szöveg kell, szóköz nélkül). |
