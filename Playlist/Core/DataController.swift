// Copyright 2020 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Data/models/DataController.swift`.
//
// Changes from upstream:
//   * The managed object model is built in code instead of being compiled from
//     a versioned `.xcdatamodeld`. Brave ships ~40 model versions and needs the
//     migration chain; a new app starts at version 1, and a programmatic model
//     removes the `momc` build step, which keeps this project buildable from a
//     hand-written `project.pbxproj` with no Xcode-generated file references.
//   * Brave's model has ~15 browser entities (Domain, Favorite, History,
//     SessionTab, WalletUserAsset …). Only PlaylistItem and PlaylistFolder
//     remain.
//   * The `.new(inMemory:)` / `.existing(_:)` `WriteContext` enum and the
//     `perform(context:save:_:)` entry point are preserved as-is, because every
//     adapted call site in PlaylistItem/PlaylistFolder/PlaylistManager uses them.

import CoreData
import Foundation
import os.log

/// The CoreData stack.
///
/// Threading follows Brave's rule exactly: reads happen on `viewContext` (main
/// queue) and every write happens on a private-queue child context created per
/// operation and merged back. That is why `PlaylistItem.updateCache` can be
/// called from a `URLSession` delegate without blocking the UI or tripping
/// CoreData's concurrency debugger.
public class DataController {
  private static let modelName = "Playlist"

  public static let shared = DataController()

  /// Selects the context an operation runs against.
  public enum WriteContext {
    /// Spin up a fresh private-queue context for this operation.
    case new(inMemory: Bool)
    /// Reuse a caller-supplied context, so several operations compose into one
    /// save.
    case existing(NSManagedObjectContext)
  }

  // MARK: - Contexts

  /// Main-queue context. Read from this; never write to it.
  public static var viewContext: NSManagedObjectContext {
    DataController.shared.container.viewContext
  }

  /// An in-memory store used for transient items (a media item being previewed
  /// before the user commits to downloading it) so a cancelled add leaves
  /// nothing behind on disk.
  public static var viewContextInMemory: NSManagedObjectContext {
    DataController.shared.inMemoryContainer.viewContext
  }

  // MARK: - Model

  /// The managed object model, constructed in code.
  ///
  /// Attribute names and types match brave-ios's `Model.xcdatamodeld` so that
  /// the adapted `PlaylistItem` / `PlaylistFolder` accessors — and any future
  /// diff against upstream — line up.
  static let managedObjectModel: NSManagedObjectModel = {
    let model = NSManagedObjectModel()

    // MARK: PlaylistItem

    let item = NSEntityDescription()
    item.name = "PlaylistItem"
    item.managedObjectClassName = NSStringFromClass(PlaylistItem.self)

    let itemAttributes: [NSAttributeDescription] = [
      .make("cachedData", .binaryDataAttributeType, optional: true),
      .make("dateAdded", .dateAttributeType),
      .make("duration", .doubleAttributeType),
      .make("lastPlayedOffset", .doubleAttributeType),
      .make("mediaSrc", .stringAttributeType),
      .make("mimeType", .stringAttributeType),
      .make("name", .stringAttributeType),
      .make("order", .integer32AttributeType),
      .make("pageSrc", .stringAttributeType),
      .make("pageTitle", .stringAttributeType, optional: true),
      .make("uuid", .stringAttributeType, optional: true),
      // Not present upstream — see PlaylistInfo.artworkURL.
      .make("artworkURL", .stringAttributeType, optional: true),
      // Not present upstream — see PlaylistItem.segmentIndex. Added with a
      // default so an existing store migrates without a mapping model.
      .make("segmentIndex", .integer32AttributeType),
    ]

    // MARK: PlaylistFolder

    let folder = NSEntityDescription()
    folder.name = "PlaylistFolder"
    folder.managedObjectClassName = NSStringFromClass(PlaylistFolder.self)

    let folderAttributes: [NSAttributeDescription] = [
      .make("dateAdded", .dateAttributeType),
      .make("order", .integer32AttributeType),
      .make("title", .stringAttributeType),
      .make("uuid", .stringAttributeType, optional: true),
      // Not present upstream — see PlaylistFolder.isAnonymous. Added with a
      // default so an existing store migrates without a mapping model.
      .make("isAnonymous", .booleanAttributeType),
      // Not present upstream — see PlaylistFolder.segmentDuration. Zero means
      // the playlist plays its items whole, which is every existing folder.
      .make("segmentDuration", .doubleAttributeType),
    ]

    // MARK: Relationships

    let itemToFolder = NSRelationshipDescription()
    itemToFolder.name = "playlistFolder"
    itemToFolder.destinationEntity = folder
    itemToFolder.minCount = 0
    itemToFolder.maxCount = 1
    itemToFolder.isOptional = true
    // Nullify, not cascade: PlaylistManager deletes an item's file from disk
    // before deleting the row, and a cascade would let CoreData delete rows
    // whose media files are still on disk, orphaning the bytes forever.
    itemToFolder.deleteRule = .nullifyDeleteRule

    let folderToItems = NSRelationshipDescription()
    folderToItems.name = "playlistItems"
    folderToItems.destinationEntity = item
    folderToItems.minCount = 0
    folderToItems.maxCount = 0  // to-many
    folderToItems.isOptional = true
    folderToItems.deleteRule = .nullifyDeleteRule

    itemToFolder.inverseRelationship = folderToItems
    folderToItems.inverseRelationship = itemToFolder

    item.properties = itemAttributes + [itemToFolder]
    folder.properties = folderAttributes + [folderToItems]

    model.entities = [item, folder]
    return model
  }()

  // MARK: - Containers

  private lazy var container: NSPersistentContainer = {
    let container = NSPersistentContainer(
      name: DataController.modelName,
      managedObjectModel: DataController.managedObjectModel)

    let storeURL = DataController.storeURL
    let description = NSPersistentStoreDescription(url: storeURL)
    description.shouldMigrateStoreAutomatically = true
    description.shouldInferMappingModelAutomatically = true
    container.persistentStoreDescriptions = [description]

    container.loadPersistentStores { _, error in
      if let error = error {
        // A corrupt or unreadable store is unrecoverable, and continuing would
        // mean every fetch silently returning nothing while the user's library
        // appears to have vanished. Fail loudly instead.
        fatalError("Unable to load persistent store: \(error)")
      }
    }

    container.viewContext.automaticallyMergesChangesFromParent = true
    container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
    return container
  }()

  private lazy var inMemoryContainer: NSPersistentContainer = {
    let container = NSPersistentContainer(
      name: DataController.modelName,
      managedObjectModel: DataController.managedObjectModel)

    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]

    container.loadPersistentStores { _, error in
      if let error = error {
        Logger.module.error("In-memory store failed to load: \(error.localizedDescription)")
      }
    }

    container.viewContext.automaticallyMergesChangesFromParent = true
    return container
  }()

  /// The database lives in Application Support next to the downloaded media, so
  /// the two are backed up (or excluded) together.
  private static var storeURL: URL {
    let directory =
      FileManager.default.getOrCreateFolder(
        name: "Database",
        excludeFromBackups: false,
        location: .applicationSupportDirectory)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    return directory.appendingPathComponent("\(modelName).sqlite")
  }

  // MARK: - Writing

  /// Runs `task` on a write context, saves it, and only then calls `completion`
  /// on the main queue.
  ///
  /// Signature preserved from Brave so adapted call sites read identically,
  /// with one addition: the `completion` parameter.
  ///
  /// Brave's call sites dispatch their own completion to the main queue from
  /// *inside* the task closure — i.e. before `perform` saves the context. That
  /// makes "completion" mean "the changes are staged", not "the changes are
  /// visible", and every caller here assumes the latter: `AddMediaView` starts
  /// an auto-download from the completion (the download manager immediately
  /// writes a bookmark back onto that row), and the view models reload from it.
  /// Firing after the save is what makes those callers correct.
  ///
  /// `save: false` hands responsibility for saving to the task, which the batch
  /// paths use so a reorder and an insert land in a single save.
  public static func perform(
    context: WriteContext = .new(inMemory: false),
    save: Bool = true,
    _ task: @escaping (NSManagedObjectContext) -> Void,
    completion: (() -> Void)? = nil
  ) {
    let run = { (context: NSManagedObjectContext) in
      task(context)
      if save && context.hasChanges {
        DataController.save(context: context)
      }

      if let completion = completion {
        // The save notification is merged into `viewContext` on the main queue;
        // hopping there after the save puts this behind that merge, so a read
        // from the completion sees the write.
        DispatchQueue.main.async {
          completion()
        }
      }
    }

    switch context {
    case .existing(let existingContext):
      existingContext.perform { run(existingContext) }

    case .new(let inMemory):
      let backgroundContext = DataController.newBackgroundContext(inMemory: inMemory)
      backgroundContext.perform { run(backgroundContext) }
    }
  }

  /// Creates a private-queue context suitable for writing.
  public static func newBackgroundContext(inMemory: Bool = false) -> NSManagedObjectContext {
    let container =
      inMemory ? DataController.shared.inMemoryContainer : DataController.shared.container
    let context = container.newBackgroundContext()
    // Property-level trump: two concurrent writers touching the same row (say a
    // download completing while the user renames the item) should each keep
    // their own field rather than one clobbering the whole object.
    context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    return context
  }

  static func save(context: NSManagedObjectContext) {
    guard context.hasChanges else { return }

    if context.concurrencyType == .mainQueueConcurrencyType {
      Logger.module.warning("Writing to view context, this should be avoided.")
    }

    do {
      try context.save()
    } catch {
      Logger.module.error("Error saving DB: \(error.localizedDescription)")
      assertionFailure("Error saving DB: \(error.localizedDescription)")
    }
  }

  /// Removes every row from both entities. Backs "Delete All" in Settings.
  ///
  /// Uses a batch delete for speed, then merges the result into `viewContext`
  /// by hand — batch deletes bypass the context, so without the merge the UI
  /// would keep showing rows that no longer exist.
  public static func destroyAllData(completion: (() -> Void)? = nil) {
    let container = DataController.shared.container
    container.performBackgroundTask { context in
      for entityName in ["PlaylistItem", "PlaylistFolder"] {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs

        do {
          let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
          if let objectIDs = result?.result as? [NSManagedObjectID] {
            NSManagedObjectContext.mergeChanges(
              fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
              into: [DataController.viewContext])
          }
        } catch {
          Logger.module.error(
            "Failed to delete all \(entityName): \(error.localizedDescription)")
        }
      }

      DispatchQueue.main.async {
        completion?()
      }
    }
  }
}

// MARK: - Model construction helpers

extension NSAttributeDescription {
  fileprivate static func make(
    _ name: String,
    _ type: NSAttributeType,
    optional: Bool = false
  ) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = optional
    // Non-optional scalars need a default, otherwise inserting a row without
    // explicitly assigning every field fails validation on save.
    if !optional {
      switch type {
      case .doubleAttributeType: attribute.defaultValue = 0.0
      case .integer32AttributeType: attribute.defaultValue = 0
      case .booleanAttributeType: attribute.defaultValue = false
      case .stringAttributeType: attribute.defaultValue = ""
      case .dateAttributeType: attribute.defaultValue = Date()
      default: break
      }
    }
    return attribute
  }
}

// MARK: - CRUD

/// The fetch/delete helpers Brave's models get from its `CRUD` protocol in
/// `Sources/Data/models/CRUDProtocols.swift`, reduced to the operations the
/// Playlist entities actually use.
public protocol CRUD: NSFetchRequestResult, NSManagedObject {
  static func entityName() -> String
}

extension CRUD {
  public static func entity(in context: NSManagedObjectContext) -> NSEntityDescription {
    guard let entity = NSEntityDescription.entity(forEntityName: entityName(), in: context) else {
      fatalError("Entity \(entityName()) is not present in the model")
    }
    return entity
  }

  public static func all(
    where predicate: NSPredicate? = nil,
    sortDescriptors: [NSSortDescriptor] = [],
    fetchLimit: Int = 0,
    fetchBatchSize: Int = 0,
    context: NSManagedObjectContext = DataController.viewContext
  ) -> [Self]? {
    let request = NSFetchRequest<Self>()
    request.entity = Self.entity(in: context)
    request.predicate = predicate
    request.sortDescriptors = sortDescriptors
    request.fetchLimit = fetchLimit
    request.fetchBatchSize = fetchBatchSize

    do {
      return try context.fetch(request)
    } catch {
      Logger.module.error("Fetch of \(entityName()) failed: \(error.localizedDescription)")
      return nil
    }
  }

  public static func first(
    where predicate: NSPredicate? = nil,
    sortDescriptors: [NSSortDescriptor] = [],
    context: NSManagedObjectContext = DataController.viewContext
  ) -> Self? {
    all(
      where: predicate, sortDescriptors: sortDescriptors, fetchLimit: 1, context: context
    )?.first
  }

  public static func count(
    predicate: NSPredicate? = nil,
    context: NSManagedObjectContext = DataController.viewContext
  ) -> Int? {
    let request = NSFetchRequest<Self>()
    request.entity = Self.entity(in: context)
    request.predicate = predicate

    do {
      return try context.count(for: request)
    } catch {
      Logger.module.error("Count of \(entityName()) failed: \(error.localizedDescription)")
      return nil
    }
  }

  public static func deleteAll(
    predicate: NSPredicate? = nil,
    context: DataController.WriteContext = .new(inMemory: false),
    includesPropertyValues: Bool = true,
    completion: (() -> Void)? = nil
  ) {
    DataController.perform(
      context: context,
      { context in
        let request = NSFetchRequest<Self>()
        request.entity = Self.entity(in: context)
        request.predicate = predicate
        request.includesPropertyValues = includesPropertyValues

        do {
          let results = try context.fetch(request)
          results.forEach { context.delete($0) }
        } catch {
          Logger.module.error("Delete of \(entityName()) failed: \(error.localizedDescription)")
        }
      },
      completion: completion)
  }

  public func delete(context: DataController.WriteContext = .new(inMemory: false)) {
    let objectID = self.objectID
    DataController.perform(context: context) { context in
      guard let object = try? context.existingObject(with: objectID) else { return }
      context.delete(object)
    }
  }
}
