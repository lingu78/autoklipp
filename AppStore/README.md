# Produktsidan i App Store

Allt som behövs för att lägga ut Autoklipp 1.0 i App Store.

**Det mesta fylls i automatiskt.** Arbetsflödet *App Store page*
(`.github/workflows/appstore.yml`, skriptet `scripts/app_store_connect.py`) körs när något här
ändras och skriver till App Store Connect med TestFlight-flödets API-nyckel: beskrivning, nyckelord,
kampanjtext, namn och undertitel på engelska och svenska, kategorin, anteckningarna till App Review,
6,9"-skärmbilderna och det senaste färdiga bygget av version 1.0. Webbadresser fylls i när filerna
`support_url.txt`, `privacy_policy_url.txt` (och valfritt `marketing_url.txt`) finns i `en-US/`
och `sv/`.

Arbetsflödet sätter också Content Rights (inget innehåll från andra), gratis pris, tillgänglighet
i alla länder och adresserna till supportsidan (`support.md`) och integritetspolicyn
(`privacy-policy.md`), båda i det här offentliga repot med GitHub-ärenden som kontaktväg.

**Kvar för hand:** sidhuvud- och sökresultatbilden, App Privacy (måste göras av en Admin; API:t
kan inte), åldersgränsen, kontaktuppgifter till App Review samt copyright.

Texterna finns på svenska (`sv/`, appens huvudspråk i App Store Connect) och engelska (`en-US/`).
Varje fil kan klistras in som den är. Skärmbilderna laddas upp per språk: de svenska ur
`images/sv/` (appen på svenska, svenska bildtexter) och de engelska ur `images/`. Huvudspråket
måste ha skärmbilder; ett språk utan egna visar huvudspråkets.

Skärmbilderna finns för tre avsnitt, på båda språken:

| Avsnitt i App Store Connect | Filer | Storlek |
| --- | --- | --- |
| iPhone, stor skärm (6,9") | `iphone-69-*.jpg` | 1320 × 2868 |
| iPhone, mellanstor skärm (6,3", krävs) | `iphone-63-*.jpg` | 1206 × 2622 |
| iPhone Duo, ytterskärmen | `duo-outer-*.jpg` | 1398 × 2034 |
| iPhone Duo, innerskärmen utfälld | `duo-inner-*.jpg` | 2853 × 2007 |

API:t kallar dem `APP_IPHONE_67`, `APP_IPHONE_61` och `APP_IPHONE_DUO` (Duo saknas ännu i Apples
publicerade specifikation men tas emot; arbetsflödet med *probe* frågar API:t vilka typer det tar).

## Version 1.0 – Product Page Information (per språk)

| Fält i App Store Connect | Fil | Gräns |
| --- | --- | --- |
| Header (sidhuvud, 21:9) | `images/header.png` (3840 × 1646) | PNG, ingen genomskinlighet |
| Search Results (sökresultat, 3:2) | `images/search-results.png` (3840 × 2560) | PNG, ingen genomskinlighet |
| Promotional Text | `promotional_text.txt` | 170 tecken |
| Description | `description.txt` | 4000 tecken |
| Keywords | `keywords.txt` | 100 byte |
| Support URL | adressen till en sida med kontaktuppgift (se nedan) | – |
| Marketing URL | valfri | – |
| iPhone 6,9"-skärmbilder | `images/iphone-69-*.jpg` (1320 × 2868), i nummerordning | 1–10 bilder |

Bilderna görs av appens egna skärmar i CI (`AutoklippTests/StoreAssetsTests.swift`) och ligger
också i artefakten *screenshots* under `store/` i varje CI-körning. Skärmbilderna för 6,9" räcker:
App Store skalar dem till mindre iPhone-skärmar.

## Bygget

Versionen i App Store Connect är 1.0, så bygget måste också ha version 1.0. Projektet har
`MARKETING_VERSION = 1.0`; kör arbetsflödet **TestFlight** en gång till och välj det nya bygget
(1.0 och ett byggnummer) under *Build* på versionssidan.

## Nästa version (uppdateringar)

Version 1.0 lämnas orörd medan den granskas eller ligger ute: arbetsflödet ändrar bara en version
som förbereds (*Prepare for Submission*) och rapporterar annars bara. För en uppdatering:

1. App Store Connect → **+** vid iOS App → nytt versionsnummer, t.ex. 1.0.1.
2. Samma nummer som `MARKETING_VERSION` i projektet, och arbetsflödet **TestFlight**.
3. *What's New* per språk i `sv/whats_new.txt` och `en-US/whats_new.txt` (krävs för uppdateringar).
4. Arbetsflödet **App Store page** (körs vid push hit, eller för hand) fyller i den nya versionen:
   texter, skärmbilder och det senaste färdiga bygget av den.
5. **Add for Review** i App Store Connect.

## App Information

- **Name:** `name.txt` (Autoklipp) · **Subtitle:** `subtitle.txt` (30 tecken)
- **Category:** Photo & Video (Foto och video)
- **Content Rights:** *No* – appen visar inget innehåll från andra. Musiken är skapad för appen
  och CC0 (se `LICENSES/music.md`); allt annat är användarens egna bilder och filmer.
- **Age Rating:** svara *None/No* på alla frågor → 4+.

## App Privacy

- **Privacy Policy URL:** `privacy-policy.md` i repot, ifylld av arbetsflödet
  (`privacy_policy_url.txt`). Pekar på arbetsgrenen; slås den ihop med `main`, byt adressen i
  `privacy_policy_url.txt` och `support_url.txt` till `main`.
- **Data Collection (för hand, en Admin):** App Privacy → *Get Started* → *No, we do not collect
  data from this app* → *Save* → *Publish*. Appen har ingen analys, ingen reklam och använder inte
  nätverket.

## Pricing and Availability

Gratis i alla länder, även nya som Apple lägger till; sätts av arbetsflödet (bas: Sverige).

## App Review Information

- **Sign-in required:** nej.
- **Contact information:** ditt namn, telefon och e-post (syns bara för Apple). Fyll i dem
  först: Apple sparar anteckningarna bara tillsammans med kontaktuppgifterna.
- **Notes:** `review_notes.txt`. Fylls i av arbetsflödet *App Store page* när kontaktuppgifterna
  finns (kör det igen under Actions), eller klistra in filen.

## Övrigt

- **Copyright:** `2026` följt av ditt namn eller företagsnamn.
- **Export compliance:** besvarat i bygget (`ITSAppUsesNonExemptEncryption = NO`).
- Sidan *Preview* uppe till höger visar hur sidhuvudet och sökresultatbilden beskärs.
