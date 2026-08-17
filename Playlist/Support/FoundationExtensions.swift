// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Local re-implementations of the handful of helpers that the Brave Playlist
// sources import from Brave's `Shared` module. Brave's `Shared` also pulls in
// the browser's URL classification, the Public Suffix List database, and
// Chromium bridging; none of that is needed here, so these are written from
// the same behavioural contract rather than copied.

import Foundation
import UIKit
import os.log

// MARK: - FileManager

extension FileManager {
  /// Returns the URL of a folder inside `location`, creating it if necessary.
  ///
  /// Mirrors Brave's `FileManager.getOrCreateFolder(name:excludeFromBackups:location:)`.
  /// Downloaded media lives in Application Support (not Caches) so that iOS will
  /// not purge it under storage pressure, and is excluded from iCloud/iTunes
  /// backups because it is re-downloadable and often large.
  public func getOrCreateFolder(
    name: String,
    excludeFromBackups: Bool = true,
    location: SearchPathDirectory = .applicationSupportDirectory
  ) -> URL? {
    guard let documentsDirectory = urls(for: location, in: .userDomainMask).first else {
      return nil
    }

    var folder = documentsDirectory.appendingPathComponent(name)

    if !fileExists(atPath: folder.path) {
      do {
        try createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
      } catch {
        Logger.module.error("Failed to create folder \(name): \(error.localizedDescription)")
        return nil
      }
    }

    if excludeFromBackups {
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
      } catch {
        Logger.module.error(
          "Failed to exclude \(name) from backups: \(error.localizedDescription)")
      }
    }

    return folder
  }

  /// Total size on disk of a file or, recursively, a directory (e.g. an
  /// `.movpkg` HLS bundle).
  public func allocatedSizeOfItem(at url: URL) -> Int64 {
    var isDirectory: ObjCBool = false
    guard fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

    if !isDirectory.boolValue {
      let attributes = try? attributesOfItem(atPath: url.path)
      return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    let properties: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
    guard
      let enumerator = enumerator(
        at: url,
        includingPropertiesForKeys: properties,
        options: .skipsHiddenFiles,
        errorHandler: nil)
    else { return 0 }

    return
      enumerator
      .compactMap { try? ($0 as? URL)?.resourceValues(forKeys: Set(properties)) }
      .filter { $0.isRegularFile == true }
      .compactMap { $0.totalFileAllocatedSize }
      .reduce(Int64(0)) { $0 + Int64($1) }
  }
}

// MARK: - URL

extension URL {
  /// Returns a URL inside the receiver (a directory) that does not collide with
  /// an existing file, appending ` (1)`, ` (2)`, … before the extension.
  ///
  /// Mirrors Brave's `URL.uniquePathForFilename(_:)`. Two downloads of the same
  /// video, or two different videos that happen to share a page title, must not
  /// overwrite each other — the CoreData row points at a bookmark to a specific
  /// path, so a collision would silently corrupt the first item.
  public func uniquePathForFilename(_ filename: String) throws -> URL {
    let basePath = appendingPathComponent(filename)
    let fileExtension = basePath.pathExtension
    let filenameWithoutExtension =
      !fileExtension.isEmpty
      ? String(filename.dropLast(fileExtension.count + 1)) : filename

    var proposedPath = basePath
    var count = 0

    while FileManager.default.fileExists(atPath: proposedPath.path) {
      count += 1
      let proposedFilenameWithoutExtension = "\(filenameWithoutExtension) (\(count))"
      proposedPath =
        appendingPathComponent(proposedFilenameWithoutExtension)
        .appendingPathExtension(fileExtension)
    }

    return proposedPath
  }

  /// `example.co.uk` for `https://www.example.co.uk/watch?v=1`.
  ///
  /// Brave resolves this against the Public Suffix List via Chromium. Without
  /// that dependency this uses a small suffix table covering the common
  /// multi-part TLDs, and falls back to the last two labels. It is only used
  /// for display (the "artist" line on the lock screen and in the library), so
  /// an imperfect answer degrades presentation, never correctness.
  public var baseDomain: String? {
    guard let host = host?.lowercased(), !host.isEmpty else { return nil }

    // An IP address literal has no registrable domain.
    if host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }

    let components = host.components(separatedBy: ".")
    guard components.count > 2 else { return host }

    let lastTwo = components.suffix(2).joined(separator: ".")
    if Self.multiPartSuffixes.contains(lastTwo) {
      return components.suffix(3).joined(separator: ".")
    }
    return lastTwo
  }

  private static let multiPartSuffixes: Set<String> = [
    "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk", "net.uk", "sch.uk",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
    "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
    "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
    "com.br", "net.br", "org.br", "gov.br",
    "co.in", "net.in", "org.in", "gen.in", "firm.in",
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "co.kr", "or.kr", "ne.kr", "go.kr",
    "com.mx", "org.mx", "gob.mx",
    "co.za", "org.za", "net.za",
    "com.tr", "net.tr", "org.tr",
    "com.tw", "net.tw", "org.tw",
    "com.sg", "net.sg", "org.sg",
    "com.hk", "net.hk", "org.hk",
    "com.ar", "net.ar", "org.ar",
  ]

  /// Host plus path, ignoring scheme, `www.` and trailing slashes.
  ///
  /// Brave uses this to decide whether two `PlaylistInfo` values describe the
  /// same page, so `http://x/a`, `https://www.x/a` and `https://x/a/` collapse
  /// to one identity.
  public var normalizedHostAndPath: String? {
    guard var host = host?.lowercased() else { return nil }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }

    var path = self.path
    while path.count > 1 && path.hasSuffix("/") { path = String(path.dropLast()) }

    return host + path
  }

  /// The absolute string with the scheme removed, for scheme-insensitive
  /// comparisons.
  public var schemelessAbsoluteString: String {
    guard let scheme = scheme else { return absoluteString }
    return String(absoluteString.dropFirst(scheme.count + 3))
  }

  /// A filename-safe rendering of the receiver's last path component, used when
  /// naming a download whose media URL carries no useful title.
  public var suggestedDownloadName: String? {
    let name = lastPathComponent
    return name.isEmpty || name == "/" ? nil : name
  }
}

// MARK: - String

extension String {
  /// `URL(string:)` that rejects the strings Brave's callers treat as "not a
  /// URL" — empty and whitespace-only.
  public var asURL: URL? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: trimmed)
  }

  /// Strips characters that would let a filename escape its directory or spoof
  /// its extension with a Unicode right-to-left override.
  ///
  /// Copied in behaviour from Brave's
  /// `PlaylistDownloadManager.stripUnicode(fromFilename:)`.
  public var sanitizedFilename: String {
    let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
      .union(.newlines)
      .union(.controlCharacters)
      .union(.illegalCharacters)
    let stripped = components(separatedBy: invalid).joined()
    let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    // Keep well clear of the 255-byte limit once an extension and a " (12)"
    // uniquing suffix are appended.
    return String(trimmed.prefix(120))
  }
}

// MARK: - Dictionary

extension Dictionary {
  /// In-place merge, last writer wins. Brave's `Shared` spells this
  /// `merge(with:)` and the Now Playing code calls it on every tick.
  public mutating func merge(with other: [Key: Value]) {
    for (key, value) in other {
      self[key] = value
    }
  }
}

// MARK: - Formatting

/// Formatting helpers shared by the library, player and settings screens.
public enum Format {
  /// `1:02:03` / `4:05`. Returns `nil` for indefinite (live) durations so the
  /// caller can substitute a "LIVE" badge.
  public static func duration(_ seconds: TimeInterval) -> String? {
    guard seconds.isFinite, seconds > 0, seconds < TimeInterval(Int32.max) else { return nil }

    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }

  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.zeroPadsFractionDigits = true
    return formatter
  }()

  /// `1.2 GB`, matching what iOS Settings shows for app storage.
  public static func fileSize(_ bytes: Int64) -> String {
    byteFormatter.string(fromByteCount: bytes)
  }
}
