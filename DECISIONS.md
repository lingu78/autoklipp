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
- **Appens tester körs ett i taget i CI** (`-parallel-testing-enabled NO`). Runnern har tre kärnor
  och export-, analys- och renderingstesterna störde varandras tider när de gick parallellt.
  (2026-10-20, fas 1)
- **TestFlight utan Mac:** arbetsflödet `testflight.yml` arkiverar, signerar automatiskt med en
  App Store Connect API-nyckel och laddar upp. Engångsstegen som kräver ägarens konto står i
  `RELEASE.md`. (2026-10-20)

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
- **Avmarkerade objekt tas bort ur filmen men kopian ligger kvar** tills projektet sparas eller lämnas, eftersom en redan sparad version kan använda den; oanvända kopior städas då bort. (2026-10-21, granskning)
- **"N objekt kunde inte läsas" gäller det aktuella urvalet:** varje trasigt objekt räknas en gång, och avmarkeras det försvinner det ur antalet. Misslyckade objekt försöks igen när urvalet ändras, så ett iCloud-objekt som laddas ned senare kommer med. (2026-10-21, granskning)
- **Importförloppet** summerar förloppet för de objekt som laddas samtidigt. Lämnar användaren vyn mitt i en import avbryts den, och en kopia som inte kunde flyttas in i projektet tas bort. (2026-10-21, granskning)

- **Väljs ett avmarkerat objekt igen** återanvänds dess kopia och analys, om filen inte har städats bort sedan; annars importeras det på nytt. (2026-10-21, granskning)
- **Medan en ändring i klippremsan pågår** går urvalet inte att ändra och Börja om är avstängd, eftersom ändringen sparar projektet när den är klar. (2026-10-21, granskning)
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
- **Sista klippet** kapas vid mållängden men visas ändå inom sina gränser: stillbild 1,5–4 s, film minst 0,5 s och aldrig längre än materialet i sitt utrymme (annars skulle det spelas långsammare och utan eget ljud). Snittet före flyttas ett taktslag i taget genom att tidigare klipp kortas eller förlängs; räcker inte det tas ett sista moment som planeraren själv lagt till bort. Går det ändå inte slutar filmen där sista klippet tar slut (högst cirka 0,4 s före mållängden) eller, i användarens egen ordning, när ett för kort sista klipp har visats sin minsta längd (en bråkdels sekund efter). Längden håller sig inom ±1 s. (2026-10-21, granskning)
- **Material som inte räcker:** nya moment tas bara ur material som inget klipp redan spelar i sin nuvarande längd, och ett nytt moment får aldrig tvinga ett befintligt klipp över sin hårda gräns. Klipp saktas alltså aldrig ned för att fylla ut filmen. (2026-10-21, granskning)
- **Längdvarningen** räknar stillbilder med de hela taktslag de får vara i den valda låten (t.ex. 6 slag = 3,46 s vid 104 BPM) i stället för 4 s. (2026-10-21, granskning)

## 4b. Analys (fas 2)

- **Analysen körs på enheten med Vision och Accelerate, på små proxyrutor** (filmrutor med långsidan
  512 px via `AVAssetImageGenerator`, stillbilder 1024 px). Hela filmer läses aldrig in i minnet.
  En ruta per 0,5 s-segment. (2026-10-20, fas 2)
- **Skärpa = Laplace-energi relativt bildens kontrast** (`vDSP_imgfir`). Att dela med kontrasten gör
  att en skarp men jämn bild (himmel, snö) inte tas för suddig. Kalibrerad med syntetiska bilder med
  naturlig 1/f-struktur: skarpa ger 0,65–0,95, Gaussisk oskärpa σ ≥ 4 px (1080p) ger under 0,25,
  som är gränsen för "suddig". (2026-10-20, fas 2)
- **Kameraskak = hur mycket kamerans förflyttning mellan två segment skiljer sig från grannarnas**
  (Vision `TrackTranslationalImageRegistrationRequest`). En jämn panorering flyttar lika mycket varje
  gång och räknas inte som skak; handhållet skak byter riktning. Rörelse i bilden = skillnaden mellan
  rutorna efter att kamerans förflyttning kompenserats. (2026-10-20, fas 2)
- **Ansikten med kvalitetsvärde** (Vision `DetectFaceCaptureQualityRequest`), en gång per sekund för
  film. Ansiktenas lägen sparas för stillbilder så att Ken Burns-rörelsen siktar mot dem.
  (2026-10-20, fas 2)
- **Estetiskt värde för stillbilder** (Vision `CalculateImageAestheticsScoresRequest`); bilder som
  Vision klassar som "nyttobilder" (kvitton, skärmdumpar) får lågt värde. (2026-10-20, fas 2)
- **Ljudnivå per segment** (RMS via `AVAssetReader`, −50 dBFS → 0, −10 dBFS → 1). Används för
  poängen och, från fas 3, för att avgöra när musiken ska tonas ned. (2026-10-20, fas 2)
- **Etiketter** (Vision `ClassifyImageRequest`) sparas per objekt för AI-regissören i fas 5.
  (2026-10-20, fas 2)
- **Nästan identiska bilder** känns igen på en 4×4-färglayout (48 värden) per bild/segment; två
  sådana i rad undviks (den sämre tas bort). Visions feature prints hade varit mer semantiska men
  kräver Apple-ramverk i ClipCore, som ska gå att testa utan dem. (2026-10-20, fas 2)
- **Analysen sparas i projektet och återanvänds** när användaren genererar om, byter stil eller
  musik. Ett objekt som inte går att analysera får neutrala värden i stället för att stoppa filmen.
  (2026-10-20, fas 2)
- **Acceptanstest:** en syntetisk film med skarpa, suddiga, skakiga och panorerande partier
  analyseras i simulatorn och urvalet får inte hamna i de suddiga eller skakiga sekunderna.
  Ansiktsprioriteringen testas dels i ClipCore med injicerade ansiktsvärden, dels i CI med ett
  porträtt i public domain som runnern laddar ned (utvecklingsmiljön når inte Wikimedia); finns
  bilden inte hoppas just den delen över. (2026-10-20, fas 2)
- **Filmanalysen strömmar:** rutorna hämtas 16 åt gången och varje 0,5 s-segment mäts direkt i tidsordning; bara föregående rutas gråkopia och de tre rutor som etiketterna behöver sparas. Minnet är därmed detsamma oavsett filmens längd, och avbryt stoppar analysen inom en ruta. (2026-10-21, granskning)
- **Kameraskak räknas bara mot förflyttningar som faktiskt har mätts.** Första segmentet och segment intill en ruta som saknas får grannens skakvärde, så att början av en jämn panorering inte räknas som skak. (2026-10-21, granskning)
- **Leenden poängsätts inte separat** (Klipplogik 1: "ansikten/leenden"). Visions Swift-API i iOS 26 har ingen leendedetektor; antal ansikten och deras fångstkvalitet (`DetectFaceCaptureQualityRequest`, som bl.a. väger in uttryck) får stå för båda. (2026-10-21, granskning)

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
- **Kompositören kräver bildbuffertar som delas med GPU:n** (IOSurface, Metal-kompatibla), både
  för källbilder och utdata. Utan det kopierade Core Image varje bildruta via CPU:n: i simulatorn
  1,3 s per 1080p-bildruta mot 25 ms med delade buffertar. En 60 s film exporteras nu på under en
  minut i CI. Ett test (`ExportSpeedTests`) vakar över detta. (2026-10-20, fas 1)
- **Övergångar intill filmklipp utan extra material:** kompositionen håller klippets första respektive sista bildruta som frusen bild över halva övergången, i stället för att lämna spåret tomt (det gav en halv toning mot svart). (2026-10-21, granskning)
- **En video som spelas något långsammare eller snabbare (högst 5 %)** får sitt eget ljud tidsskalat lika mycket som bilden, så att ljud och bild håller synk; tonhöjden bevaras (`AVAudioTimePitchAlgorithm.spectral`). (2026-10-21, granskning)
- **Alla spår kapas vid filmens längd** och media läggs aldrig in före ett spårs nuvarande slut, så att avrundning till 1/600 s inte kan göra kompositionen längre än videokompositionens instruktion. Börjar en videos ljud senare än bilden behålls förskjutningen. (2026-10-21, granskning)
- **Kompositören byter till CPU-rendering redan när appen slutar vara aktiv** (`willResignActive`) och tillbaka vid `didBecomeActive`, utöver scenePhase, som rapporterar bakgrund först när appen redan är där. (2026-10-21, granskning)
- **Speglade videor** (negativ determinant i `preferredTransform`) får speglade orienteringar i stället för att tolkas som en rotation. (2026-10-21, granskning)
- **Filmen byggs alltid med låten som klipplistan planerades på** (klipplistans `music.trackID`; den egna låten när id:t stämmer), även om en annan låt valts sedan, så att klippen ligger på rätt taktslag i export, öppnade projekt och klippremsan. (2026-10-21, granskning)

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

## 6b. Rytm, stilar och ljudmix (fas 3)

- **Biblioteket har 12 egengenererade låtar (CC0)**, 72–132 BPM, minst två per stil (F9: minst tio).
  En stil föreslår sin låt automatiskt tills användaren själv väljer en. (2026-10-20, fas 3)
- **Beat detection för egna ljudfiler:** ljudet avkodas en gång till 22 kHz mono; ett
  spektralflöde (log-komprimerat magnitudspektrum, FFT 1024, hopp 256 ≈ 11,6 ms) räknas med
  Accelerate (`vDSP.FFT`); tempo tas ur autokorrelationen viktad mot ~120 BPM (en oktav bred),
  och taktslagen placeras med dynamisk programmering (Ellis 2007) och finjusteras till närmaste
  ansats. Själva taktalgoritmen ligger i ClipCore och testas på Linux.
  Avsnitt (lugnt/intensivt) för egna låtar tas ur ljudnivån per 8 takter. (2026-10-20, fas 3)
- **Dubbel takt rättas, halv takt accepteras.** Hi-hat och bas på offbeat kan få spårningen att
  följa åttondelar; då är vartannat slag tydligt svagare (mer än 12 %), och bara den starkare
  hälften behålls. Halverad takt lägger fortfarande varje klipp på ett taktslag, medan dubbel takt
  skulle lägga vartannat klipp mellan två slag – därför väljs alltid det säkra hållet. Halvering
  görs bara om takten blir minst 60 BPM. Med detta hittas alla tolv inbyggda låtar i rätt takt
  och minst 95 % av slagen ligger inom 50 ms. De inbyggda låtarna använder ändå sitt exakta facit.
  (2026-10-20, fas 3)
- **Acceptanstest för "inom 50 ms":** (1) beat detection på inbyggda låtar jämförs med facit från
  generatorn – visar också att AAC-avkodningen i AVFoundation inte förskjuter ljudet; (2) varje
  klippbyte i filmer gjorda med inbyggda låtar och (3) med en låt behandlad som egen fil
  (detekterade taktslag) mäts mot de verkliga taktslagen. Klippbyten avrundas till hela
  bildrutor (30 fps), vilket ger högst ~17 ms fel. (2026-10-20, fas 3)
- **Originalljud (F10) är av som standard** – filmen bärs av musiken; reglaget "Ljud från filmerna"
  slår på det. Med originalljud på följer varje klipps ljud bilden, tonas genom övergångarna, och
  musiken sänks till 30 % under klipp där analysen hört högt ljud (tal, jubel, från −22 dBFS).
  Tysta klipp behåller musiken och får lägre originalljud. Slowmotion-klipp är tysta.
  (2026-10-20, fas 3)
- **Egen ljudfil väljs med systemets filväljare** och kopieras in i projektet. Låtar köpta i Apple
  Music är DRM-skyddade och kan inte läsas; appen säger det i klartext. (2026-10-20, fas 3)
- **Stilarna skiljer sig i tempo, övergångar, färg och musik:** Lugn (4–8 slag, mjuka
  övertoningar, mild färg), Energisk (1–2 slag, mest raka klipp och zoom/blixt, klara färger),
  Nostalgisk (2–4 slag, övertoning och vit toning, blekt filmkänsla med vinjett), Resa (2–4 slag,
  klipp och glidande övergångar, varmt ljus) och Filmisk (2–6 slag, toning via svart, dämpade färger
  och vinjett). Ett test kontrollerar att tempo, övergångar och färgbehandling verkligen skiljer
  sig åt. (2026-10-20, fas 3)
- **Egna låtar analyseras högst 15 minuter** (en film är högst 10 min), så att en lång mix inte fyller minnet; en längre fil används från början. (2026-10-21, granskning)

## 6c. Justering och projekt (fas 4)

- **Klippremsan ändrar klipplistan, inte filmen direkt** (F11). Flytta, ta bort och lås går via
  `Planner.apply(_:to:request:)` i ClipCore: övriga klipp behåller ordning, in-punkter, övergångar
  och Ken Burns-rörelser; bara längderna justeras på takten så att filmen fortfarande slutar på
  mållängden. Den borttagna tiden fylls i första hand genom att grannklippen förlängs, och först
  därefter med nya moment. (2026-10-20, fas 4)
- **Gester:** dra en miniatyr för att flytta den, svep uppåt för att ta bort, håll inne för att
  låsa eller ta bort via kontextmenyn. Samma åtgärder finns som VoiceOver-åtgärder ("Flytta
  tidigare/senare", "Lås", "Ta bort"). (2026-10-20, fas 4)
- **Borttaget material kommer aldrig tillbaka:** en borttagen stillbild utesluts helt, ett
  borttaget filmklipp utesluter just det tidsavsnittet. Låsta klipp finns kvar i varje ny version
  (F12) och vid byte av stil eller musik. (2026-10-20, fas 4)
- **Efter en ändring byggs bara kompositionen om** (ingen analys, ingen export); spelaren hoppar
  till det ändrade stället. Testet mäter tiden från ändring till spelbar förhandsvisning och
  kräver under 3 s. (2026-10-20, fas 4)
- **"Byt musik", "Byt stil", "En annan version" och "Exportera"** ligger under spelaren; musik och
  stil väljs i ett ark och filmen görs om med samma frö, så att bara det som byttes märks.
  (2026-10-20, fas 4)
- **Projekt sparas automatiskt med SwiftData** (F15) när en film har genererats och efter varje
  ändring. Varje projekt är en JSON-ögonblicksbild (media, analys, inställningar, klipplista) med
  filnamn relativt projektmappen, eftersom appens containersökväg kan ändras mellan starter.
  Miniatyren sparas som extern data. Startskärmen listar projekten; svep för att radera (mappen
  med kopierade filer tas också bort). (2026-10-20, fas 4)
- **Titel och eftertext (F14)** skrivs i ett ark och ritas av kompositören som vit text med
  skugga, centrerad, med halvsekundstoning: titeln de första ~3 s, eftertexten de sista.
  Texten ändrar inte klipplistans tajming. (2026-10-20, fas 4)
- **Ta bort i klippremsan:** bara klippet vars eget material togs bort försvinner. Grannklipp ur samma film behålls och får växa fram till exakt kanten av det borttagna avsnittet, aldrig in i det. (2026-10-21, granskning)
- **Flytta och ta bort tajmar bara om det som ändrades:** klippen börjar från sina tidigare taktslagslängder, förlängs inom stilens gränser innan nya moment läggs till, och kortas, vid behov ända till sin minsta längd, innan något tas bort. Kan inget kortas och sista klippet är en film tas inget av användarens klipp bort; filmen blir i stället en bråkdels sekund längre än mållängden. (2026-10-21, granskning)
- **Ett klipp i användarens ordning behåller sin startpunkt** så länge materialet efter den räcker till ett klipp och, med samma låt, till de taktslag klippet hade. Annars, t.ex. när ett sista klipp som kapats vid filmens slut flyttas in i filmen, börjar det så lite tidigare i sin film som behövs, i stället för att tappa ett taktslag eller spelas långsammare utan eget ljud. (2026-10-21, granskning)
- **Nya moment i användarens ordning** läggs direkt efter det klipp som ligger närmast före i tid (eller i regissörens ordning), annars före det som ligger närmast efter, så att ett klipp som användaren flyttat inte knuffas från sin plats. (2026-10-21, granskning)
- **Känd begränsning:** i mycket tajt material, där filmerna används nästan helt, kan ett kapat sista klipp som flyttas in i filmen ha mindre än ett taktslag oanvänt material mellan sin startpunkt och grannklippet ur samma film. Det spelas då upp till cirka 10 % långsammare utan eget ljud. (2026-10-21, granskning)
- **En ändring i klippremsan som blir klar först efter att filmen tagits bort (eller efter Börja om) sparar den inte på nytt,** och felmeddelanden gäller bara filmen som visas. Klippremsan följer inte uppspelningen medan ett draget klipp hålls över remsan. (2026-10-21, granskning)
- **Låsta klipp tas aldrig bort.** Får de inte plats i mållängden blir filmen så mycket längre (±1 s-kravet i F2 får vika, eftersom låsta klipp alltid ska vara kvar). (2026-10-21, granskning)
- **Byt stil- och Byt musik-arken** ändrar projektet direkt, men Avbryt och nedsvepning återställer stil, musik, egen låt och originalljud. Medan en egen låt analyseras kan arket inte stängas. (2026-10-21, granskning)
- **Användarens ordning i klippremsan behålls när bara musiken eller ljudet byts;** klippen tajmas bara om. Byte av stil, en ny version, ändrat material eller en ny beskrivning gör urvalet på nytt. (2026-10-21, granskning)
- **En ny version öppnas ovanpå förhandsvisningen.** Avbryts eller misslyckas den kommer användaren tillbaka till filmen som visades, med dess stil, musik och frö. (2026-10-21, granskning)
- **Ändringar i klippremsan och av titel/eftertext bygger alltid på den senaste ändringen,** och bara den nyaste förhandsvisningen visas. Under tiden är remsan (även VoiceOver-åtgärderna), knapparna under spelaren och titelknappen avstängda. (2026-10-21, granskning)
- **Kopierade filer städas:** ett utkast som aldrig sparats tas bort vid Ny film, när ett annat projekt öppnas och vid nästa start; filer som varken utkastet eller den sparade kopian använder tas bort när projektet sparas, öppnas eller lämnas. Miniatyren i projektlistan följer filmens första klipp. (2026-10-21, granskning)

## 6d. Apple Intelligence som regissör (fas 5)

- **Foundation Models (iOS 26-API:t) på enheten, ingen Private Cloud Compute.** PCC kräver en
  särskild entitlement och nätverk; modellen på enheten räcker för att välja och ordna klipp.
  (2026-10-20, fas 5)
- **Modellen ser bara en rad text per klipp:** kort id (`c12`), tid, foto/film och längd, plats
  (koordinater med två decimaler), kvalitetspoäng, antal ansikten och Vision-etiketter (t.ex.
  "child", "beach"). Aldrig bilderna själva. Raderna byggs i ClipCore (`DirectorBriefing`) och
  testas där. (2026-10-20, fas 5)
- **Strukturerat svar med `@Generable`:** klipp-id i ordning, upp till sex kapitel, en av de fem
  stilarna (`.anyOf`) och en titel. Okända id:n och dubbletter kastas; om inget användbart
  återstår används inte planen. Modellen bestämmer aldrig tider – planeraren följer modellens urval
  och ordning och sköter tajming och längd som vanligt; räcker urvalet inte fylls det på med det
  bästa övriga materialet. (2026-10-20, fas 5)
- **Långt material delas i omgångar** som ryms i modellens kontextfönster (`contextSize` minus
  plats för svaret). Varje rad räknas med `tokenCount(for:)` där det finns (iOS 26.4+), annars
  uppskattas en och en halv tecken per token (se nedan). Omgångarnas svar slås ihop i kronologisk ordning; stilen
  avgörs med majoritet. (2026-10-20, fas 5)
- **Fritextfältet visas bara när modellen är tillgänglig och stöder språket**
  (`SystemLanguageModel.default.isAvailable` och `supportsLocale()`), kontrollerat vid start och när
  appen kommer tillbaka i förgrunden. Annars döljs det tyst och appen fungerar som vanligt. Går
  något fel under genereringen görs filmen utan beskrivningen och en kort notis visas.
  (2026-10-20, fas 5)
- **Modellens stil- och titelförslag används bara när användaren inte själv valt** stil respektive
  skrivit en titel. Planen återanvänds för nya versioner så länge beskrivningen och materialet är
  desamma. (2026-10-20, fas 5)
- **Testning:** CI:s simulator säger att modellen finns men saknar dess filer, så genereringen
  misslyckas där. CI testar därför att en beskrivning aldrig stoppar filmen (modellen saknas eller
  fallerar → filmen görs ändå, med notis), reservläget utan Apple Intelligence och att en given
  plan följs (barnklipp i majoritet). Testet som frågar den riktiga modellen ("only pictures with
  the children") hoppar över sig självt i en simulator där modellen inte kan köras och körs på en
  iPhone med Apple Intelligence. (2026-10-20, fas 5)
- **Omgångarnas storlek:** utan `tokenCount` (iOS före 26.4) uppskattas en och en halv tecken per token, eftersom datum, koordinater och poäng blir många korta token. Varje klipp får 10 token i svaret och 1 000 token hålls fria för svarsformatet. Blir en omgång ändå för stor delas den på mitten och frågas igen. Lämnar beskrivningen färre än 400 token åt klipplistan ges ingen plan alls (filmen görs som vanligt och aviseringen visas). (2026-10-21, granskning)
- **En omgång som misslyckas på grund av sina egna klipp** (för lång, guardrail eller ett svar som inte går att läsa) tappar bara de klippen; planen byggs av de omgångar som lyckades, och beskrivningen räknas som misslyckad först när alla omgångar misslyckats. Andra fel, t.ex. rate limit eller saknade modellresurser, gör att hela beskrivningen räknas som misslyckad: filmen görs som vanligt och aviseringen visas, så att en plan aldrig tyst saknar en del av materialet. Varje svar får bara använda id:n från sin egen omgång. (2026-10-21, granskning)
- **Regissörens urval förlängs först** och får fler moment ur valda filmer innan annat material fyller på; påfyllnaden kommer i få, långa klipp. Med 10 av 30 bilder och 60 s blir valda klipp i majoritet. (2026-10-21, granskning)
- **Planen återanvänds bara när beskrivningen och materialet är exakt desamma;** tillagt material ger en ny plan. När regissören föreslår en stil och användaren inte valt låt byts låten till stilens förslag före planeringen, så att filmen, projektet och exporten har samma låt. (2026-10-21, granskning)
- **Regissörens titelförslag används tills användaren själv skrivit eller tagit bort en titel;** en ny beskrivning ger då en ny titel. (2026-10-21, granskning)

## 7. Spara och dela

- **Sparar till Bilder med "endast lägga till"-behörighet** (`NSPhotoLibraryAddUsageDescription`);
  appen läser aldrig biblioteket. Delning via systemets delningsmeny (`ShareLink`). (2026-10-20, fas 1)
- **Exporten har en utgångshanterare:** tar bakgrundstiden slut avbryts exporten, bakgrundsuppgiften avslutas (annars avslutar iOS appen) och användaren får en notis. Bara den senaste exporten ligger kvar i den tillfälliga mappen. (2026-10-21, granskning)

- **Skärmen hålls tänd medan en export pågår** (`isIdleTimerDisabled`), eftersom automatisk skärmlåsning annars skickar appen till bakgrunden. Den tillfälliga exportmappen töms också när appen startar. (2026-10-21, granskning)
## 8. Språk och tillgänglighet

- **Engelska är källspråk i String Catalog, svenska är översatt.** Katalogen skrivs av
  `scripts/strings_sv.py` och kontrolleras i CI av `scripts/check_strings.py` (alla UI-strängar
  finns i katalogen, alla har svensk text, formatmarkörer stämmer). (2026-10-20, fas 1)
- **Accentfärg #D6366B.** Kontrast 4,57:1 mot vit text (knappar) och 4,6:1 mot svart bakgrund
  (mörkt läge) – AA i båda lägena med en och samma färg. (2026-10-20, fas 1)
- **Systemtypsnitt och standardkontroller** så att Dynamic Type och VoiceOver fungerar; ikoner har
  dolts för VoiceOver där texten redan säger samma sak, och valda alternativ har egenskapen
  "vald". (2026-10-20, fas 1)
- **Fel visas som begripliga, översatta meddelanden** i stället för tekniska felkoder. (2026-10-21, granskning)
- **Notisen om oläsbara objekt har orange ikon men text i vanlig textfärg:** orange text på vitt når bara cirka 2,2:1 (kravet är 4,5:1). (2026-10-21, granskning)

## 9. Öppna frågor (från SPEC.md)

| Fråga                                   | Status                                                                 |
| --------------------------------------- | ---------------------------------------------------------------------- |
| Appens namn och ikon                    | Arbetsnamn Autoklipp + platshållarikon                                 |
| Privat app eller App Store              | Obesvarad; påverkar integritetsetikett och TestFlight-flödet           |
| Var hämtas royaltyfri musik             | Löst för MVP med egengenererad CC0-musik                              |
| iOS 26 eller iOS 27 som lägsta version  | iOS 26 (spec-standard); iOS 27-funktioner bakom `#available`           |
| Vattenstämpel eller betalvägg           | Obesvarad; appen är gratis och utan vattenstämpel tills vidare         |
