# Beslutslogg – Autoklipp

Antaganden, tekniska val och avvägningar. Senaste överst inom varje avsnitt.
Format: **Beslut** – motivering – (datum, fas).

---

## 1. Repo, namn och identitet

- **Arbetsnamn "Autoklipp", bundle-id `se.autoklipp.app`.** Appens namn är en öppen fråga i
  SPEC.md; namnet syns bara som visningsnamn och kan bytas på en rad (`INFOPLIST_KEY_CFBundleDisplayName`
  och `InfoPlist.xcstrings`). Bundle-id behöver inte motsvara en ägd domän men måste vara unikt i
  App Store Connect – byt före första uppladdningen om Linus vill ha ett eget. (2026-10-20, fas 1)
- **Eget repo `lingu78/autoklipp`, publikt.** Publika repon får obegränsade macOS-minuter i GitHub
  Actions, vilket CI:n behöver (simulatortester och export). (2026-10-20, fas 1)
- **Platshållarikon** ritad av `tools/icon/make_icon.py` (staplade bildrutor + play-symbol). Byts
  när namn och ikon är bestämda. (2026-10-20, fas 1)

## 2. Plattform och verktyg

- **iOS 26.0 som lägsta version, endast iPhone, stående läge.** Enligt spec. Funktioner som kräver
  iOS 27 (nya Foundation Models-verktyg) läggs bakom `#available` i fas 5. (2026-10-20, fas 1)
- **Bygger med Xcode 26.6 / iOS 26.5 SDK.** Det är standard på GitHubs `macos-26`-runner
  (verifierat i runner-imagens README 2026-10-20). Xcode 27 finns bara som förhandsversion på
  runnern. (2026-10-20, fas 1)
- **Inga tredjepartsberoenden – inte ens byggverktyg.** Xcode-projektet är handskrivet i Xcode 16+-
  formatet med *synkroniserade mappar* (`PBXFileSystemSynchronizedRootGroup`, objectVersion 77):
  alla filer i `Autoklipp/` och `AutoklippTests/` ingår automatiskt, så projektfilen behöver nästan
  aldrig ändras. XcodeGen/Tuist hade krävt ett tredjepartsverktyg. (2026-10-20, fas 1)
- **Klipplogiken är ett eget Swift-paket, `Packages/ClipCore`** (ren Swift + Foundation, Swift 6
  språkläge, Swift Testing). Det testas både på Linux (snabbt, i CI och i utvecklingsmiljön) och
  på macOS, helt utan UI. Appen importerar det som ett lokalt paket. (2026-10-20, fas 1)
- **Appen kompileras i Swift 5-språkläge.** AVFoundations kompositör-API (`AVVideoCompositing`,
  `AVAsynchronousVideoCompositionRequest`) och AVAssetWriter är fortfarande trubbiga mot strikt
  Swift 6-concurrency; Swift 5-läget ger varningar i stället för fel. ClipCore kör Swift 6. Byte
  för appen utvärderas efter fas 3. (2026-10-20, fas 1)
- **Utvecklingsmiljön saknar Mac.** Swift-verktygskedjan (Linux) används lokalt för ClipCore; allt
  som rör iOS byggs och testas i GitHub Actions på macOS-runner (simulator iPhone 17, iOS 26.5).
  (2026-10-20, fas 1)

## 3. Mediaval och metadata

- **PhotosPicker utan biblioteksbehörighet (F1).** Användaren väljer 1–200 objekt; appen ber
  aldrig om läsrätt till biblioteket. (2026-10-20, fas 1)
- **Valda filer kopieras in i appens sandlåda** (`Application Support/Projects/<id>/Media`). Utan
  läsrätt kan appen inte hämta originalen igen senare, så kopian är förutsättningen för
  förhandsvisning, omgenerering och sparade projekt (F15). Nackdel: tar plats; projektets mapp tas
  bort med "Börja om". (2026-10-20, fas 1)
- **Metadata läses ur filerna själva** – EXIF/TIFF för bilder (inklusive tidszonsförskjutning och
  GPS) och QuickTime-metadata för filmer – inte via PhotoKit, som kräver behörighet. Picker levererar
  originalfiler (`preferredItemEncoding: .current`). (2026-10-20, fas 1)
- **Live Photos används som stillbilder.** Rörelsedelen går bara att hämta via PhotoKit-resurser,
  vilket kräver biblioteksbehörighet. Enklaste rimliga tolkning av F1. (2026-10-20, fas 1)
- **Objekt utan datum hamnar sist, i den ordning de valdes** (F5). (2026-10-20, fas 1)
- **Trasiga eller oläsbara filer hoppas över och räknas;** användaren ser "N objekt kunde inte
  läsas och hoppades över". iCloud-nedladdning sker i pickerns laddning, och förloppet visas.
  (2026-10-20, fas 1)

## 4. Klipplogik (ClipCore)

- **Algoritmen** (se `Planning.swift`): videor poängsätts i 0,5 s-segment, stillbilder som helhet;
  en tidsbudget avgör antalet moment; vid överskott delas materialet i lika stora kronologiska
  grupper och bästa källan i varje grupp väljs (sprider urvalet över hela händelsen), annars bidrar
  varje källa en gång och resten av budgeten går till fler moment ur de bästa och längsta
  filmerna. Inom en film väljs fönster efter kvalitet först och avstånd till övriga moment sedan
  (sprider utan att ta med svaga partier). Varje moment får ett helt antal taktslag; längder
  justeras ett slag i taget, och moment läggs till eller tas bort, tills sista klippet slutar på
  mållängden. (2026-10-20, fas 1)
- **Längden blir exakt mållängden** (avrundad till hel bildruta, 30 fps). Sista klippet trimmas
  eller förlängs högst 0,4 s förbi sitt taktslag; ±1 s-kravet (F2) har därmed god marginal.
  (2026-10-20, fas 1)
- **Material som inte räcker:** stillbilder förlängs upp till 4 s (F6:s övre gräns), filmer används
  i sin helhet, och filmen blir kortare än valt med en tydlig notis. Klipp upprepas aldrig.
  (2026-10-20, fas 1)
- **"Auto"-längd:** ca 2,5 s per stillbild + en tredjedel av varje film (högst 20 s per film),
  avrundat till en jämn längd och aldrig längre än materialet räcker till. (2026-10-20, fas 1)
- **Övergångar centreras på klippet** (halva före, halva efter taktslaget), så att bytet upplevs på
  takten, och blir aldrig längre än 45 % av något av grannklippen. (2026-10-20, fas 1)
- **Deterministisk slump (SplitMix64) med frö i klipplistan.** Samma frö ger exakt samma film på
  alla enheter; "En annan version" byter frö (F12). (2026-10-20, fas 1)
- **Fas 1 använder samma motor som de senare faserna** i stället för en tillfällig "jämn
  klipplängd"-variant: utan analys får alla segment samma neutrala poäng, och stilen ger
  jämna klipplängder (t.ex. Resa: 2 s vid 120 BPM). (2026-10-20, fas 1)

## 5. Rendering

- **Egen kompositör (`AVVideoCompositing`) som ritar varje bildruta med Core Image.** Det ger full
  kontroll över Ken Burns, övergångar, filter och format, och samma kod används för både
  förhandsvisning (`AVPlayer`) och export (`AVAssetExportSession`). Rendering sker alltid från
  klipplistan. (2026-10-20, fas 1)
- **Ett svart "bärarspår" (128×128, 2 s, utsträckt) ligger under hela filmen,** eftersom
  AVFoundation bara frågar kompositören om bildrutor där det finns ett videospår; stillbilder har
  inget eget spår. (2026-10-20, fas 1)
- **Filmklipp växlar mellan två spår (A/B)** så att grannar kan överlappa under övergångar.
  (2026-10-20, fas 1)
- **Format:** källor vars bildförhållande skiljer mer än 1,4× från filmens (t.ex. stående film i
  liggande format) läggs in i sin helhet över en suddig, något mörkare kopia av sig själva; övriga
  beskärs för att fylla bilden. (2026-10-20, fas 1)
- **Utdata i SDR (BT.709), 30 fps.** HDR-export är ett icke-mål för MVP. Förhandsvisningen renderas
  i 720p för flyt; exporten i 1080p (H.264) eller 4K (HEVC). (2026-10-20, fas 1)
- **`AVMutableVideoComposition` används trots att den är markerad som föråldrad i iOS 26.**
  Ersättaren `AVVideoComposition.Configuration` finns bara från iOS 26 och dess initierare kunde
  inte verifieras utan Mac; bytet görs när den kan testas. (2026-10-20, fas 1)
- **Bakgrund:** exporten körs i en `beginBackgroundTask`. Eftersom iOS inte tillåter GPU-arbete i
  bakgrunden byter kompositören till Core Images CPU-renderare när appen hamnar i bakgrunden, och en
  lokal notis säger till när filmen är klar. `BGContinuedProcessingTask` (iOS 26) är en möjlig
  förbättring för längre exporter. (2026-10-20, fas 1)

## 6. Musik

- **Biblioteket genereras av ett eget skript (`tools/music/generate_music.py`) och är CC0.** Det
  löser licensfrågan för inbäddning i appen (krav: dokumenterad licens för kommersiell användning)
  utan externa källor. Ljudkvaliteten är syntetisk men ren; riktig musik kan läggas till senare
  (öppen fråga i SPEC.md). Licensen står i `LICENSES/music.md`. (2026-10-20, fas 1)
- **Taktslag, loopområde och avsnitt (vers/refräng med energi) för de inbyggda låtarna kommer från
  generatorn** och lagras i `tracks.json`; beat detection behövs bara för egna ljudfiler (fas 3).
  (2026-10-20, fas 1)
- **Filmen börjar på låtens första taktslag. Längre filmer än låten loopar en region som börjar
  och slutar på hela takter**, så taktslagen fortsätter jämnt över skarven. Musiken tonas ut de
  sista 2 s. (2026-10-20, fas 1)
- **AAC 128 kbit/s via ffmpeg** (finns i utvecklingsmiljön; inga ljudfiler genereras vid bygget).
  Avkodning med ffmpeg visar ingen förskjutning mot originalet; att AVFoundation avkodar utan
  förskjutning verifieras med beat detection i fas 3. (2026-10-20, fas 1)

## 7. Spara och dela

- **Sparar till Bilder med "endast lägga till"-behörighet** (`NSPhotoLibraryAddUsageDescription`);
  appen läser aldrig biblioteket. Delning via systemets delningsmeny (`ShareLink`). (2026-10-20, fas 1)

## 8. Språk och tillgänglighet

- **Engelska är källspråk i String Catalog, svenska är översatt.** Katalogen skrivs av
  `scripts/strings_sv.py` och kontrolleras i CI av `scripts/check_strings.py` (alla UI-strängar
  finns i katalogen, alla har svensk text, formatmarkörer stämmer). (2026-10-20, fas 1)
- **Accentfärg #D6366B.** Kontrast 4,57:1 mot vit text (knappar) och 4,6:1 mot svart bakgrund
  (mörkt läge) – AA i båda lägena med en och samma färg. (2026-10-20, fas 1)
- **Systemtypsnitt och standardkontroller** så att Dynamic Type och VoiceOver fungerar; ikoner har
  dolts för VoiceOver där texten redan säger samma sak, och valda alternativ har egenskapen
  "vald". (2026-10-20, fas 1)

## 9. Öppna frågor (från SPEC.md)

| Fråga                                   | Status                                                                 |
| --------------------------------------- | ---------------------------------------------------------------------- |
| Appens namn och ikon                    | Arbetsnamn Autoklipp + platshållarikon                                 |
| Privat app eller App Store              | Obesvarad; påverkar integritetsetikett och TestFlight-flödet           |
| Var hämtas royaltyfri musik             | Löst för MVP med egengenererad CC0-musik                              |
| iOS 26 eller iOS 27 som lägsta version  | iOS 26 (spec-standard); iOS 27-funktioner bakom `#available`           |
| Vattenstämpel eller betalvägg           | Obesvarad; appen är gratis och utan vattenstämpel tills vidare         |
