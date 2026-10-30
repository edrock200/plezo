# Plezy with Silo — preview change log

What changed in each preview (Android, and Windows and macOS where the release has them), in plain language. Each `## silo-preview-…` section is copied onto the GitHub release page with that tag by `.github/workflows/silo-release-notes.yml` whenever this file changes. Write the next preview's notes under `## Next preview` before pushing its `[release-apk]` commit; the build puts them on the new release, and the next edit of this file should rename the heading to the new tag.

## Next preview

**Subtitle search and AI subtitles for Silo** — installs over 2.25.1 as an update.

- **Search subtitles:** in the player's subtitle menu, "Search subtitles" now works on Silo servers. Your server looks the title up with the subtitle providers it has set up, saves the one you pick, and Plezy switches to it straight away.
- **Translate with AI:** on Silo servers with AI subtitles turned on, the subtitle menu has "Translate with AI". Translate an existing subtitle, or make subtitles from an audio track, in the language you choose. It starts from where you are in the video, so the first lines arrive within seconds, and the new subtitles turn on by themselves when they're ready. You can close the menu and keep watching while it works; the menu shows the progress.
- **Subtitles saved on your server now show up:** subtitles that were downloaded or made by AI on your Silo server (from Plezo, Silo's own apps or the web) are now listed with the title's other subtitles. Before, Plezo left them out when it played the original file.

## silo-preview-2.25.1

**Plezy 2.25 and a full review of Silo support** — released October 28, 2026. Installs over 2.22.5 as an update. Previews are now numbered after the Plezy version they're built on, so this one is 2.25.1.

- **Plezy 2.25:** everything upstream Plezy added since 2.22, including `plezy://` links that open a title or switch profile, automatic intro and credits detection from chapters, Explore as a startup section, person pages with biography and dates, and many player and platform fixes.
- **Silo, watching:**
  - Movies and episodes you watch again now resume where you stopped.
  - The seek bar shows picture previews while you scrub, when your Silo server has made them.
  - Original quality no longer stops older Silo servers from converting a file your device can't play, and the false "transcode unavailable" message on lower quality settings is gone.
  - Skip-intro markers match the version you're playing, and external players (VLC, mpv) get a direct link.
- **Silo, browsing:**
  - Episodes show the show's own poster and background, even with spoiler protection on (recent Silo servers).
  - Every Silo row on Home and in libraries has "See all", and rows load faster on servers that support shorter rows.
  - Silo servers are shown with Silo's official icon.
- **Silo, staying signed in:**
  - A temporary server, proxy or network problem no longer signs you out of Silo; only a really expired login asks you to sign in again.
  - A Silo server that stops answering now shows as offline and comes back by itself.
  - Changing a Silo server's address or profile PIN no longer risks signing you out.
  - Removing a Silo server from Plezy also signs that device out on the server, and sharing a server with another Plezy profile no longer copies its login.
- **Silo sign-in:**
  - Signing in with a code behaves like Silo's TV app: an expired code is replaced on its own, a declined code says so and offers "Show a new code", and the screen says when the server can't be reached.
  - Leaving sign-in before picking a profile signs that session out on the server, and the profile step has "Change server".
  - A refused PIN shows the server's reason, Kids profiles are labelled, and screen readers read the sign-in code digit by digit.
  - On Apple TV the keyboard no longer covers the server address screen, and the code screen fits small TVs with the QR code beside the code.
- **Windows and macOS:** the Supporter themes and app icons are available, as in upstream Plezy's own downloads.

## silo-preview-2.22.5

**Trailers and extras for Silo** — released October 26, 2026.

- **Android: uninstall the previous preview first.** This build is signed with a new key (the old one expired from the build system's storage after a week without builds), so Android won't install it over 2.22.4 and says the app conflicts. Uninstalling removes your saved servers and downloads; sign in again afterwards. Windows and macOS install over the previous version as usual.
- **Trailers & extras:** movies and shows on a Silo server now show their trailers and extras (featurettes, behind the scenes and so on). They play in Plezy, and the Trailer button works for Silo titles.
- **YouTube trailers:** trailers that Silo lists from YouTube appear after the server's own. On phones, tablets and Macs they play inside Plezy in YouTube's own player; if a video doesn't allow that, Plezy opens it in the YouTube app or browser. Android TV opens them in the YouTube app (from the Trailer button), and Windows and Linux open them in your browser.

## silo-preview-2.22.4

**Windows and macOS versions** — released October 8, 2026. The app is the same as 2.22.3; this release adds Windows and macOS. The Android files install over 2.22.3 as an update.

- **Windows:** Plezy with Silo is now available for Windows 10 and 11 (x64 and ARM), as an installer or a portable download. It installs over an existing Plezy and does not update itself to Plezy without Silo.
- **macOS:** Plezy with Silo is now available for Macs (Apple silicon and Intel) as a `.dmg`: open it and drag Plezy to Applications. It is not signed by Apple, so the first time macOS blocks it: open it once, then go to System Settings › Privacy & Security and choose Open Anyway.
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
