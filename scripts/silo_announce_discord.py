#!/usr/bin/env python3
"""Posts a Plezilo (Silo preview) release to a Discord channel webhook.

  DISCORD_WEBHOOK_URL=<url> python3 scripts/silo_announce_discord.py <tag> [<repo>]
  python3 scripts/silo_announce_discord.py --self-test

The message is the release's own notes (the plain-language section of
docs/silo-preview-changelog.md that silo-release-notes.yml puts on the release)
plus links to the release page and its downloads, grouped by platform. Run it
once the Android and Windows files are attached. The webhook URL is a secret: it
comes from the environment and is never committed or printed.

Optional environment:
  GH_TOKEN / GITHUB_TOKEN  read the release with this token (avoids the anonymous API rate limit).
  WINDOWS_STATUS           "attached" (default), "failed" or "cancelled": anything but "attached"
                           adds a line saying the Windows files are missing for now.
A release carrying the asset ANNOUNCED_ASSET was already announced (the workflow uploads it after
posting); the script then posts nothing, unless --force is given.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ANNOUNCED_ASSET = "silo-preview-announced.txt"


def release(repo: str, tag: str, attempts: int = 4) -> dict:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "plezo-release",
               "X-GitHub-Api-Version": "2022-11-28"}
    token = (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            # 404 can be a release that is a moment from being visible; 403/429 a rate limit; 5xx GitHub.
            if attempt == attempts or e.code not in (403, 404, 429, 500, 502, 503, 504):
                raise
            reason = f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == attempts:
                raise
            reason = type(getattr(e, "reason", e)).__name__
        print(f"Reading release {tag} failed ({reason}); retrying.", file=sys.stderr)
        time.sleep(5 * attempt)
    raise AssertionError("unreachable")


def windows_note(status: str) -> str:
    status = (status or "attached").strip().lower()
    if status == "attached":
        return ""
    what = "was cancelled" if status == "cancelled" else "failed"
    return (f"**Windows:** the Windows build {what} for this preview, so its files are not on the release yet; "
            "they will be added there when a new Windows build succeeds.")


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
        return ("**Android & Fire TV — Downloader app codes** (always the newest preview):\n" + "\n".join(rows)
                + "\nKeep using the code you installed with: the 32-bit APK cannot update a 64-bit install "
                "(switching to 32-bit means uninstalling first).")
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
    assert windows_note("") == "" and windows_note("attached") == ""
    assert "failed" in windows_note("failed") and "cancelled" in windows_note("cancelled")
    print("silo_announce_discord self-test passed.")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--self-test"]:
        return self_test()
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not url:
        print("DISCORD_WEBHOOK_URL is not set; nothing posted.")
        return 0
    tag = args[0]
    repo = args[1] if len(args) > 1 else "edrock200/plezo"
    try:
        rel = release(repo, tag)
    except urllib.error.HTTPError as e:
        print(f"Could not read release {tag} from GitHub (HTTP {e.code}); nothing posted.", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"Could not reach GitHub for release {tag} ({type(getattr(e, 'reason', e)).__name__}); nothing posted.",
              file=sys.stderr)
        return 1
    assets = rel.get("assets") or []
    if not force and any(a.get("name") == ANNOUNCED_ASSET for a in assets):
        print(f"{tag} was already announced ({ANNOUNCED_ASSET} is on the release); nothing posted. Use --force to post again.")
        return 0
    version = tag.removeprefix("silo-preview-")
    notes = (rel.get("body") or "").strip() or "See the release page for what changed."
    page = rel.get("html_url") or f"https://github.com/{repo}/releases/tag/{tag}"
    status = windows_note(os.environ.get("WINDOWS_STATUS", ""))
    links = (f"\n\n{status + chr(10) if status else ''}{downloads(assets)}\n{downloader(repo)}"
             f"\n[Release page]({page})")
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
