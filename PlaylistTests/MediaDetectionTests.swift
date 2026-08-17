// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WebKit
import XCTest

@testable import Playlist

/// End-to-end tests for the extraction engine — the offscreen `WKWebView`,
/// Brave's injected detector script, and the message plumbing back to Swift.
///
/// These run against locally generated HTML rather than a live site, so they
/// test *our* detection logic deterministically and offline. They are the
/// closest thing to a regression suite for the part of the app most likely to
/// break as the web changes.
@MainActor
final class MediaDetectionTests: XCTestCase {

  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PlaylistTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory = temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    try super.tearDownWithError()
  }

  // MARK: - Detection

  /// The simplest case: a `<video src>` present in the markup at parse time.
  func testDetectsStaticVideoElement() async throws {
    let url = try writePage(
      body: #"<video src="https://cdn.example.com/static.mp4" controls></video>"#)

    let items = await PlaylistWebLoader().load(url: url)

    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.src, "https://cdn.example.com/static.mp4")
  }

  /// The case that actually matters. Real players assign the media URL from
  /// JavaScript well after the document has parsed; a one-shot DOM scan finds
  /// nothing. This is what Brave's `setAttribute` prototype hook exists for.
  func testDetectsSourceAssignedByScriptAfterLoad() async throws {
    let url = try writePage(
      body: "<video id=\"player\" controls></video>",
      script: """
        setTimeout(function () {
          document.getElementById('player').src = 'https://cdn.example.com/late.mp4';
        }, 400);
        """)

    let items = await PlaylistWebLoader().load(url: url)

    XCTAssertEqual(
      items.first?.src, "https://cdn.example.com/late.mp4",
      "The prototype hook must catch a source assigned after parse")
  }

  /// `<video>` with no src but `<source>` children — standard multi-format markup.
  func testDetectsSourceChildElements() async throws {
    let url = try writePage(
      body: """
        <video controls>
          <source src="https://cdn.example.com/child.mp4" type="video/mp4">
        </video>
        """)

    let items = await PlaylistWebLoader().load(url: url)
    XCTAssertEqual(items.first?.src, "https://cdn.example.com/child.mp4")
  }

  func testDetectsAudioElement() async throws {
    let url = try writePage(
      body: #"<audio src="https://cdn.example.com/track.mp3" controls></audio>"#)

    let items = await PlaylistWebLoader().load(url: url)
    XCTAssertEqual(items.first?.src, "https://cdn.example.com/track.mp3")
  }

  /// A `blob:` source is an MSE handle that means nothing outside the page and
  /// cannot be downloaded, so it must never reach the library.
  func testRejectsBlobSources() async throws {
    let url = try writePage(
      body: "<video id=\"player\" controls></video>",
      script: """
        var blob = new Blob(['x'], { type: 'video/mp4' });
        document.getElementById('player').src = URL.createObjectURL(blob);
        """)

    let items = await PlaylistWebLoader().load(url: url)
    XCTAssertTrue(items.isEmpty, "blob: sources are not downloadable and must be rejected")
  }

  func testReportsNothingForAPageWithNoMedia() async throws {
    let url = try writePage(body: "<p>Just some text, no media at all.</p>")

    let items = await PlaylistWebLoader().load(url: url)
    XCTAssertTrue(items.isEmpty)
  }

  /// Artwork is scraped from Open Graph metadata at detection time.
  func testCapturesOpenGraphMetadata() async throws {
    let url = try writePage(
      head: """
        <meta property="og:image" content="https://example.com/poster.jpg">
        <meta property="og:title" content="A Better Title">
        """,
      body: #"<video src="https://cdn.example.com/withmeta.mp4"></video>"#)

    let items = await PlaylistWebLoader().load(url: url)
    let item = try XCTUnwrap(items.first)

    XCTAssertEqual(item.artworkURL, "https://example.com/poster.jpg")
    XCTAssertEqual(item.pageTitle, "A Better Title")
  }

  /// Several media elements on one page all get reported.
  func testDetectsMultipleItems() async throws {
    let url = try writePage(
      body: """
        <video src="https://cdn.example.com/one.mp4"></video>
        <video src="https://cdn.example.com/two.mp4"></video>
        """)

    let items = await PlaylistWebLoader().load(url: url)
    let sources = Set(items.map(\.src))

    XCTAssertEqual(
      sources,
      ["https://cdn.example.com/one.mp4", "https://cdn.example.com/two.mp4"])
  }

  /// The MediaSource API must be gone before any page script can capture it.
  /// This is what pushes players onto a downloadable progressive URL.
  func testMediaSourceIsRemovedBeforePageScriptsRun() async throws {
    // The page records what it saw at document start, then exposes the result
    // as a media URL the detector will report back to us.
    let url = try writePage(
      body: "<video id=\"player\"></video>",
      script: """
        var hasMediaSource = (typeof window.MediaSource !== 'undefined') ||
                             (typeof window.ManagedMediaSource !== 'undefined') ||
                             (typeof window.WebKitMediaSource !== 'undefined');
        document.getElementById('player').src =
          'https://cdn.example.com/mse-' + hasMediaSource + '.mp4';
        """)

    let items = await PlaylistWebLoader().load(url: url)

    XCTAssertEqual(
      items.first?.src, "https://cdn.example.com/mse-false.mp4",
      "MediaSource must be deleted before page scripts run")
  }

  // MARK: - Ranking

  func testRankingPrefersLongestDuration() {
    let short = makeItem(src: "https://a/ad.mp4", duration: 15, mimeType: "video/mp4")
    let long = makeItem(src: "https://a/feature.mp4", duration: 3600, mimeType: "video/mp4")

    let ranked = PlaylistWebLoader.rank([short, long])
    XCTAssertEqual(ranked.first?.src, "https://a/feature.mp4")
  }

  func testRankingPrefersProgressiveOverHLSAtEqualDuration() {
    let hls = makeItem(src: "https://a/master.m3u8", duration: 100, mimeType: "application/x-mpegURL")
    let file = makeItem(src: "https://a/clip.mp4", duration: 100, mimeType: "video/mp4")

    let ranked = PlaylistWebLoader.rank([hls, file])
    XCTAssertEqual(
      ranked.first?.src, "https://a/clip.mp4",
      "Progressive files download faster and play offline more reliably")
  }

  func testRankingSinksUnknownDurations() {
    let unknown = makeItem(src: "https://a/unknown.mp4", duration: 0, mimeType: "video/mp4")
    let known = makeItem(src: "https://a/known.mp4", duration: 30, mimeType: "video/mp4")

    let ranked = PlaylistWebLoader.rank([unknown, known])
    XCTAssertEqual(ranked.first?.src, "https://a/known.mp4")
  }

  // MARK: - Helpers

  private func makeItem(src: String, duration: TimeInterval, mimeType: String) -> PlaylistInfo {
    PlaylistInfo(
      name: "n", src: src, pageSrc: "https://a/page", pageTitle: "t", mimeType: mimeType,
      duration: duration, lastPlayedOffset: 0, detected: true, dateAdded: Date(),
      tagId: UUID().uuidString, order: 0, isInvisible: false)
  }

  private func writePage(head: String = "", body: String, script: String = "") throws -> URL {
    let html = """
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="utf-8">
          <title>Test Page</title>
          \(head)
        </head>
        <body>
          \(body)
          <script>\(script)</script>
        </body>
      </html>
      """

    let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
    try html.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
