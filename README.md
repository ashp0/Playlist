# Playlist

An offline media player for iOS — Brave Browser's Playlist feature extracted
into a standalone app, with the browser removed.

Paste a link, the app finds the media on that page, downloads it, and plays it
back with no network connection. No tabs, no address bar, no search, no shields.
Just a library.

```
Library  ·  Now Playing  ·  Downloads  ·  Settings
```

---

## What it does

**Getting media in**
- Paste a page address — the page is loaded invisibly and its video or audio is
  detected
- Or paste a direct media link (`.mp4`, `.m3u8`, `.mp3`, …) — resolved instantly,
  no page load
- YouTube links in any form — `watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`,
  `music.youtube.com` — are normalised to one watch page and saved at 360p
- Optional YouTube sign-in for age-restricted videos, through Google's own page
- `playlist://add?url=…` for sending links from a Shortcut or another app
- Automatic re-extraction when a saved media link expires

**Shortcuts and Siri**
- **Play Playlist** starts a playlist — shuffled if you ask — without bringing
  the app to the front, so it works from an automation or a Back Tap
- **Open Playlist** opens the app with that playlist showing
- Playlists are picked from a list in Shortcuts and remembered by identity, so
  renaming one does not break a saved shortcut

**Offline**
- Downloads over a background `URLSession` — continues when the app is suspended
- HLS streams persisted as playable `.movpkg` bundles via `AVAssetDownloadURLSession`
- Storage accounting, per-item sizes, selective removal

**Playback**
- Background audio, lock screen and Control Centre controls
- Picture-in-Picture, which can be turned off — the audio keeps playing, the
  floating window does not appear
- Resume where you left off
- Queue: reorder, play-next, add-to-queue
- Shuffle · Repeat · Repeat One
- Playback speed 0.5×–2×
- Sleep timer (duration or end-of-track), under the player's options button

**Library**
- Search, seven sort orders, drag to reorder
- Playlists (folders) — the one you were last on is the one the app opens on,
  and adding a link while you are inside a playlist files it there
- **Playlists that stay off the lock screen** — mark one hidden and its items
  publish no title, no source and no artwork to the lock screen or Control
  Centre, leaving the transport controls and the timeline working. The setting
  belongs to the playlist and is remembered
- **Playlists that play in segments** — give a playlist a length, say three
  minutes, and it plays that much of each item before moving on. Come back
  round and the item picks up where it left off rather than starting again, so
  a repeating playlist works through everything a bit at a time. Items shorter
  than the segment play in full. The lock screen is told about the segment
  rather than the track: three minutes long, counting from zero, ending when
  the playlist moves on — and its scrubber and skip buttons stay inside it
- Artwork from video frames, with Open Graph images as fallback

---

## Quick start

```bash
open Playlist.xcodeproj
```

Set your **Team** and change the **Bundle Identifier** under Signing &
Capabilities, then ⌘R to your iPhone. Full instructions, including free-account
signing and `.ipa` export, are in [Docs/SIDELOADING.md](Docs/SIDELOADING.md).

No package manager, no checkout step — the project has zero external
dependencies.

---

## Project layout

```
Playlist/
├── Playlist.xcodeproj
├── Config/Info.plist
├── Playlist/
│   ├── App/            @main, AppDelegate (background sessions)
│   ├── Core/           Library engine — adapted from Brave
│   │                     PlaylistManager · PlaylistDownloadManager
│   │                     PlaylistItem · PlaylistFolder · DataController
│   │                     PlaylistInfo · PlaylistMimeTypeDetector
│   ├── Extraction/     Media detection — adapted from Brave
│   │                     PlaylistWebLoader (offscreen WKWebView)
│   │                     MediaExtractor · PageMetadataFetcher
│   │                     YouTube (new — addresses, UA, metadata)
│   │                     YouTubeSession (new — signed-in cookie store)
│   │                     Resources/PlaylistDetector.js
│   │                     Resources/PlaylistSwizzler.js
│   ├── Media/          Playback
│   │                     MediaPlayer (adapted) · NowPlayingInfo (adapted)
│   │                     ThumbnailRenderer (adapted)
│   │                     PlaybackController (new — queue, modes, sleep timer)
│   ├── Intents/        App Intents — Shortcuts and Siri (new)
│   ├── UI/             SwiftUI — Library · NowPlaying · Downloads · Settings
│   ├── Support/        Local replacements for Brave's SPM modules
│   └── Resources/      Assets.xcassets
└── PlaylistTests/      115 tests
```

~10,000 lines of Swift and JavaScript.

---

## Documentation

| | |
|---|---|
| [BRAVE-COMPONENTS.md](Docs/BRAVE-COMPONENTS.md) | **Which Brave components were reused**, file by file, with retention percentages and what was rewritten |
| [MODIFICATIONS.md](Docs/MODIFICATIONS.md) | **Every change made**, grouped by reason — including 14 upstream defects fixed |
| [ARCHITECTURE.md](Docs/ARCHITECTURE.md) | How the layers fit together; the add flow end to end |
| [SIDELOADING.md](Docs/SIDELOADING.md) | Building, signing, installing, troubleshooting |
| [LIMITATIONS.md](Docs/LIMITATIONS.md) | **What it cannot do and why** — read this before filing a bug |

---

## How the extraction works

The interesting part, in three sentences.

The app loads the page in an **offscreen WebKit view** and injects two scripts
at document start, into the page's own JavaScript world. The first deletes the
**MediaSource API**, which makes players fall back from unsaveable `blob:`
streams to a plain downloadable URL. The second hooks
`HTMLMediaElement.prototype.setAttribute`, so the moment the page's player
assigns a media source — however long after load that happens — the URL is
posted back to Swift.

Both scripts are Brave's. This is why the feature could be lifted out of a
Chromium fork **without needing any Brave Core code at all**: detection happens
in JavaScript inside WebKit, not in Chromium's network stack.

There is a fourth sentence, and YouTube is the reason for it: the swizzle can
only reveal a fallback the server already put in the page, so *how the page was
requested* matters as much as what runs inside it. YouTube ships a progressive
format to a mobile user agent and none at all to a desktop one, which is why the
watch page is always requested as an iPhone.

Notably, the app never parses a media URL out of that page. The URLs in it are
signed with an encrypted parameter and return 403 if fetched directly — letting
the page's own player decrypt and assign one, then reading it off the element,
is what makes the result downloadable with an ordinary `URLSession`.

See [ARCHITECTURE.md](Docs/ARCHITECTURE.md) for the full flow.

---

## Tests

```bash
xcodebuild -project Playlist.xcodeproj -scheme Playlist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

115 tests. The detection suite runs the real detector against generated HTML —
covering script-assigned sources, `<source>` children, `blob:` rejection, and
that MediaSource really is gone before page scripts run. The YouTube suite pins
down link parsing for every shape YouTube hands out, that the mobile user agent
survives desktop mode, and that a pre-roll advert loses to the video whose
length the page declares. The anonymity suite asserts what actually reaches
`MPNowPlayingInfoCenter` — in particular that a hidden playlist's item cannot
inherit the *previous* item's title or artwork, which is the way that feature
would fail, and a companion suite covers the other half of that dictionary: what
a segmented playlist publishes as its length and elapsed time, and that a
position scrubbed back from the lock screen lands inside the segment rather than
past the end of it. The library-selection suite stands a relaunch up as a fresh
view model and asserts the app reopens on the playlist it was left on, including
when that playlist has been deleted in the meantime. The segment suite covers the
arithmetic behind segmented playlists —
an item shorter than a segment, a final segment shorter than the rest, and
stored progress that outlived the length it was recorded against — and that the
whole library stays reachable while an empty playlist is open. The integration
suite performs a live download and asserts the result is a file `AVAsset`
reports as playable offline. Network-dependent tests skip when offline rather
than fail.

---

## Known limits, briefly

- **DRM sites (Netflix, Spotify, …) will never work.** The bytes are encrypted;
  that is the point of the technology.
- **YouTube works, at 360p.** The watch page is always requested with a mobile
  user agent, because YouTube only includes a progressive (muxed) format for
  one — the swizzle then makes the player fall back to it, and the page's own
  JavaScript signs the URL for us. That format is itag 18, 640×360 with audio.
  720p and above are adaptive-only and stay out of reach without a signature
  descrambler; the measurements behind that are in
  [LIMITATIONS.md](Docs/LIMITATIONS.md). Live streams do not work.
- **Age-restricted videos need signing in** — optional, under Settings. The
  sign-in page is Google's own; the app keeps the cookie, never a password.
- **Media links expire**, often within hours. Download immediately; the app
  re-extracts automatically when a stale link fails.
- **No CarPlay** — the entitlement is not available to sideloaded apps.

Full detail, including what *does* work reliably, in
[LIMITATIONS.md](Docs/LIMITATIONS.md).

---

## Licence

Derived from [Brave Browser for iOS](https://github.com/brave/brave-ios), which
is licensed under the **Mozilla Public License 2.0**. This project is therefore
MPL-2.0 as well.

Adapted files carry Brave's original copyright header alongside this project's,
name their upstream path, and document what changed. See
[BRAVE-COMPONENTS.md](Docs/BRAVE-COMPONENTS.md) for complete provenance.

Built for personal use and sideloading onto your own device.
