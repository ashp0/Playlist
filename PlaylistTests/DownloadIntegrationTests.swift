// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import AVFoundation
import Combine
import XCTest

@testable import Playlist

/// The whole point of the app, tested end to end: take a media URL, download
/// it, and confirm the result is a real file that plays with no network.
///
/// These need the network. When it is unavailable they skip rather than fail,
/// so an offline run of the suite stays green.
@MainActor
final class DownloadIntegrationTests: XCTestCase {

  /// A small, stable, publicly hosted test clip (~1 MB).
  private let sampleURL =
    "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"

  private var cancellables = Set<AnyCancellable>()
  private var addedItemID: String?

  override func tearDown() {
    cancellables.removeAll()

    if let addedItemID = addedItemID {
      let info = PlaylistInfo(
        name: "", src: "", pageSrc: "", pageTitle: "", mimeType: "", duration: 0,
        lastPlayedOffset: 0, detected: false, dateAdded: Date(), tagId: addedItemID,
        order: 0, isInvisible: false)
      _ = PlaylistManager.shared.delete(item: info)
    }
    addedItemID = nil

    super.tearDown()
  }

  // MARK: - Direct URL extraction

  /// A URL that *is* media should resolve without spinning up a web view.
  func testExtractsDirectMediaURLWithoutAWebView() async throws {
    try await skipIfOffline()

    let url = try XCTUnwrap(URL(string: sampleURL))
    let items = try await MediaExtractor.shared.extract(from: url)

    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(item.src, sampleURL)
    XCTAssertTrue(item.detected)
    XCTAssertGreaterThan(item.duration, 0, "Duration should be resolved at add time")
    XCTAssertTrue(item.mimeType.contains("mp4") || item.mimeType.contains("video"))
  }

  func testProbesMimeTypeOverTheNetwork() async throws {
    try await skipIfOffline()

    let url = try XCTUnwrap(URL(string: sampleURL))
    let mimeType = await NowPlayingInfo.getMimeType(url)

    let resolved = try XCTUnwrap(mimeType)
    XCTAssertTrue(
      resolved.lowercased().contains("video"),
      "Expected a video content type, got \(resolved)")
  }

  // MARK: - Download

  /// The full path: add → download → bookmark → resolvable local file → playable
  /// offline.
  func testDownloadsAndProducesAPlayableLocalFile() async throws {
    try await skipIfOffline()

    let url = try XCTUnwrap(URL(string: sampleURL))
    let extracted = try await MediaExtractor.shared.extract(from: url)
    let item = try XCTUnwrap(extracted.first)
    addedItemID = item.tagId

    // Persist it first — the download manager writes the resulting bookmark
    // back onto this row, so the row has to exist before the download starts.
    await withCheckedContinuation { continuation in
      PlaylistItem.addItem(item, cachedData: nil) { continuation.resume() }
    }
    XCTAssertTrue(PlaylistItem.itemExists(uuid: item.tagId))

    let finished = expectation(description: "download reaches a terminal state")
    var finalState: PlaylistDownloadManager.DownloadState?
    var reportedError: Error?

    PlaylistManager.shared.downloadStateChanged
      .filter { $0.id == item.tagId }
      .sink { update in
        guard update.state != .inProgress else { return }
        finalState = update.state
        reportedError = update.error
        finished.fulfill()
      }
      .store(in: &cancellables)

    PlaylistManager.shared.download(item: item)

    await fulfillment(of: [finished], timeout: 120)

    XCTAssertNil(reportedError, "Download reported an error: \(String(describing: reportedError))")
    XCTAssertEqual(finalState, .downloaded)

    // The row must now resolve to a real file through its stored bookmark.
    let localURL = try XCTUnwrap(
      PlaylistManager.shared.localAssetURL(for: item.tagId),
      "A completed download must resolve to a local URL")

    XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
    XCTAssertTrue(
      localURL.path.contains("Application Support"),
      "Media must be stored where iOS will not purge it")

    let bytes = FileManager.default.allocatedSizeOfItem(at: localURL)
    XCTAssertGreaterThan(bytes, 100_000, "Expected roughly 1 MB, got \(bytes) bytes")

    XCTAssertEqual(PlaylistManager.shared.state(for: item.tagId), .downloaded)
    XCTAssertGreaterThan(PlaylistManager.shared.sizeOfDownloadedItem(for: item.tagId), 0)

    // The container has to have been named correctly, or AVPlayer will refuse
    // the file regardless of its contents.
    XCTAssertEqual(localURL.pathExtension.lowercased(), "mp4")

    // Finally: is it actually playable from disk?
    let asset = AVURLAsset(url: localURL, options: AVAsset.defaultOptions)
    let isPlayable = try await asset.load(.isPlayable)
    XCTAssertTrue(isPlayable, "The downloaded file must be playable offline")

    let duration = try await asset.load(.duration)
    XCTAssertGreaterThan(duration.seconds, 0)
  }

  /// Removing a download must delete the bytes and clear the row's bookmark,
  /// while leaving the library entry intact.
  func testRemovingADownloadDeletesTheFileButKeepsTheItem() async throws {
    try await skipIfOffline()

    let url = try XCTUnwrap(URL(string: sampleURL))
    let extracted = try await MediaExtractor.shared.extract(from: url)
    let item = try XCTUnwrap(extracted.first)
    addedItemID = item.tagId

    await withCheckedContinuation { continuation in
      PlaylistItem.addItem(item, cachedData: nil) { continuation.resume() }
    }

    let finished = expectation(description: "download finished")
    // `deleteCache` later in this test emits a second `.invalid` event for the
    // same id, which is correct behaviour — just not a second completion.
    finished.assertForOverFulfill = false

    PlaylistManager.shared.downloadStateChanged
      .filter { $0.id == item.tagId && $0.state != .inProgress }
      .sink { _ in finished.fulfill() }
      .store(in: &cancellables)

    PlaylistManager.shared.download(item: item)
    await fulfillment(of: [finished], timeout: 120)

    let localURL = try XCTUnwrap(PlaylistManager.shared.localAssetURL(for: item.tagId))
    XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))

    XCTAssertTrue(PlaylistManager.shared.deleteCache(item: item))

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: localURL.path),
      "The file must be gone from disk")
    XCTAssertEqual(PlaylistManager.shared.state(for: item.tagId), .invalid)
    XCTAssertTrue(
      PlaylistItem.itemExists(uuid: item.tagId),
      "The library entry must survive so the item can be re-downloaded")
  }

  // MARK: - Helpers

  private func skipIfOffline() async throws {
    // `Reachability` needs a moment after launch for its first path update.
    for _ in 0..<20 where Reachability.shared.connectionStatus == .unknown {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    guard Reachability.shared.connectionStatus == .online else {
      throw XCTSkip("No network connection; skipping integration test.")
    }
  }
}
