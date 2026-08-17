// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// New in this app. Brave needs nothing like it: its Playlist is fed by whatever
// tab the user is already looking at, so the browser has already resolved the
// address, already sent a mobile user agent, and already rendered the page.
// A paste-a-link app has to reconstruct all three, and YouTube is the one site
// where getting them wrong is the difference between working and not.
//
// WHY THIS FILE EXISTS — the user agent is the whole ballgame.
//
// YouTube decides *server-side*, from the User-Agent on the watch-page request,
// whether `ytInitialPlayerResponse.streamingData` contains a progressive
// (audio+video muxed) format at all:
//
//     desktop Safari UA  →  formats: 0     — adaptive/SABR only, nothing to save
//     iPhone Safari UA   →  formats: 1     — itag 18, progressive MP4
//
// That asymmetry is not arbitrary. iPhone Safari had no Media Source Extensions
// at all until `ManagedMediaSource` in iOS 17.1, so YouTube has always had to
// keep a progressive path alive for it. `PlaylistSwizzler.js` deletes both
// `MediaSource` and `ManagedMediaSource`, which puts us back in exactly that
// bucket — but only if the page was *requested* as an iPhone in the first
// place, because by the time our script runs the server has already chosen what
// to put in the HTML.
//
// This app defaults to a desktop UA (it serves most other video sites better),
// which is precisely why YouTube appeared not to work. See `UserAgent`.
//
// The second half of the trick is that we never parse a URL out of that JSON
// ourselves. The `url` in the watch page carries an *encrypted* `n` parameter
// and often a `signatureCipher` instead of a signature; fetching it directly
// returns 403. Letting the page's own `html5player.js` decrypt `n`, apply the
// signature and assign the result to `<video src>` — which is what the
// detector's `setAttribute` hook observes — yields a URL that downloads with a
// plain `URLSession` and no headers of any kind.

import Foundation

/// YouTube-specific knowledge, kept in one place.
///
/// Everything here is address bookkeeping and metadata; the actual extraction is
/// the same Brave machinery used for every other site.
public enum YouTube {

  // MARK: - Recognition

  /// Hosts whose pages are YouTube watch pages.
  private static let hosts: Set<String> = [
    "youtube.com", "www.youtube.com", "m.youtube.com",
    "music.youtube.com", "youtu.be", "www.youtu.be",
    "youtube-nocookie.com", "www.youtube-nocookie.com",
  ]

  /// Sign-in and interstitial hosts YouTube bounces an unauthenticated,
  /// cookieless web view to.
  ///
  /// A fresh non-persistent data store has no consent or session cookie, so a
  /// few seconds into the load YouTube fires a "passive sign-in" navigation to
  /// `accounts.google.com`, which throws away the page — and with it the player
  /// that was about to hand us a URL. There is nothing for us behind a sign-in,
  /// so the navigation is simply refused and the watch page stays put.
  private static let signInHosts: Set<String> = [
    "accounts.google.com", "accounts.youtube.com",
  ]

  public static func isYouTube(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return hosts.contains(host)
  }

  public static func isSignInRedirect(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return signInHosts.contains(host)
  }

  // MARK: - Addresses

  /// A YouTube video identifier: eleven characters of URL-safe base64.
  private static func isValidID(_ candidate: String) -> Bool {
    candidate.count == 11
      && candidate.allSatisfy {
        $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_"
      }
  }

  /// Pulls the video identifier out of any of the shapes YouTube hands out.
  ///
  /// `watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`, `/live/` and `/v/` all
  /// address the same video, and users paste all of them — `/shorts/` and
  /// `youtu.be/` especially, since those are what the share sheet produces.
  public static func videoID(from url: URL) -> String? {
    guard isYouTube(url) else { return nil }

    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
      isValidID(value)
    {
      return value
    }

    let segments = url.pathComponents.filter { $0 != "/" }

    // youtu.be/<id> — the identifier is the whole path.
    if url.host?.lowercased().hasSuffix("youtu.be") == true,
      let first = segments.first, isValidID(first)
    {
      return first
    }

    // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
    let prefixes: Set<String> = ["shorts", "embed", "live", "v"]
    if segments.count >= 2, prefixes.contains(segments[0].lowercased()), isValidID(segments[1]) {
      return segments[1]
    }

    return nil
  }

  /// Rewrites any YouTube address into the mobile watch page.
  ///
  /// Two reasons to normalise rather than load what was pasted:
  ///
  ///   * `/shorts/`, `/embed/` and `music.youtube.com` are different players
  ///     with different behaviour; the plain watch page is the one whose
  ///     fallback path is reliable.
  ///   * `m.youtube.com` is where an iPhone UA ends up anyway, so going straight
  ///     there skips a redirect — and, more importantly, it is what gets stored
  ///     as `pageSrc`, which is the address re-extraction will reload months
  ///     later when the media URL has expired.
  ///
  /// Returns nil when the URL is YouTube but names no single video (a channel,
  /// a playlist index, the home page).
  public static func canonicalWatchURL(for url: URL) -> URL? {
    guard let id = videoID(from: url) else { return nil }
    return URL(string: "https://m.youtube.com/watch?v=\(id)")
  }

  /// Artwork for a video, without needing to scrape the page.
  ///
  /// `hqdefault` is the largest size guaranteed to exist for every video;
  /// `maxresdefault` 404s on anything never uploaded above 720p.
  public static func thumbnailURL(forID id: String) -> String {
    "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
  }

  // MARK: - Metadata

  /// What the watch page knows about itself.
  public struct Metadata {
    public let videoID: String
    public let title: String
    /// Declared length in seconds; 0 for a live stream.
    public let duration: TimeInterval
    public let isLive: Bool
    public let artworkURL: String?
    /// `playabilityStatus.status` — `OK`, `LOGIN_REQUIRED`, `UNPLAYABLE`, …
    public let playabilityStatus: String
    /// YouTube's own sentence explaining a refusal, when it gives one.
    public let playabilityReason: String?

    /// Whether YouTube refused this video for want of an account.
    ///
    /// Worth distinguishing from every other failure: it is the one the user
    /// can actually do something about, and the app can point them at the fix.
    public var requiresSignIn: Bool {
      playabilityStatus == "LOGIN_REQUIRED" || playabilityStatus == "AGE_VERIFICATION_REQUIRED"
    }

    public var isPlayable: Bool { playabilityStatus == "OK" }
  }

  /// Reads `ytInitialPlayerResponse.videoDetails` out of a loaded watch page.
  ///
  /// Evaluated in `.page` world because that is where YouTube's own globals
  /// live. This is metadata only — the media URL still comes from the detector
  /// watching what the player assigns, never from this JSON, for the signature
  /// reasons in the file header.
  public static let metadataScript = """
    (function () {
      try {
        var r = window.ytInitialPlayerResponse;
        if (!r) { return null; }
        var p = r.playabilityStatus || {};
        var v = r.videoDetails || {};
        var thumbs = (v.thumbnail && v.thumbnail.thumbnails) || [];
        return {
          videoID: v.videoId || "",
          title: v.title || "",
          duration: parseFloat(v.lengthSeconds || "0"),
          isLive: !!v.isLiveContent,
          artworkURL: thumbs.length ? thumbs[thumbs.length - 1].url : null,
          playabilityStatus: p.status || "",
          playabilityReason: p.reason || null
        };
      } catch (e) {
        return null;
      }
    })()
    """

  public static func metadata(from result: Any?) -> Metadata? {
    guard let dictionary = result as? [String: Any] else { return nil }

    let videoID = (dictionary["videoID"] as? String) ?? ""
    let status = (dictionary["playabilityStatus"] as? String) ?? ""

    // A response with neither an identifier nor a status is not a watch page.
    guard !videoID.isEmpty || !status.isEmpty else { return nil }

    let duration = (dictionary["duration"] as? NSNumber)?.doubleValue ?? 0
    return Metadata(
      videoID: videoID,
      title: (dictionary["title"] as? String) ?? "",
      duration: duration.isFinite && duration > 0 ? duration : 0,
      isLive: (dictionary["isLive"] as? Bool) ?? false,
      artworkURL: (dictionary["artworkURL"] as? String)
        ?? (videoID.isEmpty ? nil : thumbnailURL(forID: videoID)),
      playabilityStatus: status,
      playabilityReason: dictionary["playabilityReason"] as? String)
  }

  /// Strips the suffix WebKit puts on every YouTube document title.
  public static func cleanedTitle(_ title: String) -> String {
    var cleaned = title
    for suffix in [" - YouTube", " – YouTube"] where cleaned.hasSuffix(suffix) {
      cleaned.removeLast(suffix.count)
    }
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Media URLs

  /// True for the CDN that actually serves YouTube's media.
  public static func isMediaURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host.hasSuffix(".googlevideo.com") || host == "googlevideo.com"
  }

  /// The media length a `googlevideo.com` URL advertises, in seconds.
  ///
  /// Worth reading because it arrives *with* the URL, whereas the DOM's
  /// `duration` is still 0 at the moment the player assigns a source — the
  /// element has not loaded metadata yet. Having a real duration immediately is
  /// what lets a pre-roll advert be told apart from the feature without waiting
  /// for, or downloading, either of them.
  public static func advertisedDuration(ofMediaURL url: URL) -> TimeInterval? {
    guard isMediaURL(url),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let value = components.queryItems?.first(where: { $0.name == "dur" })?.value,
      let duration = TimeInterval(value),
      duration > 0
    else { return nil }
    return duration
  }
}
