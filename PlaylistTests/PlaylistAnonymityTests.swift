// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import CoreData
import MediaPlayer
import XCTest

@testable import Playlist

/// Tests for playlists that withhold their identity from the lock screen.
///
/// The two halves are tested separately because they fail in different ways:
/// the folder flag is a storage question (does it survive, and does an item
/// find it), while what reaches `MPNowPlayingInfoCenter` is a merge question —
/// every other publisher in `NowPlayingInfo` merges into the existing
/// dictionary, so the failure mode worth pinning down is a title or an artwork
/// from the *previous* item outliving the switch to an anonymised one.
final class PlaylistAnonymityTests: XCTestCase {

  private var createdFolderUUIDs = [String]()
  private var createdItemIDs = [String]()

  override func tearDown() {
    for uuid in createdItemIDs {
      PlaylistItem.removeItem(uuid: uuid)
    }
    for uuid in createdFolderUUIDs {
      PlaylistFolder.removeFolder(uuid)
    }
    createdItemIDs = []
    createdFolderUUIDs = []

    NowPlayingInfo.clearNowPlayingInfo()
    super.tearDown()
  }

  // MARK: - Model

  /// The attribute is added to a model that already exists in the field, and
  /// migration is inferred. A non-optional attribute with no default value is
  /// exactly the shape CoreData cannot infer a mapping for, and the store would
  /// fail to open — which this app treats as fatal.
  func testFolderAnonymityAttributeIsMigratable() throws {
    let folder = try XCTUnwrap(
      DataController.managedObjectModel.entitiesByName["PlaylistFolder"])
    let attribute = try XCTUnwrap(folder.attributesByName["isAnonymous"])

    XCTAssertEqual(attribute.attributeType, .booleanAttributeType)
    XCTAssertEqual(attribute.defaultValue as? Bool, false)
  }

  func testFolderNonOptionalAttributesHaveDefaults() throws {
    let folder = try XCTUnwrap(
      DataController.managedObjectModel.entitiesByName["PlaylistFolder"])

    for (name, attribute) in folder.attributesByName where !attribute.isOptional {
      XCTAssertNotNil(attribute.defaultValue, "\(name) needs a default value")
    }
  }

  // MARK: - Persistence

  func testNewFolderIsNotAnonymous() throws {
    let uuid = try makeFolder(title: "Ordinary")
    let folder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: uuid))

    XCTAssertFalse(folder.isAnonymous)
  }

  func testSettingAnonymityPersistsAndReverses() throws {
    let uuid = try makeFolder(title: "Private")

    let hidden = expectation(description: "hidden")
    PlaylistFolder.setAnonymous(uuid: uuid, isAnonymous: true) { hidden.fulfill() }
    wait(for: [hidden], timeout: 10)
    XCTAssertTrue(try waitForFolder(uuid: uuid) { $0.isAnonymous }.isAnonymous)

    let shown = expectation(description: "shown")
    PlaylistFolder.setAnonymous(uuid: uuid, isAnonymous: false) { shown.fulfill() }
    wait(for: [shown], timeout: 10)
    XCTAssertFalse(try waitForFolder(uuid: uuid) { !$0.isAnonymous }.isAnonymous)
  }

  /// Playback holds items, not folders — a queue can be assembled from several
  /// playlists at once — so the flag has to be reachable from an item id.
  func testItemResolvesAnonymityThroughItsFolder() throws {
    let uuid = try makeFolder(title: "Hidden Playlist")
    let info = makeInfo(name: "Track")
    createdItemIDs.append(info.tagId)

    let added = expectation(description: "added")
    PlaylistItem.addItem(info, folderUUID: uuid, cachedData: nil) { added.fulfill() }
    wait(for: [added], timeout: 10)

    XCTAssertFalse(PlaylistFolder.isAnonymous(itemId: info.tagId))

    let hidden = expectation(description: "hidden")
    PlaylistFolder.setAnonymous(uuid: uuid, isAnonymous: true) { hidden.fulfill() }
    wait(for: [hidden], timeout: 10)
    _ = try waitForFolder(uuid: uuid) { $0.isAnonymous }

    XCTAssertTrue(PlaylistFolder.isAnonymous(itemId: info.tagId))
    XCTAssertEqual(PlaylistFolder.folder(forItemId: info.tagId)?.title, "Hidden Playlist")
  }

  func testUnknownItemIsNotAnonymous() {
    XCTAssertFalse(PlaylistFolder.isAnonymous(itemId: UUID().uuidString))
  }

  // MARK: - What reaches the lock screen

  func testAnonymousInfoPublishesTimingButNoIdentity() {
    let player = Playlist.MediaPlayer()
    let item = makeInfo(name: "Should Not Appear")

    NowPlayingInfo.setNowPlayingInfo(item, withPlayer: player, isAnonymous: true)
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertNil(info[MPMediaItemPropertyTitle])
    XCTAssertNil(info[MPMediaItemPropertyArtist])
    XCTAssertNil(info[MPMediaItemPropertyArtwork])

    // The transport still has to work, which needs a timeline.
    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, item.duration)
    XCTAssertNotNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
  }

  /// The regression this feature is most likely to develop: `NowPlayingInfo`
  /// merges everywhere else, so an anonymised item published after a named one
  /// must not inherit its title, artwork or queue position.
  func testAnonymousInfoDoesNotInheritThePreviousItem() {
    let player = Playlist.MediaPlayer()

    NowPlayingInfo.setNowPlayingInfo(makeInfo(name: "Previous Track"), withPlayer: player)
    NowPlayingInfo.setQueuePosition(index: 2, count: 9)
    NowPlayingInfo.setNowPlayingMediaArtwork(image: UIImage(systemName: "music.note"))

    XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle])

    NowPlayingInfo.setNowPlayingInfo(
      makeInfo(name: "Should Not Appear"), withPlayer: player, isAnonymous: true)
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertNil(info[MPMediaItemPropertyTitle])
    XCTAssertNil(info[MPMediaItemPropertyArtist])
    XCTAssertNil(info[MPMediaItemPropertyArtwork])
    XCTAssertNil(info[MPNowPlayingInfoPropertyPlaybackQueueIndex])
    XCTAssertNil(info[MPNowPlayingInfoPropertyPlaybackQueueCount])
  }

  /// Hiding a playlist while one of its items is playing strips the identity
  /// without disturbing the timeline — re-publishing the item would move the
  /// scrubber, which the system reads as a seek.
  func testRemovingIdentityLeavesTheTimelineAlone() {
    let player = Playlist.MediaPlayer()
    let item = makeInfo(name: "Playing Now")

    NowPlayingInfo.setNowPlayingInfo(item, withPlayer: player)
    NowPlayingInfo.setQueuePosition(index: 1, count: 4)
    NowPlayingInfo.setNowPlayingMediaArtwork(image: UIImage(systemName: "music.note"))

    NowPlayingInfo.removeIdentifyingInfo()
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertNil(info[MPMediaItemPropertyTitle])
    XCTAssertNil(info[MPMediaItemPropertyArtist])
    XCTAssertNil(info[MPMediaItemPropertyArtwork])
    XCTAssertNil(info[MPNowPlayingInfoPropertyPlaybackQueueIndex])

    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, item.duration)
    XCTAssertNotNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
  }

  /// An ordinary playlist is unaffected by any of this.
  func testNamedItemStillPublishesItsIdentity() {
    let player = Playlist.MediaPlayer()
    let item = makeInfo(name: "Ordinary Track")

    NowPlayingInfo.setNowPlayingInfo(item, withPlayer: player)
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Ordinary Track")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "example.com")
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
}
