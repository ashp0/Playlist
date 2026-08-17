// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// New in this app, but assembled from Brave's parts: the direct-URL fast path
// is new, and `refreshExpiredMedia` is a browserless rewrite of
// `PlaylistMediaStreamer.streamingFallback` from
// brave-ios `Sources/Playlist/PlaylistMediaStreamer.swift`.
//
// Brave never needs a "paste a URL" entry point — its Playlist is fed by the
// tab the user is already looking at. That entry point is the whole user-facing
// premise of this app, so it gets an explicit API here.

import AVFoundation
import Foundation
import os.log

/// Turns a URL the user pasted into media the app can download.
@MainActor
public final class MediaExtractor {
  public static let shared = MediaExtractor()

  private var activeLoader: PlaylistWebLoader?

  private init() {}

  public enum ExtractionError: Error, LocalizedError {
    case invalidURL
    case noMediaFound
    case noVideoInYouTubeLink
    case youTubeSignInRequired
    case youTubeUnavailable(String)
    case cancelled

    public var errorDescription: String? {
      switch self {
      case .invalidURL:
        return "That doesn't look like a web address."
      case .noMediaFound:
        return
          "No downloadable media was found on that page. The site may stream in a format that can't be saved."
      case .noVideoInYouTubeLink:
        return
          "That YouTube link doesn't point at a single video. Open the video itself and share that link."
      case .youTubeSignInRequired:
        return
          "YouTube won't serve this video to a signed-out client. Sign in under Settings → YouTube Account and try again."
      case .youTubeUnavailable(let reason):
        return "YouTube says: \(reason)"
      case .cancelled:
        return "Cancelled."
      }
    }
  }

  /// Finds every media item reachable from `url`, best candidate first.
  ///
  /// Two paths:
  ///   * The URL *is* media (`…/clip.mp4`, an `.m3u8` manifest, or anything a
  ///     server labels `video/*` or `audio/*`) — resolved with one ranged
  ///     request, no web view.
  ///   * Otherwise it is a page, and the offscreen loader runs Brave's detector
  ///     against it.
  public func extract(from url: URL) async throws -> [PlaylistInfo] {
    guard url.scheme == "http" || url.scheme == "https" else {
      throw ExtractionError.invalidURL
    }

    // YouTube is rewritten before anything else touches the address. The share
    // sheet hands out `youtu.be/<id>` and `/shorts/<id>`, Google Search hands
    // out `/embed/`, and `music.youtube.com` is a different player again — all
    // of which resolve to one ordinary watch page that behaves predictably.
    // Doing this first also means the stored `pageSrc` is the canonical form,
    // which is the address re-extraction reloads once the media URL expires.
    if YouTube.isYouTube(url) {
      guard let canonical = YouTube.canonicalWatchURL(for: url) else {
        // A channel, a playlist index, or the home page: there is no one video
        // here to save, and loading it would just time out.
        throw ExtractionError.noVideoInYouTubeLink
      }
      return try await extractFromPage(canonical)
    }

    if let direct = await directMediaItem(for: url) {
      return [direct]
    }

    return try await extractFromPage(url)
  }

  /// Runs the offscreen detector against a page and enriches what it finds.
  private func extractFromPage(_ url: URL) async throws -> [PlaylistInfo] {
    // Only one extraction at a time: each spins up a web view that loads a full
    // page with media, and running several concurrently is a reliable way to
    // get the app jetsammed for memory on an older device.
    activeLoader?.cancel()

    let loader = PlaylistWebLoader()
    activeLoader = loader

    var items = await loader.load(url: url)
    let playabilityIssue = loader.playabilityIssue
    activeLoader = nil

    guard !items.isEmpty else {
      // When the page explained itself, say what it said. "No downloadable
      // media was found" is actively misleading for a video that YouTube simply
      // refused to serve to a signed-out client.
      switch playabilityIssue {
      case .signInRequired:
        throw ExtractionError.youTubeSignInRequired
      case .unavailable(let reason) where !reason.isEmpty:
        throw ExtractionError.youTubeUnavailable(reason)
      default:
        throw ExtractionError.noMediaFound
      }
    }

    // A task group completes in whatever order the network cooperates, so the
    // index is carried through and the loader's ordering restored afterwards.
    items = await withTaskGroup(of: (Int, PlaylistInfo).self, returning: [PlaylistInfo].self) {
      group in
      for (index, item) in items.enumerated() {
        group.addTask { (index, await Self.enrich(item)) }
      }

      var enriched = [(Int, PlaylistInfo)]()
      for await result in group {
        enriched.append(result)
      }
      return enriched.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // Enrichment is what gives most sites a duration to rank by, so ranking
    // happens after it. YouTube is the exception: the loader has already ranked
    // against the length the watch page itself declared, which is a better
    // signal than anything measurable here, and re-sorting on duration alone
    // would promote a long advert over a short video.
    if !YouTube.isYouTube(url) {
      items = PlaylistWebLoader.rank(items)
    }

    return items
  }

  /// Cancels an in-flight extraction.
  public func cancel() {
    activeLoader?.cancel()
    activeLoader = nil
  }

  /// Re-resolves an item whose media URL has stopped working.
  ///
  /// Media URLs from large sites are signed and time-limited — an item saved
  /// but never downloaded will typically be unplayable within hours. Brave
  /// handles this by silently reloading the original page in a hidden web view
  /// and swapping in the fresh URL, keeping the item's identity, position and
  /// resume point. Same contract here.
  public func refreshExpiredMedia(for item: PlaylistInfo) async -> PlaylistInfo? {
    guard let pageURL = URL(string: item.pageSrc) else { return nil }

    do {
      let items = try await extract(from: pageURL)
      guard let best = items.first else { return nil }

      let updated = item.replacingSource(with: best)

      await withCheckedContinuation { continuation in
        PlaylistItem.updateItem(updated) {
          continuation.resume()
        }
      }

      return updated
    } catch {
      Logger.module.error("Failed to refresh expired media: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Direct media

  /// Builds an item straight from a media URL, or returns nil if it is a page.
  private func directMediaItem(for url: URL) async -> PlaylistInfo? {
    let detector = PlaylistMimeTypeDetector(url: url)
    var mimeType = detector.mimeType

    // A recognisable extension is enough on its own; a signed CDN URL has none,
    // so fall back to asking the server.
    if mimeType == nil {
      guard let contentType = await NowPlayingInfo.getMimeType(url) else { return nil }

      let normalized = contentType.lowercased()
      let looksLikeMedia =
        normalized.hasPrefix("video/")
        || normalized.hasPrefix("audio/")
        || PlaylistMimeTypeDetector.isHLS(mimeType: normalized)
        || normalized.hasPrefix("application/mp4")
        || normalized.hasPrefix("application/ogg")

      // `video/*` is what `getMimeType` returns when a server answers but says
      // nothing about the type — too weak to treat an arbitrary page as media.
      guard looksLikeMedia, normalized != "video/*" else { return nil }
      mimeType = contentType
    }

    let name =
      url.deletingPathExtension().lastPathComponent
      .removingPercentEncoding ?? url.lastPathComponent

    var item = PlaylistInfo(
      name: name.isEmpty ? (url.host ?? "Media") : name,
      src: url.absoluteString,
      pageSrc: url.absoluteString,
      pageTitle: name,
      mimeType: mimeType ?? "video/mp4",
      duration: 0.0,
      lastPlayedOffset: 0.0,
      detected: true,
      dateAdded: Date(),
      tagId: UUID().uuidString,
      order: Int32.min,
      isInvisible: false,
      artworkURL: nil)

    item = await Self.enrich(item)
    return item
  }

  // MARK: - Enrichment

  /// Fills in whatever the detector could not supply.
  ///
  /// Detection reports what the DOM knows, which for a player that has only
  /// just been handed a source is often a title and nothing else. Duration in
  /// particular is worth a network round trip: it drives the library's
  /// subtitle, the scrub bar and the lock screen, and reading it once at add
  /// time avoids doing it on every render.
  private static func enrich(_ item: PlaylistInfo) async -> PlaylistInfo {
    var duration = item.duration
    var artworkURL = item.artworkURL
    var name = item.name

    if duration <= 0, let url = URL(string: item.src) {
      let asset = AVURLAsset(url: url, options: AVAsset.defaultOptions)
      if let loaded = try? await asset.load(.duration) {
        duration = loaded.isIndefinite ? TimeInterval.greatestFiniteMagnitude : loaded.seconds
        if !duration.isFinite || duration < 0 { duration = 0 }
      }
    }

    // Fall back to scraping the page for artwork when the detector saw no
    // og:image — common for iframe-embedded players, where the detector only
    // ever sees the iframe's document.
    if artworkURL == nil, let pageURL = URL(string: item.pageSrc), pageURL.scheme?.hasPrefix("http") == true {
      let metadata = await PageMetadataFetcher.fetch(url: pageURL)
      artworkURL = metadata?.imageURL
      if name.isEmpty || name == item.pageTitle, let title = metadata?.title, !title.isEmpty {
        name = title
      }
    }

    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      name = item.pageTitle.isEmpty ? (URL(string: item.pageSrc)?.host ?? "Media") : item.pageTitle
    }

    return PlaylistInfo(
      name: name,
      src: item.src,
      pageSrc: item.pageSrc,
      pageTitle: item.pageTitle,
      mimeType: item.mimeType,
      duration: duration,
      lastPlayedOffset: item.lastPlayedOffset,
      detected: item.detected,
      dateAdded: item.dateAdded,
      tagId: item.tagId,
      order: item.order,
      isInvisible: item.isInvisible,
      artworkURL: artworkURL)
  }
}
