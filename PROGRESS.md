# Framsteg – Autoklipp

Bockas av enligt acceptanskriterierna i SPEC.md. Senast uppdaterad: 2026-10-20.

| Fas | Innehåll              | Status   |
| --- | --------------------- | -------- |
| 1   | Skelett               | 🔄 Pågår |
| 2   | Smart urval           | ⬜       |
| 3   | Rytm och stil         | ⬜       |
| 4   | Justering             | ⬜       |
| 5   | Apple Intelligence    | ⬜       |

---

## Fas 1 – Skelett

Klart när: _En 1-minutersfilm av 20 blandade klipp exporteras till Bilder, längd 60 s ±1 s._

- [x] Repo, Xcode-projekt (iOS 26, iPhone), lokalt Swift-paket ClipCore, CI (Linux + macOS)
- [x] Välj media med PhotosPicker (1–200, bilder/Live Photos/filmer) utan biblioteksbehörighet;
      antal och total filmlängd visas; trasiga filer hoppas över med notis
- [x] Välj längd: snabbval 15 s–10 min, reglage för fri längd, Auto
- [x] Stil (5 stilar) och en inbyggd låt (Sommarvind, 104 BPM, CC0)
- [x] Generering med synliga steg som går att avbryta
- [x] Klipplista (EDL, JSON) i kronologisk ordning, klipp på taktslag, exakt längd
- [x] Förhandsvisning, "En annan version"
- [x] Export 1080p/4K i 9:16, 16:9, 1:1; spara i Bilder; dela
- [x] Svenska och engelska (String Catalog)
- [x] Enhetstester för klipplogiken (ClipCore)
- [ ] Acceptanstest grönt i CI: 20 blandade klipp → 60 s ±1 s → exporterad och sparad i Bilder
