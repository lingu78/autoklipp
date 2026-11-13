# Produktsidan i App Store

Allt som behövs för att lägga ut Autoklipp 1.0 i App Store.

**Det mesta fylls i automatiskt.** Arbetsflödet *App Store page*
(`.github/workflows/appstore.yml`, skriptet `scripts/app_store_connect.py`) körs när något här
ändras och skriver till App Store Connect med TestFlight-flödets API-nyckel: beskrivning, nyckelord,
kampanjtext, namn och undertitel på engelska och svenska, kategorin, anteckningarna till App Review,
6,9"-skärmbilderna och det senaste färdiga bygget av version 1.0. Webbadresser fylls i när filerna
`support_url.txt`, `privacy_policy_url.txt` (och valfritt `marketing_url.txt`) finns i `en-US/`
och `sv/`.

**Kvar för hand:** sidhuvud- och sökresultatbilden, App Privacy, åldersgränsen, kontaktuppgifter
till App Review, pris och tillgänglighet samt copyright.

Texterna finns på engelska (`en-US/`, appens huvudspråk i App Store Connect) och svenska (`sv/`).
Varje fil kan klistras in som den är. Skärmbilderna laddas upp på engelska; svenska sidan visar
samma bilder tills den får egna.

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

## App Information

- **Name:** `name.txt` (Autoklipp) · **Subtitle:** `subtitle.txt` (30 tecken)
- **Category:** Photo & Video (Foto och video)
- **Content Rights:** *No* – appen visar inget innehåll från andra. Musiken är skapad för appen
  och CC0 (se `LICENSES/music.md`); allt annat är användarens egna bilder och filmer.
- **Age Rating:** svara *None/No* på alla frågor → 4+.

## App Privacy

- **Privacy Policy URL:** krävs. `privacy-policy.md` är färdig (engelska och svenska); fyll i en
  e-postadress och lägg den där den kan läsas utan inloggning, till exempel en offentlig GitHub
  Gist eller en publicerad Notion-sida, och klistra in adressen.
- **Data Collection:** *No, we do not collect data from this app.* Appen har ingen analys, ingen
  reklam och använder inte nätverket.

## Pricing and Availability

Välj pris (t.ex. gratis) och länder.

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
