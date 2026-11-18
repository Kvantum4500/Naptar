# A fejlesztői eszközlánc frissítése (havonta egyszer, tudatosan)

A program **rögzített** Flutter-/Dart-/Android-eszközláncot használ, hogy egy újabb „stable” ne törjen meg előre nem látott módon buildet (a Build 59 és 60 pontosan ezért bukott: a rögzítetlen `stable` 3.50.0-ra lépett, a Flutter pedig új minimum-verziókat követelt az Android-eszközláncban, és a Material kiköltözött a `material_ui` csomagba). Ez a lap azt mondja meg, **hol kell átírni, mit kell lefuttatni, mi bukhat, és hogyan lépsz vissza**.

Nem kell sűrűn: havonta egyszer nézd meg, van-e újabb stable; ha nincs rá ok (biztonsági javítás, egy csomag megköveteli), maradhat a mostani.

## Mi van most rögzítve

| Mi | Érték | Hol |
|---|---|---|
| Flutter | **3.50.0** | `.github/workflows/ci.yml` (`app` job), `.github/workflows/build.yml` (`windows` és `android` job): `flutter-version` |
| Dart (a CI mag-jobjához) | **3.14.0** (a Flutter 3.50.0-é) | `.github/workflows/ci.yml` (`core` job): `setup-dart` → `sdk` |
| Java az Android-buildhez | **21** | `.github/workflows/build.yml` (`android` job): `java-version` |
| Android Gradle Plugin | **9.1.1** | `apps/kvantum_app/android/settings.gradle.kts` (`com.android.application`) |
| Kotlin | **2.4.10** | ugyanott (`org.jetbrains.kotlin.android`) |
| Gradle | **9.3.1** | `apps/kvantum_app/android/gradle/wrapper/gradle-wrapper.properties` (`distributionUrl`) |
| Dart-SDK alsó határ | `^3.13.7` (app és mag) | `apps/kvantum_app/pubspec.yaml`, `packages/kvantum_core/pubspec.yaml` (`environment: sdk`) |
| Java-célszint (kód) | 17 | `apps/kvantum_app/android/app/build.gradle.kts` (`sourceCompatibility`, `jvmTarget`) |

A Flutter **ajánlott hármasa** (AGP 9.3.1 / Kotlin 2.4.20 / Gradle 9.5.0 a 3.50.0-hoz) magasabb, mint a mostani: a Flutter figyelmeztet, de a mostani buildel. A magasabb AGP-hez a **Java 21** kell (az AGP lint-je JDK 17 alatt összeomlott, mert `List.removeLast()` csak a JDK 21-ben van); a CI már Java 21-gyel fut, így a következő emelés már megteheti.

A `.github/workflows/*` módosítása **külön pull requestben** megy, build-jelölés nélkül, és a beolvasztás a tiéd: ha a build célcommitjának workflow-fájljai eltérnek a `main`-étől, a GitHub 403-mal elutasíthatja a kiadás létrehozását (a Build 34 mutatta meg). A feladatágon a `.github` a `main`-nel azonos marad.

## A lépések

1. **Nézd meg, mi az újabb:** a Flutter kiadási jegyzete (`docs.flutter.dev/release/release-notes`), a „Breaking changes” oldal és a Dart-változásnapló. Jegyezd fel az új Flutter és az benne lévő Dart verzióját.
2. **Helyben, egy másolaton** (ne a munkafán): telepítsd az új Flutter-t külön mappába (`git clone --depth 1 --branch <verzió> https://github.com/flutter/flutter.git`), tedd az `PATH` elé, és futtasd:
   ```bash
   cd packages/kvantum_core && dart pub get && dart analyze && dart format --output=none --set-exit-if-changed . && dart test
   cd ../../apps/kvantum_app && flutter pub get && flutter analyze && dart format --output=none --set-exit-if-changed lib test && flutter test
   ```
   Ha a `build_runner` generált fájlja (`lib/data/db.g.dart`) változik, generáld újra (`dart run build_runner build --delete-conflicting-outputs`), és nézd át a különbséget; az új Flutter által a `pubspec.lock`-ba beírt SDK-rögzítések (`meta`, `test_api`, `vector_math`) a CI-ben úgyis igazodnak, azokat nem kell kézzel commitolni.
3. **Mi bukhat** (a tapasztalat szerint):
   - `flutter analyze`: új „elavult” (deprecated) figyelmeztetések – az app `analysis_options.yaml`-ja a `deprecated_member_use`-t most kikapcsolja (a `material_ui`-ra átállásig); más szabály új infót adhat, az nulla toleranciájú (az infóra is bukik);
   - Android-eszközlánc: a Flutter minimum-verziókat írhat elő az AGP-re, a Kotlinra, a Gradle-re (a hibaüzenet megmondja a számot); ilyenkor a három számot együtt emeld (a Flutter sablonja `gradle_utils.dart`-ban a tesztelt hármast tartalmazza), és Java 21-et használj;
   - tesztek: egy új Flutter a rajzolást (betűméret, a Material-elemek méretei) kissé eltolhatja; a tesztek szerkezeti állításai (nincs golden kép) ritkán érzékenyek rá;
   - a `pubspec.yaml` `environment.sdk` alsó határa: emeld, ha az új Dart-hoz kötött csomagot húzol be.
4. **Írd át a rögzítéseket** a fenti táblázat helyein (a workflow-fájlokat a külön PR-ban), és a README „Futtatás fejlesztéshez” szakaszában a verziószámot.
5. **Futtasd a CI-t** (a PR-on vagy egy `[build]` commiton): a mag, az app, a Windows- és az Android-build, a kiadás. Az Android-build az, amit itt nem tudsz kipróbálni; ha elbukik, a napló megmondja, melyik szám kell (egy kör ≈ 13 perc).
6. **Frissítsd a naplót:** egy sor a [CHANGELOG-ban](../CHANGELOG.md) („Eszközlánc”), és ha érdemi döntés volt, a [döntési naplóban](DONTESI-NAPLO.md).

## Visszalépés

Ha az új verzió bajt okoz: a rögzítések a régi értékre vissza (egy kis PR), a `pubspec.lock` a gitből visszaáll. A kiadott csomagokat ez nem érinti (azok már le vannak fordítva). Ha a Java 21 az Android-buildet törné, a `java-version` egy sorban visszavehető 17-re (de az AGP 9.3 lintje akkor nem fut).

## A `material_ui`-ra áttérés (próba: 2026-11-14; nem épült be)

A Flutter 3.50 a Material-könyvtárat a `material_ui` csomagba költözteti; a `package:flutter/material.dart` import elavult, de még működik, ezért az app `analysis_options.yaml`-ja most kikapcsolja az elavulási figyelmeztetést. Az áttérés **külön, szándékos döntés**, de a próba megmutatta, hogy kicsi és mechanikus:

- **A próba** (egy eldobható másolaton, a repó nem módosult): `flutter pub add material_ui:^1.11.0` (a csomag Dart ^3.13.0 / Flutter ≥ 3.47.0, tehát mindkét SDK-val összefér); az `analysis_options.yaml`-ban a `deprecated_member_use: ignore` sor törölve (különben a `dart fix` nem lát semmit); `dart fix --apply` → **203 javítás 95 fájlban** (a `package:flutter/material.dart` import cseréje és a direktívák sorrendje).
- **Egyetlen kézi lépés:** a `GlobalMaterialLocalizations` osztályt a `flutter_localizations` és a `material_ui` is definiálja (`ambiguous_import`: `lib/main.dart`, `lib/ui/startup_problem.dart`, `test/support/harness.dart`); a három fájlban a `flutter_localizations` import elhagyható (a `material_ui` adja).
- **Eredmény:** 98 módosított fájl (+134 / −131 sor); `flutter analyze` tiszta Flutter 3.50.0-n **és** 3.47.9-en; **a próba idején mind a 2 699 app-teszt zöld volt Flutter 3.50.0-n** (a mag nem érintett).
- **Mi marad a döntésre:** egy új függőség, amelynek a verzióját is követni kell (a fenti havi ellenőrzés ezt is lefedi); a kinézet valódi eszközön nincs megnézve (a tesztek szerkezeti állításokat tesznek, golden kép nincs). Beépítés esetén: az említett lépések egy commitban, és az `analysis_options.yaml` sora végleg törölve, hogy a valódi elavulások újra látszanak.
