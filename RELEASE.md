# Installera på iPhone med TestFlight (utan Mac)

GitHub bygger och signerar appen på en Mac i molnet och laddar upp den till App Store Connect.
Därifrån installerar du den med TestFlight-appen. Stegen märkta 🔑 kan bara du göra, eftersom de
kräver ditt Apple-konto.

## Engångsförberedelser

1. 🔑 **Gå med i Apple Developer Program** (99 USD/år) på
   [developer.apple.com/programs](https://developer.apple.com/programs/). Godkännandet kan ta upp
   till ett par dagar.
2. 🔑 **Notera ditt Team ID**: [developer.apple.com/account](https://developer.apple.com/account)
   → Membership details → Team ID (tio tecken, t.ex. `AB12CD34EF`).
3. 🔑 **Registrera app-id:t**: Certificates, Identifiers & Profiles → Identifiers → **+** →
   App IDs → App → Explicit Bundle ID `se.autoklipp.app`. Är det upptaget, välj ett eget (t.ex.
   `se.dittnamn.autoklipp`) och lägg det som repo-variabeln `BUNDLE_ID` (GitHub → Settings →
   Secrets and variables → Actions → Variables).
4. 🔑 **Skapa appen i App Store Connect**: [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
   → Appar → **+** → Ny app. Plattform iOS, ett namn (måste vara unikt i App Store, t.ex.
   "Autoklipp – filmklipp"), primärt språk svenska, paket-id:t från steg 3, valfri SKU.
5. 🔑 **Skapa en API-nyckel**: App Store Connect → Användare och åtkomst → Integrationer →
   App Store Connect API → Teamnycklar → **+**. Roll **Admin** (behövs för att molnet ska få skapa
   certifikat och profiler åt dig). Ladda ned `.p8`-filen (går bara en gång) och notera
   **Key ID** och **Issuer ID**.
6. 🔑 **Lägg in hemligheterna i GitHub**: repot → Settings → Secrets and variables → Actions →
   New repository secret:

   | Namn               | Värde                                   |
   | ------------------ | --------------------------------------- |
   | `APPLE_TEAM_ID`    | Team ID från steg 2                     |
   | `ASC_KEY_ID`       | Key ID från steg 5                      |
   | `ASC_ISSUER_ID`    | Issuer ID från steg 5                   |
   | `ASC_PRIVATE_KEY`  | Hela innehållet i `.p8`-filen           |

## Varje ny version

1. GitHub → Actions → **TestFlight** → Run workflow (välj grenen du vill bygga).
   Byggnumret blir körningens nummer, så varje uppladdning blir ny.
2. Vänta tills Apple har behandlat bygget (oftast 10–30 min). Du får ett mejl.
3. 🔑 Första gången: App Store Connect → appen → TestFlight → Interna tester → lägg till dig själv.
4. Installera **TestFlight** från App Store på iPhonen, öppna inbjudan och tryck Installera.

## Bra att veta

- Appen kräver iOS 26. Regissören med Apple Intelligence (fas 5) kräver dessutom en iPhone som
  har Apple Intelligence (iPhone 15 Pro eller senare) med funktionen påslagen; utan den fungerar
  allt annat som vanligt.
- Interna testare (upp till 100 personer i ditt team) behöver ingen granskning av Apple. Externa
  testare kräver en kort granskning av det första bygget.
- Arbetsflödet har inte kunnat provköras utan dina nycklar. Misslyckas signeringen första gången,
  skicka loggen från steget *Archive* så justerar jag det.
