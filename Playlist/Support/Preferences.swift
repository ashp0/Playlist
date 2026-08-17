// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from Brave's `Sources/Preferences/Preferences.swift` and
// `Sources/Playlist/PlaylistPreferences.swift`. Brave's version carries extra
// machinery this app has no use for (per-profile keys, migration records,
// P3A reporting hooks); what remains is the `Option<T>` box and the Playlist
// preference namespace, with browser-only options removed.

import Combine
import Foundation

/// A UserDefaults-backed preference store.
public final class Preferences {
  /// The container all options read from and write to.
  fileprivate static let defaults = UserDefaults.standard

  /// A single typed preference.
  ///
  /// `Option` is a class (not a property wrapper) because Brave's call sites
  /// use the `Preferences.Playlist.foo.value` form and observe options by
  /// identity. Keeping the shape identical means the adapted Playlist code
  /// needed no rewriting.
  public final class Option<T: PreferenceStorable>: ObservableObject {
    public let key: String
    public let defaultValue: T

    /// Emits whenever `value` is written. Used by SwiftUI views that need to
    /// react to a setting changing from elsewhere (e.g. the Now Playing bar
    /// changing playback speed while Settings is on screen).
    public let objectWillChange = ObservableObjectPublisher()

    public var value: T {
      get { T.get(key: key, from: Preferences.defaults) ?? defaultValue }
      set {
        objectWillChange.send()
        T.set(newValue, key: key, to: Preferences.defaults)
        Preferences.changeSubject.send(key)
      }
    }

    public init(key: String, default defaultValue: T) {
      self.key = key
      self.defaultValue = defaultValue
    }

    /// Restores the option to its compiled-in default.
    public func reset() {
      objectWillChange.send()
      Preferences.defaults.removeObject(forKey: key)
      Preferences.changeSubject.send(key)
    }
  }

  private static let changeSubject = PassthroughSubject<String, Never>()

  /// Emits the key of any option that changes. Views observe this rather than
  /// each individual option when they display several settings at once.
  public static var didChange: AnyPublisher<String, Never> {
    changeSubject.eraseToAnyPublisher()
  }
}

// MARK: - Storage

/// Types that can round-trip through `UserDefaults`.
public protocol PreferenceStorable {
  static func get(key: String, from defaults: UserDefaults) -> Self?
  static func set(_ value: Self, key: String, to defaults: UserDefaults)
}

extension Bool: PreferenceStorable {
  public static func get(key: String, from defaults: UserDefaults) -> Bool? {
    defaults.object(forKey: key) as? Bool
  }
  public static func set(_ value: Bool, key: String, to defaults: UserDefaults) {
    defaults.set(value, forKey: key)
  }
}

extension Int: PreferenceStorable {
  public static func get(key: String, from defaults: UserDefaults) -> Int? {
    defaults.object(forKey: key) as? Int
  }
  public static func set(_ value: Int, key: String, to defaults: UserDefaults) {
    defaults.set(value, forKey: key)
  }
}

extension Double: PreferenceStorable {
  public static func get(key: String, from defaults: UserDefaults) -> Double? {
    defaults.object(forKey: key) as? Double
  }
  public static func set(_ value: Double, key: String, to defaults: UserDefaults) {
    defaults.set(value, forKey: key)
  }
}

extension String: PreferenceStorable {
  public static func get(key: String, from defaults: UserDefaults) -> String? {
    defaults.object(forKey: key) as? String
  }
  public static func set(_ value: String, key: String, to defaults: UserDefaults) {
    defaults.set(value, forKey: key)
  }
}

extension Date: PreferenceStorable {
  public static func get(key: String, from defaults: UserDefaults) -> Date? {
    defaults.object(forKey: key) as? Date
  }
  public static func set(_ value: Date, key: String, to defaults: UserDefaults) {
    defaults.set(value, forKey: key)
  }
}

extension Optional: PreferenceStorable where Wrapped: PreferenceStorable {
  public static func get(key: String, from defaults: UserDefaults) -> Wrapped?? {
    // A missing key and a stored `nil` are the same thing here, and both should
    // fall through to the option's default value.
    guard defaults.object(forKey: key) != nil else { return nil }
    return .some(Wrapped.get(key: key, from: defaults))
  }
  public static func set(_ value: Wrapped?, key: String, to defaults: UserDefaults) {
    if let value = value {
      Wrapped.set(value, key: key, to: defaults)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

// MARK: - Playlist preferences

/// Whether a newly added item downloads immediately.
///
/// Same cases as Brave's `PlayListDownloadType`.
public enum PlayListDownloadType: String, CaseIterable, Identifiable {
  case on
  case off
  case wifi

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .on: return "Always"
    case .wifi: return "Wi-Fi Only"
    case .off: return "Never"
    }
  }
}

/// How the library list is ordered.
///
/// New in this app. Brave's list is manually ordered only (drag to reorder,
/// persisted in `PlaylistItem.order`); a standalone media library needs the
/// usual sort affordances, so manual order became one option among several.
public enum LibrarySortOrder: String, CaseIterable, Identifiable {
  case manual
  case dateAddedNewest
  case dateAddedOldest
  case titleAscending
  case titleDescending
  case durationLongest
  case durationShortest

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .manual: return "Custom Order"
    case .dateAddedNewest: return "Recently Added"
    case .dateAddedOldest: return "Oldest First"
    case .titleAscending: return "Title (A–Z)"
    case .titleDescending: return "Title (Z–A)"
    case .durationLongest: return "Longest First"
    case .durationShortest: return "Shortest First"
    }
  }
}

extension Preferences {
  /// Playlist preference namespace.
  ///
  /// Keys are kept identical to Brave's where the option survived the port, so
  /// the semantics stay greppable against the upstream source.
  public final class Playlist {
    /// The last played item's page URL, used to restore the queue on launch.
    public static let lastPlayedItemUrl = Option<String?>(
      key: "playlist.last.played.item.url", default: nil)

    /// Whether playback resumes from the stored offset instead of restarting.
    public static let playbackLeftOff = Option<Bool>(
      key: "playlist.playbackLeftOff", default: true)

    /// Whether a newly added item downloads immediately, and over which network.
    public static let autoDownloadVideo = Option<String>(
      key: "playlist.autoDownload", default: PlayListDownloadType.on.rawValue)

    /// Disables the `MediaSource` web API during extraction so that players
    /// fall back to a progressive URL we can actually download. See
    /// `PlaylistSwizzler.js`.
    public static let webMediaSourceCompatibility = Option<Bool>(
      key: "playlist.webMediaSourceCompatibility", default: false)

    /// Whether extraction requests pages with a desktop user agent.
    public static let useDesktopUserAgent = Option<Bool>(
      key: "playlist.useDesktopUserAgent", default: true)

    // MARK: Additions

    /// Playback rate applied to newly started items.
    public static let defaultPlaybackRate = Option<Double>(
      key: "playlist.defaultPlaybackRate", default: 1.0)

    /// Library sort order.
    public static let sortOrder = Option<String>(
      key: "playlist.sortOrder", default: LibrarySortOrder.dateAddedNewest.rawValue)

    /// The playlist the library was last showing, by folder UUID.
    ///
    /// Empty means "All Media" — which is both the compiled-in default and a
    /// selection the user can make deliberately, and the two want the same
    /// behaviour, so they do not need telling apart. A UUID that no longer
    /// names a folder falls back to All Media and is cleared; a playlist can be
    /// deleted between launches, and reopening onto an empty screen with no
    /// explanation is worse than reopening onto everything.
    public static let selectedFolderUUID = Option<String>(
      key: "playlist.selectedFolder", default: "")

    /// Repeat mode, persisted across launches.
    public static let repeatMode = Option<String>(
      key: "playlist.repeatMode", default: "none")

    /// Shuffle, persisted across launches.
    public static let shuffleEnabled = Option<Bool>(
      key: "playlist.shuffleEnabled", default: false)

    /// Number of seconds the skip-forward / skip-back controls jump.
    public static let seekInterval = Option<Double>(
      key: "playlist.seekInterval", default: 15.0)

    /// Continue to the next item automatically when one finishes.
    public static let autoPlayNext = Option<Bool>(
      key: "playlist.autoPlayNext", default: true)

    /// Whether video may float out into Picture-in-Picture.
    ///
    /// Off means the `AVPictureInPictureController` is never allowed to start
    /// itself when the app is backgrounded — audio continues, the video window
    /// does not appear.
    public static let pictureInPictureEnabled = Option<Bool>(
      key: "playlist.pictureInPictureEnabled", default: true)
  }
}
