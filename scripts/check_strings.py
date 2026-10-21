#!/usr/bin/env python3
"""Checks the string catalog: every UI literal in the app has an entry, and every entry has
a Swedish translation. Exits non-zero with a list of problems."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "Autoklipp")
CATALOG = os.path.join(APP, "Resources", "Localizable.xcstrings")

CALL = re.compile(
    r'\b(Text|Button|Label|Section|navigationTitle|ContentUnavailableView|Picker|Toggle|TextField|LocalizedStringKey|'
    r'String\(localized:|LocalizedStringResource)\(?\s*"((?:[^"\\]|\\.)*)"'
)
FORMAT = re.compile(r"%(lld|ld|d|@|lf|f)")


def normalise_code(literal: str) -> str:
    """Replaces each \\( … ) interpolation (with nested parentheses) by a marker."""
    out, i = [], 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[i], 0)
                i += 1
            out.append("§")
        else:
            out.append(literal[i])
            i += 1
    return "".join(out)


def main() -> int:
    with open(CATALOG, encoding="utf-8") as handle:
        strings = json.load(handle)["strings"]
    problems = []
    for key, entry in strings.items():
        sv = entry.get("localizations", {}).get("sv")
        if not sv:
            problems.append(f"missing Swedish: {key!r}")
            continue
        units = [sv.get("stringUnit")] if "stringUnit" in sv else [
            form.get("stringUnit") for form in sv.get("variations", {}).get("plural", {}).values()
        ]
        if not units or any(not unit or not unit.get("value") for unit in units):
            problems.append(f"empty Swedish: {key!r}")
        for unit in units:
            if unit and sorted(FORMAT.findall(unit["value"])) != sorted(FORMAT.findall(key)):
                problems.append(f"format mismatch: {key!r} -> {unit['value']!r}")

    known = {FORMAT.sub("§", key) for key in strings}
    for folder, _, files in os.walk(APP):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for match in CALL.finditer(text):
                literal = normalise_code(match.group(2))
                if not literal.strip() or literal in ("·",):
                    continue
                if literal not in known:
                    line = text.count("\n", 0, match.start()) + 1
                    problems.append(f"not in catalog: {literal!r} ({os.path.relpath(path, APP)}:{line})")
    for problem in problems:
        print(problem)
    print(f"{len(strings)} strings checked, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
