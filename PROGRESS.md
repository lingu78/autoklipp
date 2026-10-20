# Framsteg – Autoklipp

Bockas av enligt acceptanskriterierna i SPEC.md. Senast uppdaterad: 2026-10-20.

| Fas | Innehåll              | Status |
| --- | --------------------- | ------ |
| 1   | Skelett               | 🔄     |
| 2   | Smart urval           | 🔄     |
| 3   | Rytm och stil         | 🔄     |
| 4   | Justering             | 🔄     |
| 5   | Apple Intelligence    | 🔄     |

🔄 = implementerad, väntar på grönt acceptanstest i CI.

---

## Fas 1 – Skelett

Klart när: _En 1-minutersfilm av 20 blandade klipp exporteras till Bilder, längd 60 s ±1 s._

- [x] Repo, Xcode-projekt (iOS 26, iPhone), lokalt Swift-paket ClipCore, CI (Linux + macOS)
- [x] Välj media med PhotosPicker (1–200, bilder/Live Photos/filmer) utan biblioteksbehörighet;
      antal och total filmlängd visas; trasiga filer hoppas över med notis
- [x] Välj längd: snabbval 15 s–10 min, reglage för fri längd, Auto
- [x] Stil och en inbyggd låt
- [x] Generering med synliga steg som går att avbryta
- [x] Klipplista (EDL, JSON) i kronologisk ordning, klipp på taktslag, exakt längd
- [x] Förhandsvisning, "En annan version"
- [x] Export 1080p/4K i 9:16, 16:9, 1:1; spara i Bilder; dela; fortsätter kort i bakgrunden med notis
- [x] Svenska och engelska (String Catalog)
- [ ] Acceptanstest grönt i CI (`PhaseOneAcceptanceTests`)

## Fas 2 – Smart urval

Klart när: _Suddiga och skakiga segment väljs bort; ansikten prioriteras i ett testset._

- [x] Vision/Accelerate-analys per 0,5 s-segment och per bild: skärpa, ansikten, rörelse, skak,
      exponering, ljudnivå, estetik, etiketter
- [x] Poängsättning och urval av bästa segment med spridning och dubblettspärr
- [x] Ken Burns på bilder, riktad mot ansikten
- [ ] Acceptanstest grönt i CI (`AnalysisTests`, ClipCore `SmartSelectionTests`)

## Fas 3 – Rytm och stil

Klart när: _Klippbyten ligger inom 50 ms från taktslag; stilarna känns tydligt olika._

- [x] Beat detection (vDSP-spektralflöde + dynamisk programmering) för egna ljudfiler
- [x] 5 stilar (tempo, övergångar, färg), 12 egna CC0-låtar + egen ljudfil
- [x] Originalljud av/på med ducking under högt originalljud
- [x] Täthetsvariation för långa filmer efter låtens avsnitt
- [ ] Acceptanstest grönt i CI (`RhythmTests`)

## Fas 4 – Justering

Klart när: _Ändring i remsan ger ny förhandsvisning under 3 s._

- [x] Klippremsa: flytta, ta bort, lås (även VoiceOver)
- [x] Byt musik, byt stil, en annan version (låsta klipp och borttaget material respekteras)
- [x] Projekt sparas med SwiftData, startskärm med sparade filmer
- [x] Titel och eftertext
- [ ] Acceptanstest grönt i CI (`AdjustmentTests`)

## Fas 5 – Apple Intelligence

Klart när: _Instruktionen "bara bilder med barnen" ger en film där övervägande klipp innehåller
barn; appen fungerar fullt utan AI._

- [x] Foundation Models som regissör med `@Generable`-plan, omgångar efter tokenbudget
- [x] Fritextfält bara när modellen finns; tyst reserv utan den
- [ ] Acceptanstest grönt i CI (`DirectorAppTests` – reservläge och planföljning; den riktiga
      modellen testas på enhet med Apple Intelligence)
