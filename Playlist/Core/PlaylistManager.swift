// Copyright 2020 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Playlist/PlaylistManager.swift`.
//
// This is the façade the rest of the app talks to: it owns the fetched results
// controller, the download manager, and the Combine subjects that report
// change. Its shape is Brave's. Changes:
//
//   * Shared-folder sync (`syncSharedFolder(s)`, `PlaylistSharedFolderNetwork`)
//     removed — that is a Brave-service feature with no counterpart here.
//   * `getAssetDuration` rewritten against modern async `AVAsset.load(_:)`.
//     Brave's version calls `statusOfValue(forKey:)` and
//     `loadValuesAsynchronously`, both deprecated, and its main-thread guard
//     comments describe hazards that the async API removes outright.
//   * Sort order is a first-class concern: `sortOrder` rebuilds the FRC.
//   * Storage accounting added (`totalStorageUsed`, `storageUsage`).
//   * Background URLSession completion handlers are forwarded to the download
//     manager.

import AVFoundation
import Combine
import CoreData
import Foundation
import UIKit
import os.log

/// Single point of truth for the media library.
public class PlaylistManager: NSObject {
  public static let shared = PlaylistManager()

  private var assetInformation = [PlaylistAssetFetcher]()
  private let downloadManager = PlaylistDownloadManager()
  private var frc: NSFetchedResultsController<PlaylistItem>
  private var didRestoreSession = false

  /// Percent-complete for every download currently running, so a view that
  /// appears mid-download can render the right state immediately instead of
  /// waiting for the next progress event.
  private(set) public var downloadProgress = [String: Double]()

  /// The most recent failure per item, surfaced by the Downloads screen.
  private(set) public var downloadErrors = [String: String]()

  // MARK: - Publishers

  private let onContentWillChange = PassthroughSubject<Void, Never>()
  private let onContentDidChange = PassthroughSubject<Void, Never>()
  private let onObjectChange = PassthroughSubject<
    (
      object: Any,
      indexPath: IndexPath?,
      type: NSFetchedResultsChangeType,
      newIndexPath: IndexPath?
    ), Never
  >()

  private let onDownloadProgressUpdate = PassthroughSubject<
    (id: String, percentComplete: Double), Never
  >()
  private let onDownloadStateChanged = PassthroughSubject<
    (
      id: String,
      state: PlaylistDownloadManager.DownloadState,
      displayName: String?,
      error: Error?
    ), Never
  >()
  private let onCurrentFolderChanged = PassthroughSubject<Void, Never>()
  private let onFolderDeleted = PassthroughSubject<Void, Never>()

  private override init() {
    frc = PlaylistItem.frc(sortOrder: PlaylistManager.storedSortOrder)
    super.init()

    downloadManager.delegate = self
    frc.delegate = self

    // Clears the system's staging directory for interrupted HLS downloads.
    // Anything left there is a partial download from a previous run that can
    // never complete, and it can be many gigabytes.
    deleteUserManagedAssets()

    reloadData()
  }

  // MARK: - Configuration

  private static var storedSortOrder: LibrarySortOrder {
    LibrarySortOrder(rawValue: Preferences.Playlist.sortOrder.value) ?? .dateAddedNewest
  }

  /// The library's sort order. Setting it rebuilds the fetched results
  /// controller, because sort descriptors cannot be changed on a live one.
  public var sortOrder: LibrarySortOrder {
    get { PlaylistManager.storedSortOrder }
    set {
      Preferences.Playlist.sortOrder.value = newValue.rawValue
      rebuildFetchedResultsController()
    }
  }

  /// The folder being shown, or nil for "everything".
  public var currentFolder: PlaylistFolder? {
    didSet {
      rebuildFetchedResultsController()
      onCurrentFolderChanged.send()
    }
  }

  private func rebuildFetchedResultsController() {
    frc.delegate = nil

    if let currentFolder = currentFolder {
      frc = PlaylistItem.frc(parentFolder: currentFolder, sortOrder: sortOrder)
    } else {
      frc = PlaylistItem.allFoldersFRC(sortOrder: sortOrder)
    }

    frc.delegate = self
    reloadData()
    onContentDidChange.send()
  }

  // MARK: - Publisher accessors

  public var onFolderRemovedOrUpdated: AnyPublisher<Void, Never> {
    onFolderDeleted.eraseToAnyPublisher()
  }

  public var contentWillChange: AnyPublisher<Void, Never> {
    onContentWillChange.eraseToAnyPublisher()
  }

  public var contentDidChange: AnyPublisher<Void, Never> {
    onContentDidChange.eraseToAnyPublisher()
  }

  public var objectDidChange:
    AnyPublisher<
      (
        object: Any, indexPath: IndexPath?, type: NSFetchedResultsChangeType,
        newIndexPath: IndexPath?
      ), Never
    >
  {
    onObjectChange.eraseToAnyPublisher()
  }

  public var downloadProgressUpdated: AnyPublisher<(id: String, percentComplete: Double), Never> {
    onDownloadProgressUpdate.eraseToAnyPublisher()
  }

  public var downloadStateChanged:
    AnyPublisher<
      (
        id: String, state: PlaylistDownloadManager.DownloadState, displayName: String?,
        error: Error?
      ), Never
    >
  {
    onDownloadStateChanged.eraseToAnyPublisher()
  }

  public var onCurrentFolderDidChange: AnyPublisher<Void, Never> {
    onCurrentFolderChanged.eraseToAnyPublisher()
  }

  // MARK: - Reading

  /// The items in the folder currently being browsed.
  ///
  /// Scoped to `currentFolder`, because this is what the library list shows.
  /// Anything that is about the library *as a whole* — the Downloads screen,
  /// storage accounting, "delete everything" — must use `everyItem` /
  /// `everyItemObject` instead, or selecting an empty playlist would empty it
  /// too.
  public var allItems: [PlaylistInfo] {
    frc.fetchedObjects?.map { PlaylistInfo(item: $0) } ?? []
  }

  /// Every item in the library, whichever playlist is being browsed.
  public var everyItem: [PlaylistInfo] {
    everyItemObject.map { PlaylistInfo(item: $0) }
  }

  /// Every item in the library as managed objects, in the current sort order.
  ///
  /// A fetch rather than a read of the fetched results controller: that
  /// controller carries the browsing folder's predicate, and a screen that
  /// answers "what have I downloaded?" or "how much space is this using?" is
  /// not asking about the folder the library happens to be showing.
  public var everyItemObject: [PlaylistItem] {
    PlaylistItem.all(
      where: nil,
      sortDescriptors: PlaylistItem.sortDescriptors(for: sortOrder),
      fetchBatchSize: 20) ?? []
  }

  public var numberOfAssets: Int {
    frc.fetchedObjects?.count ?? 0
  }

  public var fetchedObjects: [PlaylistItem] {
    frc.fetchedObjects ?? []
  }

  public func itemAtIndex(_ index: Int) -> PlaylistInfo? {
    guard index >= 0, index < numberOfAssets else { return nil }
    return PlaylistInfo(item: frc.object(at: IndexPath(row: index, section: 0)))
  }

  public func assetAtIndex(_ index: Int) -> AVURLAsset? {
    guard let item = itemAtIndex(index) else { return nil }
    return asset(for: item.tagId, mediaSrc: item.src)
  }

  public func index(of itemId: String) -> Int? {
    frc.fetchedObjects?.firstIndex(where: { $0.uuid == itemId })
  }

  public func reloadData() {
    do {
      try frc.performFetch()
    } catch {
      Logger.module.error("Fetch failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Lifecycle

  public func restoreSession() {
    guard !didRestoreSession else { return }
    didRestoreSession = true

    downloadManager.restoreSession { [weak self] in
      self?.reloadData()
      self?.onContentDidChange.send()
    }
  }

  /// Forwards the system's background-session completion handler.
  public func setBackgroundSessionCompletionHandler(
    _ handler: @escaping () -> Void,
    forSessionIdentifier identifier: String
  ) {
    downloadManager.setBackgroundCompletionHandler(handler, for: identifier)
  }

  /// Guarantees the default folder exists.
  public func setupPlaylistFolder() {
    if let savedFolder = PlaylistFolder.getFolder(uuid: PlaylistFolder.savedFolderUUID) {
      if savedFolder.title != PlaylistFolder.defaultFolderTitle {
        PlaylistFolder.renameFolder(
          uuid: PlaylistFolder.savedFolderUUID, title: PlaylistFolder.defaultFolderTitle)
      }
    } else {
      PlaylistFolder.addFolder(
        title: PlaylistFolder.defaultFolderTitle, uuid: PlaylistFolder.savedFolderUUID
      ) { uuid in
        Logger.module.debug("Created Playlist Folder: \(uuid)")
      }
    }
  }

  // MARK: - Download state

  public func state(for itemId: String) -> PlaylistDownloadManager.DownloadState {
    if downloadManager.downloadTask(for: itemId) != nil {
      return .inProgress
    }

    if let assetUrl = downloadManager.localAsset(for: itemId)?.url,
      FileManager.default.fileExists(atPath: assetUrl.path)
    {
      return .downloaded
    }

    return .invalid
  }

  /// Bytes on disk for one item, or 0 if it is not downloaded.
  public func sizeOfDownloadedItem(for itemId: String) -> Int64 {
    guard let asset = downloadManager.localAsset(for: itemId) else { return 0 }
    return FileManager.default.allocatedSizeOfItem(at: asset.url)
  }

  /// Total bytes held by downloaded media.
  ///
  /// - Important: walks the media directory, which for a library of HLS
  ///   `.movpkg` bundles means thousands of `stat` calls. Never call it from a
  ///   SwiftUI `body` — see `storageUsage()`, which is the same answer off the
  ///   main thread.
  public func totalStorageUsed() -> Int64 {
    guard let directory = PlaylistDownloadManager.playlistDirectory else { return 0 }
    return FileManager.default.allocatedSizeOfItem(at: directory)
  }

  /// What the storage screens show, measured off the main thread.
  ///
  /// Every figure here costs a directory walk, and they were being taken during
  /// `body` — so scrolling a list of downloads re-`stat`ed every bundle in it,
  /// once per row per frame. The work itself is unavoidable; doing it on the
  /// thread that draws is not.
  public struct StorageUsage: Equatable {
    /// One downloaded item and what it costs.
    public struct Entry: Equatable, Identifiable {
      public let item: PlaylistInfo
      public let bytes: Int64

      public var id: String { item.tagId }
    }

    public var total: Int64 = 0
    public var available: Int64 = 0
    public var thumbnails: Int64 = 0
    /// Bytes per item id, for rows that want to show their own size.
    public var perItem: [String: Int64] = [:]
    /// The downloaded items, largest first.
    public var largest: [Entry] = []
  }

  @MainActor
  public func storageUsage() async -> StorageUsage {
    // The rows are read here and turned into plain values, because they are
    // CoreData objects living on a main-queue context: `localAsset(for:)` —
    // which is how a size is normally asked for — fetches one, and fetching it
    // from another thread is a concurrency violation, not merely slow. What
    // crosses to the background is the bookmark data and nothing else.
    let entries = everyItemObject.map { (info: PlaylistInfo(item: $0), bookmark: $0.cachedData) }

    return await Task.detached(priority: .utility) { () -> StorageUsage in
      var usage = StorageUsage()
      usage.total = PlaylistManager.measureDirectory(PlaylistDownloadManager.playlistDirectory)
      usage.available = PlaylistManager.freeSpace() ?? 0
      usage.thumbnails = ImageCache.shared.diskUsage()

      var sized = [StorageUsage.Entry]()
      for entry in entries {
        let bytes = PlaylistManager.measureBookmark(entry.bookmark)
        guard bytes > 0 else { continue }
        usage.perItem[entry.info.tagId] = bytes
        sized.append(StorageUsage.Entry(item: entry.info, bytes: bytes))
      }

      usage.largest = sized.sorted { $0.bytes > $1.bytes }
      return usage
    }.value
  }

  /// Bytes on disk behind a stored bookmark. Touches no CoreData, so it is safe
  /// off the main thread.
  private static func measureBookmark(_ bookmark: Data?) -> Int64 {
    guard let bookmark = bookmark, !bookmark.isEmpty else { return 0 }

    var isStale = false
    guard
      let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale),
      !isStale
    else { return 0 }

    return FileManager.default.allocatedSizeOfItem(at: url)
  }

  private static func measureDirectory(_ url: URL?) -> Int64 {
    guard let url = url else { return 0 }
    return FileManager.default.allocatedSizeOfItem(at: url)
  }

  private static func freeSpace() -> Int64? {
    try? URL(fileURLWithPath: NSHomeDirectory())
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }

  // MARK: - Downloading

  /// Starts an offline download, choosing a strategy from the media's type.
  ///
  /// The type has to be probed over the network rather than guessed from the
  /// URL: media URLs routinely carry no extension (a signed CDN URL is all
  /// query string), and picking the wrong strategy fails in a confusing way —
  /// an HLS manifest fetched as a file downloads a few kilobytes of text that
  /// then refuses to play.
  public func download(item: PlaylistInfo) {
    guard downloadManager.downloadTask(for: item.tagId) == nil,
      let assetUrl = URL(string: item.src)
    else { return }

    downloadErrors[item.tagId] = nil

    Task { @MainActor in
      if assetUrl.scheme == "data" {
        downloadManager.downloadDataAsset(assetUrl, for: item)
        return
      }

      // Cheap syntactic check first, so an offline add of an obvious `.m3u8`
      // still routes correctly.
      if PlaylistMimeTypeDetector.isHLS(url: assetUrl) {
        downloadManager.downloadHLSAsset(assetUrl, for: item)
        return
      }

      let mimeType = await NowPlayingInfo.getMimeType(assetUrl)

      guard let mimeType = mimeType?.lowercased() else {
        // No answer at all — the URL is dead or the host refused a ranged HEAD.
        // Treat as a progressive file; the download will report a real error.
        downloadManager.downloadFileAsset(assetUrl, for: item)
        return
      }

      if PlaylistMimeTypeDetector.isHLS(mimeType: mimeType) {
        downloadManager.downloadHLSAsset(assetUrl, for: item)
      } else {
        downloadManager.downloadFileAsset(assetUrl, for: item)
      }
    }
  }

  public func cancelDownload(itemId: String) {
    downloadManager.cancelDownload(itemId: itemId)
    downloadProgress[itemId] = nil
  }

  /// Applies the auto-download preference to a freshly added item.
  public func autoDownload(item: PlaylistInfo) {
    guard
      let downloadType = PlayListDownloadType(
        rawValue: Preferences.Playlist.autoDownloadVideo.value)
    else { return }

    switch downloadType {
    case .on:
      download(item: item)
    case .wifi:
      if Reachability.shared.isOnUnmeteredConnection {
        download(item: item)
      }
    case .off:
      break
    }
  }

  /// Identifiers of every download currently running.
  public var activeDownloadIds: [String] {
    downloadManager.activeDownloadIds
  }

  // MARK: - Deleting

  /// Deletes a folder and everything in it.
  ///
  /// Files come off disk before rows come out of the database. Doing it the
  /// other way round — or letting a cascade delete rule do it — orphans the
  /// bytes: nothing would remain that knows those files exist.
  public func delete(folder: PlaylistFolder, _ completion: ((_ success: Bool) -> Void)? = nil) {
    var success = true
    var itemsToDelete = [PlaylistInfo]()

    folder.playlistItems?.forEach {
      let item = PlaylistInfo(item: $0)
      cancelDownload(itemId: item.tagId)

      if let index = assetInformation.firstIndex(where: { $0.itemId == item.tagId }) {
        assetInformation.remove(at: index).cancelLoading()
      }

      if deleteCache(item: item) {
        itemsToDelete.append(item)
      } else {
        // Leave the whole folder alone if any one file resists deletion,
        // rather than half-deleting and stranding the rest.
        success = false
      }
    }

    let folderUUID = folder.uuid
    if success, currentFolder?.objectID == folder.objectID {
      currentFolder = nil
    }

    PlaylistItem.removeItems(itemsToDelete) { [weak self] in
      guard let self = self else {
        completion?(success)
        return
      }

      guard success, let folderUUID = folderUUID,
        folderUUID != PlaylistFolder.savedFolderUUID
      else {
        self.finishFolderDeletion(completion: completion, success: success)
        return
      }

      PlaylistFolder.removeFolder(folderUUID) { [weak self] in
        self?.finishFolderDeletion(completion: completion, success: success)
      }
    }
  }

  private func finishFolderDeletion(
    completion: ((_ success: Bool) -> Void)?, success: Bool
  ) {
    if currentFolder?.isDeleted == true {
      currentFolder = nil
    }
    onFolderDeleted.send()
    reloadData()
    onContentDidChange.send()
    completion?(success)
  }

  /// Removes an item from the library, file and all.
  @discardableResult
  public func delete(item: PlaylistInfo) -> Bool {
    cancelDownload(itemId: item.tagId)

    if let index = assetInformation.firstIndex(where: { $0.itemId == item.tagId }) {
      assetInformation.remove(at: index).cancelLoading()
    }

    if let artworkURL = item.artworkURL {
      ImageCache.shared.remove(forKey: artworkURL)
    }
    ImageCache.shared.remove(forKey: item.src)

    if let cacheItem = PlaylistItem.getItem(uuid: item.tagId), cacheItem.cachedData != nil {
      // Refuse to delete the row if its file cannot be removed — a row with no
      // file is recoverable, a file with no row is invisible dead weight.
      guard deleteCache(item: item) else { return false }
    }

    PlaylistItem.removeItems([item])
    onDownloadStateChanged(id: item.tagId, state: .invalid, displayName: nil, error: nil)
    return true
  }

  /// Removes an item's downloaded file but keeps the library row, so it can be
  /// re-downloaded later.
  @discardableResult
  public func deleteCache(item: PlaylistInfo) -> Bool {
    cancelDownload(itemId: item.tagId)

    guard let cacheItem = PlaylistItem.getItem(uuid: item.tagId),
      let cachedData = cacheItem.cachedData,
      !cachedData.isEmpty
    else { return true }

    var isStale = false

    do {
      let url = try URL(resolvingBookmarkData: cachedData, bookmarkDataIsStale: &isStale)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      PlaylistItem.updateCache(uuid: item.tagId, pageSrc: item.pageSrc, cachedData: nil)
      onDownloadStateChanged(id: item.tagId, state: .invalid, displayName: nil, error: nil)
      return true
    } catch {
      Logger.module.error(
        "Error deleting cached item \(cacheItem.name): \(error.localizedDescription)")
      return false
    }
  }

  /// Deletes every item, or just their files when `cacheOnly` is true.
  ///
  /// Deliberately reads `everyItemObject` rather than the fetched results
  /// controller: "delete everything" means the library, not the playlist the
  /// user last looked at.
  public func deleteAllItems(cacheOnly: Bool, completion: (() -> Void)? = nil) {
    for item in everyItemObject {
      let info = PlaylistInfo(item: item)
      cancelDownload(itemId: info.tagId)
      _ = deleteCache(item: info)
    }

    if !cacheOnly {
      assetInformation.forEach { $0.cancelLoading() }
      assetInformation.removeAll()
    }

    if let playlistDirectory = PlaylistDownloadManager.playlistDirectory {
      do {
        try FileManager.default.removeItem(at: playlistDirectory)
      } catch {
        Logger.module.error(
          "Failed to delete Playlist directory: \(error.localizedDescription)")
      }
    }

    deleteUserManagedAssets()
    ImageCache.shared.clear()

    if cacheOnly {
      reloadData()
      onContentDidChange.send()
      completion?()
    } else {
      DataController.destroyAllData { [weak self] in
        guard let self = self else {
          completion?()
          return
        }
        self.currentFolder = nil
        self.setupPlaylistFolder()
        self.reloadData()
        self.onContentDidChange.send()
        completion?()
      }
    }
  }

  /// Clears AVFoundation's staging directory for HLS downloads.
  ///
  /// `AVAssetDownloadURLSession` writes into `com.apple.UserManagedAssets*` in
  /// the app's Library folder before handing us the final location. If the app
  /// dies mid-download the partial bundle is stranded there — invisible to the
  /// user, counted against the app's storage, and never resumable. Brave clears
  /// it on every launch, and so does this.
  private func deleteUserManagedAssets() {
    guard
      let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
        .first
    else { return }

    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: libraryPath, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

      for url in urls where url.absoluteString.contains("com.apple.UserManagedAssets") {
        // Any library row pointing into this directory is about to be lying.
        if let assets = try? FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
          assets.forEach {
            if let item = PlaylistItem.cachedItem(cacheURL: $0), let itemId = item.uuid {
              cancelDownload(itemId: itemId)
              PlaylistItem.updateCache(
                uuid: itemId, pageSrc: item.pageSrc, cachedData: nil)
            }
          }
        }

        do {
          try FileManager.default.removeItem(at: url)
        } catch {
          Logger.module.error(
            "Deleting staged asset \(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
      }
    } catch {
      Logger.module.error(
        "Enumerating staged Playlist assets failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Disk pressure

  /// True when the volume is more than 90% full.
  ///
  /// Used to warn before starting a download that would likely fail partway.
  public func isDiskSpaceEncumbered() -> Bool {
    let freeSpace = availableDiskSpace() ?? 0
    let totalSpace = totalDiskSpace() ?? 0
    let usedSpace = totalSpace - freeSpace

    return totalSpace == 0 || (Double(usedSpace) / Double(totalSpace)) * 100.0 >= 90.0
  }

  public func availableDiskSpace() -> Int64? {
    do {
      return try URL(fileURLWithPath: NSHomeDirectory())
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
    } catch {
      Logger.module.error("Error retrieving disk space: \(error.localizedDescription)")
    }
    return nil
  }

  public func totalDiskSpace() -> Int64? {
    do {
      if let result = try URL(fileURLWithPath: NSHomeDirectory())
        .resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity
      {
        return Int64(result)
      }
    } catch {
      Logger.module.error("Error retrieving disk space: \(error.localizedDescription)")
    }
    return nil
  }

  // MARK: - Resume points

  public func updateLastPlayed(item: PlaylistInfo, playTime: Double) {
    let lastPlayedTime = Preferences.Playlist.playbackLeftOff.value ? playTime : 0.0
    Preferences.Playlist.lastPlayedItemUrl.value = item.pageSrc
    PlaylistItem.updateLastPlayed(
      itemId: item.tagId, pageSrc: item.pageSrc, lastPlayedOffset: lastPlayedTime)
  }
}

// MARK: - Assets

extension PlaylistManager {
  /// The asset to play for an item.
  ///
  /// Order matters: an in-flight download's asset first (AVFoundation can play
  /// an HLS download while it is still being written), then the completed local
  /// file, and only then the remote URL.
  func asset(for itemId: String, mediaSrc: String) -> AVURLAsset {
    if let task = downloadManager.downloadTask(for: itemId) {
      return task.asset
    }

    if let asset = downloadManager.localAsset(for: itemId) {
      return asset
    }

    return AVURLAsset(
      url: URL(string: mediaSrc) ?? URL(fileURLWithPath: "/dev/null"),
      options: AVAsset.defaultOptions)
  }

  /// The local file for a downloaded item, if any.
  public func localAssetURL(for itemId: String) -> URL? {
    downloadManager.localAsset(for: itemId)?.url
  }

  /// Resolves an item's duration, preferring the stored value.
  ///
  /// Rewritten against `AVAsset.load(_:)`; Brave's version predates it and
  /// juggles `statusOfValue` / `loadValuesAsynchronously` to avoid blocking the
  /// main thread.
  public func getAssetDuration(item: PlaylistInfo) async -> TimeInterval? {
    let tolerance = 0.00001

    // Live streams: stored as `greatestFiniteMagnitude`, reported as infinite.
    if item.duration.isInfinite
      || abs(item.duration.distance(to: TimeInterval.greatestFiniteMagnitude)) < tolerance
    {
      return TimeInterval.infinity
    }

    // Already known.
    if abs(item.duration) >= tolerance {
      return item.duration
    }

    // Not known, and we cannot ask the network for it.
    if Reachability.shared.connectionStatus != .online,
      localAssetURL(for: item.tagId) == nil
    {
      return item.duration
    }

    let asset = self.asset(for: item.tagId, mediaSrc: item.src)
    let fetcher = PlaylistAssetFetcher(itemId: item.tagId, asset: asset)
    assetInformation.append(fetcher)

    defer {
      if let index = assetInformation.firstIndex(where: { $0 === fetcher }) {
        assetInformation.remove(at: index)
      }
    }

    do {
      let duration = try await asset.load(.duration)

      if duration.isIndefinite {
        return TimeInterval.infinity
      }

      let seconds = duration.seconds
      guard seconds.isFinite, abs(seconds) > tolerance else {
        return item.duration
      }

      // Write it back so the next render is instant.
      if PlaylistItem.itemExists(uuid: item.tagId, pageSrc: item.pageSrc) {
        let updated = PlaylistInfo(
          name: item.name,
          src: item.src,
          pageSrc: item.pageSrc,
          pageTitle: item.pageTitle,
          mimeType: item.mimeType,
          duration: seconds,
          lastPlayedOffset: item.lastPlayedOffset,
          detected: item.detected,
          dateAdded: item.dateAdded,
          tagId: item.tagId,
          order: item.order,
          isInvisible: item.isInvisible,
          artworkURL: item.artworkURL)

        PlaylistItem.updateItem(updated)
      }

      return seconds
    } catch {
      Logger.module.error("Failed to load asset duration: \(error.localizedDescription)")
      return nil
    }
  }
}

// MARK: - PlaylistDownloadManagerDelegate

extension PlaylistManager: PlaylistDownloadManagerDelegate {
  func onDownloadProgressUpdate(id: String, percentComplete: Double) {
    downloadProgress[id] = percentComplete
    onDownloadProgressUpdate.send((id: id, percentComplete: percentComplete))
  }

  func onDownloadStateChanged(
    id: String, state: PlaylistDownloadManager.DownloadState, displayName: String?, error: Error?
  ) {
    switch state {
    case .inProgress:
      downloadProgress[id] = downloadProgress[id] ?? 0.0
      downloadErrors[id] = nil
    case .downloaded, .invalid:
      downloadProgress[id] = nil
      downloadErrors[id] = error?.localizedDescription
    }

    onDownloadStateChanged.send(
      (id: id, state: state, displayName: displayName, error: error))
  }
}

// MARK: - NSFetchedResultsControllerDelegate

extension PlaylistManager: NSFetchedResultsControllerDelegate {
  public func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any,
    at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?
  ) {
    onObjectChange.send(
      (object: anObject, indexPath: indexPath, type: type, newIndexPath: newIndexPath))
  }

  public func controllerDidChangeContent(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>
  ) {
    onContentDidChange.send(())
  }

  public func controllerWillChangeContent(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>
  ) {
    onContentWillChange.send(())
  }
}
