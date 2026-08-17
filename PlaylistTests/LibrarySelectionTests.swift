// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import XCTest

@testable import Playlist

/// Tests that the library reopens on the playlist it was left on.
///
/// A fresh `LibraryViewModel` is what a launch builds, so building one is how
/// a relaunch is stood in for here — the restore runs in `init` and nowhere
/// else, and it has to leave both the model and `PlaylistManager` pointing at
/// the same folder. The manager is the half worth asserting: the model's own
/// property drives the navigation title, but the manager's is what the fetched
/// results controller is scoped to, and the two disagreeing shows up as a
/// playlist's name over the whole library's contents.
@MainActor
final class LibrarySelectionTests: XCTestCase {

  private var createdFolderUUIDs = [String]()

  override func tearDown() {
    PlaylistManager.shared.currentFolder = nil
    Preferences.Playlist.selectedFolderUUID.reset()

    for uuid in createdFolderUUIDs {
      PlaylistFolder.removeFolder(uuid)
    }
    createdFolderUUIDs = []

    super.tearDown()
  }

  // MARK: - Remembering

  func testSelectingAPlaylistRecordsIt() throws {
    let uuid = try makeFolder(title: "Morning Run")
    let model = LibraryViewModel()

    model.selectedFolder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: uuid))

    XCTAssertEqual(Preferences.Playlist.selectedFolderUUID.value, uuid)
  }

  /// All Media is a choice, not the absence of one. Recording it as empty is
  /// what lets the restore treat "never picked anything" and "picked All Media"
  /// the same way, which is right because they want the same screen.
  func testSelectingAllMediaRecordsTheAbsenceOfAPlaylist() throws {
    let uuid = try makeFolder(title: "Morning Run")
    let model = LibraryViewModel()

    model.selectedFolder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: uuid))
    model.selectedFolder = nil

    XCTAssertEqual(Preferences.Playlist.selectedFolderUUID.value, "")
  }

  // MARK: - Restoring

  func testAPlaylistIsRestoredOnTheNextLaunch() throws {
    let uuid = try makeFolder(title: "Morning Run")

    let first = LibraryViewModel()
    first.selectedFolder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: uuid))

    let relaunched = LibraryViewModel()

    XCTAssertEqual(relaunched.selectedFolder?.uuid, uuid)
    XCTAssertEqual(PlaylistManager.shared.currentFolder?.uuid, uuid)
  }

  /// The behaviour asked for by name: having chosen a playlist, the app must
  /// not quietly go back to showing everything.
  func testARestoredPlaylistIsNotReplacedByAllMedia() throws {
    let uuid = try makeFolder(title: "Language Course")
    Preferences.Playlist.selectedFolderUUID.value = uuid

    let relaunched = LibraryViewModel()

    XCTAssertNotNil(relaunched.selectedFolder)
    XCTAssertEqual(relaunched.selectedFolder?.title, "Language Course")
  }

  func testAllMediaIsRestoredWhenItWasTheLastChoice() throws {
    let uuid = try makeFolder(title: "Morning Run")

    let first = LibraryViewModel()
    first.selectedFolder = try XCTUnwrap(PlaylistFolder.getFolder(uuid: uuid))
    first.selectedFolder = nil

    let relaunched = LibraryViewModel()

    XCTAssertNil(relaunched.selectedFolder)
    XCTAssertNil(PlaylistManager.shared.currentFolder)
  }

  func testNothingRestoredWhenNothingWasEverChosen() {
    Preferences.Playlist.selectedFolderUUID.reset()

    let model = LibraryViewModel()

    XCTAssertNil(model.selectedFolder)
  }

  /// A playlist can be deleted while the app is closed — from another device's
  /// restore, or simply in a previous session. Reopening onto a playlist that
  /// no longer exists would be an empty screen with a stale name on it.
  func testAPlaylistDeletedWhileClosedFallsBackToAllMedia() {
    Preferences.Playlist.selectedFolderUUID.value = UUID().uuidString

    let model = LibraryViewModel()

    XCTAssertNil(model.selectedFolder)
    // And it is forgotten, rather than being retried on every launch from here
    // to the end of the install.
    XCTAssertEqual(Preferences.Playlist.selectedFolderUUID.value, "")
  }

  // MARK: - Scope

  /// The Downloads screen reads the whole library whichever playlist is
  /// selected. If it restored a selection too, two models would be writing the
  /// manager's browsing folder at launch with nothing deciding which won.
  func testTheWholeLibraryScopeDoesNotRestoreASelection() throws {
    let uuid = try makeFolder(title: "Morning Run")
    Preferences.Playlist.selectedFolderUUID.value = uuid

    let downloads = LibraryViewModel(scope: .wholeLibrary)

    XCTAssertNil(downloads.selectedFolder)
    XCTAssertNil(PlaylistManager.shared.currentFolder)
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
    return try XCTUnwrap(folderUUID.isEmpty ? nil : folderUUID)
  }
}
