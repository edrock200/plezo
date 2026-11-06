#!/usr/bin/env python3
"""Posts a Plezilo (Silo preview) release to a Discord channel webhook.

  DISCORD_WEBHOOK_URL=<url> python3 scripts/silo_announce_discord.py <tag> [<repo>]
  python3 scripts/silo_announce_discord.py --self-test

The message is the release's own notes (the plain-language section of
docs/silo-preview-changelog.md that silo-release-notes.yml puts on the release)
plus links to the release page and its downloads, grouped by platform. Run it
once the Android, Windows and macOS files are all attached. The webhook URL is a
secret: it comes from the environment and is never committed or printed.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def release(repo: str, tag: str) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "plezo-release"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


# Fire TV "Downloader" app codes (aftv.news short links) for the rolling plezilo-android-latest
# release, whose fixed-name APKs every preview replaces, so the codes never change. (The old codes
# 7329550 / 4196538 point at the retired silo-android-latest release; never announce them.)
# Entries: (label, code, abi).
DOWNLOADER_CODES: list[tuple[str, str, str]] = [
    ("Fire TV and Android TV sticks; 32-bit, also runs on 64-bit", "5985619", "armeabi-v7a"),
    ("Android phones, tablets and newer Android TV / Fire TV; 64-bit", "8032572", "arm64-v8a"),
]
LATEST_ABIS = [
    ("Fire TV and Android TV sticks; 32-bit, also runs on 64-bit", "armeabi-v7a"),
    ("Android phones, tablets and newer Android TV / Fire TV; 64-bit", "arm64-v8a"),
]
LATEST = "https://github.com/{repo}/releases/download/plezilo-android-latest/plezilo-{abi}.apk"


def downloader(repo: str) -> str:
    if DOWNLOADER_CODES:
        rows = [f"`{code}` · [aftv.news/{code}](http://aftv.news/{code}) · [{abi} APK]({LATEST.format(repo=repo, abi=abi)}) ({label})"
                for label, code, abi in DOWNLOADER_CODES]
        return "**Android & Fire TV — Downloader app codes** (always the newest preview):\n" + "\n".join(rows)
    rows = [f"[{abi} APK]({LATEST.format(repo=repo, abi=abi)}) ({label})" for label, abi in LATEST_ABIS]
    return ("**Android & Fire TV — direct links** (always the newest preview; Downloader codes for them "
            "are coming soon, until then type the link into Downloader):\n" + "\n".join(rows))


def downloads(assets: list) -> str:
    groups = {"Android": [], "Windows": [], "macOS": []}
    for a in assets:
        name, url = a["name"], a["browser_download_url"]
        if name.endswith("-x86_64.apk"):
            continue  # emulator build: on the release page, not in the post (the user's wish)
        if name.endswith(".apk"):
            stem = name.removesuffix(".apk")
            label = next((abi for abi in ("arm64-v8a", "armeabi-v7a") if stem.endswith("-" + abi)), stem.rsplit("-", 1)[-1])
            groups["Android"].append(f"[{label}]({url})")
        elif name.endswith(".exe"):
            groups["Windows"].append(f"[installer]({url})")
        elif name.endswith(".7z") or name.endswith(".zip"):
            groups["Windows"].append(f"[{name.rsplit('-', 1)[-1].split('.')[0]} portable]({url})")
        elif name.endswith(".dmg"):
            groups["macOS"].append(f"[dmg]({url})")
    return "\n".join(f"**{k}:** " + " · ".join(v) for k, v in groups.items() if v)


def with_wait(url: str) -> str:
    """The webhook URL with `wait=true` merged into its query, keeping what it already
    carries (e.g. `thread_id=` for a forum thread) and replacing an existing `wait`."""
    parts = urllib.parse.urlsplit(url)
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True) if k != "wait"]
    query.append(("wait", "true"))
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))


def self_test() -> int:
    base = "https://discord.com/api/webhooks/1/abc"
    assert with_wait(base) == base + "?wait=true"
    assert with_wait(base + "?thread_id=42") == base + "?thread_id=42&wait=true"
    assert with_wait(base + "?wait=false&thread_id=42") == base + "?thread_id=42&wait=true"
    assert with_wait(base + "?") == base + "?wait=true"
    assert with_wait(base + "#frag") == base + "?wait=true#frag"
    print("silo_announce_discord self-test passed.")
    return 0


def main() -> int:
    if sys.argv[1:2] == ["--self-test"]:
        return self_test()
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
        "username": "Plezilo",
        "embeds": [{"title": f"Plezilo {version} is out", "url": page,
                    "description": notes + links, "color": 0x4F46E5}],
        "allowed_mentions": {"parse": []},
    }
    req = urllib.request.Request(with_wait(url), data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "plezo-release"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"Posted {tag} to Discord (HTTP {resp.status}).")
    except urllib.error.HTTPError as e:
        # Never print the request (its URL is the webhook secret); the status says enough.
        print(f"Discord refused the post for {tag} (HTTP {e.code}).", file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print(f"Could not reach Discord for {tag} ({type(e.reason).__name__}).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
