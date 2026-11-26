# Plezilo (Plezy with Silo) — preview change log

What changed in each preview (Android, and Windows and macOS where the release has them), in plain language. Each `## silo-preview-…` section is copied onto the GitHub release page with that tag by `.github/workflows/silo-release-notes.yml` whenever this file changes. Write the next preview's notes under `## Next preview

## Next preview

- **Tofa posters and pictures show again:** no Tofa artwork loaded anywhere (posters, backdrops, episode pictures, profile pictures; Continue Watching showed empty cards). Plezilo now loads them the way Tofa's own apps do, so they appear.
- **Tofa Live TV appears:** Live TV stayed hidden for Tofa servers that have it, because Plezilo didn't tell the server it can play live channels. It does now, and channels play the way Tofa's own apps play them: provider and antenna channels as a live stream, channels made from your library from the programme on air right now. Favourite channels are now your Tofa favourites, the same as in Tofa's apps. *(please test)*
- **Cancel a scheduled Tofa recording:** in Live TV's *Recordings*, picking a scheduled recording now cancels it (after you confirm), as for other servers.
- **Continue Watching no longer offers other episodes as "versions":** when two of your servers have the same show, its Continue Watching card used to list each server's episode under *Select Version*, even when they were different episodes (for example S5 E19 on one server and S5 E15 on another). The card now shows the episode you watched most recently, and *Select Version* only appears when another server has that same episode.

## silo-preview-2.68.0

Released November 26, 2026. Android and Windows.

- **Tofa Discover and requests:** the profile menu now has *Discover* for each Tofa server: its featured titles, shelves, themes you can follow and *Coming soon*. A title's page shows whether you have it (*Open*), plays its trailer, lists its cast with their own pages, and lets you mark it *Seen it* or *Not interested*. Where your server takes requests, *Requests* lets you search for a movie or series and request it (in 4K too, where you may), shows how many requests you have left and follows the ones you made.
- **Tofa watch history:** *History* in the profile menu lists what this Tofa profile played, newest first. Remove one entry, or clear it all after confirming.
- **Switch Tofa profile without signing in again:** *Switch Tofa profile* in the profile menu lists the account's other Tofa profiles (with their pictures where the server provides them); pick one, enter its PIN if it has one, and Plezilo uses it from then on.
- **Subtitle search on Tofa:** while a Tofa title plays, the subtitle menu offers *Search subtitles*: pick a language, pick a result, and your server fetches it; the player switches to it once it arrives. A downloaded subtitle can be removed from the same place.
- **Movies split over several files:** a Tofa title stored as parts (cd1, cd2) now plays as one, with one seek bar across all parts, moving to the next part on its own and resuming in the part you were in. Finishing the last part marks the title watched.
- **Tofa's own scores:** Tofa titles show the server's critic and audience scores in words ("Tofa critics 85") next to IMDb, Rotten Tomatoes and Metacritic.
- **Finished Tofa recordings:** Live TV's *Recordings* tab now lists what was recorded under *Recorded*; pick one to watch it.
- Still not there for Tofa: cancelling one scheduled recording (Tofa's API has no way to do it; recording rules can be deleted), Watch Together and Tofa's remote control. Playing a Live channel follows the API as far as it is documented, so please report whether it works. All of this was built from Tofa's published API; please report what doesn't work.
- **Removing a Tofa connection works again:** after you had switched Tofa profiles, removing the Tofa connection left the previous profile's connection saved and still talking to the server. Remove now takes the whole sign-in away, and the server stays gone after a restart.
- **Switch a connection off without removing it:** each connection in a profile's list (Settings › Profiles) now has an on/off switch, for every server type. A switched-off connection stays saved with its sign-in, but Plezilo doesn't connect to it: nothing from that server appears on Home, in libraries, search, Live TV or Continue Watching. Its row is dimmed and marked *Disabled*, and *Remove* is still in its menu. Switch it back on and it returns without signing in again. The switch applies to every profile that uses the connection.

## silo-preview-2.67.0

Released November 26, 2026. Android and Windows.

- **New "Expand on Focus" option:** in Settings › Appearance (Library & Cards). When it's on and you move to a poster in a row (Home, a library's Recommended page, More Like This and other rows on a detail page), the poster smoothly widens into a wide card showing the title's background art, with its name or logo on top; the cards beside it slide aside and it shrinks back when you move on. It works with a TV remote and the keyboard. Titles without background art stay as posters, and library and search grids keep their usual size. It's off unless you turn it on.
- **Every row in a Tofa library's Recommended tab:** a Tofa library's *Recommended* tab used to show only Recently Added. It now shows Continue Watching, Recently Added, Suggested for You and Ready to Binge for that library, Recently Released, Top Rated, Unwatched and rows for the library's main genres, each only when your server offers it. *View all* on any of them pages through the whole list.
- **Tofa Home rows that were missing:** Suggested for You, Ready to Binge, your Watchlist and the collections your server pins to Home now appear on Home (Plezilo only read the per-library rows before). Recently Added comes once per section of your server's Browse page, as in Tofa's own apps.
- **Tofa collections:** each Tofa library's *Collections* tab lists your server's collections (franchises, curated ones, and your own collections and lists). Opening one shows the titles of it you have; *Play* and *Shuffle* play them, series with their episodes in order. Search finds collections too. Plezilo doesn't edit Tofa collections.
- **Tofa Live TV:** when your Tofa server has Live, it appears in Plezilo's *Live TV*: channels, the guide, playing a channel and favourite channels (kept on this device). You can record a programme the guide marks recordable, once or every time it airs (new episodes only, any channel, keep the last few), and see, edit and delete your recording rules under *Recordings*. Tofa offers apps no way to cancel one scheduled recording, so Plezilo says so; finished recordings are not listed in Plezilo yet. *(please test: playing a channel follows the API as far as it is documented)*
- **Cast, people search and trailers on Tofa:** picking someone in a Tofa title's cast opens the titles you have with them and their biography, search finds people, and a title's trailer plays from its page.
- **Tofa Home stays up to date:** when you watch or mark something on another device, Plezilo's Home reads your Tofa rows again; on servers that don't send these updates it checks every two minutes while Home is open.
- **Explore finds titles on your Tofa server:** titles from Explore and other catalogs are now matched to your Tofa library, so you can play them from there.

## silo-preview-2.66.0

Released November 26, 2026. Android and Windows.

- **Signing in to Tofa with your account finds a way to your server:** after you sign in with the code and pick your server from the list, Plezilo used to try only the address Tofa's cloud gives for it, and gave up with "Couldn't finish signing in" when that address doesn't answer from your device (common when the server is reached through its own domain, or its port isn't open to the internet). It now tries every address Tofa lists for the server, at home, over the internet (including the server's custom address) and through Tofa's relay, and uses the first that answers. If none does, it says it can't reach the server instead of a vague error. Playing through the relay works now too: Plezilo's address check didn't send your sign-in to the relay, so it never picked it.

## silo-preview-2.65.0

Released November 25, 2026. Android and Windows.

- **Tofa servers can now be downloaded for offline viewing:** on a Tofa movie or episode, *Download* works as it does for Silo. When the server offers smaller versions, Plezilo asks which quality you want (Original, or a smaller copy with its size; the server prepares a smaller copy first, and the download waits until it is ready). Downloads keep their audio tracks, text subtitles and intro/credits skip buttons, and play without a connection. Where you stop while offline, and what you mark watched, goes to your Tofa server the next time Plezilo is online. Deleting a download tells the server too.
- **Sorting and filters in Tofa libraries:** the library's Sort menu now lists the sorts your Tofa server offers (title, date added and so on), and Filters offers genre, watch status (unwatched, in progress, watched), quality, year and "Available only". The A–Z bar jumps by the letters the server lists, and the Genres tab lists the library's genres.
- **More Home rows for Tofa:** Home now shows Recently Added (also per library), Suggested for You, Ready to Binge (complete seasons you have not started), your Watchlist and the collections your server pins to Home, next to Continue Watching.
- **Chapters, skip buttons and seek-bar previews on Tofa:** Tofa episodes and movies now show their chapters, offer Skip Intro and Skip Credits where your server found them, and show a picture while you scrub the seek bar.
- **Tofa watchlist:** a Tofa movie or series page, and its card's menu, can add it to or remove it from your Tofa watchlist (Tofa has no favorites, so there is no heart).
- **Tofa away from home:** Plezilo now finds the best way to reach your Tofa server, as Tofa's own apps do: your home network first, then a direct connection over the internet, then Tofa's relay, and it switches when the one in use stops answering. When a video plays through the relay, Plezilo says so: its quality is limited to the relay's bandwidth (2 Mbps on Tofa's free tier). You can also sign in with your Tofa account instead of typing an address (*Sign in with your Tofa account* under *Connect to Tofa*) and pick your server from the list, which works away from home from the start.
- All of this was built from Tofa's published API and has not been tried on a real Tofa server yet, so please report what doesn't work.

## silo-preview-2.64.0

Released November 25, 2026. Android and Windows.

- **Tofa servers (new, a first version):** Plezilo can now connect to a Tofa media server, its fifth server type next to Plex, Jellyfin, Emby and Silo. In *Add connection* pick *Connect to Tofa*, type your server's address, then sign in with the code (or QR code) Plezilo shows, on your phone or computer, and pick your Tofa profile (with its PIN if it has one). You can browse your libraries, open movies and series with their seasons and episodes, search, see Continue Watching, mark things watched or unwatched, and play: the server decides whether your device plays the file as is or gets a converted stream, Plezilo starts where you left off and keeps your place. Not there yet: downloads, sorting and filters, other Home rows, chapters and seek-bar previews, watchlist, and connecting from outside your home network through Tofa's relay (use an address your device can reach). This was built from Tofa's published API and has not been tried on a real Tofa server yet, so please report what doesn't work.

## silo-preview-2.63.0

Released November 25, 2026. Android and Windows.

- **Audio and subtitles you pick in the player are remembered for the whole show, and for movies:** when you change the audio or subtitles while a Silo episode plays, Plezilo already saved the choice on your Silo server for the rest of the series. It now does the same for movies, so the next time you start that movie it plays your pick, also in Silo's own apps. A pick is saved only once it actually plays: if the server cannot switch to that track (or plays a different one instead), nothing is saved and your earlier choice stays. Plex and Jellyfin are unchanged. *(From Silo's own apps.)*

## silo-preview-2.62.0

Released November 24, 2026. Android and Windows.

- **Sports games show their date instead of a made-up episode number:** some Silo servers number a sports league's games by year and game (so a basketball game read "S2026 E296"). When your Silo server marks a series that way, Plezilo now shows the game's date, written the way your language writes dates ("Nov 20, 2026"), wherever the season and episode number used to go: episode cards (Continue Watching too), the big banner at the top of Home and the TV detail page, the season's episode list, the Play button on a series page, the player's title, the media notification and the Play Next card. A game without a date keeps its numbers, and the order of games and what plays next do not change. This needs a Silo server new enough to send it; other series, and Plex and Jellyfin, are unchanged. *(From Silo's own apps.)*

## silo-preview-2.61.0

Released November 24, 2026. Android and Windows.

- **Downloaded Silo episodes count as watched when you stop in the end credits:** if you watched a downloaded Silo episode or movie and stopped during its end credits, it used to stay unwatched (and in Continue Watching) after Plezilo synced, unless you had gone past 90%. Plezilo now notes where the credits start when a download finishes, and a stop in them is sent to the server as watched. On your device the title still resumes where you stopped. This applies to downloads made from this preview on; older downloads behave as before. Plex and Jellyfin are unchanged. *(From Silo's own apps.)*
- **Picture-in-picture respects "Auto-play next episode":** with auto-play turned off, an episode that ends in picture-in-picture no longer starts the next one. The Play Next card waits, without a countdown, and shows when you return to the full player. *(From Plezy.)*
- **Watch Together guests can skip end credits:** a guest allowed to control playback can now skip credits that run to the end of the episode, and the room moves on for everyone. *(From Plezy.)*

## silo-preview-2.60.0

Released November 23, 2026. Android and Windows.

- **Silo says when a long pause ended playback:** your Silo server can stop a video that has been paused for too long (its administrator sets how long). Plezilo now stops the video and says "Playback stopped because it was paused for too long." (in your language), instead of saying an administrator ended it. Seeking or changing the audio, subtitles or quality in the moments after the server stopped it no longer starts a new playback behind its back either: press Back and play the title again when you are ready, and it picks up where you paused. Plex and Jellyfin are unchanged. *(From Silo's own apps.)*

## silo-preview-2.59.0

Released November 22, 2026. Android and Windows.

- **Collections on a title's page:** a Silo movie or series page now shows the collections it belongs to, below the box set row. When one collection holds it, you see up to six of that collection's other titles under its name, then the collection itself to open the rest. When several do, an "Also in" row shows each collection. This needs a Silo server new enough to offer it; on older servers nothing changes. Collections of libraries Plezilo does not show (such as e-books) stay hidden, as on Home. *(From Silo's own apps.)*
- **Play Next follows Silo's "Show Next Up" setting:** on a Silo episode, the Play Next card now appears the number of seconds before the end that you chose in Silo's Show Next Up setting (30 seconds unless you changed it), or only at the very end if you picked "At end". When it appears early, its countdown follows the time left in the episode, so the next episode starts when this one ends, not in the middle of the last scene. Skip Credits works as before. Plex and Jellyfin are unchanged. *(From Silo's own apps; please test.)*

## silo-preview-2.58.0

Released November 22, 2026. Android and Windows.

- **Silo episodes no longer flash their ending before playing:** starting a Silo episode or movie that your server repackages on the fly could show a few seconds from near the end, then jump back to the start (or to where you left off). The server's video is still being prepared at that point, and Plezilo's player treated it like a live broadcast and joined it at its newest part. It now always plays such a video from its first part, so it opens where it should, and seeking within it lands on the right place. Plex and Jellyfin are unchanged. *(please test)*

## silo-preview-2.57.0

Released November 21, 2026. Android and Windows.

- **Switching profiles from an empty Home on TV:** when a profile's server shows nothing on Home, the remote can now reach the profile menu (and the Retry button leads to it), so you can switch to another profile. *(From Plezy.)*

## silo-preview-2.56.0

Released November 21, 2026. Android and Windows.

- **Silo row titles in more languages:** the names of the rows your Silo server makes itself (Continue Watching, Recommended for You, Because You Watched…, the holiday rows and so on) now appear in Plezilo's language for Bulgarian, Hungarian, Japanese, Korean, Simplified and Traditional Chinese, and in European Portuguese (which used the Brazilian wording until now). The other languages pick up Silo's newest translations. *(From Silo's own apps.)*

## silo-preview-2.55.0

Released November 20, 2026. Android and Windows.

- **Silo Home keeps up with what you watched:** Continue Watching, watched checks and progress on Silo rows now update when you come back to Home (from a title's page, the player, another tab, or another app), not only every 15 minutes. While Home is on screen, Plezilo also listens to your Silo server, so marking something watched or watching it on another device (your phone, the web, a Roku) updates Home a couple of seconds later. If a Silo row could not be loaded because the server was busy or the connection dropped for a moment, Plezilo keeps what it showed and tries again a few seconds later instead of leaving the row out. Plex and Jellyfin are unchanged. *(From Silo's own apps; please test with two devices.)*

## silo-preview-2.54.0

Released November 20, 2026. Android and Windows.

- **Resume works again on Silo:** resuming a Silo episode or movie could spin and then say "Playback could not be started.", while starting from the beginning worked. Plezilo now asks your Silo server to start the video where you left off, as Silo's own apps do, instead of starting it at the beginning and jumping ahead before the server had got there. When the server converts the video, going back to before the point you resumed from reloads it from there, and subtitles stay in time. *(please test)*

## silo-preview-2.53.0

Released November 20, 2026. Android and Windows.

- **Subtitle search only when your server has a provider:** in the player's subtitle menu, "Search Subtitles" for a Silo title now shows only when your Silo server has a subtitle provider set up, so it no longer offers a search that can only come back empty. Plezilo asks the server each time you open the menu, so a provider added or removed meanwhile shows up the next time. If the server does not answer (or is too old to say), the menu keeps what it showed last time, and offers the search when it has nothing to go on. Downloaded titles never offer it. Plex and Jellyfin are unchanged. *(From Silo's own apps.)*

## silo-preview-2.52.0

Released November 19, 2026. Android and Windows.

- **Silo titles open on the standard cut:** when a Silo movie comes in several editions and you have not watched any of them, its page now opens on the standard (or unnamed) edition, then the theatrical cut, and only then on another cut such as an Extended or Director's Cut, even when that other cut has a better-quality file. Quality still decides between cuts with the same kind of name, and the edition you last watched still opens first. *(From Silo's own apps.)*
- **Downloads stay stopped after a storage problem:** when downloads stop because the device is running out of space, automatic download rules no longer start them again (and stop them again) on every refresh. Starting a download yourself, Retry or Resume still restarts them. *(From Plezy.)*
- **Plex media deletion follows the server's switch:** "Delete from server" now shows on a Plex server only when its "Allow media deletion" setting is on; with it off Plezilo no longer deletes anything and says the setting is off. Jellyfin, Emby and Silo are unchanged. *(From Plezy.)*
- **Roomier Libraries bar on phones:** on a narrow phone screen, Manage Libraries and Refresh now sit in a ⋮ menu, and a long library name ends in "…" instead of running under the buttons. Tablets, computers and TVs keep every button. *(From Plezy.)*
- **Profile prompt on Android TV:** with "Ask for profile on app open" on, an Android TV that has the companion remote server turned on now asks for a profile again when you come back to Plezilo, like any other TV. *(From Plezy.)*
- European Portuguese wording tidy-ups; on iOS and macOS, downloads count space the system can free, and iOS video on an external display is fixed for the newest iOS. *(From Plezy.)*

## silo-preview-2.51.0

Released November 18, 2026. Android and Windows.

- **European Portuguese:** Plezilo can now be shown in European Portuguese (Settings › Language), alongside Brazilian Portuguese. The language list also names both variants and puts each regional variant right after its base language. Silo's row titles use the Portuguese translation in it. *(From Plezy.)*

## silo-preview-2.50.0

Released November 17, 2026. Android and Windows.

- **Hidden libraries in rows of collections:** a library you hid in Plezilo now also keeps its collections out of Home's Silo rows of collections. Your personal collections stay, and a row left with nothing to show goes away. Showing the library again brings them back.

## silo-preview-2.49.0

Released November 17, 2026. Android and Windows.

From Silo's Android app (November 17, 2026):

- **Who shared a collection:** in a row of collections, a personal collection that another profile on your Silo account made and shared now says "by" and that profile's name. On phones, tablets and computers it sits beside the number of titles; on a TV it takes the place of the number, which does not fit beside it. Your own collections and the server's collections show only the number. Every card in such a row now shows its number, an empty collection's "0 items" included. *(please test)*
- **Rows of collections are sturdier:** a collection the server describes in a way Plezilo cannot read is left out on its own; the rest of the row and the rest of Home still show. Collections from an e-book library (or another kind of library Plezilo does not show) no longer appear in Home's rows of collections, and while Plezilo cannot tell which libraries those are, Home shows only your personal collections in such a row.

## silo-preview-2.48.0

Released November 17, 2026. Android and Windows.

From Silo's own apps (November 17, 2026):

- **Rows of collections:** when your Silo server puts a row of collections on Home or on a library's Recommended page, Plezilo now shows it, one poster per collection with its name and how many titles it holds (its collage when it has no poster of its own, a plain placeholder when it has neither). Opening one shows the collection: from Home every title in it you can see, from a library page that library's titles. The row shows all its collections and has no View All, since there is nothing more to open. On a TV, a collection with a backdrop shows that backdrop, its name and its title count at the top of the screen while it is focused; one without leaves the top as it was. The long-press / ⋮ menu offers Play, Shuffle and Download, as on a library's Collections tab. Needs a Silo server with collection rows. *(please test)*

## silo-preview-2.47.0

Released November 17, 2026. Android and Windows.

- **Finished episodes leave Continue Watching:** a Silo title you watch to the end is now marked watched on the server, so it leaves Continue Watching and its page no longer shows it unfinished. The green watched check no longer appears on a card that still has a resume bar. Titles that already got stuck can be marked watched once from their card menu.

From Silo's own apps (November 16, 2026):

- **Square audiobook covers:** a Silo audiobook library now shows its books as square covers instead of cutting them down to tall posters, in the grid, the list view and while it loads. Your Silo For You lists and a person's page do the same when they hold only audiobooks, and Home and library rows of only audiobooks (a Continue Watching row of books included, with its progress bars) stay square as before. Rows and grids that mix audiobooks with movies or shows keep one card shape. *(please test)*
- **Cleaner audiobook titles:** when your server bakes the series into a book's title ("Stormlight Archive 5 - Wind and Truth (5 of 5)"), the audiobook page, the player and the system media controls now show just "Wind and Truth". Cards drop a trailing "(5 of 5)". A title that only starts like its series, such as "Dune Messiah" in the Dune series, stays whole.
- **Listen again at the end of a book:** a Silo audiobook you have listened to the end now offers "Listen again" instead of "Play", even when it is not marked as finished. Mark as Watched / Unwatched in the long-press or ⋮ menu still follows the book's saved finished flag only.

## silo-preview-2.46.0

Released November 17, 2026. Android and Windows.

- **Watchlist and Favorites for Silo titles:** a Silo movie or show page now has a Watchlist (bookmark) and a Favorite (heart) button, and the long-press / ⋮ menu of Silo movie and show cards (Home, libraries, search, recommendation rows, For You) has Add to / Remove from Watchlist and Favorites. The change shows at once; if the server refuses it, it is undone and the reason is shown. The For You page and Home rows that show your Watchlist or Favorites update to match. *(please test)*

## silo-preview-2.45.0

Released November 16, 2026. Android and Windows.

- **A title page whose server is offline says so:** opening a movie or show from a card while its server is not connected now shows "Couldn't load this title" with Retry, which works once the server is back.

## silo-preview-2.44.0

Released November 16, 2026. Android and Windows.

- **A title page that cannot load says so:** if a movie or show opened from a card cannot be loaded, the page now shows "Couldn't load this title" with a Retry button instead of a half-filled page.

## silo-preview-2.43.0

Released November 16, 2026. Android and Windows.

From Silo's own apps (November 16, 2026):

- **Silo row titles in your language:** the rows your Silo server names itself (Home sections such as Continue Watching and Recently Added in Movies, and the For You recommendations) now follow Plezilo's language, using Silo's own translations. They are available in Danish, Dutch, French, German, Italian, Norwegian, Polish, Portuguese, Russian, Spanish, Swedish and Turkish; other languages show Silo's English. Titles your server administrator typed stay as written.
- **Title pages open instantly:** opening a movie or show from Home, a library, search or a recommendation row now shows its title, year, overview and picture straight away instead of a loading spinner, on every server type. Play reads "Loading…" for the moment it takes to fetch the rest, and the other buttons appear once it has. *(please test)*

## silo-preview-2.42.0

Released November 16, 2026. Android and Windows.

- **WAV audiobooks play:** Silo audiobooks stored as WAV files, including 8-bit, 32-bit and floating-point WAV, now play instead of failing with "No validated playback route". *(please test)*

## silo-preview-2.41.0

Released November 16, 2026. Android and Windows.

- **The right resume point after watching:** back from the player, a Silo title's page now shows where the server will resume (or Play), not just where you stopped. Silo ignores a very short watch and keeps your earlier place. On a show's page the episode list and season watched counts update too. *(please test)*
- **Offline progress no longer undoes newer progress:** watching a downloaded Silo title offline is sent with the time you watched it, so progress you made since on another device is kept, and finished titles are marked watched by the server's own rule. *(please test)*
- **Live AI subtitles stack like normal captions:** when two lines are on screen together, the earlier one stays on the bottom line.
- **Request pages close when requests are turned off** on the Silo server, when you come back to the app or try a request.
- **No pointless "Explore all"** on a Silo Next Up or Continue Watching row that already shows every title.
- **Voice search on Google TV:** on a Google TV Streamer and other Google TV devices with Android 12 or later, voice search now fills the search field (Plezilo asks for microphone access the first time). *(please test)*
- **From Plezy:** with "Ask for profile on app open" on, a PIN-protected profile's Continue Watching no longer shows on the Android TV home screen row. The remote keeps working when the player reopens a video in place (quality switch, waking the TV).

## silo-preview-2.40.0

Released November 15, 2026. Android and Windows.

- **Seek from the Skip button on every server:** on TV, Left and Right now skip back and forward while the Skip Intro or Skip Credits button is selected for Plex and Jellyfin videos too, not just Silo (asked for by a user).

## silo-preview-2.39.0

Released November 15, 2026. Android and Windows.

- **Smoother 25 and 30 fps video on TVs:** with the display refresh rate switching on (Android TV and Fire TV), 25 and 30 fps videos now switch the TV to 50 or 60 Hz instead of 25 or 30 Hz, which some TVs show with flicker or a blank pause (from Plezy).

## silo-preview-2.38.0

Released November 15, 2026. Android and Windows.

- **New For You page for Silo servers:** your Silo recommendations, Favorites and Watchlist in one place, like Silo's own apps. Find it in the side menu below Home on TV and desktop, or with the For You button at the top of Home on phones. *(please test)*
- **Favorites and Watchlist** can be filtered to Movies or Shows and sorted. When there are no recommendations yet, For You shows your saved titles instead.
- **Two new switches** in Settings › Appearance › Silo: "Show Silo recommendations on Home" and "Show For You". Both are on by default.

## silo-preview-2.37.0

Released November 15, 2026. Android and Windows.

From Silo's own apps (November 15, 2026):

- **Seek from the Skip button on TV:** while the Skip Intro or Skip Credits button is selected with the player controls showing, Left and Right now skip back and forward in Silo videos (holding them keeps seeking) instead of doing nothing. OK still skips. *(please test)*

## silo-preview-2.36.0

Released November 15, 2026. Android and Windows.

- **Silo's recommendations really show up on Home now:** in 2.35.0 they could vanish when the server took more than a few seconds to answer, and Silo's own "Recommended for You" Home section could hide the For You row. Home now opens right away and the recommendation rows ("For You", "Because you enjoy …", "Popular on This Server" and more) appear when they arrive. They also show when "Use Home Layout" is off. *(please test)*
- Settings › Logs now says how many recommendation rows arrived, or why there were none.

## silo-preview-2.35.0

Released November 15, 2026. Android and Windows.

- **Silo's personalised recommendations on Home:** Silo servers now add your recommendations from Silo ("For You", "Because You Watched …", "Popular on This Server" and more) below Silo's own Home rows, and they refresh with Home. Rows already on your Home aren't shown twice, and servers without recommendations look the same as before. *(please test)*
- Row names that Silo words itself now use Plezilo's own wording.

## silo-preview-2.34.0

Released November 15, 2026. Android and Windows.

- **Silo sort options like Silo's own apps:** Latest Episode Added and Latest Episode Air Date for shows, separate IMDb and TMDB rating sorts, Rotten Tomatoes critic and audience sorts when your server shows those ratings, plus Content Rating, Resolution, Bitrate, Progress, Date Viewed and Plays. Audiobook libraries can sort by author, narrator and series. Your saved sort still works; "Rating" is now called "IMDb Rating".
- **Easier-to-read counts** on collections and people pages ("1,284 titles").
- **Plex servers come back by themselves:** a server that was asleep or unreachable when the app started now reconnects within about a minute, and a reconnecting server no longer interrupts playback or downloads.
- **Smaller fixes:** libraries whose item count is ahead of what the server sends no longer keep loading at the end; searching for an artist shows their albums first; Fire TV plays Dolby Vision files that also carry HDR10+ data; picture-in-picture starts on its own for Live TV and on the first tap on iPhone and iPad; Live TV access is checked again after switching Plex Home profiles.

## silo-preview-2.33.0

Released November 14, 2026. Android and Windows.

From Silo's own apps (November 14, 2026):

- **Silo badges follow your text size:** badges on Silo cards now grow with your device's text size, up to about a third larger, and smaller text never shrinks them.
- **Badges on landscape cards and episode thumbnails follow the library density setting:** smaller on compact, larger on comfortable, and the watched check matches.

## silo-preview-2.32.0

Released November 14, 2026. Android and Windows.

From Silo's own apps (November 13, 2026):

- **Silo editions:** on a Silo film with several editions (cuts, such as Theatrical and Director's Cut), Play now starts the edition you last watched. "Auto" picks the best copy of that cut for your quality setting and never switches to another cut. *(please test)*
- **Play Version…** on Silo titles with several editions asks for the edition first, then offers "Auto" or a specific file. The item page shows which edition Play will start.

## silo-preview-2.31.0

Released November 13, 2026. Android and Windows.

- **View All on Silo's Continue Watching row:** with more than 20 titles in progress, the Continue Watching row now ends with View All (on TVs; on phones and tablets tap the row's title), like Silo's own apps, and View All lists them all. Silo sends each Home row with at most 20 titles, so Plezilo never found out there were more.

## silo-preview-2.30.0

Released November 12, 2026. Android and Windows.

- **Continue Watching is in the same order as Silo's own apps:** the title you watched most recently is first again. Plezilo re-sorted the row by itself and put the next episode of a show you had just finished by the date that episode was added to the library, so it could land far down the row (or jump ahead of what you were watching). Plezilo now keeps Silo's order; with several servers, Silo's rows still slot in by time between the others'.

## silo-preview-2.29.0

Released November 12, 2026. Android and Windows.

Fixes from a full review of the app. Things to try on your device are marked *(please test)*.

- **Long Silo films keep playing:** Plezilo now renews its Silo sign-in while a film plays. Before, a long film could stop with an error about 30–60 minutes in, or the first seek after an hour failed. On Android the film plays straight through; on Windows, macOS and iPhone the player reopens where you were once the old sign-in runs out (a short hitch, no error). *(please test: a film longer than an hour)*
- **Live AI subtitles keep coming:** if the live connection for "Transcribe/Translate with AI" drops during a long job, Plezilo reconnects and keeps the lines you already have. If it can't, your normal subtitles come back instead of staying hidden.
- **Personal collections open:** a profile's own collections shown on a library's Collections tab now open (they showed an empty page or an error). Collection descriptions now show too.
- **An administrator stopping a stream stops the player:** Plezilo now says "An administrator ended this playback session." and no longer keeps playing, saving your place or marking the title watched.
- **Remove from Continue Watching really removes it:** it follows Silo's own apps; before, it could say "Removed" while nothing changed on the server.
- **Sign-in fixes:** waiting a long time on the profile or PIN screen no longer makes a new server ask you to sign in again at once; re-adding a Silo account and profile you already have signs the old session out; changing a server's address is no longer undone later; a busy or restarting server now says so instead of "No Silo server answered at this address", and errors no longer show raw technical text.
- **Downloads get their subtitles:** subtitles of a long Silo download are fetched with a fresh sign-in when the video finishes, so they no longer go missing, and no stray playback session is left on the server.
- **Smaller fixes:** your last subtitle and audio choice for a series is kept when the app reconnects or closes; a Silo badge picture that failed to load is tried again after a few minutes; the external-player fallback gets a fresh sign-in; less memory is kept after AI subtitle jobs.
- **Downloads and releases:** the fixed Downloader links no longer stop working for a moment while a new version is uploaded. If you install with a Downloader code, keep using the code you installed with: switching from the 64-bit to the 32-bit code needs an uninstall first. Each release now checks that it is signed with the same key as the last one and warns at the top of these notes if you must uninstall first.

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
- **Windows and macOS:** the Supporter themes are available.

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
