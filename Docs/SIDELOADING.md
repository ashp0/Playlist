# Building and Sideloading

The app has **no external dependencies** — no CocoaPods, no Carthage, no Swift
Package Manager checkout. Open it and build.

---

## Requirements

- Xcode 16 or later (developed against Xcode 26.4, iOS 26.4 SDK)
- An iPhone or iPad running iOS 17.0 or later
- An Apple ID (a paid developer account is *not* required)

---

## 1. Set your signing identity

This is the only step that must be done by hand.

1. Open `Playlist.xcodeproj`.
2. Select the **Playlist** target → **Signing & Capabilities**.
3. Tick **Automatically manage signing**.
4. Choose your **Team**. If your Apple ID is not listed:
   Xcode → Settings → Accounts → **+** → Apple ID.
5. Change the **Bundle Identifier** from `com.overnight.playlist` to something
   unique to you, e.g. `com.yourname.playlist`.

   This matters: bundle identifiers are globally unique to Apple's signing
   service, and `com.overnight.playlist` will be rejected if anyone else has
   already registered it.

Repeat step 5 for the **PlaylistTests** target if you intend to run the tests on
a device (its identifier is `com.overnight.playlist.tests`).

---

## 2. Build and install

Connect the device over USB, select it in Xcode's destination menu, and press
**⌘R**.

The first launch will fail with *"Untrusted Developer"*. On the device:

**Settings → General → VPN & Device Management → your Apple ID → Trust**

Launch the app again.

---

## Free vs. paid developer account

| | Free Apple ID | Paid ($99/yr) |
|---|---|---|
| App validity | **7 days** | 1 year |
| Apps installed at once | 3 | 100 |
| Reinstall to renew | Yes, weekly | No |

With a free account the app stops launching after seven days. Reconnect and
press ⌘R again to re-sign it — **your library and downloads are preserved**, as
long as the bundle identifier does not change. (Changing the bundle identifier
creates a new container, which orphans the old library.)

---

## Command line

```bash
# Build for the simulator
xcodebuild -project Playlist.xcodeproj -scheme Playlist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

```bash
# Run the tests
xcodebuild -project Playlist.xcodeproj -scheme Playlist \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

```bash
# Build for a device (signing configured in Xcode)
xcodebuild -project Playlist.xcodeproj -scheme Playlist \
  -configuration Release -destination 'generic/platform=iOS' build
```

### Producing an .ipa

For AltStore, Sideloadly or similar:

```bash
xcodebuild -project Playlist.xcodeproj -scheme Playlist \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Playlist.xcarchive archive
```

Then **Window → Organizer → Distribute App → Custom → Development**, or export
with an `exportOptions.plist` specifying `method: development`.

---

## Capabilities

Everything the app needs is already declared in `Config/Info.plist`; no
capabilities need to be enabled in Xcode.

| Key | Why |
|---|---|
| `UIBackgroundModes: audio` | Playback continues when the screen locks or you switch apps |
| `UIBackgroundModes: fetch`, `processing` | Lets iOS resume background downloads and wake the app to file a completed one |
| `NSAppTransportSecurity` | Media URLs handed back by third-party pages are frequently plain HTTP; downloads would fail outright under default ATS rules |
| `CFBundleURLTypes: playlist` | The `playlist://add?url=…` scheme |

**CarPlay is not supported.** It requires an entitlement Apple only grants to
approved App Store apps, so it cannot work on a sideloaded build — which is why
Brave's ~1,200 lines of CarPlay code were not ported.

---

## Sending links from Safari

The app registers `playlist://add?url=<percent-encoded address>`. To use it from
Safari's share sheet, create a Shortcut:

1. Shortcuts → **+** → *Add Action* → **Get URLs from Input**
2. *Add Action* → **URL Encode** (Text)
3. *Add Action* → **Open URLs**, set to
   `playlist://add?url=` + the encoded text
4. Name it "Save to Playlist", and enable **Show in Share Sheet** with *URLs* as
   the accepted input.

Tapping it in Safari's share sheet opens the app with extraction already
running.

---

## Troubleshooting

**"Failed to register bundle identifier"**
Someone else has that identifier. Change it to something unique (step 5 above).

**"Unable to install — the maximum number of apps has been reached"**
A free account allows three sideloaded apps. Delete one.

**App builds but immediately closes on launch**
The certificate has expired (free accounts, seven days). Rebuild from Xcode.

**"No media found" on a site that clearly has video**
See [LIMITATIONS.md](LIMITATIONS.md). In short: the site is probably delivering
DRM-protected or strictly MSE-only video, which by design cannot be saved.
Settings → *Finding Media* has two toggles worth trying.

**Downloads fail immediately with a server error**
Media URLs are signed and time-limited. If the item sat in the library for hours
before you downloaded it, its link has expired — play it once (which triggers an
automatic re-extraction) and then download.

**HLS downloads fail in the simulator**
Expected. `AVAssetDownloadURLSession` does not work in the simulator; Brave's
source carries the same note. Test HLS on a device.
