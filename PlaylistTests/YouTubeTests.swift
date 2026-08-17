// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import XCTest

@testable import Playlist

/// YouTube extraction hinges on three things being right before a page is even
/// requested: the address, the user agent, and — once media comes back — being
/// able to tell a pre-roll advert from the video the user asked for.
///
/// None of these need the network, and all three have failed silently before,
/// which is exactly the kind of thing worth pinning down in a test.
final class YouTubeTests: XCTestCase {

  // MARK: - Recognition

  func testRecognisesEveryYouTubeHost() {
    let youTube = [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtube.com/watch?v=dQw4w9WgXcQ",
      "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtu.be/dQw4w9WgXcQ",
      "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
    ]

    for address in youTube {
      XCTAssertTrue(YouTube.isYouTube(URL(string: address)!), "should recognise \(address)")
    }

    let notYouTube = [
      "https://example.com/watch?v=dQw4w9WgXcQ",
      "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
      // A lookalike host: matching by suffix rather than exactly would let this
      // through, and it is not Google's.
      "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
    ]

    for address in notYouTube {
      XCTAssertFalse(YouTube.isYouTube(URL(string: address)!), "should reject \(address)")
    }
  }

  // MARK: - Addresses

  func testExtractsVideoIDFromEveryLinkShape() {
    let cases: [(String, String)] = [
      ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
      ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", "dQw4w9WgXcQ"),
      ("https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
      ("https://youtu.be/dQw4w9WgXcQ?si=abcdef", "dQw4w9WgXcQ"),
      ("https://www.youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
      ("https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
      ("https://www.youtube.com/live/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
      ("https://www.youtube.com/v/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
      ("https://m.youtube.com/watch?v=aqz-KE-bpKQ", "aqz-KE-bpKQ"),
      ("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD", "dQw4w9WgXcQ"),
    ]

    for (address, expected) in cases {
      XCTAssertEqual(
        YouTube.videoID(from: URL(string: address)!), expected, "failed for \(address)")
    }
  }

  func testRejectsYouTubeLinksThatNameNoSingleVideo() {
    let addresses = [
      "https://www.youtube.com/",
      "https://www.youtube.com/@someuser",
      "https://www.youtube.com/playlist?list=PL1234567890",
      "https://www.youtube.com/results?search_query=cats",
      // Eleven characters is the whole identifier format; anything else is not one.
      "https://www.youtube.com/watch?v=tooshort",
    ]

    for address in addresses {
      XCTAssertNil(YouTube.videoID(from: URL(string: address)!), "should reject \(address)")
    }
  }

  func testCanonicalisesToTheMobileWatchPage() {
    let expected = URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")

    for address in [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90",
      "https://youtu.be/dQw4w9WgXcQ",
      "https://www.youtube.com/shorts/dQw4w9WgXcQ",
      "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
    ] {
      XCTAssertEqual(YouTube.canonicalWatchURL(for: URL(string: address)!), expected)
    }

    XCTAssertNil(YouTube.canonicalWatchURL(for: URL(string: "https://www.youtube.com/@user")!))
  }

  // MARK: - User agent

  /// The single most important assertion in this file.
  ///
  /// YouTube decides server-side whether the watch page carries a progressive
  /// format, and it only does so for a mobile client. Requesting it as desktop
  /// yields a page with nothing downloadable in it at all, which is what made
  /// YouTube look permanently unsupported.
  func testYouTubeIsAlwaysRequestedAsMobileEvenInDesktopMode() {
    let original = Preferences.Playlist.useDesktopUserAgent.value
    defer { Preferences.Playlist.useDesktopUserAgent.value = original }

    Preferences.Playlist.useDesktopUserAgent.value = true

    let youTube = URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!
    XCTAssertEqual(UserAgent.userAgent(for: youTube), UserAgent.mobile)
    XCTAssertTrue(UserAgent.userAgent(for: youTube).contains("iPhone"))

    // Every other site keeps following the preference.
    let other = URL(string: "https://example.com/video")!
    XCTAssertEqual(UserAgent.userAgent(for: other), UserAgent.desktop)
  }

  func testSignInRedirectsAreRecognised() {
    XCTAssertTrue(
      YouTube.isSignInRedirect(URL(string: "https://accounts.google.com/ServiceLogin?x=1")!))
    XCTAssertFalse(
      YouTube.isSignInRedirect(URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!))
  }

  // MARK: - Media URLs

  func testReadsAdvertisedDurationFromMediaURL() {
    let media = URL(
      string: "https://rr5---sn-abc.googlevideo.com/videoplayback?itag=18&dur=213.089&mime=video/mp4"
    )!
    XCTAssertEqual(try XCTUnwrap(YouTube.advertisedDuration(ofMediaURL: media)), 213.089, accuracy: 0.001)

    // A live stream carries `dur=0`, which is not a duration.
    let live = URL(string: "https://rr5---sn-abc.googlevideo.com/videoplayback?itag=18&dur=0")!
    XCTAssertNil(YouTube.advertisedDuration(ofMediaURL: live))

    // Not YouTube's CDN, so the parameter means nothing.
    XCTAssertNil(
      YouTube.advertisedDuration(ofMediaURL: URL(string: "https://example.com/a.mp4?dur=90")!))
  }

  // MARK: - Playability

  /// The distinction that makes signing in discoverable: a video YouTube
  /// refuses to a signed-out client must not be reported as "no media found",
  /// because that is the one failure the user can actually fix.
  func testDistinguishesSignInRequiredFromOtherRefusals() {
    func metadata(_ status: String, reason: String? = nil) -> YouTube.Metadata? {
      YouTube.metadata(
        from: [
          "videoID": "dQw4w9WgXcQ", "title": "", "duration": NSNumber(value: 0.0),
          "isLive": false, "playabilityStatus": status, "playabilityReason": reason as Any,
        ] as [String: Any])
    }

    XCTAssertTrue(try XCTUnwrap(metadata("LOGIN_REQUIRED")).requiresSignIn)
    XCTAssertTrue(try XCTUnwrap(metadata("AGE_VERIFICATION_REQUIRED")).requiresSignIn)

    let unplayable = try? XCTUnwrap(metadata("UNPLAYABLE", reason: "This live event has ended."))
    XCTAssertFalse(unplayable?.requiresSignIn ?? true)
    XCTAssertEqual(unplayable?.playabilityReason, "This live event has ended.")

    let ok = try? XCTUnwrap(metadata("OK"))
    XCTAssertTrue(ok?.isPlayable ?? false)
    XCTAssertFalse(ok?.requiresSignIn ?? true)
  }

  /// A refused page has no `videoDetails`, so metadata parsing must not depend
  /// on them — otherwise the reason is thrown away with the rest.
  func testParsesStatusEvenWithoutVideoDetails() {
    let metadata = YouTube.metadata(
      from: ["videoID": "", "playabilityStatus": "LOGIN_REQUIRED"] as [String: Any])

    XCTAssertNotNil(metadata)
    XCTAssertTrue(metadata?.requiresSignIn ?? false)
    // With no identifier there is no artwork to guess at.
    XCTAssertNil(metadata?.artworkURL)

    // Neither an identifier nor a status is not a watch page at all.
    XCTAssertNil(YouTube.metadata(from: ["videoID": ""] as [String: Any]))
  }

  // MARK: - Session

  @MainActor
  func testCookielessExtractionIsTheDefaultAndYouTubeOnlyWhenSignedIn() async {
    let session = YouTubeSession.shared
    await session.refresh()

    // Nothing is signed in under test, so every load must stay cookieless.
    let youTube = URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!
    let other = URL(string: "https://example.com/video")!

    XCTAssertFalse(session.isSignedIn)
    XCTAssertFalse(session.dataStore(for: youTube).isPersistent)
    XCTAssertFalse(session.dataStore(for: other).isPersistent)
  }

  func testCleansTheDocumentTitleSuffix() {
    XCTAssertEqual(YouTube.cleanedTitle("Some Video - YouTube"), "Some Video")
    XCTAssertEqual(YouTube.cleanedTitle("Some Video"), "Some Video")
    // A title that legitimately ends in the word stays intact.
    XCTAssertEqual(YouTube.cleanedTitle("A History of YouTube"), "A History of YouTube")
  }

  func testParsesMetadataFromThePlayerResponse() {
    let metadata = try? XCTUnwrap(
      YouTube.metadata(
        from: [
          "videoID": "dQw4w9WgXcQ",
          "title": "A Song",
          "duration": NSNumber(value: 213.0),
          "isLive": false,
          "artworkURL": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg",
        ] as [String: Any]))

    XCTAssertEqual(metadata?.videoID, "dQw4w9WgXcQ")
    XCTAssertEqual(metadata?.title, "A Song")
    XCTAssertEqual(metadata?.duration ?? 0, 213.0, accuracy: 0.001)

    XCTAssertNil(YouTube.metadata(from: nil))
    XCTAssertNil(YouTube.metadata(from: ["videoID": ""] as [String: Any]))
  }

  // MARK: - Advert rejection

  /// The case that motivates matching against the declared length: a pre-roll
  /// advert that runs longer than the video itself. Ranking on duration alone
  /// picks the advert, which is exactly the wrong answer.
  @MainActor
  func testPrefersTheVideoMatchingTheDeclaredLengthOverALongerAdvert() {
    let advert = Self.item(
      name: "advert", src: "https://rr1.googlevideo.com/videoplayback?dur=45", duration: 45)
    let feature = Self.item(
      name: "feature", src: "https://rr2.googlevideo.com/videoplayback?dur=30.2", duration: 30.2)

    let ranked = PlaylistWebLoader.rank([advert, feature], matching: 30)
    XCTAssertEqual(ranked.first?.name, "feature")

    // Without the page's own answer, the longer one still wins — the general
    // heuristic, unchanged for every other site.
    XCTAssertEqual(PlaylistWebLoader.rank([advert, feature]).first?.name, "advert")
  }

  @MainActor
  func testOnlyTheMatchingItemTakesThePageIdentity() {
    let advert = Self.item(
      name: "advert", src: "https://rr1.googlevideo.com/videoplayback?dur=45", duration: 45)
    let feature = Self.item(
      name: "Some Video - YouTube", src: "https://rr2.googlevideo.com/videoplayback?dur=213.089",
      duration: 213.089)

    let metadata = YouTube.Metadata(
      videoID: "dQw4w9WgXcQ",
      title: "Some Video",
      duration: 213,
      isLive: false,
      artworkURL: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
      playabilityStatus: "OK",
      playabilityReason: nil)

    let applied = PlaylistWebLoader.applying(metadata, to: [advert, feature])

    let labelledFeature = try? XCTUnwrap(applied.first(where: { $0.duration == 213.089 }))
    XCTAssertEqual(labelledFeature?.name, "Some Video")
    XCTAssertEqual(labelledFeature?.artworkURL, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")

    // The advert must not be dressed up as the feature.
    let labelledAdvert = try? XCTUnwrap(applied.first(where: { $0.duration == 45 }))
    XCTAssertNotEqual(labelledAdvert?.name, "Some Video")
    XCTAssertNotEqual(labelledAdvert?.artworkURL, metadata.artworkURL)
  }

  // MARK: - Helpers

  private static func item(name: String, src: String, duration: TimeInterval) -> PlaylistInfo {
    PlaylistInfo(
      name: name,
      src: src,
      pageSrc: "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
      pageTitle: "YouTube",
      mimeType: "video/mp4",
      duration: duration,
      lastPlayedOffset: 0,
      detected: true,
      dateAdded: Date(),
      tagId: UUID().uuidString,
      order: 0,
      isInvisible: false,
      artworkURL: nil)
  }
}
