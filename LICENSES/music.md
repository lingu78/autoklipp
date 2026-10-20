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

Varje låt har intro, vers, refräng, brygga och outro. Loopområdet (vers till sista refrängen)
och avsnittens energi står i `tracks.json`.
