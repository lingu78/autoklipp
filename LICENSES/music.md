# Musiklicens

All musik i `Autoklipp/Resources/Music/` är skapad av skriptet
[`tools/music/generate_music.py`](../tools/music/generate_music.py) i det här repot. Varje ton
syntetiseras från grunden (oscillatorer, FM-syntes och en plockad sträng-modell), utan samplingar,
loopar eller noter från någon annan.

Musiken är tillägnad allmän egendom enligt
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/): den får användas,
ändras och spridas, även kommersiellt, utan krav på erkännande. Det gäller både appen och filmer
som användarna gör med den.

| Låt | Tempo | Längd | Stilar | Fil |
| --- | --- | --- | --- | --- |
| Morgondimma | 72 BPM | 3:09 | Lugn | `morgondimma.m4a` |
| Stilla vatten | 84 BPM | 2:42 | Lugn | `stilla-vatten.m4a` |
| Full fart | 128 BPM | 1:47 | Energisk | `full-fart.m4a` |
| Ljusår | 124 BPM | 1:50 | Energisk | `ljusar.m4a` |
| Hoppborg | 132 BPM | 1:44 | Energisk, Resa | `hoppborg.m4a` |
| Gamla foton | 86 BPM | 2:38 | Nostalgisk | `gamla-foton.m4a` |
| Sommaren då | 92 BPM | 2:28 | Nostalgisk, Lugn | `sommaren-da.m4a` |
| Sommarvind | 104 BPM | 2:11 | Resa | `sommarvind.m4a` |
| Vägen söderut | 112 BPM | 2:02 | Resa, Energisk | `vagen-soderut.m4a` |
| Horisont | 98 BPM | 2:19 | Resa, Filmisk | `horisont.m4a` |
| Fjällvidd | 76 BPM | 2:59 | Filmisk | `fjallvidd.m4a` |
| Ljuset faller | 90 BPM | 2:31 | Filmisk, Nostalgisk | `ljuset-faller.m4a` |
| Vinterljus | 66 BPM | 3:26 | Lugn, Nostalgisk | `vinterljus.m4a` |
| Molnfri | 80 BPM | 2:50 | Lugn, Filmisk | `molnfri.m4a` |
| Neonnatt | 118 BPM | 1:56 | Energisk, Filmisk | `neonnatt.m4a` |
| Studsmatta | 140 BPM | 1:38 | Energisk | `studsmatta.m4a` |
| Discoboll | 120 BPM | 1:54 | Energisk, Nostalgisk | `discoboll.m4a` |
| Kassettband | 88 BPM | 2:35 | Nostalgisk | `kassettband.m4a` |
| Brev hem | 96 BPM | 2:22 | Nostalgisk, Resa | `brev-hem.m4a` |
| Palmblad | 108 BPM | 2:06 | Resa, Energisk | `palmblad.m4a` |
| Landsväg | 100 BPM | 2:16 | Resa | `landsvag.m4a` |
| Kustlinje | 116 BPM | 1:58 | Resa, Lugn | `kustlinje.m4a` |
| Stjärnhimmel | 70 BPM | 3:14 | Filmisk | `stjarnhimmel.m4a` |
| Eko | 78 BPM | 2:54 | Filmisk, Lugn | `eko.m4a` |

Sedan version 1.1 finns också pianoballad, ambient, synthwave, trap, disco, boom bap, akustisk
gitarr, tropiskt med marimba och orkester, med instrument som syntetiseras på samma sätt (ett piano
av sträckta deltoner, marimba, visselpipa, 808-bas, en kör formad av vokalens formanter och gitarr
av plockade strängar).

Varje låt har intro, vers, refräng, brygga och outro. Loopområdet (vers till sista refrängen)
och avsnittens energi står i `tracks.json`.
