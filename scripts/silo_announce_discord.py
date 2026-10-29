#!/usr/bin/env python3
"""Posts a Plezy-with-Silo preview release to a Discord channel webhook.

  DISCORD_WEBHOOK_URL=<url> python3 scripts/silo_announce_discord.py <tag> [<repo>]

The message is the release's own notes (the plain-language section of
docs/silo-preview-changelog.md that silo-release-notes.yml puts on the release)
plus links to the release page and its downloads, grouped by platform. Run it
once the Android, Windows and macOS files are all attached. The webhook URL is a
secret: it comes from the environment and is never committed or printed.
"""
import json
import os
import sys
import urllib.request


def release(repo: str, tag: str) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "plezo-release"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


# Fire TV "Downloader" app codes (aftv.news short links). They point at the rolling
# silo-android-latest release, whose fixed-name APKs every preview replaces, so they never change.
DOWNLOADER_CODES = [
    ("Fire TV and Android TV sticks; 32-bit, also runs on 64-bit", "7329550", "armeabi-v7a"),
    ("Android phones, tablets and newer Android TV / Fire TV; 64-bit", "4196538", "arm64-v8a"),
]
LATEST = "https://github.com/{repo}/releases/download/silo-android-latest/plezy-silo-{abi}.apk"


def downloader(repo: str) -> str:
    rows = [f"`{code}` · [aftv.news/{code}](http://aftv.news/{code}) · [{abi} APK]({LATEST.format(repo=repo, abi=abi)}) ({label})"
            for label, code, abi in DOWNLOADER_CODES]
    return "**Android & Fire TV — Downloader app codes** (always the newest preview):\n" + "\n".join(rows)


def downloads(assets: list) -> str:
    groups = {"Android": [], "Windows": [], "macOS": []}
    for a in assets:
        name, url = a["name"], a["browser_download_url"]
        if name.endswith(".apk"):
            label = name.rsplit("-", 1)[-1].removesuffix(".apk")  # arm64-v8a, armeabi-v7a, x86_64
            groups["Android"].append(f"[{label}]({url})")
        elif name.endswith(".exe"):
            groups["Windows"].append(f"[installer]({url})")
        elif name.endswith(".7z") or name.endswith(".zip"):
            groups["Windows"].append(f"[{name.rsplit('-', 1)[-1].split('.')[0]} portable]({url})")
        elif name.endswith(".dmg"):
            groups["macOS"].append(f"[dmg]({url})")
    return "\n".join(f"**{k}:** " + " · ".join(v) for k, v in groups.items() if v)


def main() -> int:
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not url:
        print("DISCORD_WEBHOOK_URL is not set; nothing posted.")
        return 0
    tag = sys.argv[1]
    repo = sys.argv[2] if len(sys.argv) > 2 else "edrock200/plezo"
    rel = release(repo, tag)
    version = tag.removeprefix("silo-preview-")
    notes = (rel.get("body") or "").strip() or "See the release page for what changed."
    page = rel.get("html_url") or f"https://github.com/{repo}/releases/tag/{tag}"
    links = f"\n\n{downloads(rel.get('assets') or [])}\n{downloader(repo)}\n[Release page]({page})"
    room = 4000 - len(links)
    if len(notes) > room:
        notes = notes[: room - 40].rsplit("\n", 1)[0] + "\n… (full notes on the release page)"
    payload = {
        "username": "Plezy with Silo",
        "embeds": [{"title": f"Plezy {version} with Silo is out", "url": page,
                    "description": notes + links, "color": 0xE5A00D}],
        "allowed_mentions": {"parse": []},
    }
    req = urllib.request.Request(url + "?wait=true", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "plezo-release"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(f"Posted {tag} to Discord (HTTP {resp.status}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
