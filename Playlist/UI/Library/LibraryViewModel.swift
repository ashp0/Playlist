// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Combine
import Foundation
import SwiftUI

/// Bridges `PlaylistManager` — an `NSFetchedResultsController` behind Combine
/// subjects, inherited from Brave's UIKit design — into something SwiftUI can
/// observe.
///
/// The FRC is kept rather than replaced with `@FetchRequest` because it is what
/// the ported manager, download manager and CoreData helpers are all written
/// against; swapping it out would mean rewriting the layer this app most wants
/// to reuse unchanged.
@MainActor
final class LibraryViewModel: ObservableObject {

  /// Which items the model lists.
  enum Scope {
    /// Follows the playlist the user has selected in the library.
    case selectedPlaylist
    /// The whole library, whatever the library happens to be showing.
    ///
    /// The Downloads screen uses this. Being downloaded is a property of an
    /// item, not of the playlist being browsed, and `PlaylistManager`'s fetched
    /// results controller is scoped to that playlist — so a screen that reads
    /// it goes empty the moment the user opens an empty playlist in the other
    /// tab.
    case wholeLibrary
  }

  let scope: Scope

  @Published private(set) var items = [PlaylistInfo]()
  @Published private(set) var folders = [PlaylistFolder]()

  @Published var searchText = "" {
    didSet {
      guard searchText != oldValue else { return }
      applyFilter()
    }
  }

  @Published var sortOrder: LibrarySortOrder {
    didSet {
      guard sortOrder != oldValue else { return }
      PlaylistManager.shared.sortOrder = sortOrder
      reload()
    }
  }

  /// The folder being browsed, or nil for the whole library.
  ///
  /// Remembered across launches — see `restoreSelectedFolder`. Picking a
  /// playlist is a statement about what the user is listening to at the moment,
  /// not a temporary filter, so coming back to the app puts them where they
  /// left off rather than back at everything they own.
  @Published var selectedFolder: PlaylistFolder? {
    didSet {
      guard selectedFolder?.objectID != oldValue?.objectID else { return }
      PlaylistManager.shared.currentFolder = selectedFolder
      rememberSelectedFolder()
      reload()
    }
  }

  /// Download state per item id, so rows do not each hit the filesystem.
  @Published private(set) var downloadStates = [String: PlaylistDownloadManager.DownloadState]()
  @Published private(set) var downloadProgress = [String: Double]()

  private var allItems = [PlaylistInfo]()
  private var cancellables = Set<AnyCancellable>()

  init(scope: Scope = .selectedPlaylist) {
    self.scope = scope
    sortOrder = PlaylistManager.shared.sortOrder
    restoreSelectedFolder()
    observeManager()
    reload()
  }

  // MARK: - Remembering the selection

  /// Reopens the library on whatever playlist it was last showing.
  ///
  /// Only the library-scoped model does this. The Downloads screen deliberately
  /// reads the whole library whichever playlist is selected, and having it
  /// restore a selection would mean two view models writing the manager's
  /// browsing folder at launch with no agreement about which won.
  ///
  /// This runs as a method rather than inline in `init` on purpose: the write
  /// then goes through `selectedFolder`'s observer, which is what points the
  /// manager at the folder. An assignment in `init` itself would not — Swift
  /// runs no property observer for one — and the library would come up showing
  /// a playlist's name over the whole of everything.
  private func restoreSelectedFolder() {
    guard scope == .selectedPlaylist else { return }

    let uuid = Preferences.Playlist.selectedFolderUUID.value
    guard !uuid.isEmpty else { return }

    guard let folder = PlaylistFolder.getFolder(uuid: uuid) else {
      // The playlist was deleted while the app was closed. Forget it rather
      // than trying again on every launch.
      Preferences.Playlist.selectedFolderUUID.value = ""
      return
    }

    selectedFolder = folder
  }

  private func rememberSelectedFolder() {
    guard scope == .selectedPlaylist else { return }
    Preferences.Playlist.selectedFolderUUID.value = selectedFolder?.uuid ?? ""
  }

  // MARK: - Loading

  func reload() {
    let manager = PlaylistManager.shared

    // A playlist can go away without this model being the one that removed it —
    // "Delete Everything" empties the store from Settings, and a batch delete
    // leaves the row here as a deleted object rather than nil. Reading a
    // deleted object's title is a crash, so the selection is dropped before
    // anything else looks at it.
    if let folder = selectedFolder, folder.isDeleted || folder.managedObjectContext == nil {
      selectedFolder = nil
    }

    manager.reloadData()

    switch scope {
    case .selectedPlaylist:
      allItems = manager.allItems
    case .wholeLibrary:
      allItems = manager.everyItem
    }

    folders = PlaylistFolder.getFolders()

    refreshDownloadStates()
    applyFilter()
  }

  /// Applies the search text.
  ///
  /// Filtered in memory rather than re-fetching: the library is small enough
  /// (hundreds, not millions) that a predicate round trip per keystroke would
  /// cost more than it saves, and this keeps the FRC's sort order intact.
  private func applyFilter() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !query.isEmpty else {
      items = allItems
      return
    }

    items = allItems.filter { item in
      item.name.localizedCaseInsensitiveContains(query)
        || item.pageTitle.localizedCaseInsensitiveContains(query)
        || (URL(string: item.pageSrc)?.baseDomain?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private func refreshDownloadStates() {
    let manager = PlaylistManager.shared
    var states = [String: PlaylistDownloadManager.DownloadState]()

    for item in allItems {
      states[item.tagId] = manager.state(for: item.tagId)
    }

    downloadStates = states
    downloadProgress = manager.downloadProgress
  }

  private func observeManager() {
    let manager = PlaylistManager.shared

    manager.contentDidChange
      // The FRC can emit a burst of changes for a single batch write; coalesce
      // them so the list rebuilds once rather than per row.
      .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
      .sink { [weak self] in
        self?.reload()
      }.store(in: &cancellables)

    manager.downloadProgressUpdated
      .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
      .sink { [weak self] update in
        self?.downloadProgress[update.id] = update.percentComplete
      }.store(in: &cancellables)

    manager.downloadStateChanged
      .receive(on: RunLoop.main)
      .sink { [weak self] update in
        guard let self = self else { return }
        self.downloadStates[update.id] = update.state

        if update.state != .inProgress {
          self.downloadProgress[update.id] = nil
        }

        // A finished download means a real frame can now be pulled from the
        // local file, replacing whatever placeholder artwork was cached.
        if update.state == .downloaded {
          Task {
            await ThumbnailRenderer.shared.invalidate(id: update.id)
          }
        }
      }.store(in: &cancellables)

    manager.onFolderRemovedOrUpdated
      .receive(on: RunLoop.main)
      .sink { [weak self] in
        guard let self = self else { return }
        if self.selectedFolder?.isDeleted == true {
          self.selectedFolder = nil
        }
        self.reload()
      }.store(in: &cancellables)
  }

  // MARK: - Actions

  func state(for item: PlaylistInfo) -> PlaylistDownloadManager.DownloadState {
    downloadStates[item.tagId] ?? .invalid
  }

  func progress(for item: PlaylistInfo) -> Double? {
    downloadProgress[item.tagId]
  }

  func download(_ item: PlaylistInfo) {
    PlaylistManager.shared.download(item: item)
    downloadStates[item.tagId] = .inProgress
  }

  func cancelDownload(_ item: PlaylistInfo) {
    PlaylistManager.shared.cancelDownload(itemId: item.tagId)
    downloadStates[item.tagId] = .invalid
  }

  func delete(_ item: PlaylistInfo) {
    _ = PlaylistManager.shared.delete(item: item)
    reload()
  }

  func delete(at offsets: IndexSet) {
    for index in offsets where items.indices.contains(index) {
      _ = PlaylistManager.shared.delete(item: items[index])
    }
    reload()
  }

  /// Removes the downloaded file but keeps the library entry.
  func removeDownload(_ item: PlaylistInfo) {
    _ = PlaylistManager.shared.deleteCache(item: item)
    downloadStates[item.tagId] = .invalid
  }

  func rename(_ item: PlaylistInfo, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    PlaylistItem.updateName(uuid: item.tagId, name: trimmed) { [weak self] in
      self?.reload()
    }
  }

  /// Whether a drag can reorder the list.
  ///
  /// Manual reordering only makes sense against the custom order; any other
  /// would re-sort the list the moment the drag landed and discard it. Searching
  /// is the same problem from the other end — the visible rows are a subset, so
  /// the positions a drag produces do not describe the library's order.
  var canReorder: Bool {
    sortOrder == .manual && searchText.isEmpty
  }

  func move(from source: IndexSet, to destination: Int) {
    guard canReorder else { return }

    var reordered = items
    reordered.move(fromOffsets: source, toOffset: destination)
    items = reordered

    PlaylistItem.reorderItems(
      from: Array(source), identifiers: reordered.map(\.tagId))
  }

  func createFolder(named name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    PlaylistFolder.addFolder(title: trimmed) { [weak self] _ in
      self?.reload()
    }
  }

  func deleteFolder(_ folder: PlaylistFolder) {
    PlaylistManager.shared.delete(folder: folder) { [weak self] _ in
      self?.reload()
    }
  }

  /// Shows the playlist a Shortcut asked for.
  ///
  /// Silently does nothing for an unknown identifier: a Shortcut can outlive
  /// the playlist it names, and the useful behaviour there is to leave the
  /// library on whatever it was showing rather than to empty it.
  func selectFolder(uuid: String) {
    guard let folder = PlaylistFolder.getFolder(uuid: uuid) else { return }
    searchText = ""
    selectedFolder = folder
  }

  /// Hides a playlist's titles and artwork from the lock screen, or restores
  /// them.
  func setAnonymous(_ isAnonymous: Bool, for folder: PlaylistFolder) {
    guard let uuid = folder.uuid else { return }

    PlaylistFolder.setAnonymous(uuid: uuid, isAnonymous: isAnonymous) { [weak self] in
      self?.reload()
      // Whatever is playing may belong to this folder, in which case the lock
      // screen is showing the old answer and has to be told.
      PlaybackController.shared.reapplyPlaylistSettings()
    }
  }

  /// Sets how long each of a playlist's items plays before it moves on, or
  /// clears it with zero.
  func setSegmentDuration(_ duration: TimeInterval, for folder: PlaylistFolder) {
    guard let uuid = folder.uuid else { return }

    PlaylistFolder.setSegmentDuration(uuid: uuid, duration: duration) { [weak self] in
      self?.reload()
      // The item playing right now may be in this playlist, and it is the one
      // the change is most likely to have been made for.
      PlaybackController.shared.reapplyPlaylistSettings()
    }
  }

  /// Sends every item in a playlist back to its first segment.
  func resetSegmentProgress(for folder: PlaylistFolder) {
    guard let uuid = folder.uuid else { return }

    PlaylistItem.resetSegmentIndices(folderUUID: uuid) { [weak self] in
      self?.reload()
      PlaybackController.shared.forgetSegmentProgress(inPlaylist: uuid)
    }
  }

  func move(_ item: PlaylistInfo, toFolder folder: PlaylistFolder?) {
    guard let playlistItem = PlaylistItem.getItem(uuid: item.tagId) else { return }
    PlaylistItem.moveItems(items: [playlistItem.objectID], to: folder?.uuid)
    reload()
  }
}
