# Plezilo (Plezy with Silo) — preview change log

What changed in each preview (Android, and Windows and macOS where the release has them), in plain language. Each `## silo-preview-…` section is copied onto the GitHub release page with that tag by `.github/workflows/silo-release-notes.yml` whenever this file changes. Write the next preview's notes under `## Next preview` before pushing its `[release-apk]` commit; the build puts them on the new release, and the next edit of this file should rename the heading to the new tag.

## Next preview

## silo-preview-2.28.0

Released November 12, 2026. Android and Windows.

- **Silo movies follow your Silo profile's subtitles and audio:** a Silo movie now starts with the subtitles and audio language your Silo profile is set to (Off, Auto or Always, its language, forced subtitles), like episodes already did and like Silo's own apps. Before, movies used Plezilo's own rules and ignored the profile. If you have set Settings › Playback › Subtitles › "Default subtitles" to None or a language, that still wins; left on "Server default", the Silo profile decides.

## silo-preview-2.27.0

Released November 12, 2026. Android and Windows.

- **Jump to a letter in Silo libraries (from Silo's Android app):** when a Silo library is sorted by title, the A–Z bar now scrolls the grid to the first title under the letter you pick instead of showing only that letter's titles, just as it does for Plex libraries. The bar lists only letters that have titles, follows along as you scroll, works with filters, and now also appears on phones. Servers that don't have Silo's letter index yet keep the old A–Z filter.

## silo-preview-2.26.6

Released November 12, 2026. Android and Windows.

- **AI subtitles from audio say what they are doing:** the progress line now reads "Transcribing…" for a transcription and "Transcribing and translating…" only when the subtitles are also being translated, instead of "Translating…" for everything.
- **Untagged audio is transcribed only:** when the audio track has no language tag, Plezilo now asks Silo just to transcribe it (the server works out the language) instead of transcribing and translating, which slowed every part of the job. If the audio turns out to be in a different language from the one you picked, the subtitles stay in the spoken language; pick a tagged audio track or translate them afterwards.

## silo-preview-2.26.5

Released November 11, 2026. Android and Windows.

- **Silo badges are readable again:** since 2.26.4 badge text on Silo posters was cut short ("108…" instead of "1080p", "EA…", "5…", and an empty box where "CC" belonged). The text picked up a little extra letter spacing from the app's theme, so it no longer fit the space measured for it. Badges now draw their full text.

## silo-preview-2.26.4

Released November 11, 2026. Android and Windows.

- **Silo posters look like Silo's own apps:** a poster's top-right corner now always shows Silo's green check on a watched title, or how many episodes are left on a series or season you have started, even when Silo's badges are turned off (it replaces Plezilo's own check and unwatched count on Silo posters; landscape cards keep Plezilo's check). Badge icons are the same drawings Silo's website uses, Dolby Vision gets its mark, text has Silo's letter spacing, badges along the bottom move up above a progress bar on posters too, and an uploaded badge logo never runs past its badge. Plex, Jellyfin and Emby cards are unchanged.

## silo-preview-2.26.3

Released November 11, 2026. Android and Windows.

- **Downloads use less battery on Android (from upstream Plezy):** while you watch a downloaded video with the mpv player, Plezilo reads ahead half a second at a time instead of after every frame, so the phone or TV works less during playback. Streaming is unchanged.

## silo-preview-2.26.2

Released November 10, 2026. Android and Windows.

- **Faster video start on Android (from upstream Plezy):** the mpv player no longer loads seven built-in scripts Plezilo never uses, so videos start a little sooner and each player uses less memory.

## silo-preview-2.26.1

Released November 9, 2026. Android and Windows.

- **Voice search on Android 11 Google TV:** on Google TV devices still on Android 11, the voice search button now works. Plezilo listens through the TV's speech service itself there, asks once for microphone access, and shows a small box with what it heard (from Silo Android #860). Other devices work as before.
- **Fixes from upstream Plezy (version 2.26):**
  - Dolby Vision no longer plays green on a Fire TV Stick 4K with mpv and "Match content frame rate" on: the TV switches its refresh rate before the video starts.
  - Pausing, leaving Plezilo and coming back no longer leaves the picture black on Android until you press play.
  - The cosmetic purchase is now called "Theme & Icon Pack".

## silo-preview-2.25.22

Released November 8, 2026. Android and Windows.

- **Default subtitles:** Settings › Playback › Subtitles has a new "Default subtitles" choice for every server: Server default (as before), None, or a language, with "Subtitle type" Regular or Forced only. Every video then starts with that choice: None turns subtitles off; Regular turns on the language's full subtitles (its forced track if that's all there is, and the server's usual pick if the language is missing); Forced only turns on just the lines for foreign speech and signs, and leaves subtitles off when there are none. A subtitle you pick while watching still carries on to the next episode. While a language or None is set, it takes the place of the subtitle a server remembers for a show.

## silo-preview-2.25.21

Released November 8, 2026. Android and Windows.

- **Fixes from upstream Plezy:**
  - Continue Watching posters no longer flip between the series and season poster when you come back from the player.
  - With "Ask for profile on app open" on, coming back to Plezilo with a video open now asks for the profile too, and keeps the video paused until one is chosen.
  - In Watch Together, a guest who switches to another version of the room's video (1080p to 4K, say) stays in sync with the room.

## silo-preview-2.25.20

Released November 8, 2026. Android and Windows.

- **Air dates on episode pages:** on phones, tablets and computers an episode's page now shows when it aired, as the TV layout already did. Silo episodes have no year of their own, so their pages showed no date at all before. Silo episodes are dated by their air date, like in Silo's own apps.

## silo-preview-2.25.19

Released November 8, 2026. Android and Windows.

- **Running times for Silo titles:** a Silo title whose server has no running time on record no longer shows "0s" on its page and cards. Plezilo now uses the length the server measured from the file, like Silo's own apps, and shows no time at all when neither is known.

## silo-preview-2.25.18

Released November 7, 2026. Android and Windows.

- **AI subtitles show up within seconds:** when you use Translate with AI (or AI subtitles from the audio) on a Silo server, Plezilo now shows the translated lines for the scene you're watching as soon as the server makes them, like Silo's website does, instead of waiting minutes for the whole file. They appear where subtitles go, with your original subtitle hidden meanwhile, and the finished track replaces them when the server is done. On a Silo server without this live connection, or if it can't be opened, Plezilo waits for the finished file as before.

## silo-preview-2.25.17

Released November 7, 2026. Android and Windows.

- **Fixes from upstream Plezy:**
  - A title you have in two libraries (an HD and a 4K copy, say) keeps its Select Version choice in Continue Watching when a server comes online after Discover first loaded.
  - Leaving fullscreen or closing the player while the display was switching to the video's refresh rate (or HDR on Windows) no longer leaves the screen in that mode afterwards.
  - On Android the anime mappings download now checks the server's certificate against the system's certificate authorities only, like Plezilo's other fixed downloads.

## silo-preview-2.25.16

Released November 6, 2026. Android and Windows.

- **Remove a failed request:** in Requests, a request of yours that failed without delivering anything now has a Remove button (also on the title's page). Plezilo asks first, naming the title, then removes it and lets you request the title again. A request that delivered one quality before failing keeps its record. If the request changed since the list loaded (an administrator retried it, say), Plezilo shows its current state and says why it wasn't removed. This needs a Silo server that supports removing failed requests; older servers show no button.
- **Voice search on Android TV and Fire TV:** the search screen has a microphone button right of the search field. Press it and speak a title; your TV's own voice recogniser listens through the remote and Plezilo searches for what you said and moves to the results. This also works on Google TV, where Gboard's mic key didn't type into Plezilo. The button only shows when the TV has a speech recogniser installed.

## silo-preview-2.25.15

Released November 6, 2026. Android and Windows.

- **Audiobooks from your Silo server:** Silo audiobook libraries now show in Plezilo. Each book has a page with its authors, narrators, parts and chapters, and Play, Resume or Start over. The player saves your place on the server, moves by chapter or 30 seconds, plays at 0.75× to 2×, and works from the lock screen and notifications. If the server drops the session it picks up where it was; if an administrator stops it, Plezilo says so. (Silo has no music libraries yet, so there's nothing to show for music.)
- **Requests and Calendar for Silo:** your profile menu has a Calendar with the week's new episodes and movie releases (Following, Trending or All) and badges like PREMIERE and FINALE, and — when your Silo server has requests on — a Requests page to search, request and follow movies and series. Search also shows titles "Available to request".
- **Series remember your audio and subtitles:** the audio and subtitle tracks you pick for a show on a Silo server carry over to its next episodes on any device, and episodes follow your Silo profile's subtitle setting (Off, Auto or Always).
- **Silo's download list:** downloads from a Silo server now show in the server's download list and count toward its limits; deleting one removes it there too, and if an administrator removes a download, Plezilo deletes your copy and tells you. Where the server can convert downloads, you can pick a smaller copy (for example "5 Mbps · up to 1080p").
- **Fix a Silo server without removing it:** the Silo server on a profile's page has "Sign in again" and "Edit address", and the "Session expired" banner signs you in again directly. Your profiles and downloads stay, and the old session is signed out on the server.
- **Safer sign-in:** if a Silo server only answers over plain HTTP, Plezilo asks before sending your password or code, and marks the server "Not encrypted".
- **Fixes:**
  - A Silo server that's down is no longer checked every few seconds; Plezilo checks less and less often (up to every 10 minutes) and notices when it's back.
  - Signing in again signs the old session out on the server instead of leaving it in the device list.
  - Copied logs keep hiding your Plex, Jellyfin and Emby sign-ins however often Silo renews its own.
  - On Android TV the microphone question only appears when Gboard is the keyboard; Fire TV and other keyboards aren't asked.
  - Plezy's update-feed details are gone from the Mac and Windows apps.

## silo-preview-2.25.14

Released November 6, 2026. Android and Windows.

- **Silo's card badges on Silo posters and episode pictures:** posters, wide cards and episode pictures from a Silo server now show the badges your Silo profile chose in Silo's web app, such as 4K, Dolby Vision, Atmos, the release type or a rating, in the same places and style (including the combined "4K DV Atmos" badge and pictures your server's admin uploaded). A watched title shows Silo's green check, and a series or season you have started shows how many episodes are left, in place of Plezilo's own marks. If the profile has badges turned off, or the server doesn't offer them, cards look as before. Plex, Jellyfin and Emby cards don't change. Changes you make in Silo show up the next time you open Home.
- **From upstream Plezy:** the player can remember the zoom you pick for a show, a library or everywhere; subtitles line up with the picture on Amlogic and MediaTek TV boxes; and a page opened over the main screen gets the remote's focus straight away.

## silo-preview-2.25.13

Released November 5, 2026. Android and Windows.

- **Hold OK on the remote for more options (Android TV and Fire TV), from upstream Plezy:** list rows that have a second action, such as choosing a secondary subtitle track in the player's subtitle menu, now open it when you hold OK (or press the remote's menu key). Before, that action only worked with touch.

## silo-preview-2.25.12

Released November 5, 2026.

*Android and Windows only: previews no longer include a Mac version unless one is requested. The last Mac version is 2.25.11.*

- **Sign in several Silo accounts from your phone at once (Android TV and Google TV):** with Silo's phone app (a version that lists your accounts on the TV card), pick several accounts, on one server or several, and send them to the TV in one go. Each account is approved with its own code on your phone. If one doesn't work, the others still sign in. When your phone is done (or you press Continue on the TV), Plezilo asks which Silo profile to use for each account, then shows where each one went. A second account on a server your Plezilo profile already uses gets a new Plezilo profile of its own, as before; accounts on different servers share your profile. Accounts you didn't finish setting up are signed out again if you leave the screen.
- **Safer phone sign-in on servers that support it:** on an HTTPS server that checks it, each sign-in from your phone is tied to that phone session, so only this TV can collect the sign-in your phone approved.
- **No more title flashing before a show's logo on downloaded items:** when you open a downloaded movie or show offline, its name now waits a moment for the logo instead of flashing up first (it still shows if the logo is missing or slow).

## silo-preview-2.25.11

Released November 5, 2026.

*The Mac version was added a little later (GitHub's Mac build machines were busy when it was first built).*

- **Voice typing on Google TV and Android TV:** the keyboard's microphone can now type into Plezilo's search and other text fields. The first time you open the keyboard in Plezilo on a TV, it asks for permission to use the microphone; choose Allow. If you said no, you can turn it on later in the TV's Settings › Apps › Plezilo › Permissions.

## silo-preview-2.25.10

Released November 5, 2026.

- **Finding out why voice typing types nothing (Android TV and Google TV):** speaking into Gboard's microphone in a Plezilo text field still doesn't type anything; this preview isn't the fix yet. It adds a log you can switch on with a computer (`adb shell setprop log.tag.PleziloTextInput DEBUG`, then restart Plezilo) that records what the keyboard sends to the field and whether the field took it, so one capture shows where the words go. It records only lengths, never what you typed or said.

## silo-preview-2.25.9

Released November 5, 2026. Android, Windows and Mac. Mac users coming from 2.25.7 also get everything new in 2.25.8 (more than one Silo account per server, and Plezy's download fixes).

- **The remote's Stop button leaves the player (Android TV and Fire TV):** pressing Stop now ends playback and closes the player from anywhere, even with a menu open or while loading, like Silo's own TV app. Before, the picture just froze and Play couldn't start it again.

## silo-preview-2.25.8

Released November 4, 2026.

*No Mac version of 2.25.8: GitHub's Mac build machines weren't available. On a Mac, install 2.25.9 instead, which includes everything below.*

- **More than one Silo account on the same server:** you can now add a second account (or a second Silo profile) on a Silo server you already use, as Silo's own apps now allow. If the Plezilo profile you are adding it to already uses another account on that server, Plezilo puts the new account in a Plezilo profile of its own and tells you its name, so both accounts keep working; switch profiles to change account. Each account keeps its own sign-in, watched marks, Continue Watching and downloads, signing in again as the same account updates it instead of adding it twice, and removing one account signs out only that one. Profile settings and "Borrow from another profile" now show which account a Silo server signs in as.
- **From upstream Plezy:** downloads on Windows, macOS and Linux are no longer slowed down by the free-space check, and on iPhone and iPad downloaded videos are no longer copied into your iCloud backup.

## silo-preview-2.25.7

Released November 3, 2026.

*The Mac version was added on November 4 (GitHub's Mac build machines were unavailable when it was first built). Also new since the last announcement (2.25.6): libraries with box sets keep loading on newer Silo servers.*

- **Watched marks for Silo:** movies and episodes you have watched now show their check mark on their own page, in a season's episode list and in downloads (they used to look unwatched there, while Home cards were right). A show's page and its seasons show how many episodes you have left. Downloaded episodes that were wrongly reset to unwatched are corrected at the next sync while online.
- **Sign in from your phone (Android TV and Fire TV):** while Plezilo's "Add Silo server" screen is open, Silo's phone app on the same Wi‑Fi now lists your TV, just as it lists a TV running Silo's own app. Pick it on your phone and choose your server; Plezilo asks "Allow this setup?", shows a sign-in code, your phone checks the same code and approves it, and you go straight to choosing your profile. With a code already on screen, the phone can approve that code too. Your password and sign-in tokens never travel over your home network: the server hands them to Plezilo directly. Plezilo signs in to one server at a time, so pick one server on your phone.

## silo-preview-2.25.6

Released November 3, 2026.

- **Libraries with box sets keep loading:** Silo servers are dropping the option that showed a movie collection (such as all the Harry Potter films) as one box set card in a library grid, and newer servers refuse it, which would have left those libraries empty. Plezilo now lists a collection's movies as separate titles in the library grid, like Silo's own apps. Box sets are still there in search and on a movie's page.

## silo-preview-2.25.5

Released November 3, 2026.

- **Temporary passwords from your Silo admin:** if your Silo server's admin gave you a temporary password, signing in on a phone, tablet or computer no longer ends in an error. Plezilo asks you to choose your own password (type the temporary one, then your new one twice), saves it and carries on to your profiles. On a TV, Plezilo tells you to set the new password in Silo's phone app or website and then sign in again. Other screens now say the account has a temporary password instead of showing a confusing server message.
- **From upstream Plezy:** posters and backgrounds no longer reload over and over from your server while a window or screen is being resized.

## silo-preview-2.25.4

Released November 3, 2026.

- **YouTube trailers play inside Plezilo on Android TV and Fire TV:** trailers from a Silo server (and other YouTube trailers) now play in Plezilo's built-in YouTube player instead of opening the YouTube app, so you stay in the app. Buttons above the video go back or forward 10 seconds and pause or play, and the remote's play/pause, rewind and fast-forward buttons work too. Press Back to close the trailer. If YouTube doesn't allow a video to play inside other apps, it still opens in the YouTube app.

## silo-preview-2.25.3

**Plezy with Silo is now Plezilo** — released November 3, 2026.

- **New name and icon:** the app is now called Plezilo and has its own icon. Plezy's makers asked forks to use their own name, icon and services, so this fork now has its own.
- **It installs as a new app:** Plezilo appears next to your old "Plezy with Silo" app instead of replacing it. Open Plezilo, add your servers and sign in again, check everything works, then uninstall the old "Plezy with Silo" app. Downloads and settings from the old app don't carry over.
- **New download links and Downloader codes:** the always-newest Android links have moved. New Fire TV Downloader codes: **5985619** (32-bit, every Fire TV) and **8032572** (64-bit). The old codes still work but stay on the last "Plezy with Silo" version.
- **Switched off for now:** Trakt, MyAnimeList, AniList, Simkl and MDBList sync, Discord status, log upload and crash reports. They used the Plezy project's own services, which other apps aren't allowed to use. Copying your logs still works.
- **Links:** links that open the app now start with `plezilo://` instead of `plezy://`. Update any Home Assistant automations, shortcuts or NFC tags that used the old links.

**Also new**

- **From upstream Plezy:** shuffle a whole movie or TV library, a Genres tab in libraries (Silo libraries too), an offer to let the server convert a file when it reports its limit, a choice of copy when Continue Watching merges the same title from several places, display refresh-rate matching on macOS, and fixes for Android TV remotes, Dolby Vision letterboxing and servers showing offline by mistake.
- **Silo box sets:** in a library with box sets turned on, each film collection shows as one card, opens to its films in release order with Play for the next unwatched one, comes first in Search, and a movie's page shows the rest of its set.
- **Silo subtitles:** subtitle tracks an older Silo server can't play are no longer offered, so picking one can't leave you without subtitles. On current servers nothing changes.
- **Silo collections:** Delete and Add/Remove, which Silo servers always refuse, are no longer offered.

## silo-preview-2.25.2

**Subtitle search and AI subtitles for Silo** — released October 30, 2026. Installs over 2.25.1 as an update.

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
