# Kravspecifikation – iOS-app för automatisk videoklippning

Oct 20, 2026 · @Linus

## Till dig som bygger appen

Bygg en native iOS-app i Swift/SwiftUI där användaren väljer bilder och filmer ur sitt bibliotek,
anger önskad längd på slutfilmen, och får en färdigklippt film med musik och övergångar – utan att
behöva redigera själv. Tänk CapCut, men med ett enda huvudflöde: välj → längd → stil → klart.

Arbetsregler för dig som AI-utvecklare:

- Bygg i faser (se Leveransfaser). Leverera en körbar app efter varje fas innan du går vidare.
- Välj alltid Apples egna ramverk före tredjepartsbibliotek. Inga externa beroenden utan att fråga
  först.
- All bearbetning sker på enheten. Ingen egen server, ingen uppladdning av användarens media.
- När ett krav är oklart: välj det enklaste rimliga alternativet, skriv ner antagandet i
  DECISIONS.md och fortsätt.
- Skriv enhetstester för klipplogiken (längdberäkning, urval, rytm) – den är appens kärna.

## Mål, icke-mål och målgrupp

Målet är att en vanlig iPhone-användare ska gå från ett gäng klipp till en delbar film på under 2
minuter, i valfri längd från 15 sekunder till 10 minuter.

### Mål

- Automatisk ihopklippning av valda bilder och filmer till en sammanhängande film.
- Användaren styr längden fritt – inte bara korta 15–30 s-snuttar.
- Musiken styr rytmen: klipp landar på takten.
- Enkel efterjustering: byta ordning, ta bort ett klipp, byta musik eller stil, och generera om.

### Icke-mål (MVP)

- Ingen tidslinje med flera spår, keyframes eller avancerad färgkorrigering.
- Inget socialt flöde, inga konton, ingen molnlagring.
- Ingen Android-version.

### Målgrupp

Föräldrar, resenärer och hobbyfilmare som vill göra en film av semestern, fotbollsmatchen eller
födelsedagen – men som tycker att CapCut är för pilligt och att Apples egna minnesfilmer ger för
lite kontroll över längden.

## Användarflöde

Huvudflödet är sex steg i rak följd; allt utöver det är valfritt.

1. **Välj media** – systemets bildväljare (PhotosPicker), flerval av bilder, Live Photos och
   filmer. Visa antal valda och total råmaterial-längd.
2. **Välj längd** – snabbval 15 s / 30 s / 1 min / 3 min / 5 min / 10 min plus ett reglage för fri
   längd. Alternativet "Auto" låter appen föreslå längd utifrån materialet.
3. **Välj stil och musik** – 4–6 stilar (t.ex. Lugn, Energisk, Nostalgisk, Resa) som styr tempo,
   övergångar och filter. Musik från inbyggt royaltyfritt bibliotek eller egen ljudfil.
4. **Generering** – förloppsindikator med tydliga steg ("Analyserar klipp…", "Väljer bästa
   ögonblicken…", "Renderar…"). Ska gå att avbryta.
5. **Förhandsvisning och justering** – spela upp filmen. Under spelaren: en enkel rad med
   klippminiatyrer där användaren kan dra för att byta ordning, svepa bort ett klipp eller låsa ett
   klipp som måste vara med. Knappar: Byt musik, Byt stil, Generera om, Exportera.
6. **Export** – spara till Bilder, dela via delningsmenyn. Val av upplösning (1080p/4K) och format
   (9:16 stående, 16:9 liggande, 1:1 kvadrat).

## Funktionella krav (MVP)

| ID  | Krav                                                                                  | Prioritet |
| --- | ------------------------------------------------------------------------------------- | --------- |
| F1  | Välja 1–200 bilder/filmer via PhotosPicker utan full biblioteksbehörighet             | Måste     |
| F2  | Ange mållängd 15 s–10 min; slutfilmen får avvika max ±1 s                             | Måste     |
| F3  | Automatisk analys av varje klipp: skärpa, rörelse, ansikten, kameraskak, tystnad      | Måste     |
| F4  | Automatiskt urval av de bästa delarna så att mållängden uppnås                        | Måste     |
| F5  | Kronologisk ordning som standard (från tidsstämpel i metadata)                        | Måste     |
| F6  | Bilder visas 1,5–4 s med lätt Ken Burns-panorering                                    | Måste     |
| F7  | Klipp synkade till musikens takt (beat detection)                                     | Måste     |
| F8  | 4–6 stilar som styr tempo, övergångar och färgfilter                                  | Måste     |
| F9  | Inbyggt bibliotek med minst 10 royaltyfria låtar + egen ljudfil                       | Måste     |
| F10 | Originalljud från filmer: av/på, automatisk nedtoning under musik (ducking)           | Bör       |
| F11 | Byta ordning, ta bort och låsa klipp i förhandsvisningen                              | Måste     |
| F12 | Generera om med samma eller ny slumpfrö ("Ge mig en annan version")                   | Bör       |
| F13 | Export 1080p/4K, 9:16, 16:9, 1:1, till Bilder och delningsmenyn                       | Måste     |
| F14 | Titel och eftertext (en rad text i början och slutet)                                 | Bör       |
| F15 | Spara projekt lokalt så att man kan öppna och justera senare                          | Bör       |
| F16 | Textinstruktion: "Gör en lugn film om sommaren, fokus på barnen" (se Apple Intelligence) | Kan    |

Om materialet är kortare än mållängden: förläng bildvisningstider och använd längre filmsegment,
och visa en tydlig notis om att materialet inte räcker för full längd. Fyll aldrig ut med upprepade
klipp utan att fråga.

## Klipplogik

Kärnan är en deterministisk algoritm som gör en klipplista (EDL) av fast längd; AI är ett valfritt
lager ovanpå, aldrig ett krav för att appen ska fungera.

1. **Analys** – dela varje film i segment om 0,5 s. Ge varje segment ett poängvärde 0–1 utifrån
   skärpa, ansikten/leenden, rörelse (lagom är bra, skak är dåligt), exponering och ljudnivå.
   Bilder får ett eget poängvärde (skärpa, ansikten, estetik).
2. **Takt** – analysera vald låt och ta fram taktslag (BPM + tidpunkter). Stilen avgör hur många
   slag ett klipp varar (t.ex. Energisk 1–2 slag, Lugn 4–8 slag).
3. **Budget** – mållängden delas upp i ett antal klipplatser som landar på taktslag. Antal platser ≈
   mållängd / genomsnittlig klipplängd för stilen.
4. **Urval** – välj de högst poängsatta segmenten, med två spärrar: sprid urvalet över hela
   materialet (varje källklipp bidrar om möjligt minst en gång) och undvik två nästan identiska
   segment i rad.
5. **Ordning** – kronologiskt som standard; låsta klipp har alltid plats.
6. **Slutjustering** – sista klippet trimmas så att filmen slutar exakt på mållängden och musiken
   tonas ut de sista 2 s.

Genomsnittlig klipplängd beräknas så här:

$$\bar{t}_{klipp} = \frac{60}{BPM} \times \text{slag per klipp}$$

Exempel: en låt i 120 BPM med stilen Energisk (2 slag) ger 1 s per klipp, alltså cirka 180 klipp
för en 3-minutersfilm. För långa filmer (över 3 min) ska stilen automatiskt växla mellan tätare och
glesare partier, så att filmen inte blir monoton – t.ex. lugnare vers, tätare refräng om låten har
tydlig struktur.

Resultatet sparas som en klipplista (JSON) med källa, in-/utpunkt, varaktighet, övergång och filter
per klipp. Rendering sker alltid från klipplistan, så att justeringar i förhandsvisningen bara
ändrar listan och renderar om.

## Apple Intelligence-integration

Apple Intelligence kan inte klippa filmen åt appen, men den kan fungera som regissör: Apples
språkmodell bestämmer vad som ska med och i vilken ordning, och appens egen kod renderar. Apples
egen funktion i Bilder-appen (minnesfilm från en textbeskrivning) har inget publikt API och kan
inte anropas från en tredjepartsapp.

Det som går att använda:

- **Foundation Models-ramverket** – Apples språkmodell direkt i Swift, på enheten. Med iOS 27 har
  Apple utökat ramverket och lagt till systemverktyg kopplade till Spotlight och Vision (WWDC 2026).
  Det finns också en molnvariant via Private Cloud Compute, kostnadsfri för utvecklare under 2
  miljoner nedladdningar men kräver en särskild entitlement.
- **Vision-ramverket** – ansikten, motiv, estetiskt poängvärde och bildklassificering per
  bild/videoruta. Detta behövs oavsett AI-läge.

### Krav på AI-läget

- Indata till modellen är en kompakt textbeskrivning per klipp (tid, plats, poäng, Vision-etiketter
  som "barn", "strand", "fotboll"), aldrig själva bilderna.
- Utdata ska vara strukturerad via guidad generering (`@Generable`-typer): urval av klipp-ID,
  ordning, kapitelindelning, föreslagen stil, förslag på titel.
- Algoritmen i Klipplogik tar modellens plan som indata och sköter tajming och längd. Modellen får
  aldrig bestämma exakta tider.
- Fritextfältet (F16) visas bara när modellen är tillgänglig. Kontrollera tillgänglighet vid start
  och dölj funktionen tyst om den saknas.
- Långa materialmängder delas upp i omgångar så att modellens kontextfönster räcker; använd
  ramverkets API för att räkna tokens.

**Fallback:** Utan Apple Intelligence (äldre iPhone, funktionen avslagen, språk som inte stöds) ska
appen ge en fullt fungerande film med den regelbaserade algoritmen. AI-läget ska kännas som en
bonus, inte en förutsättning.

## Teknisk arkitektur

Allt byggs på Apples egna ramverk, och allt flödar genom en enda klipplista som både AI-läget och
den regelbaserade motorn skriver till. Regissören är valfri: utan den går analysen direkt till
klipplistan.

| Del        | Ramverk                                               | Ansvar                                                      |
| ---------- | ----------------------------------------------------- | ----------------------------------------------------------- |
| UI         | SwiftUI, Observation                                  | Alla skärmar, klippremsa med drag-and-drop                  |
| Mediaval   | PhotosUI (PhotosPicker), PhotoKit                     | Hämta assets, metadata (datum, plats), iCloud-nedladdning   |
| Analys     | Vision, AVFoundation (AVAssetImageGenerator)          | Poängsätta segment och bilder                               |
| Takt       | AVFoundation + Accelerate (vDSP)                      | BPM och taktslag ur ljudfilen                               |
| Regissör   | Foundation Models                                     | Strukturerad plan från metadata + användarens instruktion   |
| Klipplogik | Ren Swift, egen modul                                 | Bygga klipplistan, helt testbar utan UI                     |
| Rendering  | AVMutableComposition, AVVideoComposition, Core Image  | Klipp, övergångar, Ken Burns, filter, ljudmix               |
| Lagring    | SwiftData                                             | Projekt och klipplistor lokalt                              |

## Icke-funktionella krav

| Område         | Krav                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| Plattform      | iOS 26 som lägsta version, optimerad för iOS 27. Endast iPhone i MVP.                                   |
| Prestanda      | Analys + klipplista för 50 klipp under 20 s på iPhone 15 Pro. Rendering av 3 min 1080p under 60 s.     |
| Minne          | Analysera med lågupplösta proxyrutor; ladda aldrig in hela filmer i minnet.                            |
| Integritet     | Allt på enheten. Ingen analys, inga spårare, ingen uppladdning. Begränsad bildbehörighet (PhotosPicker) räcker. |
| Bakgrund       | Rendering ska kunna fortsätta kort i bakgrunden och notifiera när filmen är klar.                      |
| Robusthet      | iCloud-filer som inte finns lokalt laddas ned med förloppsvisning; trasiga filer hoppas över med notis. |
| Språk          | Svenska och engelska i UI från start (String Catalogs).                                                |
| Tillgänglighet | VoiceOver-etiketter, Dynamic Type, tillräcklig kontrast.                                               |
| Licenser       | Endast musik med dokumenterad licens för kommersiell användning i appen.                               |

## Leveransfaser och acceptanskriterier

Varje fas ska ge en app som går att installera och använda via TestFlight eller Xcode.

| Fas                  | Innehåll                                                                                          | Klart när                                                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| 1. Skelett           | Välj media, välj längd, enkel ihopklippning i kronologisk ordning med jämn klipplängd, en låt, export | En 1-minutersfilm av 20 blandade klipp exporteras till Bilder, längd 60 s ±1 s                                         |
| 2. Smart urval       | Vision-analys, poängsättning, urval av bästa segment, Ken Burns på bilder                         | Suddiga och skakiga segment väljs bort; ansikten prioriteras i ett testset                                                 |
| 3. Rytm och stil     | Beat detection, 4–6 stilar, musikbibliotek, ducking                                               | Klippbyten ligger inom 50 ms från taktslag; stilarna känns tydligt olika                                                   |
| 4. Justering         | Klippremsa: ordna om, ta bort, lås, generera om, spara projekt                                    | Ändring i remsan ger ny förhandsvisning under 3 s                                                                          |
| 5. Apple Intelligence | Foundation Models som regissör, fritextinstruktion, fallback                                     | Instruktionen "bara bilder med barnen" ger en film där övervägande klipp innehåller barn; appen fungerar fullt utan AI     |

Fas 1–3 är MVP. Fas 4–5 kan levereras som uppdatering.

## Öppna frågor

- [ ] Appens namn och ikon.
- [ ] Privat app för familjen eller App Store? Avgör om musiklicenser och integritetsetikett måste
      vara klara före fas 3.
- [ ] Var hämtas royaltyfri musik med licens för inbäddning i app?
- [ ] Lägsta iOS-version: iOS 26 (bredare publik) eller iOS 27 (nyaste Foundation
      Models-funktionerna)?
- [ ] Ska vattenstämpel eller betalvägg finnas, eller är appen gratis?

## Källor

- What's new in the Foundation Models framework – WWDC 2026
- PhotoKit – Apple Developer Documentation
