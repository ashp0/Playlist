// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Replaces Brave's use of `SDImageCache.shared` in
// `PlaylistThumbnailUtility.swift`. Brave stores generated thumbnails in
// SDWebImage's shared cache keyed by the media URL; this is the same contract
// against `NSCache` + a directory in Caches, so the app has no SPM dependencies.

import CryptoKit
import Foundation
import UIKit

/// Two-tier (memory + disk) cache for artwork.
///
/// Thumbnails are expensive: generating one means spinning up an `AVAsset`, and
/// for HLS an entire `AVPlayer` + `AVPlayerItemVideoOutput`. The library shows
/// dozens of rows and SwiftUI will re-request artwork on every scroll pass, so
/// caching is what makes the list usable rather than a nicety.
///
/// The disk tier lives in Caches (unlike downloaded media, which lives in
/// Application Support) — it is cheap to regenerate, so letting iOS evict it
/// under storage pressure is the correct trade.
public final class ImageCache {
  public static let shared = ImageCache()

  private let memory = NSCache<NSString, UIImage>()
  private let directory: URL?
  private let ioQueue = DispatchQueue(
    label: "com.overnight.playlist.imagecache", qos: .utility)

  private init() {
    memory.countLimit = 200
    // ~64 MB of decoded bitmaps. `UIImage` cost is supplied per-entry below.
    memory.totalCostLimit = 64 * 1024 * 1024

    directory = FileManager.default.getOrCreateFolder(
      name: "Thumbnails",
      excludeFromBackups: true,
      location: .cachesDirectory)
  }

  /// Returns a cached image without touching disk. Safe to call from `body`.
  public func imageFromMemory(forKey key: String) -> UIImage? {
    memory.object(forKey: key as NSString)
  }

  /// Returns a cached image, consulting the disk tier if needed.
  public func image(forKey key: String) async -> UIImage? {
    if let image = imageFromMemory(forKey: key) {
      return image
    }

    guard let url = fileURL(forKey: key) else { return nil }

    let image: UIImage? = await withCheckedContinuation { continuation in
      ioQueue.async {
        guard let data = try? Data(contentsOf: url),
          let image = UIImage(data: data)
        else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: image)
      }
    }

    if let image = image {
      memory.setObject(image, forKey: key as NSString, cost: image.estimatedCost)
    }
    return image
  }

  /// Stores an image in both tiers.
  public func store(_ image: UIImage, forKey key: String) {
    memory.setObject(image, forKey: key as NSString, cost: image.estimatedCost)

    guard let url = fileURL(forKey: key) else { return }
    ioQueue.async {
      // JPEG rather than PNG: these are photographic video frames, where JPEG is
      // an order of magnitude smaller at indistinguishable quality.
      guard let data = image.jpegData(compressionQuality: 0.8) else { return }
      try? data.write(to: url, options: .atomic)
    }
  }

  /// Drops a single entry, e.g. when its media item is deleted.
  public func remove(forKey key: String) {
    memory.removeObject(forKey: key as NSString)
    guard let url = fileURL(forKey: key) else { return }
    ioQueue.async {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Empties both tiers. Surfaced in Settings alongside storage usage.
  public func clear() {
    memory.removeAllObjects()
    guard let directory = directory else { return }
    ioQueue.async {
      try? FileManager.default.removeItem(at: directory)
      _ = FileManager.default.getOrCreateFolder(
        name: "Thumbnails", excludeFromBackups: true, location: .cachesDirectory)
    }
  }

  /// Total bytes held by the disk tier.
  public func diskUsage() -> Int64 {
    guard let directory = directory else { return 0 }
    return FileManager.default.allocatedSizeOfItem(at: directory)
  }

  // MARK: - Private

  /// Keys are arbitrary URLs, which contain characters that are not legal in a
  /// filename and can exceed the length limit, so they are hashed.
  private func fileURL(forKey key: String) -> URL? {
    guard let directory = directory else { return nil }
    let digest = SHA256.hash(data: Data(key.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name).appendingPathExtension("jpg")
  }
}

extension UIImage {
  /// Approximate decoded byte size, for `NSCache` cost accounting.
  fileprivate var estimatedCost: Int {
    guard let cgImage = cgImage else { return 1 }
    return cgImage.bytesPerRow * cgImage.height
  }
}
