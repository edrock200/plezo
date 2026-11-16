#!/usr/bin/env python3
"""Extract the Silo row titles Plezilo shows from Silo's translation catalogs.

Silo's server words some rows itself (Home and library sections, recommendation
hubs) and sends `title_key` (`home.section.*`) and `title_args` next to the
English `title`. Silo's apps translate those keys from a shared catalog that
ships in AGPL-3.0 projects. Plezilo bundles only the `home.section.*` entries,
one small JSON file per Plezilo locale, in `assets/silo_i18n/`, and resolves
them in `lib/services/silo/silo_catalog_strings.dart`.

The catalogs are the ones the Siku Roku project vendors
(`third_party/silo-translations/roku/<folder>/strings.json`, Silo's silo-roku
catalogs, with named `{placeholders}`). Re-run after refreshing them:

    python3 scripts/silo_catalog_strings.py [--catalogs ../siku/third_party/silo-translations]

It rewrites `assets/silo_i18n/<locale>.json` for every Plezilo locale
(`lib/i18n/<locale>.i18n.json`) that has a Silo catalog, removes files for
locales that lost theirs, copies the AGPL text to `LICENSE.txt` and writes
`NOTICE.txt` naming the source and the languages.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "silo_i18n")
PREFIX = "home.section."

# Plezilo locale (lib/i18n file name) -> silo-roku catalog folder, where the
# names differ. Every other locale uses the folder of the same name if present.
FOLDERS = {"en": "en_US", "pt": "pt_BR"}

LANGUAGE_NAMES = {
    "en": "English",
    "cs": "Czech",
    "da": "Danish",
    "de": "German",
    "es": "Spanish",
    "fi": "Finnish",
    "fr": "French",
    "hr": "Croatian",
    "it": "Italian",
    "nb": "Norwegian Bokmål",
    "nl": "Dutch",
    "pl": "Polish",
    "pt": "Brazilian Portuguese",
    "ru": "Russian",
    "sv": "Swedish",
    "tr": "Turkish",
    "uk": "Ukrainian",
}


def plezilo_locales() -> list[str]:
    names = os.listdir(os.path.join(ROOT, "lib", "i18n"))
    return sorted(n[: -len(".i18n.json")] for n in names if n.endswith(".i18n.json"))


def section_titles(path: str) -> dict[str, str]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {k: v for k, v in sorted(data.items()) if k.startswith(PREFIX) and isinstance(v, str) and v.strip()}


def source_line(catalogs: str) -> str:
    """'silo-roku at <commit> (catalog release <release>)' from the vendored NOTICE.md."""
    try:
        with open(os.path.join(catalogs, "NOTICE.md"), encoding="utf-8") as f:
            notice = f.read()
    except OSError:
        return "Silo-Server/silo-roku"
    m = re.search(r"Silo-Server/silo-roku at (\w+)\s*\(catalog release ([^)]+)\)", notice)
    if not m:
        return "Silo-Server/silo-roku"
    return f"Silo-Server/silo-roku at {m.group(1)} (catalog release {m.group(2)})"


def notice_text(source: str, locales: list[str]) -> str:
    languages = textwrap.fill(
        "Languages: " + ", ".join(LANGUAGE_NAMES.get(loc, loc) for loc in locales) + ".", width=78
    )
    return f"""SILO TRANSLATIONS — NOTICE
==========================

The translated titles of the rows a Silo server words itself (Home sections
and recommendation rows, catalog keys "home.section.*") in this folder are
taken from Silo's translation catalogs:

  {source}
  locale/<language>/strings.json

{languages}

Copyright (c) their authors (Silo Media L.L.C. and contributors).

These strings are licensed under the GNU Affero General Public License,
version 3 or (at your option) any later version; the full text is in
LICENSE.txt beside this file and at https://www.gnu.org/licenses/agpl-3.0.html.
Plezilo itself is licensed under the GNU General Public License, version 3,
whose section 13 permits combining it with work under the AGPL.

Only the "home.section.*" entries are included, unmodified apart from being
copied into one JSON file per language. The source of these files is the
catalogs named above; scripts/silo_catalog_strings.py in Plezilo's source
regenerates them.

"Silo" is a trademark of Silo Media L.L.C. Plezilo is not made or endorsed by
Silo Media L.L.C.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--catalogs",
        default=os.path.join(os.path.dirname(ROOT), "siku", "third_party", "silo-translations"),
        help="the vendored silo-translations folder (default: ../siku/third_party/silo-translations)",
    )
    parser.add_argument(
        "--license",
        default=None,
        help="the AGPL-3.0 text to copy as LICENSE.txt (default: the catalogs' project LICENSE)",
    )
    args = parser.parse_args()

    roku = os.path.join(args.catalogs, "roku")
    if not os.path.isdir(roku):
        print(f"no catalogs at {roku}", file=sys.stderr)
        return 1

    english = section_titles(os.path.join(roku, FOLDERS["en"], "strings.json"))
    if not english:
        print("the English catalog has no home.section.* entries", file=sys.stderr)
        return 1

    os.makedirs(OUT, exist_ok=True)
    written = []
    for loc in plezilo_locales():
        folder = FOLDERS.get(loc, loc)
        path = os.path.join(roku, folder, "strings.json")
        target = os.path.join(OUT, f"{loc}.json")
        if not os.path.isfile(path):
            if os.path.exists(target):
                os.remove(target)
            continue
        table = section_titles(path)
        # Only keys the English catalog has: the resolver falls back to English.
        table = {k: v for k, v in table.items() if k in english}
        with open(target, "w", encoding="utf-8") as f:
            json.dump(table, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        written.append(loc)
        print(f"{loc}: {len(table)} of {len(english)} titles (from {folder})")

    license_src = args.license or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.catalogs))), "LICENSE")
    try:
        with open(license_src, encoding="utf-8") as f:
            license_text = f.read()
    except OSError:
        license_text = ""
    if "GNU AFFERO GENERAL PUBLIC LICENSE" not in license_text:
        print(f"{license_src} is not the AGPL text; pass --license", file=sys.stderr)
        return 1
    with open(os.path.join(OUT, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(license_text)

    ordered = ["en"] + [loc for loc in written if loc != "en"]
    with open(os.path.join(OUT, "NOTICE.txt"), "w", encoding="utf-8") as f:
        f.write(notice_text(source_line(args.catalogs), ordered))
    return 0


if __name__ == "__main__":
    sys.exit(main())
