# Architecture

How the pieces fit, and why they are arranged this way.

---

## The one idea worth understanding

**Media detection happens in JavaScript, inside a WebKit page — not in native
code and not in Chromium.**

That single fact is why Brave's Playlist can be lifted out of a Chromium fork
without dragging Chromium along, and it is what makes this project possible.

The detector script hooks `HTMLMediaElement.prototype.setAttribute` and watches
the DOM. When a video player — YouTube's, SoundCloud's, anyone's — assigns a
source to its `<video>` element, the hook fires and the URL is posted to Swift.
No knowledge of any particular site is required, and no network-stack
integration either.

The second load-bearing idea is the **MediaSource swizzle**. Modern players use
Media Source Extensions to feed a `<video>` element chunks over a `blob:` URL,
which is meaningless outside that page and cannot be downloaded. Deleting the
`MediaSource` API at document start makes feature detection fail, and well-built
players fall back to a progressive URL that *can* be saved. Without this file,
the app finds `blob:` URLs on most large sites and can download nothing.

---

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│  UI/                          SwiftUI. Knows nothing about    │
│  Library · NowPlaying ·       WebKit, CoreData or AVFoundation│
│  Downloads · Settings         beyond what it renders.         │
└────────────────┬─────────────────────────────────────────────┘
                 │ @EnvironmentObject / @StateObject
┌────────────────▼─────────────────────────────────────────────┐
│  Media/PlaybackController     Queue, shuffle, repeat, sleep   │
│                               timer, resume, expired-media    │
│                               refresh. The observable façade. │
└────────┬──────────────────────────────┬──────────────────────┘
         │                              │
┌────────▼───────────────┐  ┌───────────▼──────────────────────┐
│  Media/MediaPlayer     │  │  Core/PlaylistManager            │
│  One AVPlayer.         │  │  Library façade: FRC + Combine,   │
│  Audio session, remote │  │  download orchestration, storage  │
│  commands, PiP.        │  │  accounting, deletion ordering.   │
└────────┬───────────────┘  └───────────┬──────────────────────┘
         │                              │
         │              ┌───────────────┼──────────────────┐
         │              │               │                  │
┌────────▼──────┐ ┌─────▼───────┐ ┌─────▼────────┐ ┌───────▼────────┐
│ NowPlayingInfo│ │ Download    │ │ CoreData     │ │ Extraction/    │
│ Lock screen,  │ │ Manager     │ │ PlaylistItem │ │ WebLoader +    │
│ Control Centre│ │ HLS/file/   │ │ Folder       │ │ Detector.js    │
│               │ │ data        │ │ DataController│ │ Swizzler.js   │
└───────────────┘ └─────────────┘ └──────────────┘ └────────────────┘
```

`Support/` sits under everything: `Preferences`, `Logger`, `UserAgent`,
`Reachability`, `ImageCache`, `Then` and the Foundation extensions that replace
Brave's `Shared` module.

`Intents/` enters from the side rather than the top. An App Intent run from
Shortcuts has no view to hang off — and for `PlayPlaylistIntent`, which does not
open the app, there may be no scene in the process at all — so it talks to
`PlaybackController.shared` directly. `RootView` holds that same instance as its
`@StateObject`. An intent that needs the UI (`OpenPlaylistIntent`) leaves its
request on `AppIntentRouter`, which `RootView` collects both on change and on
first appearance, since on a cold launch the intent runs before there is a view.

---

## The add flow, end to end

```
User pastes https://example.com/watch?v=123
        │
        ▼
MediaExtractor.extract(from:)
        │
        ├─ Is the URL itself media?  (extension, or a 1-byte ranged GET)
        │     └─ yes ──▶ build PlaylistInfo directly, no web view       ◀── fast path
        │
        └─ no ──▶ PlaylistWebLoader.load(url:)
                     │
                     │  offscreen WKWebView, 1% alpha, in the key window
                     │  ├─ PlaylistSwizzler.js   @documentStart, page world
                     │  │     deletes MediaSource / ManagedMediaSource
                     │  └─ PlaylistDetector.js   @documentStart, page world
                     │        hooks setAttribute, polls the DOM, scrapes og:image
                     │
                     │  page loads … player assigns <video>.src …
                     ▼
                  postMessage { src, name, duration, pageSrc, artworkURL, token }
                     │
                     │  token checked · blob:/data:/detached rejected
                     │  first hit starts a 2.5 s settle window for better candidates
                     ▼
                  rank(): longest duration first, progressive before HLS
        │
        ▼
MediaExtractor.enrich()   duration via AVAsset · og:image via PageMetadataFetcher
        │
        ▼
AddMediaView shows candidates ──▶ user taps Add
        │
        ▼
PlaylistItem.addItem()  ──(completion: after the save)──▶ autoDownload()
        │
        ▼
PlaylistManager.download(item:)
        │
        ├─ data:  ──▶ PlaylistDataDownloadManager     (write bytes directly)
        ├─ .m3u8 ──▶ PlaylistHLSDownloadManager       (AVAssetDownloadURLSession → .movpkg)
        └─ else  ──▶ PlaylistFileDownloadManager      (background URLSession)
                          │
                          │  detect container: URL → Content-Type → magic bytes
                          │  move into Application Support/Playlist/ (unique name)
                          │  take URL.bookmarkData()
                          ▼
                     PlaylistItem.updateCache(…) ──(completion)──▶ .downloaded
```

The two `completion` annotations in that diagram are the ordering fixes
described in [MODIFICATIONS.md §5.1–5.2](MODIFICATIONS.md#5-defects-fixed).
Upstream announces both events before the write lands.

---

## Storage

Three locations, chosen for three different eviction policies:

| What | Where | Backed up | Purgeable by iOS |
|---|---|---|---|
| Media files | `Application Support/Playlist/` | No | **No** |
| Database | `Application Support/Database/Playlist.sqlite` | Yes | No |
| Artwork | `Caches/Thumbnails/` | No | Yes |

Media must not be purgeable — a user's offline library silently disappearing is
the worst possible failure for this app. Artwork should be, because it is cheap
to regenerate. The database is small and worth backing up.

**Items point at files through bookmark data, never paths.** iOS relocates app
containers between installs and OS upgrades; a stored absolute path goes stale
and every download appears to vanish. `cachedData == nil` is the canonical
"not downloaded" signal everywhere in the app.

---

## Threading

| Concern | Rule |
|---|---|
| CoreData reads | `DataController.viewContext`, main queue |
| CoreData writes | A private-queue context per operation, merged back |
| Download delegates | `OperationQueue.main` |
| Playback + UI | `@MainActor` (`PlaybackController`, `PlaylistWebLoader`, `MediaExtractor`) |
| Thumbnails | `actor ThumbnailRenderer`, which also coalesces duplicate requests |
| Image cache I/O | A private serial queue |

The project builds in **Swift 5 language mode** (`SWIFT_VERSION = 5.0`,
`SWIFT_STRICT_CONCURRENCY = minimal`). Brave's Playlist sources predate strict
concurrency and lean on `DispatchQueue` conventions throughout; forcing them
into Swift 6 isolation would have meant rewriting the very code this project set
out to reuse. Actor isolation is applied deliberately at the boundaries that
need it rather than universally.

---

## Why `PlaybackController` exists

In Brave, "what plays next" lives inside `PlaylistViewController` (1,009 lines)
and `PlaylistListViewController` (973 lines) — UIKit view controllers that are
simultaneously managing table views, popovers, drag-and-drop and browser tabs.

That is fine in a browser, where the player is a screen. It does not work in a
media player, where playback must outlive every screen: audio has to keep going
with no UI on screen at all, and the lock screen has to keep working when the
app is not running in the foreground.

So the decisions moved into one observable object, created once in `RootView`
and injected into the environment:

- Queue and current index, with shuffle preserving the currently playing item
- `next(isAutomatic:)` — repeat-one restarts only on automatic advance, because
  a user pressing "next" wants the *next* track
- `previous()` — restarts the track if more than 3 s in
- Resume from `lastPlayedOffset`, unless within 5 s of the end
- Segments: a playlist can ask for only part of each item, and the boundary is
  watched on the periodic time observer because nothing in AVFoundation fires at
  an arbitrary time. An item's last segment ends when the item does, so the two
  paths converge on one method — and because that means one end is reported
  twice, each stretch of playback carries an id whose end is acted on once
- The segment cycle: a repeating segmented playlist advances each item's
  progress *past* its last segment rather than wrapping it, so "this item has
  played all of itself" is a state the queue can see. `next` then moves to the
  next item that still owes the pass a stretch, and when none does the playlist
  has been through in full and resets to the top. Skipping counts the stretch
  as played, which is what stops a skipped-through playlist from replaying the
  same stretches for ever
- The expired-media refresh: when a stream fails to load and we are online,
  re-extract from the original page and retry once, keeping identity intact
- Sleep timer

`MediaPlayer` stays deliberately ignorant of all of it. It drives one
`AVPlayer` and reports what happened; that separation is what let the same
player serve a browser tab, a full-screen controller and CarPlay upstream, and
it is why it survived the browser being deleted from around it.

---

## Testing

115 tests, `xcodebuild test`. Network-dependent tests skip when offline rather
than fail.

| Suite | Covers |
|---|---|
| `PlaylistAnonymityTests` | The folder flag that hides a playlist from the lock screen: that the attribute is migratable, that it persists and resolves from an item, and exactly which keys reach `MPNowPlayingInfoCenter` |
| `MediaDetectionTests` | The detector against generated HTML: static `src`, script-assigned `src`, `<source>` children, audio, `blob:` rejection, og:image, multi-item, **and that MediaSource is gone before page scripts run** |
| `DownloadIntegrationTests` | Live download → bookmark → resolvable local file → `AVAsset.isPlayable` offline; remove-download semantics |
| `LibraryStorageTests` | CoreData round trips, model invariants, path uniquing, filename sanitisation, the row-aliasing regression |
| `MimeTypeDetectionTests` | Container detection from URL, header and magic bytes, incl. sliced buffers |
| `PlaylistInfoTests` | Detector-message decoding, schemeless URL resolution, identity, refresh merge |
| `PlaylistSegmentTests` | Dividing an item into segments — the short-item exemption, the trailing fragment, full coverage of the item, an out-of-range stored index — plus how a pass ends: progress stops *at* the segment count rather than wrapping, and an item played whole counts as one. Also the folder/item attributes and that `everyItem` ignores the folder being browsed |

The detection tests are the ones worth keeping an eye on: they are the
regression suite for the part of the app most exposed to the web changing
underneath it.
