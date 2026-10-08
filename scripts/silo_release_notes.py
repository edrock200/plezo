#!/usr/bin/env python3
"""Build GitHub release notes for Silo preview APKs from docs/silo-preview-changelog.md.

  silo_release_notes.py <changelog> <section> <out-file> [<branch> <sha>]

<section> is a release tag (`silo-preview-…`) or `Next preview`. Writes the section's text followed
by the standard install notes. A missing or empty section exits 3, unless <branch> and <sha> are
given (a new build): then the page gets a placeholder and the install notes, and a warning is printed.
"""

import sys

FOOTER = """
### Which APK
- `arm64-v8a`: most phones, tablets and Android TV devices (Shield, recent Fire TV, Google TV boxes).
- `armeabi-v7a`: older or 32-bit devices, including Chromecast with Google TV and many TV sticks.
- `x86_64`: emulators and x86 devices.

### Installing
These previews use Plezy's package id but not the store signing key: uninstall a store-installed Plezy
before installing one. A later preview installs over an earlier one as an update only when both are
signed with the same key; if Android refuses the update, uninstall the previous preview first.
"""


def section(text: str, name: str) -> str:
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if inside:
                break
            inside = line[3:].strip() == name
            continue
        if inside:
            out.append(line)
    return "\n".join(out).strip()


def main() -> int:
    changelog, name, out_file = sys.argv[1:4]
    with open(changelog, encoding="utf-8") as f:
        body = section(f.read(), name)
    built = len(sys.argv) >= 6
    if not body:
        if not built:
            return 3
        print(f"::warning::{changelog} has no '{name}' notes.")
        body = "Preview build; see the commit history for changes."
    source = ""
    if built:
        source = f"\n\nBuilt from `{sys.argv[4]}` at {sys.argv[5]}."
    with open(out_file, "w", encoding="utf-8") as f:
        f.write("### What's new\n\n" + body + source + "\n" + FOOTER)
    return 0


if __name__ == "__main__":
    sys.exit(main())
