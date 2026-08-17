# Brave Components Reused

This app is Brave's Playlist feature extracted from the browser. This document
records, file by file, what came from Brave, where it came from, and how much of
it survived the extraction.

Upstream sources:

- **brave-ios** (archived) — <https://github.com/brave/brave-ios>, at
  `398f8b7` (release 1.62.2, the final commit before the repository was archived
  and iOS development moved into `brave-core/ios/brave-ios`).
- **brave-core** — <https://github.com/brave/brave-core>

Everything reused is licensed under **MPL-2.0**. Adapted files keep Brave's
original copyright header alongside this project's, and each one names its
upstream path in a header comment.

---

## Where Playlist lives in Brave

Brave's Playlist is not one module. It is split across three layers, and the
split is what made this extraction tractable:

| Layer | Location in brave-ios | Browser-coupled? |
|---|---|---|
| Playback & download engine | `Sources/Playlist/` | **No** — a standalone SPM target |
| Data model | `Sources/Data/models/Playlist*.swift` | No |
| Detection scripts | `Sources/Brave/Frontend/UserContent/UserScripts/…` | Partly |
| UI & orchestration | `Sources/Brave/Frontend/Browser/Playlist/` | **Yes** — UIKit, tabs, shields |

`Sources/Playlist/` is an independent Swift package target that imports no
browser code. It is the bulk of what actually makes Playlist work, and it ported
nearly intact. The browser coupling is concentrated almost entirely in the UI
layer, which was rewritten.

---

## Reused with substantial fidelity

These files are ports. Structure, control flow, and the non-obvious decisions
are Brave's; changes are limited to removing dependencies and fixing defects.

### `Core/PlaylistDownloadManager.swift` ← `Sources/Playlist/PlaylistDownloadManager.swift`

**~85% retained.** The single most valuable file in the port.

Brave's insight, reproduced whole: offline media on iOS needs *three* download
strategies, not one.

- **HLS** (`.m3u8`) via `AVAssetDownloadURLSession` → produces a playable
  `.movpkg`. A plain `URLSession` fetch of an HLS manifest gets a text file
  pointing at URLs that will not exist offline.
- **Progressive files** via a background `URLSession` download task.
- **`data:` URIs** via a data task, written straight to disk.

Also reused: the three-tier file-extension detection (URL → `Content-Type`
header → magic bytes), the unique-path allocation, the `taskDescription`
round-trip that survives app termination, and the cleanup-on-failure paths.

### `Core/PlaylistItem.swift` ← `Sources/Data/models/PlaylistItem.swift`

**~80% retained.** The CoreData entity and its full CRUD surface.

The load-bearing decision reused here is storing **bookmark data**, not a path,
in `cachedData`. An iOS app's container path changes between installs and OS
upgrades; a stored absolute path goes stale and every download appears to
vanish. Resolving a bookmark survives relocation. `cachedData == nil` is the
canonical "not downloaded" signal throughout the app.

### `Core/PlaylistManager.swift` ← `Sources/Playlist/PlaylistManager.swift`

**~70% retained.** The library façade: `NSFetchedResultsController` +
Combine subjects, download-state queries, the delete ordering (file first, then
row), disk-space accounting, and `deleteUserManagedAssets` — the launch-time
sweep of AVFoundation's `com.apple.UserManagedAssets*` staging directory, where
interrupted HLS downloads otherwise strand gigabytes invisibly.

### `Media/MediaPlayer.swift` ← `Sources/Playlist/MediaPlayer.swift`

**~75% retained.** The `AVPlayer` wrapper that makes background audio, lock
screen controls and PiP work: audio session category, remote command
registration, interruption and route-change handling, the layer detach/reattach
on backgrounding, and the deliberately-biased `isVideoTracksAvailable()`.

### `Core/PlaylistMimeTypeDetector.swift` ← `Sources/Playlist/PlaylistMimeTypeDetector.swift`

**~95% retained.** The MIME/extension tables and magic-number probes, nearly
verbatim. Exists because `AVPlayer` refuses to play a local file whose extension
it does not recognise, regardless of the actual container.

### `Extraction/Resources/PlaylistDetector.js` ← `…/Scripts/Paged/PlaylistScript.js`

**~70% retained.** The detection algorithm itself:

- Hooking `HTMLMediaElement.prototype.setAttribute` to catch the moment a player
  assigns a source. Players set the real URL programmatically long after parse,
  so a one-shot DOM scan finds nothing.
- The 1-second polling backstop for players the hooks miss.
- `MutationObserver` on `<body>` watching for SPA URL changes.
- Reversed element order (last `<video>` is usually the content, earlier ones
  are ads), `<source>` child traversal, the `window.top` cross-origin fallback,
  the detached-node (`invisible`) signal, and duration clamping.

### `Extraction/Resources/PlaylistSwizzler.js` ← `…/Scripts/Paged/PlaylistSwizzlerScript.js`

**~100% retained.** Deletes `MediaSource` / `WebKitMediaSource` /
`ManagedMediaSource` at document start.

This is the highest-leverage file in the whole project. With MSE available, a
player hands the `<video>` element a `blob:` URL that is meaningless outside
that page and cannot be downloaded. Removing the API makes feature detection
fail, and well-built players fall back to a progressive URL that *can* be saved.

### `Extraction/PlaylistWebLoader.swift` ← `LivePlaylistWebLoader` in `Playlist/Managers & Cache/PlaylistCacheLoader.swift`

**~40% retained** — and the most conceptually important reuse.

Upstream this is a *fallback*: Playlist normally detects media in the tab the
user is already browsing, and this offscreen loader runs only when a saved media
URL has expired. Removing the browser promotes it to the primary extraction
path. That promotion is the seam that lets Playlist stand alone at all.

Retained: the offscreen-`WKWebView`-plus-scripts approach, injection at
`.atDocumentStart` into `WKContentWorld.page` (an isolated world shares the DOM
but not the prototype chain, so the `setAttribute` hook would never fire),
`forMainFrameOnly: false` for iframe-embedded players, the randomized handler
name and security token, the parented-but-invisible view (WebKit throttles
media loading for views it believes are offscreen), the `blob:`/`data:` and
detached-node rejections, and the `_WKRecoveryAttempterErrorKey` guard.

### `Media/ThumbnailRenderer.swift` ← `Playlist/Utilities/PlaylistThumbnailUtility.swift`

**~60% retained.** The fallback chain and, in particular,
`HLSThumbnailGenerator` — `AVAssetImageGenerator` does not work on HLS, so the
workaround is a real `AVPlayer` with an attached `AVPlayerItemVideoOutput`,
seeked at rate zero, with the pixel buffer copied out. Its `deinit` ordering
comment is preserved verbatim: it documents a real KVO crash.

### `Core/PlaylistInfo.swift` ← `Sources/Data/models/PlaylistInfo.swift`

**~85% retained.** The transport struct crossing every boundary — JS detector,
database, downloader, player — plus `fixSchemelessURLs` and the
normalized-host-and-path identity semantics.

### `Media/NowPlayingInfo.swift` ← static half of `Sources/Playlist/PlaylistMediaStreamer.swift`

**~70% retained.** Now Playing / lock screen publishing, and the one-byte ranged
GET used to probe a media URL's real type (many CDNs answer `HEAD` differently
from a real transfer, or not at all).

### `Media/MPRemoteCommandCenter+Combine.swift` ← same filename

**~80% retained.** Combine bridge over `MPRemoteCommandCenter`.

### `Core/DataController.swift` ← `Sources/Data/models/DataController.swift`

**~40% retained.** The threading contract — reads on `viewContext`, every write
on a per-operation private-queue child — and the `WriteContext` /
`perform(context:save:)` API that all the ported call sites are written against.

### `Core/PlaylistFolder.swift`, `Core/PlaylistAssetFetcher.swift`

**~70% / ~95% retained.** Collections, and the asset-cancellation pairing.

---

## Rewritten (browser-coupled)

Replaced entirely. Behaviours were taken from these files; no code was.

| Brave file | Lines | Replaced by |
|---|---|---|
| `PlaylistViewController.swift` | 1009 | `Media/PlaybackController.swift` + `UI/NowPlaying/` |
| `PlaylistListViewController.swift` (+3 extensions) | 1798 | `UI/Library/` |
| `PlaylistCarplayController.swift` | 1012 | *(not ported — see Limitations)* |
| `PlaylistFolderController.swift` | 645 | Folder UI inside `LibraryView` |
| `VideoPlayer.swift` + controls/trackbar/infobar | 1228 | `UI/NowPlaying/NowPlayingView.swift` |
| `PlaylistCell.swift`, `PlaylistCellRedacted.swift` | 395 | `UI/Components/MediaRowView.swift` |
| `PlaylistScriptHandler.swift` | 316 | Folded into `PlaylistWebLoader` |
| `PlaylistToast.swift`, `PlaylistPopoverView.swift`, `PlaylistMenuButton.swift`, `PlaylistURLBarButton.swift`, `BVC+Playlist.swift` | ~700 | *(deleted — browser chrome)* |
| `PlaylistSettingsViewController.swift` | — | `UI/Settings/SettingsView.swift` |

`PlaybackController` is where most of that logic landed. In Brave, "what plays
next", repeat semantics, resume-from-offset and the expired-media refresh live
*inside* UIKit view controllers that are also managing table views, popovers and
browser tabs. Extracting them into an observable object is the single largest
structural change in this project.

---

## Deliberately not ported

| Brave component | Why |
|---|---|
| `PlaylistSharedFolder.swift`, `syncSharedFolder(s)` | Brave-service playlist sharing; no counterpart |
| `PlaylistP3A.swift` | Brave's privacy-preserving analytics |
| `PlaylistCarplayManager/Controller` | CarPlay needs an entitlement Apple does not grant to sideloaded apps |
| Shields / `ContentBlockerManager` / `Domain` | Ad blocking is a browser feature |
| `BraveCertificateUtility` pinning | Requires Chromium; system trust evaluation is used |
| `PlaylistFolderSharingScript` | Sharing service |
| `MediaBackgroundingScript.js`, `AdsMediaReportingScript.js` | Keep media playing in a *tab*; there are no tabs |
| Long-press-to-add gesture | Requires a web view to long-press |

---

## Brave Core

**No Brave Core (Chromium) code is used, and none is required.**

This was the main open question at the start, and it resolves cleanly. Auditing
`Sources/Playlist/` and the Playlist UI layer for `import BraveCore` finds it in
exactly two places, neither of which is part of Playlist proper:

1. `PlaylistCacheLoader.swift` — `BraveCertificateUtility.verifyTrust(...)` for
   certificate pinning. Replaced with the system's default trust evaluation.
   (This is not a downgrade to "accept anything": `.performDefaultHandling`
   still rejects invalid certificates.)
2. `FaviconFetcher` in the thumbnail utility — backed by Chromium's favicon
   database. Replaced with Open Graph metadata, which yields better artwork for
   a media library anyway.

Everything else in Playlist is AVFoundation, WebKit, CoreData and Foundation.
The `blink`/`net`/`components` layers are not involved: media detection happens
in *JavaScript inside a WKWebView*, not in Chromium's network stack. This is why
the feature can be lifted out of a Chromium fork without dragging Chromium
along.

---

## Third-party packages

Brave's Playlist target depends on `Then`, `SnapKit`, `SDWebImage` and
`Introspect`. All were replaced with local equivalents:

| Brave dependency | Replacement | Size |
|---|---|---|
| `Then` | `Support/Then.swift` | 41 lines |
| `SDWebImage` | `Support/ImageCache.swift` | 132 lines |
| `SnapKit` | *(not needed — SwiftUI)* | — |
| `Preferences` module | `Support/Preferences.swift` | 239 lines |
| `Shared` module helpers | `Support/FoundationExtensions.swift` | 262 lines |
| `UserAgent` module | `Support/UserAgent.swift` | 41 lines |
| `Reach()` (SystemConfiguration) | `Support/Reachability.swift` (Network.framework) | 62 lines |

**The app has zero external package dependencies.** For a sideloaded build this
is not just tidiness: an unresolvable SPM checkout is a hard build failure, and
a free developer account re-signs the app every seven days.
