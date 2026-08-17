// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import MediaPlayer
import XCTest

@testable import Playlist

/// Tests for what a segmented playlist tells the world outside the app.
///
/// The lock screen and Control Centre draw their scrubber by extrapolating from
/// two numbers — a duration and an elapsed time — so the pair have to be in the
/// same timebase or the bar drifts away from the audio. While a playlist is
/// playing items in segments that timebase is the *segment*: three minutes long,
/// counting from zero, ending when the playlist moves on. Publishing the
/// track's length instead leaves a scrubber that promises another twenty
/// minutes of something that is about to stop.
///
/// The conversion is tested in both directions, because the lock screen scrubs
/// as well as reads: a position it reports back is in the segment's timebase and
/// has to be put into the item's before the player is sent there.
final class SegmentNowPlayingTests: XCTestCase {

  override func tearDown() {
    NowPlayingInfo.clearNowPlayingInfo()
    super.tearDown()
  }

  // MARK: - The window itself

  func testNoWindowPresentsTheWholeItem() {
    let player = Playlist.MediaPlayer()
    XCTAssertNil(player.playbackWindow)

    // No asset is loaded, so there is no measured length to present.
    XCTAssertEqual(player.presentedDuration, 0)
    XCTAssertEqual(player.presentedTime(for: 90), 90)
    XCTAssertEqual(player.absoluteTime(forPresented: 90), 90)
  }

  func testWindowPresentsItsOwnLength() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    XCTAssertEqual(player.presentedDuration, 180)
  }

  /// The number the lock screen counts up: how far into *this* stretch playback
  /// is, not how far into the track.
  func testPositionIsCountedFromTheStartOfTheWindow() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    XCTAssertEqual(player.presentedTime(for: 180), 0)
    XCTAssertEqual(player.presentedTime(for: 250), 70)
    XCTAssertEqual(player.presentedTime(for: 360), 180)
  }

  /// A seek is asynchronous, so the player can report a position from before it
  /// landed — from outside the segment entirely, on the first tick after the
  /// playlist moves into one. Publishing a negative elapsed time, or one past
  /// the duration, is what makes the lock-screen scrubber jump to an end it is
  /// nowhere near.
  func testPositionOutsideTheWindowIsHeldAtItsEdges() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    XCTAssertEqual(player.presentedTime(for: 12), 0)
    XCTAssertEqual(player.presentedTime(for: 900), 180)
    XCTAssertEqual(player.presentedTime(for: .nan), 0)
    XCTAssertEqual(player.presentedTime(for: .infinity), 0)
  }

  // MARK: - Scrubbing back the other way

  func testAScrubbedPositionIsPutBackIntoTheItemsTimebase() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    XCTAssertEqual(player.absoluteTime(forPresented: 0), 180)
    XCTAssertEqual(player.absoluteTime(forPresented: 70), 250)
    XCTAssertEqual(player.absoluteTime(forPresented: 180), 360)
  }

  /// Dragging to the very end of the lock screen's bar must not land past the
  /// segment, which would immediately advance the playlist — the opposite of
  /// what dragging to the end of the bar you are looking at should do.
  func testAScrubCannotLandOutsideTheWindow() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    XCTAssertEqual(player.absoluteTime(forPresented: -30), 180)
    XCTAssertEqual(player.absoluteTime(forPresented: 5_000), 360)
  }

  func testTheTwoConversionsAreInverses() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    for absolute in stride(from: 180.0, through: 360.0, by: 17.0) {
      XCTAssertEqual(
        player.absoluteTime(forPresented: player.presentedTime(for: absolute)),
        absolute,
        accuracy: 0.0001)
    }
  }

  // MARK: - What is published

  func testPublishedTimelineDescribesTheSegment() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    NowPlayingInfo.setNowPlayingInfo(
      makeInfo(name: "A Long Mix", duration: 3_600), withPlayer: player, elapsed: 250)

    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 70)
    // The identity is untouched by any of this.
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "A Long Mix")
  }

  /// A hidden playlist can also be a segmented one, and the two features must
  /// not have to know about each other: the timing is published from the same
  /// window either way, it is only the identity that is withheld.
  func testHiddenPlaylistAlsoPublishesTheSegmentsTimeline() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    NowPlayingInfo.setNowPlayingInfo(
      makeInfo(name: "A Long Mix", duration: 3_600),
      withPlayer: player, elapsed: 250, isAnonymous: true)

    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 70)
    XCTAssertNil(info[MPMediaItemPropertyTitle])
  }

  /// The refresh published on every pause, resume and seek. It used to read the
  /// item's duration straight off the player, so the timeline reverted to the
  /// whole track's the first time playback was touched — the segment's length
  /// survived exactly until the user pressed pause.
  func testTheRefreshKeepsTheSegmentsTimeline() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360

    NowPlayingInfo.setNowPlayingInfo(
      makeInfo(name: "A Long Mix", duration: 3_600), withPlayer: player, elapsed: 250)
    NowPlayingInfo.updateNowPlayingInfo(player, elapsed: 300)

    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 120)
  }

  /// Moving from a segmented playlist to an ordinary one has to put the whole
  /// item back, or every track after it is announced three minutes long.
  func testClearingTheWindowRestoresTheWholeItem() {
    let player = Playlist.MediaPlayer()
    player.playbackWindow = 180...360
    player.playbackWindow = nil

    let item = makeInfo(name: "An Ordinary Track", duration: 240)
    NowPlayingInfo.setNowPlayingInfo(item, withPlayer: player, elapsed: 30)

    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    // Nothing is loaded, so the stored length is the only one there is.
    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 240)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 30)
  }

  // MARK: - The segment a window is built from

  /// `PlaybackController` derives the window from the segment, so the segments
  /// the arithmetic produces have to be usable as one: ordered, and covering
  /// the item between them.
  func testSegmentsProduceUsableWindows() throws {
    let length: TimeInterval = 180
    let itemDuration: TimeInterval = 500

    let count = PlaylistSegment.count(length: length, itemDuration: itemDuration)
    XCTAssertEqual(count, 3)

    var covered: TimeInterval = 0
    for index in 0..<count {
      let segment = try XCTUnwrap(
        PlaylistSegment.make(index: index, length: length, itemDuration: itemDuration))

      XCTAssertGreaterThan(segment.end, segment.start, "segment \(index) would be an empty window")
      XCTAssertEqual(segment.start, covered, accuracy: 0.0001)
      covered = segment.end
    }

    XCTAssertEqual(covered, itemDuration, accuracy: 0.0001)
  }

  // MARK: - Helpers

  private func makeInfo(name: String, duration: TimeInterval) -> PlaylistInfo {
    PlaylistInfo(
      name: name,
      src: "https://cdn.example.com/media.mp4",
      pageSrc: "https://example.com/watch",
      pageTitle: name,
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
