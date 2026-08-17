// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Data/models/PlaylistItem.swift`.
//
// Changes from upstream:
//   * Dropped the shared-folder sync paths (`updateItems(_:folderUUID:newETag:)`
//     took an ETag from Brave's playlist-sharing service; `addInMemoryItems` and
//     `saveInMemoryItemsToDisk` existed to stage a shared folder before the user
//     saved it). Kept the in-memory staging pair, repurposed for previewing a
//     pasted URL before the user commits to it.
//   * Added `artworkURL` and `updateArtwork(uuid:artworkURL:)`.
//   * Added `search(query:)` and sort-descriptor plumbing for the library.

import CoreData
import Foundation
import os.log

/// A single saved media item.
///
/// The important field is `cachedData`: it holds *bookmark data*, not a path.
/// This is Brave's design and it is load-bearing on iOS — an app's container
/// path changes between installs and across OS upgrades, so a stored absolute
/// path goes stale and every downloaded file appears to vanish. Resolving a
/// bookmark survives that relocation. `cachedData == nil` is the canonical
/// meaning of "not downloaded".
@objc(PlaylistItem)
final public class PlaylistItem: NSManagedObject, CRUD, Identifiable {
  @NSManaged public var cachedData: Data?
  @NSManaged public var dateAdded: Date
  @NSManaged public var duration: TimeInterval
  @NSManaged public var lastPlayedOffset: TimeInterval
  @NSManaged public var mediaSrc: String
  @NSManaged public var mimeType: String
  @NSManaged public var name: String
  @NSManaged public var order: Int32
  @NSManaged public var pageSrc: String
  @NSManaged public var pageTitle: String?
  @NSManaged public var uuid: String?
  @NSManaged public var artworkURL: String?
  @NSManaged public var playlistFolder: PlaylistFolder?

  /// Which segment of this item a segmented playlist plays next.
  ///
  /// Only meaningful while the item's folder has a segment length set — see
  /// `PlaylistFolder.segmentDuration`. It is the item's own progress through
  /// itself, so it lives on the item rather than on the playlist: a queue can
  /// be assembled from several playlists at once, and moving an item between
  /// them should not lose where it had got to.
  @NSManaged public var segmentIndex: Int32

  public static func entityName() -> String { "PlaylistItem" }

  @available(*, unavailable)
  public init() {
    fatalError("No Such Initializer: init()")
  }

  @available(*, unavailable)
  public init(context: NSManagedObjectContext) {
    fatalError("No Such Initializer: init(context:)")
  }

  @objc
  private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?) {
    super.init(entity: entity, insertInto: context)
  }

  public init(
    context: NSManagedObjectContext,
    name: String,
    pageTitle: String?,
    pageSrc: String,
    cachedData: Data,
    duration: TimeInterval,
    mimeType: String,
    mediaSrc: String,
    artworkURL: String? = nil
  ) {
    let entity = PlaylistItem.entity(in: context)
    super.init(entity: entity, insertInto: context)
    self.name = name
    self.pageTitle = pageTitle
    self.pageSrc = pageSrc
    self.dateAdded = Date()
    self.cachedData = cachedData
    self.duration = duration
    self.lastPlayedOffset = 0.0
    self.mimeType = mimeType
    self.mediaSrc = mediaSrc
    self.artworkURL = artworkURL
    self.segmentIndex = 0
    self.order = .min
    self.uuid = UUID().uuidString
  }

  public var id: String {
    objectID.uriRepresentation().absoluteString
  }

  /// True when this item has media on disk.
  public var isCached: Bool {
    guard let cachedData = cachedData else { return false }
    return !cachedData.isEmpty
  }

  // MARK: - Fetched results controllers

  /// Every item, in the library's current sort order.
  public class func frc(
    sortOrder: LibrarySortOrder = .dateAddedNewest
  ) -> NSFetchedResultsController<PlaylistItem> {
    let context = DataController.viewContext
    let fetchRequest = NSFetchRequest<PlaylistItem>()
    fetchRequest.entity = PlaylistItem.entity(in: context)
    fetchRequest.fetchBatchSize = 20
    fetchRequest.sortDescriptors = sortDescriptors(for: sortOrder)

    return NSFetchedResultsController(
      fetchRequest: fetchRequest, managedObjectContext: context,
      sectionNameKeyPath: nil, cacheName: nil)
  }

  /// Items belonging to one folder, or to no folder when `parentFolder` is nil.
  public class func frc(
    parentFolder: PlaylistFolder?,
    sortOrder: LibrarySortOrder = .dateAddedNewest
  ) -> NSFetchedResultsController<PlaylistItem> {
    let context = parentFolder?.managedObjectContext ?? DataController.viewContext
    let fetchRequest = NSFetchRequest<PlaylistItem>()
    fetchRequest.entity = PlaylistItem.entity(in: context)
    fetchRequest.fetchBatchSize = 20

    if let parentFolder = parentFolder, let uuid = parentFolder.uuid {
      fetchRequest.predicate = NSPredicate(format: "playlistFolder.uuid == %@", uuid)
    } else {
      fetchRequest.predicate = NSPredicate(format: "playlistFolder == nil")
    }

    fetchRequest.sortDescriptors = sortDescriptors(for: sortOrder)

    return NSFetchedResultsController(
      fetchRequest: fetchRequest, managedObjectContext: context,
      sectionNameKeyPath: nil, cacheName: nil)
  }

  /// Items across every folder.
  public class func allFoldersFRC(
    sortOrder: LibrarySortOrder = .dateAddedNewest
  ) -> NSFetchedResultsController<PlaylistItem> {
    frc(sortOrder: sortOrder)
  }

  /// Maps a user-facing sort choice onto sort descriptors.
  ///
  /// Every case falls back to `dateAdded` descending so the order is total —
  /// otherwise items with equal titles or durations shuffle between fetches and
  /// the list visibly jitters as CoreData faults rows in.
  public static func sortDescriptors(for order: LibrarySortOrder) -> [NSSortDescriptor] {
    let newestFirst = NSSortDescriptor(key: "dateAdded", ascending: false)

    switch order {
    case .manual:
      return [NSSortDescriptor(key: "order", ascending: true), newestFirst]
    case .dateAddedNewest:
      return [newestFirst]
    case .dateAddedOldest:
      return [NSSortDescriptor(key: "dateAdded", ascending: true)]
    case .titleAscending:
      return [
        NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
        newestFirst,
      ]
    case .titleDescending:
      return [
        NSSortDescriptor(key: "name", ascending: false, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
        newestFirst,
      ]
    case .durationLongest:
      return [NSSortDescriptor(key: "duration", ascending: false), newestFirst]
    case .durationShortest:
      return [NSSortDescriptor(key: "duration", ascending: true), newestFirst]
    }
  }

  // MARK: - Creating

  public static func addItem(
    _ item: PlaylistInfo,
    folderUUID: String? = nil,
    cachedData: Data?,
    completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        let playlistItem = PlaylistItem(
          context: context,
          name: item.name,
          pageTitle: item.pageTitle,
          pageSrc: item.pageSrc,
          cachedData: cachedData ?? Data(),
          duration: item.duration,
          mimeType: item.mimeType,
          mediaSrc: item.src,
          artworkURL: item.artworkURL)
        playlistItem.order = item.order
        playlistItem.uuid = item.tagId
        playlistItem.playlistFolder = PlaylistFolder.getFolder(
          uuid: folderUUID ?? PlaylistFolder.savedFolderUUID, context: context)

        PlaylistItem.reorderItems(context: context)
      },
      completion: completion)
  }

  // MARK: - Reading

  public static func getItems(parentFolder: PlaylistFolder?) -> [PlaylistItem] {
    let predicate: NSPredicate
    if let parentFolder = parentFolder, let uuid = parentFolder.uuid {
      predicate = NSPredicate(format: "playlistFolder.uuid == %@", uuid)
    } else {
      predicate = NSPredicate(format: "playlistFolder == nil")
    }

    return PlaylistItem.all(
      where: predicate,
      sortDescriptors: sortDescriptors(for: .manual),
      fetchBatchSize: 20) ?? []
  }

  public static func getItems(pageSrc: String) -> [PlaylistItem] {
    PlaylistItem.all(where: NSPredicate(format: "pageSrc == %@", pageSrc)) ?? []
  }

  public static func getItem(uuid: String) -> PlaylistItem? {
    PlaylistItem.first(where: NSPredicate(format: "uuid == %@", uuid))
  }

  public class func all() -> [PlaylistItem] {
    all(where: nil) ?? []
  }

  public static func itemExists(pageSrc: String) -> Bool {
    if let count = PlaylistItem.count(predicate: NSPredicate(format: "pageSrc == %@", pageSrc)),
      count > 0
    {
      return true
    }
    return false
  }

  public static func itemExists(uuid: String) -> Bool {
    if let count = PlaylistItem.count(predicate: NSPredicate(format: "uuid == %@", uuid)),
      count > 0
    {
      return true
    }
    return false
  }

  /// Finds the item whose cached file resolves to `cacheURL`.
  ///
  /// Used to reconcile the system's `com.apple.UserManagedAssets` staging
  /// directory against the database on launch — see
  /// `PlaylistManager.deleteUserManagedAssets`.
  public static func cachedItem(cacheURL: URL) -> PlaylistItem? {
    PlaylistItem.all()?.first(where: {
      var isStale = false
      if let cacheData = $0.cachedData, !cacheData.isEmpty,
        let url = try? URL(resolvingBookmarkData: cacheData, bookmarkDataIsStale: &isStale)
      {
        return url.path == cacheURL.path
      }
      return false
    })
  }

  /// Resolves the row an update refers to, preferring the unique identifier.
  ///
  /// Brave's update paths all use a single `uuid == X OR pageSrc == Y`
  /// predicate. `pageSrc` is *not* unique — one page can contribute several
  /// items, each with its own media source, which Brave supports and comments
  /// on explicitly — so that predicate can resolve to a sibling item and write
  /// one item's data (including its downloaded-file bookmark) onto another.
  /// Matching on uuid first, and only falling back to pageSrc for rows written
  /// before a uuid existed, keeps the fallback without the aliasing.
  static func firstMatching(
    uuid: String, pageSrc: String, context: NSManagedObjectContext
  ) -> PlaylistItem? {
    if !uuid.isEmpty,
      let item = PlaylistItem.first(
        where: NSPredicate(format: "uuid == %@", uuid), context: context)
    {
      return item
    }

    guard !pageSrc.isEmpty else { return nil }
    return PlaylistItem.first(
      where: NSPredicate(format: "pageSrc == %@ AND uuid == nil", pageSrc), context: context)
  }

  /// Whether `firstMatching` would resolve to a row.
  ///
  /// Kept in step with `firstMatching` deliberately: the update paths gate on
  /// this before looking the row up, and a guard that says "yes" where the
  /// lookup then says "no" turns an update into a silent no-op.
  public static func itemExists(uuid: String, pageSrc: String) -> Bool {
    firstMatching(uuid: uuid, pageSrc: pageSrc, context: DataController.viewContext) != nil
  }

  /// Case- and diacritic-insensitive search over title, page title and host.
  public static func search(query: String) -> [PlaylistItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return all() }

    let predicate = NSPredicate(
      format: "name CONTAINS[cd] %@ OR pageTitle CONTAINS[cd] %@ OR pageSrc CONTAINS[cd] %@",
      trimmed, trimmed, trimmed)

    return PlaylistItem.all(where: predicate, fetchBatchSize: 20) ?? []
  }

  // MARK: - Updating

  public static func updateLastPlayed(
    itemId: String, pageSrc: String, lastPlayedOffset: TimeInterval
  ) {
    guard itemExists(uuid: itemId, pageSrc: pageSrc) else { return }

    DataController.perform(context: .new(inMemory: false), save: true) { context in
      if let existingItem = PlaylistItem.firstMatching(
        uuid: itemId, pageSrc: pageSrc, context: context)
      {
        existingItem.lastPlayedOffset = lastPlayedOffset
      }
    }
  }

  public static func updateItem(_ item: PlaylistInfo, completion: (() -> Void)? = nil) {
    guard itemExists(uuid: item.tagId, pageSrc: item.pageSrc) else {
      addItem(item, cachedData: nil, completion: completion)
      return
    }

    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let existingItem = PlaylistItem.firstMatching(
          uuid: item.tagId, pageSrc: item.pageSrc, context: context)
        {
          existingItem.name = item.name
          existingItem.pageTitle = item.pageTitle
          existingItem.pageSrc = item.pageSrc
          existingItem.duration = item.duration
          existingItem.lastPlayedOffset = item.lastPlayedOffset
          existingItem.mimeType = item.mimeType
          existingItem.mediaSrc = item.src
          existingItem.uuid = item.tagId
          if let artworkURL = item.artworkURL {
            existingItem.artworkURL = artworkURL
          }
        }
      },
      completion: completion)
  }

  /// Renames an item without disturbing any of its other fields.
  public static func updateName(uuid: String, name: String, completion: (() -> Void)? = nil) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let item = PlaylistItem.first(
          where: NSPredicate(format: "uuid == %@", uuid), context: context)
        {
          item.name = name
        }
      },
      completion: completion)
  }

  /// Records which segment of this item a segmented playlist should play next.
  public static func updateSegmentIndex(
    uuid: String, segmentIndex: Int, completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let item = PlaylistItem.first(
          where: NSPredicate(format: "uuid == %@", uuid), context: context)
        {
          item.segmentIndex = Int32(max(0, segmentIndex))
        }
      },
      completion: completion)
  }

  /// Sends a given set of items back to their first segment.
  ///
  /// Works from item ids rather than from a folder because the thing a
  /// segmented playlist measures a full pass over is the *queue*, which need
  /// not be a whole folder — a search result or a hand-built queue is just as
  /// playable. One write for the lot: this runs at the moment playback moves
  /// on, and a save per item would be felt.
  public static func resetSegmentIndices(
    uuids: [String], completion: (() -> Void)? = nil
  ) {
    guard !uuids.isEmpty else {
      completion?()
      return
    }

    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        let items = PlaylistItem.all(
          where: NSPredicate(format: "uuid IN %@", uuids), context: context) ?? []

        for item in items {
          item.segmentIndex = 0
        }
      },
      completion: completion)
  }

  /// Sends every item in a playlist back to its first segment.
  ///
  /// Segment progress is the one piece of per-item state a listener cannot
  /// otherwise undo — short of playing each item all the way through — so the
  /// playlist's own settings screen offers to reset it.
  public static func resetSegmentIndices(
    folderUUID: String, completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        let items = PlaylistItem.all(
          where: NSPredicate(format: "playlistFolder.uuid == %@", folderUUID),
          context: context) ?? []

        for item in items {
          item.segmentIndex = 0
        }
      },
      completion: completion)
  }

  public static func updateArtwork(uuid: String, artworkURL: String?) {
    DataController.perform(context: .new(inMemory: false), save: true) { context in
      if let item = PlaylistItem.first(
        where: NSPredicate(format: "uuid == %@", uuid), context: context)
      {
        item.artworkURL = artworkURL
      }
    }
  }

  /// Points an item at its downloaded file, or clears it.
  ///
  /// `cachedData` is bookmark data produced by `URL.bookmarkData()`. Passing
  /// nil (or empty) marks the item as no longer downloaded, which is how every
  /// failure and cancellation path reports itself.
  /// - Note: `completion` runs after the write is visible on `viewContext`.
  ///   The download manager relies on that: it announces `.downloaded` from the
  ///   completion, and every listener immediately asks
  ///   `PlaylistManager.state(for:)` — which reads this very field. Announcing
  ///   first would have listeners see a completed download as not-downloaded.
  public static func updateCache(
    uuid: String, pageSrc: String, cachedData: Data?, completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let item = PlaylistItem.firstMatching(
          uuid: uuid, pageSrc: pageSrc, context: context)
        {
          if let cachedData = cachedData, !cachedData.isEmpty {
            item.cachedData = cachedData
          } else {
            item.cachedData = nil
          }
        }
      },
      completion: completion)
  }

  // MARK: - Deleting

  public static func removeItem(uuid: String) {
    PlaylistItem.deleteAll(
      predicate: NSPredicate(format: "uuid == %@", uuid),
      context: .new(inMemory: false),
      includesPropertyValues: false)
  }

  public static func removeItems(_ items: [PlaylistInfo], completion: (() -> Void)? = nil) {
    var uuids = [String]()
    var mediaSrcs = [String]()

    items.forEach {
      if $0.tagId.isEmpty {
        mediaSrcs.append($0.src)
      } else {
        uuids.append($0.tagId)
      }
    }

    PlaylistItem.deleteAll(
      predicate: NSPredicate(format: "uuid IN %@", uuids),
      context: .new(inMemory: false),
      includesPropertyValues: false,
      completion: mediaSrcs.isEmpty ? completion : nil)

    if !mediaSrcs.isEmpty {
      // Fallback for rows written before a tagId existed. Deliberately keyed on
      // mediaSrc rather than pageSrc: one page can yield several items, each
      // with a distinct media URL, so pageSrc would over-delete.
      PlaylistItem.deleteAll(
        predicate: NSPredicate(format: "mediaSrc IN %@", mediaSrcs),
        context: .new(inMemory: false),
        includesPropertyValues: false,
        completion: completion)
    }
  }

  // MARK: - Organising

  public static func moveItems(items: [NSManagedObjectID], to folderUUID: String?) {
    DataController.perform { context in
      var folder: PlaylistFolder?
      if let folderUUID = folderUUID {
        folder = PlaylistFolder.getFolder(uuid: folderUUID, context: context)
      }

      let playlistItems = items.compactMap {
        try? context.existingObject(with: $0) as? PlaylistItem
      }
      playlistItems.forEach { $0.playlistFolder = folder }
    }
  }

  /// Persists a manual reorder produced by a drag in the library.
  public static func reorderItems(
    from sourceIndices: [Int],
    identifiers: [String],
    completion: (() -> Void)? = nil
  ) {
    _ = sourceIndices
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        for (order, uuid) in identifiers.enumerated() {
          if let item = PlaylistItem.first(
            where: NSPredicate(format: "uuid == %@", uuid), context: context)
          {
            item.order = Int32(order)
          }
        }
      },
      completion: completion)
  }

  // MARK: - Internal

  /// Renumbers `order` densely from zero.
  ///
  /// New items are inserted with `order == Int32.min` so they sort to the top;
  /// this collapses that sentinel back into the sequence after every insert.
  static func reorderItems(context: NSManagedObjectContext) {
    let orderSort = NSSortDescriptor(key: "order", ascending: true)
    let items = PlaylistItem.all(sortDescriptors: [orderSort], context: context) ?? []

    for (order, item) in items.enumerated() {
      item.order = Int32(order)
    }
  }
}
