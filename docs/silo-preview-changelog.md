# Plezy with Silo — preview change log

What changed in each Android preview, in plain language. Each `## silo-preview-…` section is copied onto the GitHub release page with that tag by `.github/workflows/silo-release-notes.yml` whenever this file changes. Write the next preview's notes under `## Next preview` before pushing its `[release-apk]` commit; the build puts them on the new release, and the next edit of this file should rename the heading to the new tag.

## Next preview

## silo-preview-2.22.4

**Windows version** — released October 8, 2026. The app is the same as 2.22.3; this release adds Windows. The Android files install over 2.22.3 as an update.

- **Windows:** Plezy with Silo is now available for Windows 10 and 11 (x64 and ARM), as an installer or a portable download. It installs over an existing Plezy and does not update itself to Plezy without Silo.
- **Windows downloads:** `windows-installer.exe` installs it (x64 or ARM is picked automatically); the `.7z` files are portable versions you unzip and run. The files are not code-signed, so Windows SmartScreen may warn the first time: choose More info, then Run anyway.

## silo-preview-2.22.3

**4K HDR plays in its original quality** — released October 8, 2026. Installs over the previous preview as an update.

- **4K HDR and Dolby Vision:** these titles (usually 4K HEVC) now play as the original file. Before, Plezy didn't tell the server it could handle HDR itself, so the server converted them to a lower-quality, non-HDR stream, which also loaded the server heavily.
- **Version numbers:** previews are now numbered 2.22.1, 2.22.2, 2.22.3 and so on, newest first on the releases page, and Settings › About shows the same number. (2.22.1 and 2.22.2 were built before this and show 2.22.0 inside the app.)

## silo-preview-2.22.2

**Fixes from a full code review** — released October 8, 2026. Installs over the previous preview as an update.

- **Big libraries:** jumping far down a large library is faster and no longer fails. If the library changes while you are scrolling, the list quietly reloads instead of erroring.
- **Seasons:** marking a season as watched (or rating or favoriting it) from an episode's season link now changes only that season. Before, it could change the whole show.
- **Watching:** if Plezy could not tell the server you stopped watching (for example the network dropped), it tries again the next time you play that title instead of leaving a stuck session on the server. Playback now needs a Silo server recent enough for Silo's own apps.
- **Signing in:** when the server ends your session, Plezy stops retrying in the background and simply asks you to sign in again. Sign-in codes that expire are replaced with a new one automatically, too many wrong PIN attempts now shows a clear message, and a missing profile picture no longer causes errors.
- **Downloads:** a downloaded title's details now open without a connection, and after restarting the app each Plezy profile's downloads stay with the right Silo account.
- **Speed:** Home rows and "play all episodes" lists load at the same time instead of one by one.
- **Smaller fixes:** "Remove from Continue Watching" works for every card, IMDb scores show on the right scale, some versions now show their running time, and Discord status no longer sends your Silo login along with cover art.

## silo-preview-2.22.1

**First preview: Silo support** — released October 8, 2026.

- **New:** connect Plezy to a Silo media server, next to Plex, Jellyfin and Emby, on phones, tablets and Android TV.
- **Signing in:** sign in with a code (scan the QR code or approve it from Silo on your phone) or with your username and password, then pick your Silo profile and enter its PIN if it has one. Servers on Silo's default port (8090) and accounts from company directories (LDAP) work.
- **Browsing:** your server's Home rows, Continue Watching, movie and TV libraries with sorting, filters and the A–Z bar, shows, seasons and episodes, cast pages, similar titles and search.
- **Watching:** the server picks whether to play the file as-is or convert it for your device. Subtitles, skip intro and credits, chapters and quality settings work, and your progress is saved to the server as you watch.
- **Your library:** mark things watched, favorite them and give 1–5 star ratings.
- **Downloads:** download movies and episodes in their original quality, with subtitles and artwork, to watch offline. Progress made offline is sent to the server when you reconnect. Download links never contain your login.
- **Like Silo's own apps:** tablets and TVs identify themselves correctly so the server applies the right settings, and the server is told when you are on mobile data.
- **Not yet available for Silo:** music, audiobooks and e-books, playlists, live TV, and signing in through a web browser.
- **Installing:** uninstall a Plezy installed from an app store first; this preview replaces it.
