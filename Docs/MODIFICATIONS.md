# Modifications

Every change made to Brave's Playlist code while extracting it into a
standalone app. Organised by *why* the change was necessary.

Sources are `brave-ios` @ `398f8b7` (release 1.62.2).

---

## 1. Removing the browser

The extraction itself. Brave's Playlist assumes a browser exists around it.

### The web view

Brave's `LivePlaylistWebLoader` is built on `Tab`, which is `WKWebView` plus
Brave's entire content-blocking, shields, user-script and certificate-pinning
stack:

```swift
// brave-ios — LivePlaylistWebLoader
private let tab = Tab(configuration: …, type: .private).then {
  $0.createWebview()
  $0.setScript(script: .playlistMediaSource, enabled: true)
}
// …and in load(url:):
guard let browserViewController = self.currentScene?.browserViewController else { … }
self.certStore = browserViewController.profile.certStore
browserViewController.tab(tab, didCreateWebView: webView)
KVOs.forEach { webView.removeObserver(browserViewController, forKeyPath: $0.keyPath) }
```

Replaced with a plain `WKWebView` plus two user scripts. `Tab`,
`BrowserViewController`, `CertStore`, `ContentBlockerManager`, `Domain`,
`PageData`, `UserScriptManager`, `InternalURL`, `OpenPassBookHelper` and
`UniversalLinkManager` are all gone.

Two upstream behaviours were consciously preserved because they are not
incidental:

- The web view is **parented in the key window at 1% alpha**. Brave inserts its
  loader behind the player view with the comment "if we don't do this, youtube
  shows ads 100% of the time … some weird race-condition in WKWebView where the
  content blockers may not load until the WebView is visible". The underlying
  cause is that WebKit throttles timers and defers media loading for views it
  believes are offscreen — and the detector depends on both.
- Scripts inject at `.atDocumentStart` into **`WKContentWorld.page`**, not an
  isolated world. An isolated world shares the DOM but not the prototype chain,
  so the `HTMLMediaElement.prototype.setAttribute` hook would never fire.

### Certificate pinning

`BraveCertificateUtility.verifyTrust(_:host:port:)` (Brave Core) replaced with
`.performDefaultHandling`. This is not "accept anything" — the system still
rejects invalid certificates. Only Brave's *additional* pinning is lost.

### The detection script's host framework

Brave's `PlaylistScript.js` runs inside a browser-wide bootstrap
(`window.__firefox__.includeOnce`, `$.postNativeMessage`, `$(…)` function
sealing) defined in `__firefox__.js` and injected by `UserScriptManager`.

Rewritten as a plain IIFE posting to `webkit.messageHandlers` directly. The
per-load randomized handler name and security token are preserved; the
function-sealing is not, because it defends against a threat model (arbitrary
browsing on arbitrary sites) that this app does not have.

Also removed from the script: `setupLongPress` (no web view to long-press) and
the dead `useObservers` branch, which upstream hardcodes to `false`.

### UI

~5,700 lines of UIKit view controllers rewritten in SwiftUI. See
[BRAVE-COMPONENTS.md](BRAVE-COMPONENTS.md#rewritten-browser-coupled) for the
file-by-file mapping. The behaviours — repeat semantics, resume points, the
expired-media refresh — were carried over; the code was not.

---

## 2. Removing Brave services

| Removed | Reason |
|---|---|
| `PlaylistSharedFolder.swift`, `PlaylistManager.syncSharedFolder(s)`, `PlaylistFolder.sharedFolder*`, `PlaylistItem.updateItems(_:newETag:)` | Brave's playlist-sharing service |
| `PlaylistP3A.swift` | Brave's privacy-preserving analytics |
| `FaviconFetcher` (Brave Core) | Replaced by Open Graph metadata — better artwork for a media library |
| CarPlay (`PlaylistCarplayManager`, `PlaylistCarplayController`, ~1,200 lines) | Needs an entitlement Apple does not issue for sideloaded apps |

---

## 3. Removing third-party packages

`Then`, `SnapKit`, `SDWebImage` and Brave's `Shared` / `Preferences` /
`UserAgent` / `Data` SPM modules replaced with ~780 lines of local code in
`Support/`. See the table in
[BRAVE-COMPONENTS.md](BRAVE-COMPONENTS.md#third-party-packages).

The app has **zero external dependencies**. For a sideloaded build this is
load-bearing rather than tidy: a free developer account re-signs the app every
seven days, and an unresolvable SPM checkout is a hard build failure at exactly
the moment you need it to work.

### CoreData model

Brave compiles a versioned `Model.xcdatamodeld` with ~40 model versions and ~15
browser entities. Here the model is **built programmatically** in
`DataController.managedObjectModel`, with two entities.

Attribute names and types match upstream exactly, so a diff against Brave still
lines up. The trade-off: a future schema change needs either an inferred
lightweight migration (which still works — `shouldInferMappingModelAutomatically`
is on) or a hand-written mapping, rather than Xcode's model editor. For an app
starting at version 1 that is a good trade, and it removes the `momc` build step
that a hand-written `project.pbxproj` would otherwise need to invoke.

Two attributes are this app's own: `PlaylistItem.artworkURL` and
`PlaylistFolder.isAnonymous`. Both are added in the shape CoreData can infer a
mapping for — optional, or non-optional with a default — because a store that
fails to open is fatal here by design, and `PlaylistAnonymityTests` asserts that
property of the model rather than trusting it.

---

## 4. Modernisation

Deployment target is iOS 17, so several upstream workarounds are obsolete.

### `MediaPlayer.swift`

Removed the entire `#unavailable(iOS 16)` `previousRate` mechanism — an involved
KVO dance working around `AVPlayer` lacking `defaultRate` before iOS 16, whose
own comment reads *"So we need to do some weird hacks below."* Replaced with
`player.defaultRate`.

### `PlaylistManager.getAssetDuration`

Upstream is ~160 lines of `statusOfValue(forKey:)` / `loadValuesAsynchronously`
with careful commentary about which property accesses block the main thread.
Rewritten as ~50 lines against `try await asset.load(.duration)`, which does not
have the hazard.

### `ThumbnailRenderer`

Brave chains Combine `Future`s with `.catch { }` to express "try each source
until one works". Rewritten as sequential `await`s, which is what that chain is.

### `Reachability`

`Reach()` (SystemConfiguration, deprecated) → `NWPathMonitor`.
`DeviceInfo.hasWifiConnection()` → `NWPath.isExpensive`/`isConstrained`, which
correctly treats a personal hotspot as metered.

---

## 5. Defects fixed

Found while porting. Each has a `NOTE:` at the site; the first four have
regression tests.

### 5.1 Completions fired before the CoreData save — **fixed, tested**

`DataController.perform` saves the context *after* the task closure returns, but
every call site dispatches its completion from *inside* that closure:

```swift
// brave-ios — PlaylistItem.addItem
DataController.perform(context: .new(inMemory: false), save: false) { context in
  …
  PlaylistItem.saveContext(context)
  DispatchQueue.main.async { completion?() }   // ← races the merge into viewContext
}
```

So "completion" meant "staged", while every caller assumed "visible". Concretely:
`AddMediaView` starts an auto-download from that completion, and the download
manager immediately writes a bookmark back onto a row that may not exist yet.

**Fix:** `perform` takes a `completion:` parameter and invokes it on the main
queue after the save. All call sites use it.
*Test: `LibraryStorageTests.testUpdateItemPreservesIdentity`, `testDeleteRemovesItem`.*

### 5.2 `.downloaded` announced before the bookmark was stored — **fixed, tested**

```swift
// brave-ios — PlaylistDownloadManager
DispatchQueue.main.async {
  PlaylistItem.updateCache(uuid: asset.id, …, cachedData: cachedData)  // async
  self.delegate?.onDownloadStateChanged(… state: .downloaded …)        // fires first
}
```

`updateCache` is asynchronous. Listeners receive `.downloaded` and immediately
ask `PlaylistManager.state(for:)`, which reads the field that has not been
written yet — so a completed download reads back as not-downloaded.

**Fix:** `updateCache` takes a completion; the state change is announced from
it.
*Test: `DownloadIntegrationTests.testDownloadsAndProducesAPlayableLocalFile`.*

### 5.3 Row aliasing across items from one page — **fixed, tested**

Every update path resolves its row with:

```swift
NSPredicate(format: "uuid == %@ OR pageSrc == %@", uuid, pageSrc)
```

`pageSrc` is not unique. One page can contribute several items — which Brave
supports and comments on directly: *"you can add multiple items per page but
they'd each have a different media source"*. When it does, `first(where:)` can
return a **sibling**, so one item's update — including its downloaded-file
bookmark — lands on another item.

**Fix:** `PlaylistItem.firstMatching(uuid:pageSrc:)` resolves by uuid first and
only falls back to `pageSrc` for legacy rows that have no uuid. The existence
guards were updated to match, since a guard that says "yes" where the lookup
says "no" turns an update into a silent no-op.
*Test: `LibraryStorageTests.testUpdatingOneItemDoesNotClobberASiblingFromTheSamePage`.*

### 5.4 `Content-Type` parameters defeated MIME detection — **fixed, tested**

`PlaylistMimeTypeDetector(mimeType:)` matches the raw header against its table,
so an ordinary `video/mp4; charset=utf-8` misses every entry and the download is
named `.mp4` by luck rather than detection.

**Fix:** strip parameters and lowercase before matching.
*Test: `MimeTypeDetectionTests.testStripsContentTypeParameters`.*

### 5.5 MP3 files saved with an `.mp4` extension — **fixed, tested**

```swift
// brave-ios — PlaylistMimeTypeDetector(data:)
if findHeader(offset: 0, data: data, header: [0xFF, 0xFB]) || …[0x49, 0x44, 0x33]… {
  mimeType = "audio/mpeg"
  fileExtension = "mp4"      // ← the later `mp3` branch is unreachable
```

*Test: `MimeTypeDetectionTests.testDetectsMP3FromID3Header`.*

### 5.6 `data:` downloads used the wrong session — **fixed**

`downloadDataAsset` passes `self.fileSession` to the *data* delegate and
enqueues onto `fileQueue`, so `data:` URI downloads were driven by a session
whose delegate never sees them. The session was also configured as a background
session, which does not support `dataTask` at all.

### 5.7 Cancelling a download reported it as a failure — **fixed**

`PlaylistFileDownloadManager.cancelDownload` never appends to
`pendingCancellationTasks`, so the branch that suppresses the error is
unreachable. A user-initiated cancel surfaced as a download failure, and hit an
`assertionFailure` in debug builds.

### 5.8 `data:` payloads assumed to arrive in one delivery — **fixed**

`urlSession(_:dataTask:didReceive:)` writes the file from inside the callback.
`URLSession` may deliver a payload in several chunks, each overwriting the last.
Now accumulated and written on completion.

### 5.9 `assertionFailure` on ordinary network errors — **fixed**

Both download delegates call `assertionFailure` for any non-cancellation error.
A 404 from an expired media URL is the single most likely outcome in this app,
not a programming error. Replaced with logging.

### 5.10 Repeat mode published one step behind — **fixed**

```swift
// brave-ios — MediaPlayer.toggleRepeatMode
case .none:
  command.currentRepeatType = .off    // publishes the OUTGOING state
  self.repeatState = .repeatOne       // …while moving to a different one
```

Control Center therefore always showed the previous mode. The cycle order was
also `none → one → all`, the reverse of the platform convention.

**Fix:** publish the incoming state; cycle `none → all → one`; and honour the
exact mode when Control Center's three-way control sends one, rather than
cycling from wherever we happened to be.

### 5.11 `toggleShuffleMode` never changed the shuffle state — **fixed**

Upstream updates `MPRemoteCommandCenter` but never assigns `shuffleState`, so
the player's own view of shuffle never changed. (Shuffle is disabled outright in
Brave's UI — `changeShuffleModeCommand.isEnabled = false` — which is presumably
why this went unnoticed.)

### 5.12 `downloadTask(for:)` blocked the calling thread — **fixed**

Upstream dispatches to three `OperationQueue`s and `group.wait()`s when called
off the main thread. All three queues *are* `OperationQueue.main`, so the wait
blocks until the main queue drains — and would deadlock outright from the main
thread were it not for an `isMainThread` special case. Since the state is only
ever mutated on the main queue, reading it there is sufficient.

### 5.13 Now Playing cleared before every update — **fixed**

`setNowPlayingInfo` nils the dictionary before reassigning it, producing a
visible flicker of empty lock-screen metadata on every track change. A single
assignment is atomic from the system's point of view.

### 5.14 Dead WebM/Matroska branch — **fixed**

`PlaylistMimeTypeDetector(data:)` probes the same four EBML bytes twice and
assigns `webm` both times, making the `mkv` branch unreachable. Dropped.

### 5.15 Artwork flickered between the thumbnail and the placeholder — **fixed**

This one is this app's own, in `ArtworkView` rather than anything of Brave's.
Three faults compounding:

* The view blanked `image` to nil at the start of every load, then fetched
  through an actor. SwiftUI recycles these views constantly — every list row
  reuse, and every rebuild of the branch the mini player lives in — and each
  recycle hands the view fresh `@State`. So a thumbnail that was already in
  memory still spent a frame or two showing the film placeholder, which reads
  as flickering.
* A nil result was recorded as a completed attempt, permanently. An item played
  before its download finished resolved to whatever artwork existed at that
  moment — often none — and the mini player, which outlives every list row, kept
  that answer for the rest of the session.
* `withAnimation` wrapped the assignment even when the new value was nil, so a
  failed reload *faded* the artwork out into the placeholder rather than leaving
  it alone.

Fixed by painting straight from the memory cache during `body`
(`ThumbnailRenderer.cachedThumbnail(id:)`, synchronous and `nonisolated`), only
clearing the image when the item genuinely changed, animating only real images,
and re-requesting on a new `.thumbnailInvalidated` notification — which
`ThumbnailRenderer.invalidate(id:)` now posts, and which `PlaybackController`
also observes so the Now Playing and lock screens pick up the real frame once a
download lands.

### 5.16 The player's controls did not follow a newly started item — **fixed, tested**

Also this app's own. `MediaPlayer.isPlaying` was defined as
`timeControlStatus == .playing` — "audio is actually coming out" — and both
`play()` and `pause()` guarded on it, while `PlaybackController` published it.

That definition is right for the question it asks and wrong for driving a
transport. A newly started item is in `.waitingToPlayAtSpecifiedRate`, not
`.playing`, for as long as it takes to fill a buffer: a moment for a local file,
several seconds for a stream. Through that window `isPlaying` was false, so the
Now Playing screen showed a **play** button for an item that was already on its
way — and tapping it did nothing, because `togglePlayPause` read the same flag,
called `play()`, and `play()`'s own guard dropped the call.

Compounding it, the only thing that resynchronised the published flags was the
periodic time observer, which ticks when time advances and therefore says
nothing at all while an item is buffering or stalled.

Fixed with `isPlaybackRequested` (`timeControlStatus != .paused`) as the transport's
notion of playing, and by observing `timeControlStatus` and `currentItem`
directly — a new `.playbackStatusChanged` event — so every transition is
published rather than waiting for playback to produce one.

### 5.17 Dismissing the player revealed a black screen — **fixed**

`NowPlayingView` was presented with `.fullScreenCover`. Once a cover is fully
presented, UIKit takes the presenting view controller's view out of the window;
there is nothing behind it to see. The player's own drag-to-dismiss gesture
shrinks and offsets it as the finger moves, which uncovered that nothing — a
black frame — and the app then reappeared abruptly at the end of the animation.
A `Color.black` backdrop had been added underneath to make the void look
deliberate.

The player is now a sibling of the `TabView` inside `RootView`'s `ZStack`, shown
with a move transition. The library stays in the hierarchy and is what the drag
reveals, and the corners round off as the player lifts away.

### 5.18 The browsing folder scoped screens that are not about a folder — **fixed, tested**

`PlaylistManager` owns one fetched results controller, and `currentFolder`
rebuilds it with that folder's predicate. That is right for the library list and
wrong for everything else reading `allItems` or `fetchedObjects`: the Downloads
tab, `storageUsage()` and `deleteAllItems(cacheOnly:)` are all questions
about the library as a whole. Opening an empty playlist in the Library tab
therefore emptied the Downloads tab as well, and would have made "delete
everything" delete only what the user was looking at.

Library-wide callers now fetch through `everyItem` / `everyItemObject`, which
carry no folder predicate, and `LibraryViewModel` takes a `Scope` so the
Downloads screen states which of the two it wants.

The other half of the same report: `LibraryView` swapped the whole list for
`ContentUnavailableView` whenever the visible items ran out — and the playlist
switcher lives *in* that list. Selecting an empty playlist left "Nothing Saved
Yet" and no way back to the rest of the library. The full-screen empty state is
now only for when there is nowhere else to go; an empty playlist keeps the list
and puts the message in the items section.

### 5.19 Selecting the item already playing restarted it — **fixed**

Every list called `PlaybackController.play(item:in:)`, which loads
unconditionally — so tapping the row you are listening to reloaded the asset and
seeked back to its stored resume point, throwing away your place in it. The
easiest tap in the app to make by accident had the most destructive result.

Rows now call `select(item:in:)` (and `select(at:)` in the queue), which does
nothing when the item is already current. `play(item:in:)` stays the
unconditional primitive, because "Play All", a Shortcut and an automatic advance
all have to start a queue whether or not its first item is the one loaded.

### 5.20 The player's dark scheme applied to the whole window — **fixed**

`NowPlayingView` carried both `.environment(\.colorScheme, .dark)` and
`.preferredColorScheme(.dark)`. The first is scoped to the player's own subtree;
the second is a *preference*, which propagates up to the window and repaints
everything in it. Since §5.17 made the library visible behind the player during
the drag, that library came out dark in light mode — the drag revealed the app
in the wrong appearance and then snapped back to light when the player left.

The window's scheme now belongs to `RootView`, which asks for dark only while
the player is at rest covering the screen: `NowPlayingView` clears the flag as
the first pixel of library shows, and it is set again on the presentation
animation's completion rather than at its start. The player itself is dark
throughout from the environment override, and its two sheets state
`.preferredColorScheme(.dark)` for themselves.

---

## 5b. Defects fixed in the pre-release review

Not upstream's. These are this project's own, found going back over the app
before open-sourcing it. Same convention: a `NOTE:` at the site where the wrong
answer is the tempting one.

### 5b.1 The swipe rebuilt the whole tab shell on every frame — **fixed**

`NowPlayingView`'s drag handler assigned `isCoveringScreen = false` on every
`onChanged`, unconditionally. That binding is `RootView`'s state, so each of the
hundred-odd events a drag delivers invalidated `RootView` — and with it the
`TabView`, the tab bar, and the mini player in the accessory slot. Those are the
most expensive views in the app to rebuild and they sit along the bottom edge,
which is where the swipe visibly came apart. It is now written only on the
transition.

### 5b.2 The player jumped when a drag was recognised — **fixed**

`DragGesture(minimumDistance: 10)` delivers its first event with those ten
points already in `translation`, and the offset took it verbatim — so the player
leapt ten points the instant the gesture was admitted, every time. The slop is
subtracted back out, which also means the frame that flips the window's colour
scheme is a frame on which nothing moves.

### 5b.3 Releasing the drag restarted the motion — **fixed**

On release the overlay's `.move(edge: .bottom)` transition took over: the scale
and corner radius froze at whatever the finger left them at, and the remaining
travel was the container's full height rather than the distance actually left.
A slow release and a fast flick produced the same animation. The player now
animates its own `dragOffset` to the bottom of the screen — same value, same
derived scale, radius and scrim, continuous across the release — and asks to be
removed only once it is there. The spring is launched at the finger's velocity
(`Animation.playerTravel`), so a flick carries.

### 5b.4 Queue items could not be tapped — **fixed**

`QueueView` forced `editMode` to `.active` so reorder handles were always
showing. A list in edit mode does not deliver taps to its rows' buttons, so
tapping a queue entry to play it — half of what the screen is for — did nothing
at all. Edit mode is gone; a long press still picks a row up, and swipe-to-delete
works outside it too.

### 5b.5 Library rows could never be reordered — **fixed**

The mirror image: `LibraryView` forced `editMode` to `.inactive`, which
suppressed the drag outright, so the "drag to reorder" the custom sort order
exists for never worked. `onMove` is now passed only in the custom order with no
search active, and nil otherwise — nil is what tells the list a row cannot be
picked up, rather than letting it lift and snap back.

### 5b.6 The sleep-timer countdown never counted down — **fixed**

`SleepTimer.remaining` is derived from a deadline, so nothing publishes as it
changes; the controller announces the timer when it is set and again when it is
cancelled. Both the badge and the sleep-timer sheet were therefore frozen at
whatever the value read when the view was last built. `SleepTimerCountdown` puts
them in a `TimelineView`, which stops on its own when off screen — a shared
`Timer` feeding published state would wake the app once a second through a whole
night's playback for a label nobody is looking at.

### 5b.7 The play button stuck at the end of a queue — **fixed**

Reaching the end of a non-repeating queue called `player.pause()`, which guards
on `isPlaybackRequested`. An item that has run out is already paused as far as
`AVPlayer` is concerned, so the call did nothing and published nothing —
`isPlaying` stayed true, and every play button in the app went on showing pause.
`stopAtEndOfQueue()` reads the flags back from the player by hand.

### 5b.8 Storage was measured on the main thread, inside `body` — **fixed**

`totalStorageUsed()` and the per-item sizes walk directories, and an HLS
`.movpkg` is a bundle of thousands of files. Settings called the first inline in
`body` and Downloads called the second per row, so a toggle or a scroll re-stat-ed
the whole library before it could draw. See `PlaylistManager.storageUsage()` in §6.

### 5b.9 The rename alert used a constant binding — **fixed**

`.alert(isPresented: .constant(renamingItem != nil))` gives the alert no way to
report that it closed. Any dismissal the system performed itself left
`renamingItem` set, and rename was then dead for the rest of the session.

### 5b.10 The add sheet read the clipboard on appear — **fixed**

It prefilled the address field from the pasteboard whenever the sheet opened.
Since iOS 16 that puts a system alert in front of the user asking them to allow
the read — so the convenience cost a modal on every visit, and the app looked at
the clipboard whether or not there was anything on it for us. Replaced with
`PasteButton`, which hands the value over on an explicit tap, with no alert and
no read until then.

### 5b.11 Queueing an item already in the queue did nothing — **fixed**

`addToQueue` and `playNext` filtered out anything already queued, so the menu
item silently no-oped on a duplicate. The user cannot see the whole queue from
the library, so that reads as a broken button rather than as a duplicate
refused. Both now move the item instead; the one playing is never moved.

### 5b.12 The mini player was unreachable and silent about failures — **fixed**

It opened the full player from an `onTapGesture` on the bar, which VoiceOver
cannot see — the assistive user got a container with a label and no action.
And `errorMessage` is only ever presented as an alert *on* the full player, so a
load that failed while it was closed — which is most of them, since playback
usually starts from a library row — left a play button that did nothing and no
indication why. The tap area is a real button, and the subtitle line reports the
error.

### 5b.13 The skip buttons always drew 15 seconds — **fixed**

`Skip Interval` offers 10, 15, 30 and 45, and the glyphs were hard-coded to
`gobackward.15` / `goforward.15`, so three of the four settings left the player
showing a number it did not obey. The accessibility labels said 15 too.

### 5b.14 Adding from inside a playlist filed the item elsewhere — **fixed**

`AddMediaView` always passed no folder, which files into the default one. With
the browsing playlist now remembered across launches (§6), a user who lives
inside one playlist would have added to it repeatedly and found nothing there.
It takes the browsing playlist as its destination and says which one it is.

---

## 6. Additions

Features with no upstream counterpart, added because a standalone media player
needs them where a browser feature did not.

| Addition | Where | Why |
|---|---|---|
| Paste-a-URL entry point | `MediaExtractor`, `AddMediaView` | Brave's Playlist is fed by the tab you are already on. This app has no tabs, so this *is* the product |
| Direct-URL fast path | `MediaExtractor.directMediaItem` | A link to a `.mp4` needs one ranged request, not a whole web view |
| Multi-candidate extraction | `PlaylistWebLoader` | Brave takes the first item and navigates away. With no page context to disambiguate, the first reporter is often a pre-roll ad — so candidates are collected for a 2.5 s settle window and ranked by duration, then by container |
| Per-site user agent | `UserAgent.userAgent(for:)`, `YouTube` | YouTube decides server-side, from the request's UA, whether the watch page carries a progressive format at all: none for desktop, itag 18 for an iPhone. The swizzle can only reveal a fallback that the server already put in the page, so this has to be right *before* the request. Brave never faces this — a browser is already a mobile client on the page the user opened |
| YouTube address handling | `YouTube`, `MediaExtractor` | `youtu.be/`, `/shorts/`, `/embed/`, `/live/` and `music.youtube.com` all normalise to one mobile watch page, which is also what gets stored as `pageSrc` for re-extraction |
| Declared-length ranking | `PlaylistWebLoader.rank(_:matching:)` | A `googlevideo.com` URL states its own length in a `dur` parameter, and the watch page states the video's. Matching the two is what stops a pre-roll advert being saved instead of a short video — duration alone picks the advert |
| Sign-in redirect refusal | `PlaylistWebLoader`, `YouTube.isSignInRedirect` | A cookieless web view gets bounced to `accounts.google.com` a few seconds into a YouTube load, which unloads the watch page mid-extraction. There is nothing for us behind a sign-in, so the navigation is cancelled — and `NSURLErrorCancelled` is no longer treated as a failed load, since it never means the current document died |
| YouTube sign-in | `YouTubeSession`, `SignInView`, `SettingsView` | Age-restricted and members-only videos are refused by YouTube to anonymous clients, before extraction has anything to work with. Brave needs no equivalent because its Playlist runs in a tab that is already signed in. A visible web view — the only one in the app — shows Google's own login page behind a host allowlist, and the resulting cookie lives in WebKit's persistent store. The app never handles a credential |
| Session-scoped cookie store | `YouTubeSession.dataStore(for:)`, `PlaylistWebLoader` | Extraction stays cookieless for every site, as before. The one exception is a YouTube load once the user has signed in, which is the trade they opted into by signing in |
| Playability reporting | `YouTube.Metadata`, `PlaylistWebLoader.playabilityIssue`, `MediaExtractor` | The watch page states *why* it will not play — `LOGIN_REQUIRED`, `UNPLAYABLE` and a human sentence. Reporting "no downloadable media was found" for a video that YouTube simply refused to serve is misleading, and hides the one failure the user can fix |
| Sleep timer | `PlaybackController.SleepTimer` | Duration-based or end-of-track |
| Anonymised playlists | `PlaylistFolder.isAnonymous`, `NowPlayingInfo.setAnonymousNowPlayingInfo`, `NowPlayingView` options menu | A playlist can withhold its titles and artwork from the lock screen and Control Centre, leaving working transport controls and a timeline and nothing else. Per folder rather than per app, because the reason for wanting it is one playlist you would rather not have announced on a screen other people can see. Brave has no equivalent: a browser's Playlist is metadata about tabs the user is already showing on their own screen |
| Segmented playlists | `PlaylistSegment`, `PlaylistFolder.segmentDuration`, `PlaylistItem.segmentIndex`, `PlaybackController` segment section, `SegmentSettingsView` | A playlist can be given a length — three minutes, say — and plays that much of each item before moving on, picking up where it left off the next time round. The length belongs to the folder, the progress to the item, for the same reason as anonymity: a queue can be assembled from several playlists at once, and moving an item between them should not lose where it had got to. Items no longer than one segment are exempt, since dividing them would mean playing silence. On repeat the playlist works through every segment of every item and only then starts again from the top — progress counts *past* an item's last segment rather than wrapping at it, which is what makes "everything has been played" a state the queue can act on |
| Picture-in-Picture preference | `Preferences.Playlist.pictureInPictureEnabled`, `MediaPlayer.applyPictureInPictureSetting` | Upstream sets `canStartPictureInPictureAutomaticallyFromInline` unconditionally, which is the whole feature here — with no PiP button in the app, backgrounding a video is the only way a window appears. Off keeps the audio and drops the window |
| App Intents (Shortcuts, Siri) | `Intents/PlaylistIntents.swift`, `AppIntentRouter`, `PlaybackController.play(folderUUID:shuffled:)` | Play or open a playlist from a Shortcut, an automation or Siri. `PlayPlaylistIntent` is an `AudioPlaybackIntent`, so it starts audio without bringing the app forward — the app may not even have been running. Playlists are addressed by folder UUID, so renaming one does not break a saved Shortcut |
| Persisted artwork (`artworkURL`) | `PlaylistInfo`, `PlaylistItem`, `PlaylistDetector.js` | Brave re-derives artwork from a favicon on every render. A library shows artwork far more prominently, so `og:image` is captured at add time |
| Library sorting | `LibrarySortOrder`, `PlaylistItem.sortDescriptors(for:)` | Brave's list is manual-order only |
| Library search | `LibraryViewModel`, `PlaylistItem.search(query:)` | — |
| Remembered playlist selection | `Preferences.Playlist.selectedFolderUUID`, `LibraryViewModel.restoreSelectedFolder` | Picking a playlist says what the user is listening to at the moment, not what they want filtered for the next thirty seconds, so the app reopens on it. Empty records All Media, which makes "never chose anything" and "chose everything" the same state — right, because they want the same screen. A UUID that no longer names a folder falls back and is cleared rather than retried every launch. Brave has no equivalent: its Playlist opens from a browser tab, so there is no "last time" to return to |
| Segment-relative Now Playing timeline | `MediaPlayer.playbackWindow`, `NowPlayingInfo.playbackDuration`, `PlaybackController.currentSegment` observer | While a segmented playlist is playing, the lock screen is told the segment's length and how far into *it* playback is, rather than the track's — the two disagree by design, and publishing the track's leaves a scrubber promising twenty more minutes of something about to stop. The window also bounds the remote skip buttons and maps a scrubbed position back into the item's timebase, so a drag to the end of the lock screen's bar lands at the end of the segment instead of past it |
| Storage measured off the main thread | `PlaylistManager.storageUsage()` | Every figure on the storage screens is a directory walk, and an HLS `.movpkg` is a bundle of thousands of files. They were being taken during `body`, so scrolling the Downloads list re-`stat`-ed every bundle in it once per row per frame. The bookmarks cross to a background task; the CoreData rows they come from are read on the main queue first, because resolving one through `localAsset(for:)` fetches from a main-queue context |
| Storage accounting | `PlaylistManager.storageUsage()`, `StorageView` | "Which downloads are eating my disk" is a real question for an offline library |
| Queue management | `PlaybackController` | Reorder, play-next, add-to-queue, remove |
| `playlist://add?url=…` URL scheme | `RootView.handle(incoming:)` | Lets a link reach the app from a Shortcut or another app without copy-switch-paste |
| Playback state observed rather than polled | `MediaPlayer.isPlaybackRequested`, `.playbackStatusChanged` | See §5.16 |
| Background session completion handlers | `AppDelegate`, `PlaylistDownloadManager` | So a download finishing while the app is suspended can wake it, be filed, and let it suspend again |
| Route-change handling | `MediaPlayer` | Pause on headphone unplug rather than blasting the speaker |
| Test suite (115 tests) | `PlaylistTests/` | Brave's `PlaylistTests.swift` covers URL parsing only |

---

## 7. Deliberate non-changes

Preserved as-is because the reasoning is sound and not obvious:

- **Bookmark data, not paths**, in `PlaylistItem.cachedData`. iOS relocates app
  containers between installs and OS upgrades; a stored path goes stale and
  every download appears to vanish.
- **Application Support, not Caches**, for media, excluded from backups. Caches
  is purgeable under storage pressure — the user's downloads would silently
  disappear.
- **`deleteUserManagedAssets()` on every launch.** `AVAssetDownloadURLSession`
  stages HLS downloads in `com.apple.UserManagedAssets*`; an interrupted
  download strands gigabytes there, invisible and unresumable.
- **File deleted before row.** The reverse — or a cascade delete rule — orphans
  the bytes, since nothing would remain that knows the file exists.
- **`isVideoTracksAvailable()` biased towards "video".** For HLS, tracks are
  often unresolved; guessing "audio" would show the audio-only UI over a video
  about to start.
- **`HLSThumbnailGenerator`'s `deinit` ordering.** Its comment documents a real
  KVO crash, not a style preference.
- **The one-byte ranged GET** for MIME probing. Many media CDNs answer `HEAD`
  differently from a real transfer, or not at all.
- **The `_WKRecoveryAttempterErrorKey` guard.** WebKit reports a spurious
  navigation failure for pages it is about to reload itself.
