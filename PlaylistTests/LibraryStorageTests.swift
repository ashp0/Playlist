// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import CoreData
import XCTest

@testable import Playlist

/// Tests for the CoreData layer and the filesystem conventions the download
/// manager depends on.
final class LibraryStorageTests: XCTestCase {

  /// Items created by a test, removed in teardown so runs stay independent.
  private var createdItemIDs = [String]()

  override func tearDown() {
    for uuid in createdItemIDs {
      PlaylistItem.removeItem(uuid: uuid)
    }
    createdItemIDs = []
    super.tearDown()
  }

  // MARK: - Model

  func testManagedObjectModelHasBothEntities() {
    let entityNames = Set(DataController.managedObjectModel.entities.compactMap(\.name))
    XCTAssertEqual(entityNames, ["PlaylistItem", "PlaylistFolder"])
  }

  /// The relationship must be nullify, not cascade: `PlaylistManager` removes an
  /// item's file from disk *before* deleting its row, and a cascade would let
  /// CoreData delete rows whose files are still on disk, orphaning the bytes.
  func testItemFolderRelationshipDoesNotCascade() throws {
    let item = try XCTUnwrap(
      DataController.managedObjectModel.entitiesByName["PlaylistItem"])
    let relationship = try XCTUnwrap(item.relationshipsByName["playlistFolder"])

    XCTAssertEqual(relationship.deleteRule, .nullifyDeleteRule)
    XCTAssertEqual(relationship.inverseRelationship?.name, "playlistItems")
  }

  func testNonOptionalAttributesHaveDefaults() throws {
    // Without defaults, inserting a row that does not assign every field fails
    // validation on save.
    let entity = try XCTUnwrap(
      DataController.managedObjectModel.entitiesByName["PlaylistItem"])

    for (name, attribute) in entity.attributesByName where !attribute.isOptional {
      XCTAssertNotNil(attribute.defaultValue, "\(name) needs a default value")
    }
  }

  // MARK: - CRUD

  func testAddThenFetchItem() throws {
    let info = makeInfo(name: "Round Trip")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "item added")
    PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)

    let stored = try XCTUnwrap(PlaylistItem.getItem(uuid: info.tagId))
    XCTAssertEqual(stored.name, "Round Trip")
    XCTAssertEqual(stored.mediaSrc, info.src)
    XCTAssertEqual(stored.pageSrc, info.pageSrc)
    XCTAssertFalse(stored.isCached, "A newly added item is not downloaded")
    XCTAssertTrue(PlaylistItem.itemExists(uuid: info.tagId))
  }

  func testUpdateItemPreservesIdentity() throws {
    let info = makeInfo(name: "Before")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)

    let updated = PlaylistInfo(
      name: "After", src: "https://cdn.example.com/new.mp4", pageSrc: info.pageSrc,
      pageTitle: info.pageTitle, mimeType: info.mimeType, duration: 250,
      lastPlayedOffset: 33, detected: true, dateAdded: info.dateAdded,
      tagId: info.tagId, order: info.order, isInvisible: false)

    let saved = expectation(description: "updated")
    PlaylistItem.updateItem(updated) { saved.fulfill() }
    wait(for: [saved], timeout: 10)

    let stored = try XCTUnwrap(PlaylistItem.getItem(uuid: info.tagId))
    XCTAssertEqual(stored.name, "After")
    XCTAssertEqual(stored.mediaSrc, "https://cdn.example.com/new.mp4")
    XCTAssertEqual(stored.duration, 250, accuracy: 0.001)
    XCTAssertEqual(stored.lastPlayedOffset, 33, accuracy: 0.001)
  }

  func testUpdateLastPlayedStoresResumePoint() throws {
    let info = makeInfo(name: "Resume")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)

    PlaylistItem.updateLastPlayed(
      itemId: info.tagId, pageSrc: info.pageSrc, lastPlayedOffset: 91.5)

    // The write lands on a background context; poll rather than sleep blindly.
    let stored = try waitForItem(uuid: info.tagId) { $0.lastPlayedOffset > 0 }
    XCTAssertEqual(stored.lastPlayedOffset, 91.5, accuracy: 0.01)
  }

  func testDeleteRemovesItem() throws {
    let info = makeInfo(name: "Doomed")

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)
    XCTAssertTrue(PlaylistItem.itemExists(uuid: info.tagId))

    let removed = expectation(description: "removed")
    PlaylistItem.removeItems([info]) { removed.fulfill() }
    wait(for: [removed], timeout: 10)

    XCTAssertFalse(PlaylistItem.itemExists(uuid: info.tagId))
  }

  /// Regression test: one page can contribute several items, each with its own
  /// media source. Upstream resolves updates with `uuid == X OR pageSrc == Y`,
  /// which can match a *sibling* item and write one item's data — including its
  /// downloaded-file bookmark — onto another.
  func testUpdatingOneItemDoesNotClobberASiblingFromTheSamePage() throws {
    let sharedPage = "https://example.com/watch/\(UUID().uuidString)"

    let first = makeInfo(name: "First", pageSrc: sharedPage)
    let second = makeInfo(name: "Second", pageSrc: sharedPage)
    createdItemIDs.append(contentsOf: [first.tagId, second.tagId])

    for info in [first, second] {
      let added = expectation(description: "added \(info.name)")
      PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
      wait(for: [added], timeout: 10)
    }

    // Give the second item a cache bookmark, addressed by its own uuid.
    let bookmark = Data("pretend-bookmark".utf8)
    let cached = expectation(description: "cache updated")
    PlaylistItem.updateCache(
      uuid: second.tagId, pageSrc: sharedPage, cachedData: bookmark
    ) { cached.fulfill() }
    wait(for: [cached], timeout: 10)

    let storedSecond = try XCTUnwrap(PlaylistItem.getItem(uuid: second.tagId))
    XCTAssertEqual(storedSecond.cachedData, bookmark)

    let storedFirst = try XCTUnwrap(PlaylistItem.getItem(uuid: first.tagId))
    XCTAssertFalse(
      storedFirst.isCached,
      "The sibling item must not have picked up the other item's download")
  }

  func testSearchMatchesNameCaseInsensitively() throws {
    let info = makeInfo(name: "A Very Distinctive Zebra Title")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)

    let results = PlaylistItem.search(query: "distinctive zebra")
    XCTAssertTrue(results.contains { $0.uuid == info.tagId })
  }

  // MARK: - Sorting

  func testSortDescriptorsAlwaysTotallyOrder() {
    // A non-total order lets equal-keyed rows swap between fetches, which shows
    // up as the library list visibly jittering while it scrolls.
    for order in LibrarySortOrder.allCases {
      let descriptors = PlaylistItem.sortDescriptors(for: order)
      XCTAssertFalse(descriptors.isEmpty, "\(order) has no sort descriptors")

      if order != .dateAddedOldest {
        XCTAssertTrue(
          descriptors.contains { $0.key == "dateAdded" },
          "\(order) needs dateAdded as a tiebreaker")
      }
    }
  }

  // MARK: - Storage conventions

  /// Media must live in Application Support, not Caches: iOS purges Caches
  /// under storage pressure, which would silently delete the user's downloads.
  func testPlaylistDirectoryIsInApplicationSupportAndExcludedFromBackups() throws {
    let directory = try XCTUnwrap(PlaylistDownloadManager.playlistDirectory)

    XCTAssertTrue(directory.path.contains("Application Support"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  /// Two downloads that resolve to the same filename must not overwrite each
  /// other — the CoreData row holds a bookmark to a specific path, so a
  /// collision silently corrupts the first item.
  func testUniquePathAvoidsCollisions() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try directory.uniquePathForFilename("clip.mp4")
    XCTAssertEqual(first.lastPathComponent, "clip.mp4")
    FileManager.default.createFile(atPath: first.path, contents: Data([0x00]))

    let second = try directory.uniquePathForFilename("clip.mp4")
    XCTAssertEqual(second.lastPathComponent, "clip (1).mp4")
    FileManager.default.createFile(atPath: second.path, contents: Data([0x00]))

    let third = try directory.uniquePathForFilename("clip.mp4")
    XCTAssertEqual(third.lastPathComponent, "clip (2).mp4")
  }

  /// Filenames come from page titles, which are arbitrary attacker-influenced
  /// text. They must not be able to escape the directory or spoof an extension.
  func testFilenameSanitisation() {
    XCTAssertEqual("../../etc/passwd".sanitizedFilename, "....etcpasswd")
    XCTAssertEqual("a/b:c".sanitizedFilename, "abc")
    XCTAssertFalse("video\u{202E}4pm.exe".sanitizedFilename.contains("\u{202E}"))
    XCTAssertLessThanOrEqual(String(repeating: "x", count: 500).sanitizedFilename.count, 120)
  }

  // MARK: - Helpers

  private func makeInfo(name: String, pageSrc: String? = nil) -> PlaylistInfo {
    let id = UUID().uuidString
    return PlaylistInfo(
      name: name,
      src: "https://cdn.example.com/\(id).mp4",
      pageSrc: pageSrc ?? "https://example.com/watch/\(id)",
      pageTitle: name,
      mimeType: "video/mp4",
      duration: 120,
      lastPlayedOffset: 0,
      detected: true,
      dateAdded: Date(),
      tagId: id,
      order: 0,
      isInvisible: false)
  }

  /// Polls the view context until `predicate` holds. Writes go through a
  /// background context and merge asynchronously, so a bare read races.
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
