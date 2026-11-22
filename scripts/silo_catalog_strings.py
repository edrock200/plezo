#!/usr/bin/env python3
"""Extract the Silo strings Plezilo shows from Silo's translation catalogs.

Silo's server words some rows itself (Home and library sections, recommendation
hubs) and sends `title_key` (`home.section.*`) and `title_args` next to the
English `title`. Silo's apps translate those keys from a shared catalog that
ships in AGPL-3.0 projects. Plezilo bundles only the `home.section.*` entries
and a few strings Silo's Android app words for the same server data
(`ANDROID_KEYS`, e.g. the "by {owner}" line of a shared collection's card), one
small JSON file per Plezilo locale, in `assets/silo_i18n/`, and resolves them in
`lib/services/silo/silo_catalog_strings.dart`.

The source is silo-android's catalog
(`android-shared/src/androidMain/res/values*/strings_catalog.xml`, Android's
`%1$s` placeholders written as the named `{placeholders}` its comments give).
A locale without an Android catalog falls back to the silo-roku catalogs the
Siku Roku project vendors (`third_party/silo-translations/roku/<folder>/strings.json`).
Re-run after Silo refreshes its catalogs:

    python3 scripts/silo_catalog_strings.py \
        --android-catalogs <silo-android>/android-shared/src/androidMain/res \
        --license <silo-android>/LICENSE [--catalogs ../siku/third_party/silo-translations]

It rewrites `assets/silo_i18n/<locale>.json` for every Plezilo locale
(`lib/i18n/<locale>.i18n.json`) that has a Silo catalog, removes files for
locales that lost theirs, copies the AGPL text to `LICENSE.txt` and writes
`NOTICE.txt` naming the sources and the languages.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import textwrap
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "silo_i18n")
PREFIX = "home.section."

# Plezilo locale (lib/i18n file name) -> silo-roku catalog folder, where the
# names differ. Every other locale uses the folder of the same name if present.
FOLDERS = {"en": "en_US", "pt": "pt_BR"}

# Android string name -> (catalog key, placeholder names in %1$s, %2$s, ... order).
# Strings Silo's Android app has for server data Plezilo shows; the roku
# catalogs lack them.
ANDROID_KEYS = {
    "collections_posterCard_byOwner": ("collections.posterCard.byOwner", ("owner",)),
    "detail_alsoIn": ("detail.alsoIn", ()),
}

# Plezilo locale (lib/i18n file name) -> Android resource folder, where it is
# not values-<locale>. Android keeps the legacy codes for Hebrew (iw),
# Indonesian (in) and Yiddish (ji), which devices, the server and Plezilo call
# he, id and yi.
ANDROID_FOLDERS = {
    "en": "values",
    "pt": "values-pt-rBR",
    "pt-PT": "values-pt-rPT",
    "zh": "values-b+zh+Hans",
    "zh-Hant": "values-b+zh+Hant",
    "he": "values-iw",
    "id": "values-in",
    "yi": "values-ji",
}


def android_folder(loc: str) -> str:
    """The values* folder holding locale `loc`'s Android catalog."""
    if loc in ANDROID_FOLDERS:
        return ANDROID_FOLDERS[loc]
    lang, _, rest = loc.partition("-")
    if not rest:
        return f"values-{lang}"
    if len(rest) == 4:  # a script, e.g. sr-Latn
        return f"values-b+{lang}+{rest}"
    return f"values-{lang}-r{rest.upper()}"


LANGUAGE_NAMES = {
    "en": "English",
    "bg": "Bulgarian",
    "ca": "Catalan",
    "cs": "Czech",
    "da": "Danish",
    "de": "German",
    "es": "Spanish",
    "fi": "Finnish",
    "fr": "French",
    "he": "Hebrew",
    "hr": "Croatian",
    "hu": "Hungarian",
    "id": "Indonesian",
    "it": "Italian",
    "ja": "Japanese",
    "ko": "Korean",
    "nb": "Norwegian Bokmål",
    "nl": "Dutch",
    "pl": "Polish",
    "pt": "Brazilian Portuguese",
    "pt-PT": "European Portuguese",
    "ru": "Russian",
    "sv": "Swedish",
    "tr": "Turkish",
    "uk": "Ukrainian",
    "zh": "Simplified Chinese",
    "zh-Hant": "Traditional Chinese",
}


def plezilo_locales() -> list[str]:
    names = os.listdir(os.path.join(ROOT, "lib", "i18n"))
    return sorted(n[: -len(".i18n.json")] for n in names if n.endswith(".i18n.json"))


def section_titles(path: str) -> dict[str, str]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {k: v for k, v in sorted(data.items()) if k.startswith(PREFIX) and isinstance(v, str) and v.strip()}


def _android_nodes(path: str) -> list[tuple[str, str, str]]:
    """(name, text, preceding comment) for every <string> of one strings_catalog.xml."""
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        root = ET.parse(path, parser=parser).getroot()
    except (OSError, ET.ParseError):
        return []
    out = []
    comment = ""
    for node in root:
        if node.tag is ET.Comment:
            comment = node.text or ""
            continue
        if node.tag == "string" and node.get("name"):
            out.append((node.get("name"), "".join(node.itertext()), comment))
        comment = ""
    return out


_SHARED_KEY = re.compile(r"shared (?:title )?key `(home\.section\.[^`]+)`")
_COMMENT_PLACEHOLDER = re.compile(r"\{(\w+)\}:")


def android_specs(english_path: str) -> dict[str, tuple[str, tuple[str, ...]]]:
    """Android string name -> (catalog key, placeholder names) for ANDROID_KEYS and every
    home_section_* string of the English catalog. The key and the names come from the
    string's comment (`shared title key `home.section.x``, `{title}: ...`)."""
    specs = dict(ANDROID_KEYS)
    for name, text, comment in _android_nodes(english_path):
        if not name.startswith("home_section_"):
            continue
        m = _SHARED_KEY.search(comment)
        key = m.group(1) if m else name.replace("_", ".")
        names = tuple(_COMMENT_PLACEHOLDER.findall(comment))
        if len(re.findall(r"%\d+\$s", text)) > len(names):
            print(f"{name}: its comment names no placeholder; left out", file=sys.stderr)
            continue
        specs[name] = (key, names)
    return specs


def android_strings(path: str, specs: dict[str, tuple[str, tuple[str, ...]]] | None = None) -> dict[str, str]:
    """The `specs` entries (default ANDROID_KEYS) of one strings_catalog.xml, as catalog key -> text
    with {named} placeholders."""
    specs = ANDROID_KEYS if specs is None else specs
    out = {}
    for name, text, _ in _android_nodes(path):
        spec = specs.get(name)
        if spec is None:
            continue
        key, names = spec
        # Android resource escapes.
        text = re.sub(r"\\([\'\"@?\\])", r"\1", text).replace("\\n", "\n")

        def named(m: re.Match) -> str:
            index = int(m.group(1)) - 1
            return "{" + names[index] + "}" if 0 <= index < len(names) else m.group(0)

        text = re.sub(r"%(\d+)\$s", named, text)
        if "%" in text.replace("%%", "") or not text.strip():
            continue  # a placeholder this script cannot name
        out[key] = text.replace("%%", "%")
    return dict(sorted(out.items()))


def android_repo_source(android_dir: str) -> str | None:
    """'Silo-Server/silo-android at <commit> (catalog release <release>)' from a silo-android
    checkout: the last commit that changed the catalogs and its `.silo-translations` version."""
    try:
        top = subprocess.run(
            ["git", "-C", android_dir, "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
        commit = subprocess.run(
            ["git", "-C", android_dir, "log", "-1", "--format=%h", "--abbrev=9", "--", "."],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        with open(os.path.join(top, ".silo-translations"), encoding="utf-8") as f:
            m = re.search(r"^version=(\S+)", f.read(), re.M)
    except (OSError, subprocess.CalledProcessError):
        return None
    if not commit or not m:
        return None
    return f"Silo-Server/silo-android at {commit} (catalog release {m.group(1)})"


def android_source_line(catalogs: str) -> str:
    """'silo-android at <commit> (catalog release <release>)' from the vendored NOTICE.md."""
    try:
        with open(os.path.join(catalogs, "NOTICE.md"), encoding="utf-8") as f:
            notice = f.read()
    except OSError:
        return "Silo-Server/silo-android"
    m = re.search(r"Silo-Server/silo-android at (\w+)\s*\(catalog release ([^,)]+)", notice)
    if not m:
        return "Silo-Server/silo-android"
    return f"Silo-Server/silo-android at {m.group(1)} (catalog release {m.group(2)})"


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


def notice_text(
    locales: list[str], android_source: str | None, roku_source: str | None, roku_locales: list[str]
) -> str:
    languages = textwrap.fill(
        "Languages: " + ", ".join(LANGUAGE_NAMES.get(loc, loc) for loc in locales) + ".", width=78
    )
    extra = ", ".join(f'"{key}"' for key, _ in ANDROID_KEYS.values())
    keys = f'"home.section.*" and {extra}' if android_source else '"home.section.*"'
    sources = ""
    if android_source:
        sources += f"""
  {android_source}
  android-shared/src/androidMain/res/values*/strings_catalog.xml
  (Android's %1$s placeholders written as named {{placeholders}})
"""
    if roku_source and roku_locales:
        names = ", ".join(LANGUAGE_NAMES.get(loc, loc) for loc in roku_locales)
        lead = textwrap.fill(f"and, for {names}:", width=78) + "\n" if android_source else ""
        sources += f"""
{lead}  {roku_source}
  locale/<language>/strings.json
"""
    included = textwrap.fill(
        f"Only the {keys} entries are included, unmodified apart from being copied into one JSON file "
        "per language. The source of these files is the catalogs named above; "
        "scripts/silo_catalog_strings.py in Plezilo's source regenerates them.",
        width=78,
    )
    intro = textwrap.fill(
        'The translated titles of the rows a Silo server words itself (Home sections and recommendation '
        'rows, catalog keys "home.section.*")'
        + (
            " and the line naming the profile that shared a collection and the heading of a title page's "
            f'"Also in" row (catalog keys {extra})'
            if android_source
            else ""
        )
        + " in this folder are taken from Silo's translation catalogs:",
        width=78,
    )
    return f"""SILO TRANSLATIONS — NOTICE
==========================

{intro}
{sources}
{languages}

Copyright (c) their authors (Silo Media L.L.C. and contributors).

These strings are licensed under the GNU Affero General Public License,
version 3 or (at your option) any later version; the full text is in
LICENSE.txt beside this file and at https://www.gnu.org/licenses/agpl-3.0.html.
Plezilo itself is licensed under the GNU General Public License, version 3,
whose section 13 permits combining it with work under the AGPL.

{included}

"Silo" is a trademark of Silo Media L.L.C. Plezilo is not made or endorsed by
Silo Media L.L.C.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--catalogs",
        default=os.path.join(os.path.dirname(ROOT), "siku", "third_party", "silo-translations"),
        help="the vendored silo-translations folder, for its roku/ catalogs and default android/ folder "
        "(default: ../siku/third_party/silo-translations)",
    )
    parser.add_argument(
        "--license",
        default=None,
        help="the AGPL-3.0 text to copy as LICENSE.txt (default: the catalogs' project LICENSE)",
    )
    parser.add_argument(
        "--android-catalogs",
        default=None,
        help="silo-android's res folder holding values*/strings_catalog.xml (default: <catalogs>/android)",
    )
    parser.add_argument(
        "--android-source",
        default=None,
        help="how NOTICE.txt names the Android catalogs (default: read from the silo-android checkout, "
        "else <catalogs>/NOTICE.md)",
    )
    args = parser.parse_args()
    android_dir = args.android_catalogs or os.path.join(args.catalogs, "android")
    specs = android_specs(os.path.join(android_dir, ANDROID_FOLDERS["en"], "strings_catalog.xml"))
    android_english = android_strings(os.path.join(android_dir, ANDROID_FOLDERS["en"], "strings_catalog.xml"), specs)
    android_has_sections = any(k.startswith(PREFIX) for k in android_english)
    if not android_english:
        print(f"no Silo strings in {android_dir}; reading the roku catalogs only", file=sys.stderr)

    roku = os.path.join(args.catalogs, "roku")
    roku_english = section_titles(os.path.join(roku, FOLDERS["en"], "strings.json")) if os.path.isdir(roku) else {}
    english = {**roku_english, **android_english}
    if not any(k.startswith(PREFIX) for k in english):
        print("no English catalog with home.section.* entries", file=sys.stderr)
        return 1

    os.makedirs(OUT, exist_ok=True)
    written = []
    roku_locales = []
    for loc in plezilo_locales():
        target = os.path.join(OUT, f"{loc}.json")
        folder = android_folder(loc)
        table = android_strings(os.path.join(android_dir, folder, "strings_catalog.xml"), specs)
        table = {k: v for k, v in table.items() if k in android_english}
        source = folder
        if not (android_has_sections and any(k.startswith(PREFIX) for k in table)):
            roku_path = os.path.join(roku, FOLDERS.get(loc, loc), "strings.json")
            sections = section_titles(roku_path) if os.path.isfile(roku_path) else {}
            # Only keys the English catalog has: the resolver falls back to English.
            sections = {k: v for k, v in sections.items() if k in english}
            if sections:
                table = {**sections, **{k: v for k, v in table.items() if not k.startswith(PREFIX)}}
                source = f"roku {FOLDERS.get(loc, loc)}"
                roku_locales.append(loc)
        if not any(k.startswith(PREFIX) for k in table):
            if os.path.exists(target):
                os.remove(target)
            continue
        with open(target, "w", encoding="utf-8") as f:
            json.dump(table, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        written.append(loc)
        print(f"{loc}: {len(table)} of {len(english)} strings (from {source})")

    license_candidates = [args.license] if args.license else [
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.catalogs))), "LICENSE"),
        os.path.join(os.path.abspath(android_dir), "..", "..", "..", "..", "LICENSE"),
    ]
    license_text = ""
    for license_src in license_candidates:
        try:
            with open(license_src, encoding="utf-8") as f:
                license_text = f.read()
        except OSError:
            continue
        if "GNU AFFERO GENERAL PUBLIC LICENSE" in license_text:
            break
    if "GNU AFFERO GENERAL PUBLIC LICENSE" not in license_text:
        print(f"{', '.join(license_candidates)}: not the AGPL text; pass --license", file=sys.stderr)
        return 1
    with open(os.path.join(OUT, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(license_text)

    ordered = ["en"] + [loc for loc in written if loc != "en"]
    android_source = None
    if android_english:
        android_source = args.android_source or android_repo_source(android_dir) or android_source_line(args.catalogs)
    roku_source = source_line(args.catalogs) if roku_locales else None
    with open(os.path.join(OUT, "NOTICE.txt"), "w", encoding="utf-8") as f:
        f.write(notice_text(ordered, android_source, roku_source, [loc for loc in ordered if loc in roku_locales]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
