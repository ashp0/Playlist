// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios
// `Sources/Brave/Frontend/Browser/Playlist/Utilities/PlaylistThumbnailUtility.swift`.
//
// The fallback chain (HLS frame → asset frame → site icon) and the
// `HLSThumbnailGenerator` technique are Brave's. Changes:
//
//   * `SDImageCache` replaced with the local `ImageCache`.
//   * Brave's Combine `Future` chain (`generators.reduce { $0.catch { … } }`)
//     is expressed with `async`/`await`, which is what this chain of
//     fall-throughs actually is.
//   * The final fallback is page artwork (`og:image`) rather than a favicon —
//     a media library wants a poster frame, not a 32px site icon.

import AVFoundation
import CoreImage
import Foundation
import UIKit
import os.log

extension Notification.Name {
  /// Posted with the item's `tagId` as `object` when its cached artwork is
  /// dropped and a better one can now be produced.
  public static let thumbnailInvalidated = Notification.Name(
    "com.overnight.playlist.thumbnailInvalidated")
}

/// Produces artwork for a media item.
///
/// Every source is tried in turn until one yields an image, cheapest first.
public actor ThumbnailRenderer {
  public static let shared = ThumbnailRenderer()

  /// Where in the media to grab a frame from.
  ///
  /// Three seconds in, not zero: the first frame of a video is very often black
  /// or a title card, which makes for a useless library thumbnail.
  private let seekTime: TimeInterval = 3.0

  /// Coalesces concurrent requests for the same item, so a fast scroll through
  /// the library does not start the same expensive generation ten times.
  private var inFlight = [String: Task<UIImage?, Never>]()

  private init() {}

  /// Returns artwork for an item, generating it if necessary.
  ///
  /// - Parameters:
  ///   - localURL: the downloaded file, when the item has one. Always preferred
  ///     — reading a frame from disk is fast and works offline.
  ///   - remoteURL: the media URL, used when there is no local copy.
  ///   - artworkURL: page-supplied artwork, used as the last resort.
  public func thumbnail(
    id: String,
    localURL: URL?,
    remoteURL: URL?,
    artworkURL: URL?
  ) async -> UIImage? {
    let cacheKey = "thumb-\(id)"

    if let cached = await ImageCache.shared.image(forKey: cacheKey) {
      return cached
    }

    if let existing = inFlight[cacheKey] {
      return await existing.value
    }

    let task = Task<UIImage?, Never> { [seekTime] in
      // Page artwork first when there is no local file: it is a single image
      // fetch, against pulling a frame out of a remote video stream.
      if localURL == nil, let artworkURL = artworkURL,
        let image = await Self.loadRemoteImage(url: artworkURL)
      {
        return image
      }

      if let localURL = localURL {
        if let image = await Self.frame(from: localURL, at: seekTime) {
          return image
        }
        // `.movpkg` HLS bundles frequently refuse AVAssetImageGenerator; the
        // player-based path is slower but handles them.
        if let image = await Self.hlsFrame(from: localURL, at: seekTime) {
          return image
        }
      }

      if let artworkURL = artworkURL,
        let image = await Self.loadRemoteImage(url: artworkURL)
      {
        return image
      }

      if let remoteURL = remoteURL, Reachability.shared.connectionStatus == .online {
        if PlaylistMimeTypeDetector.isHLS(url: remoteURL) {
          if let image = await Self.hlsFrame(from: remoteURL, at: seekTime) {
            return image
          }
        }
        if let image = await Self.frame(from: remoteURL, at: seekTime) {
          return image
        }
      }

      return nil
    }

    inFlight[cacheKey] = task
    let image = await task.value
    inFlight[cacheKey] = nil

    if let image = image {
      ImageCache.shared.store(image, forKey: cacheKey)
    }

    return image
  }

  /// Drops a cached thumbnail, e.g. after an item finishes downloading and a
  /// real frame becomes available in place of the page's artwork.
  ///
  /// Posts `.thumbnailInvalidated` so views already on screen re-request it.
  /// Without that, a view that had already resolved its artwork — the mini
  /// player in particular, which outlives every list row — keeps showing
  /// whatever it resolved first, forever.
  public func invalidate(id: String) async {
    ImageCache.shared.remove(forKey: "thumb-\(id)")
    await MainActor.run {
      NotificationCenter.default.post(name: .thumbnailInvalidated, object: id)
    }
  }

  /// A thumbnail already held in memory, or nil.
  ///
  /// `nonisolated` and synchronous on purpose: it lets a view paint a cached
  /// thumbnail during `body`, instead of starting at the placeholder and
  /// swapping in the real image an async hop later. That hop is what produced a
  /// visible flicker every time a row was recycled.
  public nonisolated static func cachedThumbnail(id: String) -> UIImage? {
    ImageCache.shared.imageFromMemory(forKey: "thumb-\(id)")
  }

  // MARK: - Sources

  /// Extracts a frame with `AVAssetImageGenerator`.
  private static func frame(from url: URL, at time: TimeInterval) async -> UIImage? {
    let asset = AVURLAsset(url: url, options: AVAsset.defaultOptions)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // Wide tolerance: the nearest keyframe is fine, and demanding an exact
    // frame forces a decode from the previous keyframe for no visible gain.
    generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 1)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 1)
    generator.maximumSize = CGSize(width: 640, height: 640)

    // Clamp the seek into range — asking for 3s of a 1s clip fails outright.
    var seekSeconds = time
    if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
      seekSeconds = min(time, max(0, duration.seconds / 2))
    }

    do {
      let (cgImage, _) = try await generator.image(
        at: CMTime(seconds: seekSeconds, preferredTimescale: 600))
      return UIImage(cgImage: cgImage)
    } catch {
      Logger.module.debug("Thumbnail generation failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// Extracts a frame from an HLS stream.
  ///
  /// `AVAssetImageGenerator` does not work on HLS. The workaround, from Brave's
  /// `HLSThumbnailGenerator`, is to build a real `AVPlayer` with an attached
  /// `AVPlayerItemVideoOutput`, seek it with the rate at zero, and copy the
  /// pixel buffer the output produces.
  private static func hlsFrame(from url: URL, at time: TimeInterval) async -> UIImage? {
    await withCheckedContinuation { continuation in
      let generator = HLSThumbnailGenerator(url: url, time: time) { image, error in
        if let error = error {
          Logger.module.debug("HLS thumbnail failed: \(String(describing: error))")
        }
        continuation.resume(returning: image)
      }
      // Held until the callback fires; the generator retains itself through its
      // player's KVO observation until then.
      generator.start()
    }
  }

  private static func loadRemoteImage(url: URL) async -> UIImage? {
    if let cached = await ImageCache.shared.image(forKey: url.absoluteString) {
      return cached
    }

    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15.0)
    request.addValue(UserAgent.current, forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let response = response as? HTTPURLResponse,
        (200...299).contains(response.statusCode),
        let image = UIImage(data: data)
      else { return nil }

      ImageCache.shared.store(image, forKey: url.absoluteString)
      return image
    } catch {
      Logger.module.debug("Artwork download failed: \(error.localizedDescription)")
      return nil
    }
  }
}

// MARK: - HLSThumbnailGenerator

public enum HLSThumbnailGeneratorError: Error {
  case cannotLoadItem(url: URL)
  case cannotCopyPixelBuffer
  case cannotSeekToSpecifiedTimeInterval(interval: CMTime)
  case invalidPixelBuffer
  case timedOut
}

/// Grabs a single frame out of an HLS stream.
///
/// Ported from Brave's private class of the same name, with the deinit ordering
/// comment preserved — it documents a real KVO crash, not a stylistic choice.
private final class HLSThumbnailGenerator {
  private enum State {
    case loading
    case ready
    case failed
  }

  private let asset: AVURLAsset
  private var player: AVPlayer?
  private var currentItem: AVPlayerItem?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var observer: NSKeyValueObservation?
  private var state: State = .loading
  private let time: TimeInterval
  private let url: URL
  private var completion: ((UIImage?, HLSThumbnailGeneratorError?) -> Void)?
  private let queue = DispatchQueue(label: "com.overnight.playlist.hls-thumbnail-generator")
  private var timeoutWorkItem: DispatchWorkItem?

  /// Self-retained until the completion fires, then released. Without this the
  /// caller would have to keep the generator alive across an async boundary for
  /// no reason other than KVO's lifetime rules.
  private var selfRetain: HLSThumbnailGenerator?

  init(url: URL, time: TimeInterval, completion: @escaping (UIImage?, HLSThumbnailGeneratorError?) -> Void) {
    self.asset = AVURLAsset(url: url, options: AVAsset.defaultOptions)
    self.url = url
    self.time = time
    self.completion = completion
  }

  func start() {
    selfRetain = self

    let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: nil)
    let player = AVPlayer(playerItem: item)
    // Rate zero: the frame is wanted, not playback — and playback here would
    // hijack the audio session out from under whatever is actually playing.
    player.rate = 0
    player.isMuted = true
    self.player = player
    self.currentItem = player.currentItem

    let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    self.videoOutput = videoOutput

    observer = currentItem?.observe(\.status) { [weak self] item, _ in
      guard let self = self else { return }

      if item.status == .readyToPlay && self.state == .loading {
        self.state = .ready
        self.generateThumbnail(at: self.time)
      } else if item.status == .failed {
        self.state = .failed
        self.finish(nil, .cannotLoadItem(url: self.url))
      }
    }

    player.currentItem?.add(videoOutput)

    // An HLS manifest that never becomes ready would otherwise leave this
    // generator — and its self-retain — alive forever.
    let timeout = DispatchWorkItem { [weak self] in
      self?.finish(nil, .timedOut)
    }
    timeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeout)
  }

  deinit {
    // Must be torn down in this order. There is a bug in iOS where the observed
    // item can deallocate before the observer, and KVO then raises
    // KVO_IS_RETAINING_ALL_OBSERVERS_OF_THIS_OBJECT_IF_IT_CRASHES_AN_OBSERVER_WAS_OVERRELEASED_OR_SMASHED
    // — even with block-based observers. Invalidate first, release second.
    if let videoOutput = videoOutput {
      currentItem?.remove(videoOutput)
    }

    videoOutput = nil
    observer?.invalidate()
    observer = nil
    currentItem = nil
    player = nil
  }

  private func generateThumbnail(at time: TimeInterval) {
    queue.async { [weak self] in
      guard let self = self else { return }

      let cmTime = CMTimeMakeWithSeconds(time, preferredTimescale: 1)
      self.player?.seek(to: cmTime) { [weak self] finished in
        guard let self = self else { return }

        guard finished else {
          self.finish(nil, .cannotSeekToSpecifiedTimeInterval(interval: cmTime))
          return
        }

        self.queue.async {
          guard let buffer = self.videoOutput?.copyPixelBuffer(
            forItemTime: cmTime, itemTimeForDisplay: nil)
          else {
            self.finish(nil, .cannotCopyPixelBuffer)
            return
          }
          self.snapshotPixelBuffer(buffer)
        }
      }
    }
  }

  private func snapshotPixelBuffer(_ buffer: CVPixelBuffer) {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    let quartzFrame = CGRect(
      x: 0, y: 0,
      width: CVPixelBufferGetWidth(buffer),
      height: CVPixelBufferGetHeight(buffer))

    guard let cgImage = CIContext().createCGImage(ciImage, from: quartzFrame) else {
      finish(nil, .invalidPixelBuffer)
      return
    }

    finish(UIImage(cgImage: cgImage), nil)
  }

  /// Fires the completion exactly once and drops the self-retain.
  private func finish(_ image: UIImage?, _ error: HLSThumbnailGeneratorError?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let completion = self.completion else { return }
      self.completion = nil
      self.timeoutWorkItem?.cancel()
      self.timeoutWorkItem = nil
      self.player?.replaceCurrentItem(with: nil)
      completion(image, error)
      self.selfRetain = nil
    }
  }
}
