#!/usr/bin/env python3
"""Build GitHub release notes for Silo preview APKs from docs/silo-preview-changelog.md.

  silo_release_notes.py <changelog> <section> <out-file> [<branch> <sha>]

<section> is a release tag (`silo-preview-…`) or `Next preview`. Writes the section's text followed
by the standard install notes. A missing or empty section exits 3, unless <branch> and <sha> are
given (a new build): then the page gets a placeholder and the install notes, and a warning is printed.
"""

import sys

INSTALL = (
    "These previews use Plezy's package id but not the store signing key: uninstall a store-installed "
    "Plezy before installing one. A later preview installs over an earlier one as an update only when "
    "both are signed with the same key; if Android refuses the update, uninstall the previous preview first."
)

WINDOWS_INSTALL = (
    "On Windows the installer replaces an installed Plezy (it uses Plezy's app id). The files are not code-signed, so SmartScreen may warn on first run: choose More info, then Run anyway. "
    "These builds do not check for updates, so they never replace themselves with Plezy without Silo."
)

MACOS_INSTALL = (
    "On macOS the app replaces an installed Plezy. It is not signed by Apple, so the first launch is blocked: "
    "open it once, then go to System Settings › Privacy & Security and choose Open Anyway (or run "
    "`xattr -dr com.apple.quarantine /Applications/Plezy.app` in Terminal). It does not update itself either."
)

# One line per paragraph or bullet: release pages render single line breaks as hard breaks.
FOOTER = f"""
### Which file
**Android** (`.apk`)
- `arm64-v8a`: most phones, tablets and Android TV devices (Shield, recent Fire TV, Google TV boxes).
- `armeabi-v7a`: older or 32-bit devices, including Chromecast with Google TV and many TV sticks.
- `x86_64`: emulators and x86 devices.

**Windows** (when attached)
- `windows-installer.exe`: installs on Windows 10/11, picking x64 or ARM automatically.
- `windows-x64-portable.7z` / `windows-arm64-portable.7z`: no install; unzip and run `plezy.exe`.

**macOS** (when attached)
- `macos.dmg`: macOS app for Apple silicon and Intel Macs; open it and drag Plezy to Applications.

### Installing
{INSTALL}

{WINDOWS_INSTALL}

{MACOS_INSTALL}
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
