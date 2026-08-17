// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// No upstream counterpart. Brave exposes no Playlist intents; a standalone
// media player wants them, because "play my running playlist" is an automation
// people already have for every other player on the phone.

import AppIntents
import Combine
import Foundation

// MARK: - Routing

/// The channel from an App Intent to whatever UI is on screen.
///
/// An intent cannot reach into a SwiftUI view, and on a cold launch it may run
/// before there is one. So it leaves a request here and `RootView` picks it up —
/// either when the value changes, or when the view first appears, whichever
/// happens second.
@MainActor
public final class AppIntentRouter: ObservableObject {
  public static let shared = AppIntentRouter()

  /// A playlist Shortcuts asked to show, by folder UUID.
  @Published public var requestedFolderUUID: String?

  private init() {}
}

// MARK: - Entity

/// A playlist, as Shortcuts sees it.
///
/// The identifier is the folder's UUID rather than its name: a Shortcut is
/// saved once and run for months, and renaming a playlist should not break it.
struct PlaylistEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
  static var defaultQuery = PlaylistEntityQuery()

  var id: String
  var name: String
  var itemCount: Int

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)",
      subtitle: itemCount == 1 ? "1 item" : "\(itemCount) items")
  }

  @MainActor
  init?(folder: PlaylistFolder) {
    guard let uuid = folder.uuid else { return nil }
    self.id = uuid
    self.name = folder.title
    self.itemCount = folder.itemCount
  }
}

/// Supplies the playlist picker in Shortcuts, and resolves spoken names.
struct PlaylistEntityQuery: EntityQuery, EntityStringQuery {
  func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
    // The library is CoreData behind a main-queue context, so every lookup here
    // hops to the main actor rather than touching `viewContext` from whatever
    // queue the system ran the query on.
    await MainActor.run {
      identifiers.compactMap { uuid in
        PlaylistFolder.getFolder(uuid: uuid).flatMap(PlaylistEntity.init(folder:))
      }
    }
  }

  func entities(matching string: String) async throws -> [PlaylistEntity] {
    await MainActor.run {
      PlaylistFolder.getFolders()
        .filter { $0.title.localizedCaseInsensitiveContains(string) }
        .compactMap(PlaylistEntity.init(folder:))
    }
  }

  func suggestedEntities() async throws -> [PlaylistEntity] {
    await MainActor.run {
      PlaylistFolder.getFolders().compactMap(PlaylistEntity.init(folder:))
    }
  }
}

// MARK: - Intents

/// Opens the app with one playlist showing.
struct OpenPlaylistIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Playlist"
  static var description = IntentDescription(
    "Opens Playlist with one of your playlists showing.")

  /// The point of this intent is to land the user in the app, so it always
  /// comes to the foreground.
  static var openAppWhenRun = true

  @Parameter(title: "Playlist")
  var playlist: PlaylistEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$playlist)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    AppIntentRouter.shared.requestedFolderUUID = playlist.id
    return .result()
  }
}

/// Starts a playlist playing, without bringing the app to the foreground.
///
/// `AudioPlaybackIntent` is what makes that legal: it tells the system this
/// intent's whole purpose is to start audio, which is what allows the audio
/// session to be activated from a run that the user never saw.
struct PlayPlaylistIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Play Playlist"
  static var description = IntentDescription(
    "Plays a playlist. Downloaded items play with no network connection.")

  @Parameter(title: "Playlist")
  var playlist: PlaylistEntity

  @Parameter(title: "Shuffle", default: false)
  var shuffle: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Play \(\.$playlist)") {
      \.$shuffle
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let count = PlaybackController.shared.play(folderUUID: playlist.id, shuffled: shuffle)

    guard count > 0 else {
      throw PlaylistIntentError.emptyPlaylist(playlist.name)
    }

    return .result()
  }
}

/// Pauses whatever is playing.
struct PausePlaybackIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "Pause"
  static var description = IntentDescription("Pauses playback.")

  @MainActor
  func perform() async throws -> some IntentResult {
    PlaybackController.shared.pause()
    return .result()
  }
}

// MARK: - Errors

enum PlaylistIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
  case emptyPlaylist(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .emptyPlaylist(let name):
      return "“\(name)” has nothing in it to play."
    }
  }
}

// MARK: - Siri phrases

/// The shortcuts offered without the user having to build one.
struct PlaylistAppShortcuts: AppShortcutsProvider {
  @AppShortcutsBuilder
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlayPlaylistIntent(),
      phrases: [
        "Play a playlist in \(.applicationName)",
        "Play a \(.applicationName) playlist",
      ],
      shortTitle: "Play Playlist",
      systemImageName: "play.circle")

    AppShortcut(
      intent: OpenPlaylistIntent(),
      phrases: [
        "Open a playlist in \(.applicationName)",
        "Show a \(.applicationName) playlist",
      ],
      shortTitle: "Open Playlist",
      systemImageName: "music.note.list")
  }
}
