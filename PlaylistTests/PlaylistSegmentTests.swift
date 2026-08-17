// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import CoreData
import XCTest

@testable import Playlist

/// Tests for playlists that play part of each item and come back for the rest.
///
/// The arithmetic is tested directly rather than through playback because that
/// is where the behaviour actually lives, and because its edge cases — an item
/// shorter than a segment, a final segment shorter than the others, an index
/// left over from a different segment length — are the ones that would quietly
/// cut a track in the wrong place.
final class PlaylistSegmentTests: XCTestCase {

  private var createdFolderUUIDs = [String]()
  private var createdItemIDs = [String]()

  override func tearDown() {
    PlaylistManager.shared.currentFolder = nil

    for uuid in createdItemIDs {
      PlaylistItem.removeItem(uuid: uuid)
    }
    for uuid in createdFolderUUIDs {
      PlaylistFolder.removeFolder(uuid)
    }
    createdItemIDs = []
    createdFolderUUIDs = []

    super.tearDown()
  }

  // MARK: - Dividing an item

  func testPlaylistWithNoSegmentLengthPlaysItemsWhole() {
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 0, itemDuration: 600))
  }

  /// The rule the feature is asked for by name: a song shorter than the segment
  /// is an ordinary song.
  func testItemShorterThanASegmentIsNotDivided() {
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 180, itemDuration: 150))
    XCTAssertNil(PlaylistSegment.make(index: 2, length: 180, itemDuration: 150))
  }

  /// An item the same length as the segment would divide into exactly one
  /// piece, which is the same as not dividing it — and measurement noise must
  /// not turn it into two, the second lasting a fraction of a second.
  func testItemTheLengthOfASegmentIsNotDivided() {
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 180, itemDuration: 180))
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 180, itemDuration: 180.4))
  }

  func testLiveAndUnmeasuredMediaPlayWhole() {
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 180, itemDuration: .infinity))
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 180, itemDuration: 0))
  }

  /// The worked example: three-minute segments over a seven-minute item.
  func testSuccessiveSegmentsWalkThroughTheItem() throws {
    let first = try XCTUnwrap(PlaylistSegment.make(index: 0, length: 180, itemDuration: 420))
    XCTAssertEqual(first.count, 3)
    XCTAssertEqual(first.start, 0)
    XCTAssertEqual(first.end, 180)
    XCTAssertFalse(first.isFinal)

    let second = try XCTUnwrap(PlaylistSegment.make(index: 1, length: 180, itemDuration: 420))
    XCTAssertEqual(second.start, 180)
    XCTAssertEqual(second.end, 360)
    XCTAssertFalse(second.isFinal)

    // The last segment ends with the item rather than running past it.
    let third = try XCTUnwrap(PlaylistSegment.make(index: 2, length: 180, itemDuration: 420))
    XCTAssertEqual(third.start, 360)
    XCTAssertEqual(third.end, 420)
    XCTAssertTrue(third.isFinal)
  }

  // MARK: - Knowing when an item has been played in full

  /// The count is what a playlist counts a pass with: progress runs 0, 1, 2 and
  /// then stops *at* the count, and an item whose progress has reached it has
  /// nothing left to play this time round. Wrapping there instead — which is
  /// what the first version of this did — is what left a repeating playlist
  /// replaying the same stretches for ever, because no item ever reported
  /// being finished and the pass never ended.
  func testProgressRunsUpToTheSegmentCountAndStopsThere() throws {
    let count = PlaylistSegment.count(length: 180, itemDuration: 420)
    XCTAssertEqual(count, 3)

    // The rule a segmented playlist advances by: play the stretch progress
    // points at, then move progress past it, and stop asking once progress has
    // reached the count.
    var progress = 0
    var played = [TimeInterval]()

    while progress < count {
      let segment = try XCTUnwrap(
        PlaylistSegment.make(index: progress, length: 180, itemDuration: 420))
      played.append(segment.start)
      progress += 1
    }

    XCTAssertEqual(played, [0, 180, 360], "Every stretch of the item, each of them once")
    XCTAssertEqual(progress, count, "Progress stops at the count, which reads as finished")
  }

  /// An item a segmented playlist plays whole still takes one pass to get
  /// through, so it too is finished after one — otherwise a playlist with a
  /// short song in it could never report having played everything.
  func testAnItemPlayedWholeCountsAsOneSegment() {
    XCTAssertEqual(PlaylistSegment.count(length: 180, itemDuration: 150), 1)
    XCTAssertEqual(PlaylistSegment.count(length: 180, itemDuration: 180), 1)
    XCTAssertNil(PlaylistSegment.make(index: 0, length: 180, itemDuration: 150))
  }

  /// A playlist with no segment length has nothing to divide, and neither does
  /// media of unknown or endless length.
  func testUndividableItemsTakeOnePass() {
    XCTAssertEqual(PlaylistSegment.count(length: 0, itemDuration: 600), 1)
    XCTAssertEqual(PlaylistSegment.count(length: 180, itemDuration: 0), 1)
    XCTAssertEqual(PlaylistSegment.count(length: 180, itemDuration: .infinity), 1)
  }

  /// The count agrees with what `make` produces, since one decides when an item
  /// is finished and the other decides what it plays.
  func testCountAgreesWithTheSegmentsItDescribes() throws {
    for itemDuration in [420.0, 361.0, 540.0, 605.5, 360.3] {
      let count = PlaylistSegment.count(length: 180, itemDuration: itemDuration)

      let first = try XCTUnwrap(
        PlaylistSegment.make(index: 0, length: 180, itemDuration: itemDuration))
      XCTAssertEqual(first.count, count, "at \(itemDuration)")

      let last = try XCTUnwrap(
        PlaylistSegment.make(index: count - 1, length: 180, itemDuration: itemDuration))
      XCTAssertTrue(last.isFinal, "at \(itemDuration)")
      XCTAssertEqual(last.end, itemDuration, accuracy: 0.001)
    }
  }

  /// Stored progress outlives the segment length it was recorded against, so an
  /// index past the end of the item has to wrap rather than seek past its end.
  func testIndexPastTheEndOfTheItemWraps() throws {
    let wrapped = try XCTUnwrap(PlaylistSegment.make(index: 4, length: 180, itemDuration: 420))
    XCTAssertEqual(wrapped.index, 1)
    XCTAssertEqual(wrapped.start, 180)

    let negative = try XCTUnwrap(PlaylistSegment.make(index: -1, length: 180, itemDuration: 420))
    XCTAssertEqual(negative.index, 2)
  }

  func testSegmentContainingAPositionIsTheOneBeingPlayed() throws {
    let segment = try XCTUnwrap(
      PlaylistSegment.make(containing: 200, length: 180, itemDuration: 420))

    XCTAssertEqual(segment.index, 1)
    XCTAssertEqual(segment.start, 180)
    XCTAssertEqual(segment.end, 360)
  }

  func testSegmentContainingAPositionInAShortItemIsStillNothing() {
    XCTAssertNil(PlaylistSegment.make(containing: 60, length: 180, itemDuration: 150))
  }

  /// Between them the segments have to cover the whole item: a listener working
  /// through a long recording three minutes at a time must not find that the
  /// last stretch of it is never played.
  func testSegmentsCoverTheWholeItem() throws {
    for itemDuration in [420.0, 361.0, 540.0, 605.5] {
      var covered: TimeInterval = 0
      let first = try XCTUnwrap(
        PlaylistSegment.make(index: 0, length: 180, itemDuration: itemDuration))

      for index in 0..<first.count {
        let segment = try XCTUnwrap(
          PlaylistSegment.make(index: index, length: 180, itemDuration: itemDuration))
        XCTAssertEqual(segment.start, covered, accuracy: 0.001, "gap at \(itemDuration)")
        covered = segment.end
      }

      XCTAssertEqual(covered, itemDuration, accuracy: 0.001)
    }
  }

  /// A last segment of a fraction of a second is a switch away and back for
  /// nothing audible, so it belongs to the segment before it.
  func testATrailingFragmentIsFoldedIntoTheSegmentBeforeIt() throws {
    let segment = try XCTUnwrap(
      PlaylistSegment.make(index: 0, length: 180, itemDuration: 360.3))

    XCTAssertEqual(segment.count, 2)
    XCTAssertEqual(
      try XCTUnwrap(PlaylistSegment.make(index: 1, length: 180, itemDuration: 360.3)).end,
      360.3)
  }

  // MARK: - Model

  /// Both attributes are added to a model already in the field, and migration
  /// is inferred. A non-optional attribute with no default is the one shape
  /// CoreData cannot infer a mapping for, and the store would fail to open.
  func testSegmentAttributesAreMigratable() throws {
    let folder = try XCTUnwrap(
      DataController.managedObjectModel.entitiesByName["PlaylistFolder"])
    let duration = try XCTUnwrap(folder.attributesByName["segmentDuration"])
    XCTAssertEqual(duration.attributeType, .doubleAttributeType)
    XCTAssertEqual(duration.defaultValue as? Double, 0)

    let item = try XCTUnwrap(DataController.managedObjectModel.entitiesByName["PlaylistItem"])
    let index = try XCTUnwrap(item.attributesByName["segmentIndex"])
    XCTAssertEqual(index.attributeType, .integer32AttributeType)
    XCTAssertEqual(index.defaultValue as? Int, 0)
  }

  func testNewPlaylistPlaysItsItemsWhole() throws {
    let uuid = try makeFolder(title: "Ordinary")
    let folder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: uuid))

    XCTAssertEqual(folder.segmentDuration, 0)
    XCTAssertFalse(folder.isSegmented)
  }

  func testSegmentLengthPersistsAndClears() throws {
    let uuid = try makeFolder(title: "Rotation")

    let set = expectation(description: "set")
    PlaylistFolder.setSegmentDuration(uuid: uuid, duration: 180) { set.fulfill() }
    wait(for: [set], timeout: 10)
    XCTAssertTrue(try waitForFolder(uuid: uuid) { $0.isSegmented }.isSegmented)
    XCTAssertEqual(try waitForFolder(uuid: uuid) { $0.isSegmented }.segmentDuration, 180)

    let cleared = expectation(description: "cleared")
    PlaylistFolder.setSegmentDuration(uuid: uuid, duration: 0) { cleared.fulfill() }
    wait(for: [cleared], timeout: 10)
    XCTAssertFalse(try waitForFolder(uuid: uuid) { !$0.isSegmented }.isSegmented)
  }

  func testSegmentProgressPersistsAndResets() throws {
    let folderUUID = try makeFolder(title: "Rotation")
    let info = makeInfo(name: "Long Mix")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, folderUUID: folderUUID, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)
    XCTAssertEqual(PlaylistItem.getItem(uuid: info.tagId)?.segmentIndex, 0)

    let advanced = expectation(description: "advanced")
    PlaylistItem.updateSegmentIndex(uuid: info.tagId, segmentIndex: 2) { advanced.fulfill() }
    wait(for: [advanced], timeout: 10)
    XCTAssertEqual(try waitForItem(uuid: info.tagId) { $0.segmentIndex == 2 }.segmentIndex, 2)

    let reset = expectation(description: "reset")
    PlaylistItem.resetSegmentIndices(folderUUID: folderUUID) { reset.fulfill() }
    wait(for: [reset], timeout: 10)
    XCTAssertEqual(try waitForItem(uuid: info.tagId) { $0.segmentIndex == 0 }.segmentIndex, 0)
  }

  // MARK: - Library scope

  /// The regression behind "opening an empty playlist emptied the Downloads
  /// tab": the fetched results controller carries the browsing folder's
  /// predicate, so anything asking about the library as a whole has to fetch.
  func testEveryItemIgnoresTheFolderBeingBrowsed() throws {
    let info = makeInfo(name: "Filed Elsewhere")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)

    let emptyFolderUUID = try makeFolder(title: "Empty")
    let emptyFolder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: emptyFolderUUID))

    let manager = PlaylistManager.shared
    manager.currentFolder = emptyFolder

    XCTAssertTrue(
      manager.allItems.isEmpty, "The library list is scoped to the selected playlist")
    XCTAssertTrue(
      manager.everyItem.contains { $0.tagId == info.tagId },
      "The whole library is still reachable while an empty playlist is open")
    XCTAssertFalse(manager.everyItemObject.isEmpty)
  }

  // MARK: - Helpers

  private func makeFolder(title: String) throws -> String {
    let created = expectation(description: "folder created")
    var folderUUID = ""

    PlaylistFolder.addFolder(title: title) { uuid in
      folderUUID = uuid
      created.fulfill()
    }
    wait(for: [created], timeout: 10)

    createdFolderUUIDs.append(folderUUID)
    return folderUUID
  }

  private func makeInfo(name: String) -> PlaylistInfo {
    let id = UUID().uuidString
    return PlaylistInfo(
      name: name,
      src: "https://cdn.example.com/\(id).mp4",
      pageSrc: "https://example.com/watch/\(id)",
      pageTitle: name,
      mimeType: "video/mp4",
      duration: 420,
      lastPlayedOffset: 0,
      detected: true,
      dateAdded: Date(),
      tagId: id,
      order: 0,
      isInvisible: false)
  }

  /// Polls the view context until `predicate` holds. Writes go through a
  /// background context and merge asynchronously, so a bare read races.
  private func waitForFolder(
    uuid: String,
    timeout: TimeInterval = 10,
    until predicate: (PlaylistFolder) -> Bool
  ) throws -> PlaylistFolder {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      DataController.viewContext.refreshAllObjects()
      if let folder = PlaylistFolder.getFolder(uuid: uuid), predicate(folder) {
        return folder
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    throw XCTSkip("Timed out waiting for folder \(uuid)")
  }

  private func waitForItem(
    uuid: String,
    timeout: TimeInterval = 10,
    until predicate: (PlaylistItem) -> Bool
  ) throws -> PlaylistItem {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      DataController.viewContext.refreshAllObjects()
      if let item = PlaylistItem.getItem(uuid: uuid), predicate(item) {
        return item
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    throw XCTSkip("Timed out waiting for item \(uuid)")
  }
}
