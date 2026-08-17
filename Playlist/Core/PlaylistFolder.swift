// Copyright 2022 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Data/models/PlaylistFolder.swift`.
//
// Changes from upstream: the shared-folder fields (`sharedFolderId`,
// `sharedFolderUrl`, `sharedFolderETag`, `creatorName`, `creatorLink`) and the
// `addInMemoryFolder` / `saveInMemoryFolderToDisk` pair that backed Brave's
// playlist-sharing service are removed. A folder here is purely a local
// collection. `isAnonymous` is new — see below.

import CoreData
import Foundation
import os.log

/// A user-visible collection of items — what the UI calls a playlist.
///
/// Brave always has exactly one folder with a fixed UUID ("Play Later") that
/// cannot be deleted and receives every item that is not filed elsewhere. That
/// invariant is kept: it is what lets `addItem` take an optional folder and
/// still guarantee the item is reachable.
@objc(PlaylistFolder)
final public class PlaylistFolder: NSManagedObject, CRUD, Identifiable {
  @NSManaged public var uuid: String?
  @NSManaged public var title: String
  @NSManaged public var order: Int32
  @NSManaged public var dateAdded: Date
  @NSManaged public var playlistItems: Set<PlaylistItem>?

  /// Whether items in this folder publish their title and artwork outside the
  /// app.
  ///
  /// When set, the lock screen and Control Centre get transport controls and a
  /// timeline and nothing else: no title, no source, no artwork. It is a
  /// property of the folder rather than of an item or of the app as a whole
  /// because that is the granularity that matches the reason for wanting it —
  /// one playlist you would rather not have announced on a screen other people
  /// can see, while the rest of the library behaves normally.
  @NSManaged public var isAnonymous: Bool

  /// How long each item plays before the playlist moves on, in seconds.
  ///
  /// Zero — the default, and what every existing folder migrates to — means
  /// the playlist plays its items whole. Anything else turns the playlist into
  /// a rotation: each item plays for this long, and the next time round it
  /// picks up where it left off rather than starting again. See
  /// `PlaylistSegment` for the arithmetic and for which items are exempt.
  @NSManaged public var segmentDuration: TimeInterval

  /// Whether this playlist plays its items in segments rather than whole.
  public var isSegmented: Bool { segmentDuration > 0 }

  /// The undeletable default folder. Constant carried over from Brave so an
  /// existing database would line up.
  public static let savedFolderUUID = "7B6CC019-8946-4182-ACE8-42FE7B704C43"

  /// Title used for the default folder.
  public static let defaultFolderTitle = "Play Later"

  public static func entityName() -> String { "PlaylistFolder" }

  public var id: String {
    uuid ?? objectID.uriRepresentation().absoluteString
  }

  public var isDefaultFolder: Bool {
    uuid == PlaylistFolder.savedFolderUUID
  }

  public var itemCount: Int {
    playlistItems?.count ?? 0
  }

  // MARK: - Fetching

  public class func frc() -> NSFetchedResultsController<PlaylistFolder> {
    let context = DataController.viewContext
    let fetchRequest = NSFetchRequest<PlaylistFolder>()
    fetchRequest.entity = PlaylistFolder.entity(in: context)
    fetchRequest.fetchBatchSize = 20
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: "order", ascending: true),
      NSSortDescriptor(key: "dateAdded", ascending: false),
    ]

    return NSFetchedResultsController(
      fetchRequest: fetchRequest, managedObjectContext: context,
      sectionNameKeyPath: nil, cacheName: nil)
  }

  public static func getFolder(
    uuid: String,
    context: NSManagedObjectContext = DataController.viewContext
  ) -> PlaylistFolder? {
    PlaylistFolder.first(where: NSPredicate(format: "uuid == %@", uuid), context: context)
  }

  public static func getFolders() -> [PlaylistFolder] {
    PlaylistFolder.all(
      where: nil,
      sortDescriptors: [
        NSSortDescriptor(key: "order", ascending: true),
        NSSortDescriptor(key: "dateAdded", ascending: false),
      ]) ?? []
  }

  // MARK: - Mutating

  public static func addFolder(
    title: String,
    uuid: String? = nil,
    completion: ((_ uuid: String) -> Void)? = nil
  ) {
    let folderId = (uuid?.isEmpty == false ? uuid : nil) ?? UUID().uuidString

    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        let entity = PlaylistFolder.entity(in: context)
        let playlistFolder = PlaylistFolder(entity: entity, insertInto: context)
        playlistFolder.title = title
        playlistFolder.dateAdded = Date()
        playlistFolder.order = Int32.min
        playlistFolder.uuid = folderId

        PlaylistFolder.reorderFolders(context: context)
      },
      completion: { completion?(folderId) })
  }

  /// Marks a folder as hidden from (or restored to) the lock screen.
  public static func setAnonymous(
    uuid: String, isAnonymous: Bool, completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let folder = PlaylistFolder.getFolder(uuid: uuid, context: context) {
          folder.isAnonymous = isAnonymous
        }
      },
      completion: completion)
  }

  /// Sets how long each of a playlist's items plays before it moves on, or
  /// clears it with zero.
  public static func setSegmentDuration(
    uuid: String, duration: TimeInterval, completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let folder = PlaylistFolder.getFolder(uuid: uuid, context: context) {
          folder.segmentDuration = max(0, duration)
        }
      },
      completion: completion)
  }

  /// Whether the folder an item belongs to is anonymised.
  ///
  /// Keyed on the item rather than the folder because that is what playback
  /// has to hand: a queue is a list of items, which may well have come from
  /// several folders — "All Media" is the common case — and each one's own
  /// folder decides how it is announced.
  public static func isAnonymous(itemId: String) -> Bool {
    PlaylistItem.getItem(uuid: itemId)?.playlistFolder?.isAnonymous ?? false
  }

  /// The folder an item belongs to, for UI that needs to name it.
  public static func folder(forItemId itemId: String) -> PlaylistFolder? {
    PlaylistItem.getItem(uuid: itemId)?.playlistFolder
  }

  public static func renameFolder(uuid: String, title: String, completion: (() -> Void)? = nil) {
    DataController.perform(
      context: .new(inMemory: false), save: true,
      { context in
        if let folder = PlaylistFolder.getFolder(uuid: uuid, context: context) {
          folder.title = title
        }
      },
      completion: completion)
  }

  /// Deletes a folder row.
  ///
  /// Callers must have already dealt with the folder's items — `PlaylistManager`
  /// deletes their files first, because the relationship's nullify rule would
  /// otherwise leave downloaded bytes on disk with nothing pointing at them.
  public static func removeFolder(_ uuid: String, completion: (() -> Void)? = nil) {
    guard uuid != PlaylistFolder.savedFolderUUID else {
      // The default folder is an invariant of the data model.
      DispatchQueue.main.async { completion?() }
      return
    }

    PlaylistFolder.deleteAll(
      predicate: NSPredicate(format: "uuid == %@", uuid),
      context: .new(inMemory: false),
      includesPropertyValues: false,
      completion: completion)
  }

  // MARK: - Internal

  private static func reorderFolders(context: NSManagedObjectContext) {
    let orderSort = NSSortDescriptor(key: "order", ascending: true)
    let folders = PlaylistFolder.all(sortDescriptors: [orderSort], context: context) ?? []

    for (order, folder) in folders.enumerated() {
      folder.order = Int32(order)
    }
  }
}
