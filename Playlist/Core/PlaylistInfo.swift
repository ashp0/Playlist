// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Data/models/PlaylistInfo.swift`.
//
// Changes from upstream:
//   * `from(message:)` decodes a plain dictionary rather than a `WKScriptMessage`,
//     so the type no longer needs to import WebKit and can be unit-tested and
//     constructed by the direct-URL extraction path.
//   * Added `artworkURL`, which Brave does not persist — it re-derives artwork
//     from the page favicon on every render. A standalone library shows artwork
//     far more prominently, so the page's og:image is captured at add time.

import Foundation
import os.log

/// The transport type for a single media item.
///
/// This is the value that crosses every boundary in the app: the JavaScript
/// detector emits it, the database stores it, the download manager consumes it,
/// and the player renders it. Keeping it a plain `Codable` struct — rather than
/// passing `NSManagedObject`s around — is what lets media extraction run off the
/// main thread without dragging CoreData contexts along with it.
public struct PlaylistInfo: Codable, Identifiable, Hashable, Equatable {
  /// Display title. Taken from the media element's `title`, falling back to the
  /// page title.
  public let name: String
  /// The media URL to download or stream. May be an `https:` progressive file,
  /// an `m3u8` HLS manifest, or a `data:` URI.
  public let src: String
  /// The page the media was found on. Doubles as the re-extraction key when a
  /// media URL expires.
  public let pageSrc: String
  public let pageTitle: String
  public let mimeType: String
  public let duration: TimeInterval
  /// Resume point, in seconds.
  public let lastPlayedOffset: TimeInterval
  /// `true` when the detector found this automatically, as opposed to it being
  /// synthesised from a direct media URL.
  public let detected: Bool
  public let dateAdded: Date
  /// Stable identity, generated in JS as a UUID and reused as the CoreData key.
  public let tagId: String
  public let order: Int32
  /// `true` when the media element has no parent node — a detached element the
  /// page is using as a decoder, not as playable content.
  public let isInvisible: Bool
  /// URL of page-supplied artwork (`og:image`), if any.
  public let artworkURL: String?

  public var id: String { tagId }

  public init(pageSrc: String) {
    self.name = ""
    self.src = ""
    self.pageSrc = pageSrc
    self.pageTitle = ""
    self.mimeType = ""
    self.duration = 0.0
    self.lastPlayedOffset = 0.0
    self.dateAdded = Date()
    self.detected = false
    self.tagId = UUID().uuidString
    self.order = Int32.min
    self.isInvisible = false
    self.artworkURL = nil
  }

  public init(item: PlaylistItem) {
    self.name = item.name
    self.src = item.mediaSrc
    self.pageSrc = item.pageSrc
    self.pageTitle = item.pageTitle ?? ""
    self.mimeType = item.mimeType
    self.duration = item.duration
    self.lastPlayedOffset = item.lastPlayedOffset
    self.dateAdded = item.dateAdded
    self.detected = false
    self.tagId = item.uuid ?? UUID().uuidString
    self.order = item.order
    self.isInvisible = false
    self.artworkURL = item.artworkURL
  }

  public init(
    name: String,
    src: String,
    pageSrc: String,
    pageTitle: String,
    mimeType: String,
    duration: TimeInterval,
    lastPlayedOffset: TimeInterval,
    detected: Bool,
    dateAdded: Date,
    tagId: String,
    order: Int32,
    isInvisible: Bool,
    artworkURL: String? = nil
  ) {
    self.name = name
    self.src = src
    self.pageSrc = pageSrc
    self.pageTitle = pageTitle
    self.mimeType = mimeType
    self.duration = duration
    self.lastPlayedOffset = lastPlayedOffset
    self.detected = detected
    self.dateAdded = dateAdded
    self.tagId = tagId.isEmpty ? UUID().uuidString : tagId
    self.order = order
    self.isInvisible = isInvisible
    self.artworkURL = artworkURL
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    let src = try container.decodeIfPresent(String.self, forKey: .src) ?? ""
    self.pageSrc = try container.decode(String.self, forKey: .pageSrc)
    self.pageTitle = try container.decode(String.self, forKey: .pageTitle)
    self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
    self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0.0
    self.lastPlayedOffset =
      try container.decodeIfPresent(TimeInterval.self, forKey: .lastPlayedOffset) ?? 0.0
    self.detected = try container.decodeIfPresent(Bool.self, forKey: .detected) ?? false
    self.tagId = try container.decodeIfPresent(String.self, forKey: .tagId) ?? UUID().uuidString
    self.dateAdded = Date()
    self.src = PlaylistInfo.fixSchemelessURLs(src: src, pageSrc: pageSrc)
    self.order = try container.decodeIfPresent(Int32.self, forKey: .order) ?? Int32.min
    self.isInvisible = try container.decodeIfPresent(Bool.self, forKey: .isInvisible) ?? false
    self.artworkURL = try container.decodeIfPresent(String.self, forKey: .artworkURL)
  }

  /// Decodes an item out of the JSON body posted by `PlaylistDetector.js`.
  ///
  /// Brave takes a `WKScriptMessage` here. Splitting the WebKit dependency out
  /// means the offscreen loader can validate and unwrap the message (including
  /// its security token) before this type ever sees it.
  public static func from(messageBody: Any) -> PlaylistInfo? {
    guard JSONSerialization.isValidJSONObject(messageBody) else { return nil }

    do {
      let data = try JSONSerialization.data(
        withJSONObject: messageBody, options: [.fragmentsAllowed])
      return try JSONDecoder().decode(PlaylistInfo.self, from: data)
    } catch {
      Logger.module.error("Error decoding PlaylistInfo: \(error.localizedDescription)")
      return nil
    }
  }

  /// Returns a copy with a replaced media source.
  ///
  /// Used when a stored media URL has expired and re-extraction produced a
  /// fresh one: everything else about the item — identity, position in the
  /// library, resume point — must survive.
  public func replacingSource(with other: PlaylistInfo) -> PlaylistInfo {
    PlaylistInfo(
      name: other.name.isEmpty ? name : other.name,
      src: other.src,
      pageSrc: pageSrc,
      pageTitle: other.pageTitle.isEmpty ? pageTitle : other.pageTitle,
      mimeType: other.mimeType.isEmpty ? mimeType : other.mimeType,
      duration: other.duration > 0 ? other.duration : duration,
      lastPlayedOffset: lastPlayedOffset,
      detected: other.detected,
      dateAdded: dateAdded,
      tagId: tagId,
      order: order,
      isInvisible: isInvisible,
      artworkURL: other.artworkURL ?? artworkURL)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(pageSrc.asURL?.normalizedHostAndPath ?? pageSrc)
    hasher.combine(tagId)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    if let lhsPageSrc = lhs.pageSrc.asURL?.normalizedHostAndPath,
      let rhsPageSrc = rhs.pageSrc.asURL?.normalizedHostAndPath
    {
      return lhsPageSrc == rhsPageSrc && lhs.tagId == rhs.tagId
    }
    return lhs.pageSrc == rhs.pageSrc && lhs.tagId == rhs.tagId
  }

  /// Resolves protocol-relative (`//host/x`) and root-relative (`/x`) media
  /// sources against the page they were found on.
  ///
  /// Verbatim from Brave. `<video src="//cdn.example/a.mp4">` is legal HTML and
  /// common in the wild, but `URL(string:)` yields something unusable for it.
  public static func fixSchemelessURLs(src: String, pageSrc: String) -> String {
    if src.hasPrefix("//") {
      return "\(URL(string: pageSrc)?.scheme ?? ""):\(src)"
    } else if src.hasPrefix("/"),
      let url = URL(string: src, relativeTo: URL(string: pageSrc))?.absoluteString
    {
      return url
    }
    return src
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case src
    case pageSrc
    case pageTitle
    case mimeType
    case duration
    case lastPlayedOffset
    case detected
    case tagId
    case dateAdded
    case order
    case isInvisible = "invisible"
    case artworkURL
  }
}
