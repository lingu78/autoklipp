#!/usr/bin/env python3
"""Writes Autoklipp/Resources/Localizable.xcstrings and InfoPlist.xcstrings.

English is the source language (the keys); Swedish translations live here. Run after adding
UI text, then check with scripts/check_strings.py (CI does).
"""
import json
import os

ROOT = os.path.join(os.path.dirname(__file__), "..", "Autoklipp", "Resources")

# key -> Swedish, or key -> {"en": {...plural...}, "sv": {...plural...}}
STRINGS = {
    "Analysing clips…": "Analyserar klipp…",
    "Choosing the best moments…": "Väljer bästa ögonblicken…",
    "Rendering…": "Renderar…",
    "Following your description…": "Följer din beskrivning…",
    "For example: a calm film about the summer, focusing on the children":
        "Till exempel: en lugn film om sommaren med fokus på barnen",
    "Describe your film (optional)": "Beskriv din film (valfritt)",
    "Apple Intelligence picks and orders the clips on your device. Only short descriptions of the clips are used, never the pictures.":
        "Apple Intelligence väljer och ordnar klippen på din enhet. Bara korta beskrivningar av klippen används, aldrig bilderna.",
    "Apple Intelligence could not follow your description, so the film was made without it.":
        "Apple Intelligence kunde inte följa din beskrivning, så filmen gjordes utan den.",
    "Calm": "Lugn",
    "Energetic": "Energisk",
    "Nostalgic": "Nostalgisk",
    "Travel": "Resa",
    "Cinematic": "Filmisk",
    "Long, soft crossfades and gentle colours.": "Långa, mjuka övertoningar och milda färger.",
    "Fast cuts on every beat and punchy colours.": "Snabba klipp på varje taktslag och klara färger.",
    "Faded film look with warm white flashes.": "Blekt filmkänsla med varma, vita blixtar.",
    "Lively pace, slides and warm light.": "Livligt tempo, glidande övergångar och varmt ljus.",
    "Unhurried, dark fades and a cinema grade.": "Lugnt tempo, mörka toningar och biofärger.",
    "Back": "Tillbaka",
    "Cancel": "Avbryt",
    "Close": "Stäng",
    "Start over": "Börja om",
    "No film yet": "Ingen film än",
    "Another version": "En annan version",
    "Create film": "Skapa film",
    "Export film": "Exportera film",
    "Export": "Exportera",
    "Share": "Dela",
    "Style and music": "Stil och musik",
    "Format": "Format",
    "Resolution": "Upplösning",
    "Style": "Stil",
    "Music": "Musik",
    "1080p": "1080p",
    "4K": "4K",
    "9:16 portrait": "9:16 stående",
    "16:9 landscape": "16:9 liggande",
    "1:1 square": "1:1 kvadrat",
    "All built-in music is made for Autoklipp and free to use in your films.":
        "All inbyggd musik är gjord för Autoklipp och fri att använda i dina filmer.",
    "Auto": "Auto",
    "Custom length": "Egen längd",
    "Custom length: %@": "Egen längd: %@",
    "How long should the film be?": "Hur lång ska filmen vara?",
    "Importing %lld of %lld…": "Importerar %lld av %lld…",
    "Live Photo": "Live Photo",
    "Photo": "Bild",
    "Video, %@": "Film, %@",
    "Next": "Nästa",
    "Pick photos and videos, choose a length and get a finished film with music.":
        "Välj bilder och filmer, välj en längd och få en färdig film med musik.",
    "Play preview": "Provlyssna",
    "New film": "Ny film",
    "Your films": "Dina filmer",
    "Film": "Film",
    "This film could not be opened.": "Filmen gick inte att öppna.",
    "Something went wrong": "Något gick fel",
    "OK": "OK",
    "%@ · %@": "%@ · %@",
    "Unlock": "Lås upp",
    "Lock": "Lås",
    "Remove": "Ta bort",
    "Move earlier": "Flytta tidigare",
    "Move later": "Flytta senare",
    "Video": "Film",
    "locked": "låst",
    "Clip %lld of %lld": "Klipp %lld av %lld",
    "Drag to reorder · swipe up to remove · touch and hold to lock":
        "Dra för att flytta · svep uppåt för att ta bort · håll inne för att låsa",
    "Title and credits": "Titel och eftertext",
    "Change music": "Byt musik",
    "Change style": "Byt stil",
    "Title": "Titel",
    "End credit": "Eftertext",
    "Shown over the first seconds of the film.": "Visas över filmens första sekunder.",
    "Shown over the last seconds of the film.": "Visas över filmens sista sekunder.",
    "Done": "Klar",
    "%lld BPM · own file": "%lld BPM · egen fil",
    "%lld BPM · suits the style": "%lld BPM · passar stilen",
    "Finding the beat…": "Letar efter takten…",
    "Use your own audio file…": "Använd en egen ljudfil…",
    "Sound from the videos": "Ljud från filmerna",
    "The music is lowered while people talk or cheer.": "Musiken sänks när någon pratar eller jublar.",
    "No steady beat was found in that song. Try another one.": "Ingen jämn takt hittades i låten. Prova en annan.",
    "That file could not be read. Songs bought in Apple Music are protected and cannot be used.":
        "Filen gick inte att läsa. Låtar från Apple Music är skyddade och kan inte användas.",
    "Stop preview": "Stoppa provlyssningen",
    "Rendering… %@": "Renderar… %@",
    "%lld BPM": "%lld BPM",
    "Photos: %lld · Videos: %lld · Video length: %@": "Bilder: %lld · Filmer: %lld · Filmlängd: %@",
    "Film preview": "Förhandsvisning av filmen",
    "Creating film": "Skapar film",
    "Length": "Längd",
    "New film": "Ny film",
    "Your film": "Din film",
    "Choose photos and videos": "Välj bilder och filmer",
    "Change selection": "Ändra urvalet",
    "Saved to Photos": "Sparad i Bilder",
    "Save to Photos": "Spara i Bilder",
    "There was only enough material for %@ of the %@ you asked for.":
        "Materialet räckte bara till %@ av de %@ du valde.",
    "Your photos and videos are enough for about %@. The film will be shorter unless you add more.":
        "Dina bilder och filmer räcker till ungefär %@. Filmen blir kortare om du inte lägger till mer.",
    "Autoklipp is not allowed to add to Photos. You can change this in Settings.":
        "Autoklipp får inte lägga till i Bilder. Du kan ändra det i Inställningar.",
    "None of the chosen photos or videos could be used.": "Ingen av de valda bilderna eller filmerna gick att använda.",
    "Your film is ready": "Din film är klar",
    "Open Autoklipp to save or share it.": "Öppna Autoklipp för att spara eller dela den.",
    "%lld selected": {
        "en": {"one": "%lld selected", "other": "%lld selected"},
        "sv": {"one": "%lld vald", "other": "%lld valda"},
    },
    "%lld items could not be read and were skipped.": {
        "en": {"one": "%lld item could not be read and was skipped.", "other": "%lld items could not be read and were skipped."},
        "sv": {"one": "%lld objekt kunde inte läsas och hoppades över.", "other": "%lld objekt kunde inte läsas och hoppades över."},
    },
    "%lld clips": {
        "en": {"one": "%lld clip", "other": "%lld clips"},
        "sv": {"one": "%lld klipp", "other": "%lld klipp"},
    },
}

INFO_PLIST = {
    "CFBundleDisplayName": {"en": "Autoklipp", "sv": "Autoklipp"},
    "NSPhotoLibraryAddUsageDescription": {
        "en": "Autoklipp saves your finished films to Photos.",
        "sv": "Autoklipp sparar dina färdiga filmer i Bilder.",
    },
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms):
    return {"variations": {"plural": {form: unit(text) for form, text in forms.items()}}}


def main():
    strings = {}
    for key, value in sorted(STRINGS.items(), key=lambda item: item[0].lower()):
        if isinstance(value, dict):
            strings[key] = {"localizations": {lang: plural(forms) for lang, forms in value.items()}}
        else:
            strings[key] = {"localizations": {"sv": unit(value)}}
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(os.path.join(ROOT, "Localizable.xcstrings"), "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")

    info = {
        key: {"extractionState": "manual", "localizations": {lang: unit(text) for lang, text in values.items()}}
        for key, values in INFO_PLIST.items()
    }
    with open(os.path.join(ROOT, "InfoPlist.xcstrings"), "w", encoding="utf-8") as handle:
        json.dump({"sourceLanguage": "en", "strings": info, "version": "1.0"}, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
