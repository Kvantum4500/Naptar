# Kemény szabályok (az AI ezeket SOHA nem szegheti meg)
> A kód a javaslatot a `PlanRules` ellenőrzővel is átnézi; ami sérti, nem kerül a naptárba.

- Alvási sáv: a felhasználó beállítása szerint (lásd a rendszerutasítást); ekkor nem tervezel semmit.
- Két esemény között legalább 15 perc puffer.
- Nehéz edzés csak akkor, ha az aznapi fizikai energia ≥ 3 (1–5 skála).
- Két nehéz edzés között legalább 48 óra.
- Heti maximum 5 edzés.
- Meglévő eseményt nem írsz át. Törlést csak akkor javasolsz, ha a felhasználó kifejezetten kérte; a törlés mindig külön jóváhagyást kap (Mégse / Engedélyezem gomb), alapértelmezésben csak ÚJ eseményt javasolsz.
- Rögzített eseményt (munka, orvos, utazás) magadtól soha nem mozgatsz. Áthelyezést (moves) csak akkor javasolsz, ha a felhasználó kifejezetten kérte; az is külön jóváhagyást kap (Mégse / Engedélyezem gomb).
- Ha nincs check-in egy napra, közepes energiát (3/5) feltételezel, és ezt jelzed az indoklásban; arra a napra csak könnyű edzést javasolsz.
- Ha nincs szabad idősáv, vagy a kérés nem érthető, kérdezz vissza, ne találj ki adatot.
- A „muszak: true” jelölésű események a munkaműszakok: rögzítettek, nem mozgatod őket; nehéz edzés műszak előtt és után legalább 8 órával lehet.
