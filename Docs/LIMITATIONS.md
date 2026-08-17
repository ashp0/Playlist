# Limitations

What this app cannot do, and why. Read this before concluding something is
broken.

---

## Not every site can be saved

The app finds media the same way Brave's Playlist does: it loads the page in an
offscreen WebKit view and watches what URL the page's own player hands to its
`<video>` element.

That approach works on a large number of sites. It does not work on all of them,
and the failures are structural rather than bugs.

### DRM-protected content — never

Netflix, Disney+, Apple TV+, Amazon Prime Video, Spotify and similar services
deliver video through Encrypted Media Extensions with a licence server. The
bytes are encrypted, the decryption key is held by a DRM module, and there is no
sequence of events that yields a playable file. This is not a limitation of the
technique; it is the entire purpose of the technology.

**The app will find nothing on these sites, and no setting changes that.**

### Strictly MSE-only players — usually not

Media Source Extensions let a player fetch media in chunks with JavaScript and
feed it to a `<video>` element through a `blob:` URL. A `blob:` handle is
meaningless outside the page that made it and expires with it, so it cannot be
downloaded.

`PlaylistSwizzler.js` deletes the MediaSource API at document start. Players
that feature-detect it then fall back to a plain progressive URL, which *is*
downloadable — this is the single most important trick in the extraction path
and it is why the app works on as much as it does.

But a player that requires MSE with no fallback will simply fail to start. In
that case there is nothing to detect. Settings → *Finding Media* → **Allow
Streaming APIs** restores the API so such a page can at least load and play, but
media found that way generally cannot be downloaded.

### YouTube specifically — works, at 360p

This section previously said YouTube could not work at all, on the grounds that
its watch page contained no progressive format for the swizzle to fall back to.
**That finding was an artefact of how it was tested, not a fact about YouTube.**
The probe used a desktop user agent; the app defaulted to one too.

YouTube decides *server-side*, from the `User-Agent` on the watch-page request,
whether `streamingData` carries a progressive (muxed audio+video) format at
all. Re-tested on 2026-08-06 across three videos:

| Request as | `formats` (progressive) | `adaptiveFormats` |
|---|---|---|
| desktop Safari | **0** — or one, ciphered | 14–40 |
| iPhone Safari | **1** — itag 18, muxed MP4 | 19–41 |
| iPad Safari | **1** — itag 18, muxed MP4 | 19–41 |

The asymmetry is not arbitrary. iPhone Safari had no Media Source Extensions at
all until `ManagedMediaSource` in iOS 17.1, so YouTube has always had to keep a
progressive path alive for it. `PlaylistSwizzler.js` deletes both `MediaSource`
and `ManagedMediaSource`, which puts the page back into exactly that bucket —
but only if it was *requested* as an iPhone, because by the time our script runs
the server has already chosen what to put in the HTML.

So the fix was one line of intent: YouTube is always requested with the mobile
user agent, whatever the global desktop-mode preference says. See
`Playlist/Extraction/YouTube.swift`, and `UserAgent.userAgent(for:)`.

**The media URL still must come from the live page, never from that JSON.** The
`url` in the watch page carries an encrypted `n` parameter, and often a
`signatureCipher` in place of a signature; fetching it directly returns 403.
Letting YouTube's own `html5player.js` decrypt `n`, apply the signature and
assign the result to `<video src>` — which is precisely what Brave's detector
hook already observes — yields a URL that then downloads with a plain
`URLSession` and no special headers at all. This is why the WebKit approach
succeeds where HTTP parsing fails, and why no PO-token minter or SABR client is
needed.

#### What you actually get

**360p, muxed, with audio.** itag 18 is 640×360 H.264 + AAC (or the source
resolution if the video was never above that — "Me at the zoo" downloads at its
native 320×240). Checked across eight videos on 2026-08-06, itag 18 was the only
progressive format on every one of them; itag 22 (720p muxed) is gone.

**360p is a real ceiling, not a setting.** There is no quality option to raise,
and the reason is worth writing down so it is not re-investigated every few
months.

Higher resolutions do exist in the watch page — 41 adaptive formats up to
2160p60, and with a mobile user agent every one of them carries a *plain* `url`
rather than a `signatureCipher`. They look downloadable. They are not:

1. **Fetching one directly returns 403.** The `url` carries an `n` parameter
   that is still encrypted. YouTube's player decrypts `n` before use — that is
   visible in the progressive case, where the URL the page assigns to `<video>`
   has a different `n` from the one in the JSON, and *that* one fetches fine.
   Making adaptive formats work therefore means running YouTube's `n`
   descrambler, which lives in minified `base.js` and has to be located by
   pattern-matching. That is what `yt-dlp` does, and it is why `yt-dlp` needs
   updating every few months.
2. **The player never requests them individually either.** With `MediaSource`
   left enabled so the player picks adaptive streams, the only media request it
   makes is a single `POST` to `/videoplayback` with no `itag` — SABR, carrying
   a protobuf body. There is no per-format URL to observe, so hooking `fetch`
   and `XMLHttpRequest` yields nothing usable. Verified 2026-08-06.

So the choice is a 360p file that works and keeps working, or a signature
descrambler that breaks without warning on a sideloaded app that cannot be
updated quickly. This app takes the first. For a 1080p archive, `yt-dlp` on a
computer remains the right tool, and its output can be added here as a direct
media link.

#### Signing in

Age-restricted, members-only and private videos are refused to signed-out
clients by YouTube itself, before extraction has anything to work with. There is
now an optional sign-in under **Settings → YouTube Account**: it opens Google's
own login page in a web view restricted to Google's hosts, and keeps the
resulting cookie in WebKit's store. The app never sees a password.

Once signed in, YouTube watch pages — and only YouTube watch pages — are loaded
with that session. Every other site stays cookieless, as before.

Signing in does **not** raise the 360p ceiling. It changes which videos are
reachable, not what formats exist.

#### YouTube cases that still do not work

| | Why |
|---|---|
| **Live streams** | No progressive format exists while a stream is live. |
| **Anything above 360p** | Adaptive-only, and gated behind the `n` descrambler and SABR described above. |
| **Age-restricted / members-only, signed out** | YouTube refuses them to anonymous clients. The app now says so explicitly and points at Settings, rather than reporting "no media found". Sign in and they work. |
| **Channel, playlist and search links** | These name no single video; the app says so rather than timing out. Open the video and use its own link. |

#### Two behaviours worth knowing

**Media URLs expire in about six hours.** This is more aggressive than most
sites. Downloading immediately is the only reliable way to keep something; the
app re-extracts automatically when a stale link fails during playback.

**Pre-roll adverts.** When YouTube plays an advert first, the player assigns the
advert's URL to the same element before the feature's. The loader waits a longer
settle window on YouTube for this reason, and picks the candidate whose length
matches the length the watch page declares for itself — so an advert cannot win
merely by running longer than a short video.

### What does tend to work

Direct media links (`.mp4`, `.m3u8`, `.mp3`, `.m4a`, …), self-hosted
`<video>` tags, many news and blog embeds, podcast audio, and sites using
straightforward HLS. The direct-URL fast path in particular is completely
reliable — it needs no page, no web view and no heuristics.

---

## Media links expire

Media URLs from any large site are signed and time-limited. An item added but
not downloaded will frequently be unplayable within hours.

The app handles this the way Brave does: when playback of a non-downloaded item
fails and the network is available, it silently re-loads the original page,
re-extracts a fresh URL, and retries — keeping the item's identity, queue
position and resume point.

**Downloading immediately is the only reliable way to keep something.** That is
why auto-download defaults to on.

---

## No CarPlay

Brave's Playlist has full CarPlay support (~1,200 lines). It is not ported,
because CarPlay audio requires an entitlement Apple grants only to approved App
Store apps. It cannot function on a sideloaded build regardless of the code.

---

## Platform behaviours

| | Detail |
|---|---|
| **HLS downloads in the simulator** | Do not work. `AVAssetDownloadURLSession` is unsupported there — Brave's source carries the same note. Test on a device. |
| **WebM / MKV** | Detected and downloadable, but AVFoundation cannot play them. They will appear in the library and fail to start. |
| **Live streams** | Playable; not downloadable. Shown with a LIVE badge and no scrub bar. |
| **Background extraction** | Only while the app is foregrounded. WebKit will not run a page's JavaScript reliably in the background, so extraction cannot be a background task. Downloads *do* continue in the background — that is a `URLSession` matter, not a WebKit one. |
| **Free-account signing** | The app stops launching after 7 days and must be re-signed from Xcode. Your library survives. See [SIDELOADING.md](SIDELOADING.md). |

---

## Deliberate scope choices

Not bugs; just not built.

- **No browsing.** By design — the brief asked for the browser to be removed.
  Extraction happens in an invisible web view with no navigation, no history and
  no persistence.
- **No account sync.** Everything is local to the device.
- **No playlist sharing.** Brave's shared-folder feature depends on a Brave
  service.
- **No subtitle support.** Brave's detector reports `text/vtt` tracks, but
  neither app does anything with them.
- **No AirPlay UI.** System AirPlay works through Control Centre; there is no
  in-app route picker.
- **No equaliser or audio effects.**

---

## Legal note

This is a personal-use tool for sideloading onto your own device, built at your
request. Downloading media you do not own or have permission to save may breach
a site's terms of service or copyright law depending on the content and your
jurisdiction. That judgement is yours to make per item; the app does not make it
for you.
