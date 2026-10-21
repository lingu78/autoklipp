# Autoklipp

Native iOS-app (Swift/SwiftUI) som klipper ihop valda bilder och filmer till en färdig film med
musik och övergångar – i valfri längd från 15 sekunder till 10 minuter, helt på enheten.
Huvudflödet: välj → längd → stil → klart.

Arbetsnamn; appens namn är en öppen fråga i SPEC.md.

- Kravspecifikation: [SPEC.md](SPEC.md)
- Status per fas: [PROGRESS.md](PROGRESS.md)
- Tekniska beslut och antaganden: [DECISIONS.md](DECISIONS.md)
- Musiklicens: [LICENSES/music.md](LICENSES/music.md)

## Teknik

Swift · SwiftUI + Observation · PhotosUI · AVFoundation (egen `AVVideoCompositing`) ·
Core Image · String Catalogs · Swift Testing. Inga tredjepartsberoenden.

## Projektstruktur

```
Autoklipp.xcodeproj/      Xcode-projekt (synkroniserade mappar: nya filer kommer med automatiskt)
Autoklipp/                Appen
  App/                    Appens start, tillstånd och navigering
  Features/               Skärmarna i huvudflödet (media, längd, stil, generering, förhandsvisning, export)
  Media/                  Import från PhotosPicker, metadata, miniatyrer, spara i Bilder
  Music/                  Inbyggt musikbibliotek
  Generation/             Från projekt till klipplista och komposition
  Rendering/              Komposition, kompositör (Core Image), export
  Resources/              Assets, String Catalogs, musik
AutoklippTests/           Apptester i simulatorn (bl.a. acceptanstest för fas 1)
Packages/ClipCore/        Klipplogiken: ren Swift, egen modul, testas utan UI (även på Linux)
tools/music/              Generator för det inbyggda musikbiblioteket (CC0)
tools/icon/               Generator för platshållarikonen
scripts/                  Strängkatalog (svenska) och kontroll av den
```

## Bygga och köra

Kräver en Mac med **Xcode 26** eller senare.

```bash
open Autoklipp.xcodeproj    # välj schemat Autoklipp och en iPhone-simulator, ⌘R
```

För att köra på en egen iPhone: välj ditt team under _Signing & Capabilities_.

Utan Mac: arbetsflödet **TestFlight** bygger, signerar och laddar upp appen till App Store
Connect, så att den kan installeras med TestFlight. Engångsstegen står i [RELEASE.md](RELEASE.md).

## Tester

```bash
swift test --package-path Packages/ClipCore          # klipplogiken (macOS eller Linux)
xcodebuild test -project Autoklipp.xcodeproj -scheme Autoklipp \
  -destination 'platform=iOS Simulator,name=iPhone 17'   # appen, inkl. acceptanstest
python3 scripts/check_strings.py                     # strängkatalogen
```

CI (`.github/workflows/ci.yml`) kör allt detta vid varje push: ClipCore på Linux och macOS,
appens tester i simulatorn (med tillåtelse att spara i Bilder) och ett osignerat bygge för enhet.

## Generera resurser

```bash
python3 tools/music/generate_music.py --only sommarvind   # kräver numpy och ffmpeg
python3 tools/icon/make_icon.py                           # kräver Pillow
python3 scripts/strings_sv.py                             # skriver String Catalogs
```
