// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import XCTest

@testable import Playlist

/// `PlaylistInfo` is the boundary type between the JavaScript detector and
/// everything native, so its decoding has to tolerate whatever a page produces.
final class PlaylistInfoTests: XCTestCase {

  // MARK: - Decoding from the detector

  func testDecodesFullMessageFromDetector() throws {
    let body: [String: Any] = [
      "name": "Big Buck Bunny",
      "src": "https://cdn.example.com/bbb.mp4",
      "pageSrc": "https://example.com/watch",
      "pageTitle": "Watch — Example",
      "mimeType": "video",
      "duration": 596.5,
      "detected": true,
      "tagId": "ABC-123",
      "invisible": false,
      "artworkURL": "https://example.com/poster.jpg",
    ]

    let item = try XCTUnwrap(PlaylistInfo.from(messageBody: body))

    XCTAssertEqual(item.name, "Big Buck Bunny")
    XCTAssertEqual(item.src, "https://cdn.example.com/bbb.mp4")
    XCTAssertEqual(item.pageSrc, "https://example.com/watch")
    XCTAssertEqual(item.duration, 596.5, accuracy: 0.001)
    XCTAssertTrue(item.detected)
    XCTAssertEqual(item.tagId, "ABC-123")
    XCTAssertFalse(item.isInvisible)
    XCTAssertEqual(item.artworkURL, "https://example.com/poster.jpg")
  }

  /// Real pages routinely omit most of this.
  func testDecodesMinimalMessage() throws {
    let body: [String: Any] = [
      "name": "Clip",
      "pageSrc": "https://example.com/x",
      "pageTitle": "X",
    ]

    let item = try XCTUnwrap(PlaylistInfo.from(messageBody: body))
    XCTAssertEqual(item.src, "")
    XCTAssertEqual(item.duration, 0)
    XCTAssertFalse(item.detected)
    XCTAssertFalse(item.tagId.isEmpty, "A tagId must always be synthesised")
  }

  func testRejectsMessageMissingRequiredFields() {
    XCTAssertNil(PlaylistInfo.from(messageBody: ["name": "only a name"]))
  }

  func testDecodesInvisibleFlagFromItsJavaScriptKey() throws {
    // The JS side spells this `invisible`; Swift calls it `isInvisible`.
    let body: [String: Any] = [
      "name": "Hidden", "pageSrc": "https://example.com", "pageTitle": "T",
      "invisible": true,
    ]

    let item = try XCTUnwrap(PlaylistInfo.from(messageBody: body))
    XCTAssertTrue(item.isInvisible)
  }

  // MARK: - Schemeless URLs

  func testResolvesProtocolRelativeSource() {
    let resolved = PlaylistInfo.fixSchemelessURLs(
      src: "//cdn.example.com/a.mp4", pageSrc: "https://example.com/watch")
    XCTAssertEqual(resolved, "https://cdn.example.com/a.mp4")
  }

  func testResolvesRootRelativeSource() {
    let resolved = PlaylistInfo.fixSchemelessURLs(
      src: "/media/a.mp4", pageSrc: "https://example.com/watch")
    XCTAssertEqual(resolved, "https://example.com/media/a.mp4")
  }

  func testLeavesAbsoluteSourceAlone() {
    let absolute = "https://cdn.example.com/a.mp4"
    XCTAssertEqual(
      PlaylistInfo.fixSchemelessURLs(src: absolute, pageSrc: "https://example.com/watch"),
      absolute)
  }

  func testDecodingAppliesSchemeFix() throws {
    let body: [String: Any] = [
      "name": "Clip",
      "src": "//cdn.example.com/a.mp4",
      "pageSrc": "https://example.com/watch",
      "pageTitle": "T",
    ]

    let item = try XCTUnwrap(PlaylistInfo.from(messageBody: body))
    XCTAssertEqual(item.src, "https://cdn.example.com/a.mp4")
  }

  // MARK: - Identity

  func testItemsAreEqualAcrossEquivalentPageURLs() {
    let a = makeItem(pageSrc: "https://www.example.com/watch/", tagId: "same")
    let b = makeItem(pageSrc: "http://example.com/watch", tagId: "same")

    XCTAssertEqual(a, b, "Scheme, www. and trailing slash must not change identity")
    XCTAssertEqual(a.hashValue, b.hashValue)
  }

  func testItemsWithDifferentTagsAreDistinct() {
    let a = makeItem(pageSrc: "https://example.com/watch", tagId: "one")
    let b = makeItem(pageSrc: "https://example.com/watch", tagId: "two")
    XCTAssertNotEqual(a, b, "One page can host several distinct media items")
  }

  // MARK: - Refresh

  /// When an expired media URL is re-resolved, identity and user state must
  /// survive; only the source and freshly-learned metadata may change.
  func testReplacingSourceKeepsIdentityAndResumePoint() {
    let original = PlaylistInfo(
      name: "Original", src: "https://old.example.com/expired.mp4",
      pageSrc: "https://example.com/watch", pageTitle: "T", mimeType: "video/mp4",
      duration: 100, lastPlayedOffset: 42, detected: true, dateAdded: Date.distantPast,
      tagId: "keep-me", order: 7, isInvisible: false, artworkURL: "https://a/old.jpg")

    let fresh = PlaylistInfo(
      name: "Refreshed", src: "https://new.example.com/fresh.mp4",
      pageSrc: "https://example.com/watch", pageTitle: "T2", mimeType: "video/mp4",
      duration: 120, lastPlayedOffset: 0, detected: true, dateAdded: Date(),
      tagId: "different", order: 0, isInvisible: false, artworkURL: nil)

    let merged = original.replacingSource(with: fresh)

    XCTAssertEqual(merged.src, "https://new.example.com/fresh.mp4")
    XCTAssertEqual(merged.tagId, "keep-me")
    XCTAssertEqual(merged.order, 7)
    XCTAssertEqual(merged.lastPlayedOffset, 42)
    XCTAssertEqual(merged.dateAdded, Date.distantPast)
    XCTAssertEqual(merged.pageSrc, "https://example.com/watch")
    XCTAssertEqual(merged.artworkURL, "https://a/old.jpg", "Old artwork survives a nil refresh")
    XCTAssertEqual(merged.duration, 120, "A better duration is taken")
  }

  // MARK: - Helpers

  private func makeItem(pageSrc: String, tagId: String) -> PlaylistInfo {
    PlaylistInfo(
      name: "n", src: "https://cdn/a.mp4", pageSrc: pageSrc, pageTitle: "t",
      mimeType: "video/mp4", duration: 1, lastPlayedOffset: 0, detected: true,
      dateAdded: Date(), tagId: tagId, order: 0, isInvisible: false)
  }
}
