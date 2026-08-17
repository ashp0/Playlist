// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from the static half of brave-ios
// `Sources/Playlist/PlaylistMediaStreamer.swift` — the Now Playing / lock
// screen plumbing and the MIME-type probe.
//
// The instance half of Brave's `PlaylistMediaStreamer` (which falls back to a
// hidden WKWebView when a media URL has expired) lives in
// `Extraction/MediaExtractor.swift` here, since in a browserless app that is
// extraction rather than streaming.

import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import os.log

/// Publishes playback state to the lock screen, Control Center and CarPlay.
///
/// This is what makes the app feel native while backgrounded. `MPNowPlayingInfoCenter`
/// is a plain dictionary that must be *fully* rewritten to change — mutating a
/// copy and assigning it back is the only supported update path, which is why
/// every method here reads, merges and reassigns.
public enum NowPlayingInfo {

  /// Publishes a newly started item.
  ///
  /// - Parameters:
  ///   - elapsed: where playback is starting from. Pass it whenever a seek has
  ///     been asked for but may not have landed — `AVPlayer` reports the old
  ///     position until it does, and publishing that makes the lock screen
  ///     count up from somewhere the item is not.
  ///   - isAnonymous: when true, everything that identifies the item is
  ///     withheld — see `setAnonymousNowPlayingInfo`.
  public static func setNowPlayingInfo(
    _ item: PlaylistInfo,
    withPlayer player: MediaPlayer,
    elapsed: TimeInterval? = nil,
    isAnonymous: Bool = false
  ) {
    if isAnonymous {
      setAnonymousNowPlayingInfo(item, withPlayer: player, elapsed: elapsed)
      return
    }

    let mediaType: MPNowPlayingInfoMediaType =
      item.mimeType.contains("video") ? .video : .audio

    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo.merge(with: [
      MPNowPlayingInfoPropertyMediaType: NSNumber(value: mediaType.rawValue),
      MPMediaItemPropertyTitle: item.name,
      // The source site stands in for "artist" — it is the only provenance a
      // web-sourced item has, and it is genuinely useful on the lock screen.
      MPMediaItemPropertyArtist: URL(string: item.pageSrc)?.baseDomain ?? item.pageSrc,
      MPMediaItemPropertyPlaybackDuration: playbackDuration(of: item, player: player),
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: player.playbackRate,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime(elapsed, player: player),
    ])

    // NOTE: Brave nils the dictionary out before reassigning it. That produces
    // a visible flicker of empty lock-screen metadata on every track change;
    // a single assignment is atomic from the system's point of view.
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  /// The length the lock screen should draw.
  ///
  /// While a segmented playlist is playing this is the length of the segment,
  /// not of the track it was cut from — the two disagree by design, and the
  /// segment is the one that matches what the listener is about to hear. The
  /// player owns that distinction; see `MediaPlayer.playbackWindow`.
  ///
  /// Otherwise the measured length wins over the one recorded when the item was
  /// added: that one is whatever the page claimed, is sometimes missing
  /// altogether, and a wrong duration is a scrubber that lies for the whole
  /// track.
  private static func playbackDuration(of item: PlaylistInfo, player: MediaPlayer)
    -> TimeInterval
  {
    let presented = player.presentedDuration
    guard presented <= 0 else { return presented }
    return item.duration.isFinite ? item.duration : 0
  }

  /// Where playback is, in whatever timebase `playbackDuration` is reported
  /// against — so the pair the system extrapolates its scrubber from agree.
  private static func elapsedTime(_ elapsed: TimeInterval?, player: MediaPlayer) -> TimeInterval {
    player.presentedTime(for: elapsed ?? player.currentTime.seconds)
  }

  /// Publishes an item with its identity withheld.
  ///
  /// The lock screen and Control Centre are handed a working transport — play,
  /// pause, skip, a timeline — and no title, source, artwork or queue position.
  ///
  /// Built from an empty dictionary rather than merged into the existing one,
  /// which is the whole point: every other method here merges, so a title or an
  /// artwork left over from the previously playing item would survive the
  /// switch and be exactly the thing the user asked not to be shown. What
  /// remains is the timing information the system needs to draw a scrubber that
  /// tracks reality.
  private static func setAnonymousNowPlayingInfo(
    _ item: PlaylistInfo, withPlayer player: MediaPlayer, elapsed: TimeInterval? = nil
  ) {
    let mediaType: MPNowPlayingInfoMediaType =
      item.mimeType.contains("video") ? .video : .audio

    let nowPlayingInfo: [String: Any] = [
      MPNowPlayingInfoPropertyMediaType: NSNumber(value: mediaType.rawValue),
      MPMediaItemPropertyPlaybackDuration: playbackDuration(of: item, player: player),
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: player.playbackRate,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime(elapsed, player: player),
    ]

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  /// Strips identifying fields from whatever is currently published.
  ///
  /// Used when a playlist is anonymised *while* one of its items is playing:
  /// the dynamic fields are correct already and re-publishing the item would
  /// restart the scrubber, so only the identity is removed.
  public static func removeIdentifyingInfo() {
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

    for key in [
      MPMediaItemPropertyTitle,
      MPMediaItemPropertyArtist,
      MPMediaItemPropertyAlbumTitle,
      MPMediaItemPropertyArtwork,
      MPNowPlayingInfoPropertyPlaybackQueueIndex,
      MPNowPlayingInfoPropertyPlaybackQueueCount,
    ] {
      nowPlayingInfo.removeValue(forKey: key)
    }

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  /// Refreshes the fields that change during playback.
  ///
  /// Must be called on pause, resume, seek and rate change: iOS extrapolates
  /// the scrub position from `elapsedPlaybackTime` and `playbackRate`, so a
  /// stale pair makes the lock-screen scrubber drift away from reality. A skip
  /// that never publishes leaves it counting up from the position skipped away
  /// from, which is the same amount wrong for the rest of the track.
  ///
  /// - Parameter elapsed: where playback is, or is about to be. Pass it when a
  ///   seek has been asked for and may not have landed yet; `AVPlayer` reports
  ///   the position it is leaving until it does.
  public static func updateNowPlayingInfo(_ player: MediaPlayer, elapsed: TimeInterval? = nil) {
    let mediaType: MPNowPlayingInfoMediaType =
      player.currentItem?.isVideoTracksAvailable() == true ? .video : .audio

    // Both read through the player's presentation window, so a segmented
    // playlist's timeline stays the segment's for the whole of it rather than
    // reverting to the track's on the first pause.
    let duration = player.presentedDuration
    let position = elapsedTime(elapsed, player: player)

    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo.merge(with: [
      MPNowPlayingInfoPropertyMediaType: NSNumber(value: mediaType.rawValue),
      MPMediaItemPropertyPlaybackDuration: duration.isFinite ? duration : 0.0,
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: player.playbackRate,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position.isFinite ? position : 0.0,
    ])

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  /// Publishes queue position, so Control Center can show "3 of 12".
  public static func setQueuePosition(index: Int, count: Int) {
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo.merge(with: [
      MPNowPlayingInfoPropertyPlaybackQueueIndex: NSNumber(value: index),
      MPNowPlayingInfoPropertyPlaybackQueueCount: NSNumber(value: count),
    ])
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  public static func clearNowPlayingInfo() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
  }

  public static func setPlaybackState(_ isPlaying: Bool) {
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }

  public static func setNowPlayingMediaArtwork(image: UIImage?) {
    guard let image = image else {
      var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
      return
    }

    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ -> UIImage in
      // Per Apple, do not resize here — the system requests the size it wants
      // and resizing eagerly is wasted work.
      image
    }

    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  // MARK: - MIME type probing

  /// Asks a server what a media URL actually is.
  ///
  /// A one-byte ranged GET rather than a HEAD: a surprising number of media
  /// CDNs either do not implement HEAD or answer it with a different
  /// Content-Type than they use for the real transfer. Requesting `bytes=0-1`
  /// gets the true response headers for the cost of two bytes.
  public static func getMimeType(_ url: URL) async -> String? {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
    request.addValue("bytes=0-1", forHTTPHeaderField: "Range")
    request.addValue(UUID().uuidString, forHTTPHeaderField: "X-Playback-Session-Id")
    request.addValue(UserAgent.current, forHTTPHeaderField: "User-Agent")

    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }

    do {
      let (_, response) = try await session.data(for: request)

      guard let response = response as? HTTPURLResponse,
        response.statusCode == 302 || (200...299).contains(response.statusCode)
      else { return nil }

      if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
        return contentType
      }

      // Reachable and serving bytes, but silent about the type. Brave's
      // convention: assume video and let AVFoundation sort it out.
      return "video/*"
    } catch {
      Logger.module.error("Error fetching MIME type: \(error.localizedDescription)")
      return nil
    }
  }

  /// Whether an asset can actually be played.
  ///
  /// Adapted from Brave's `PlaylistMediaStreamer.loadAssetPlayability`. The
  /// offline branch matters: with no network we cannot verify anything, and
  /// assuming "playable" gives a local file a chance to play, whereas assuming
  /// the opposite guarantees a false error on a perfectly good download.
  public static func loadAssetPlayability(asset: AVURLAsset) async -> Bool {
    if case .loaded(let value) = asset.status(of: .isPlayable), value {
      return true
    }

    switch Reachability.shared.connectionStatus {
    case .offline, .unknown:
      Logger.module.debug("Couldn't verify asset playability — offline")
      return true

    case .online:
      return (try? await asset.load(.isPlayable)) == true
    }
  }
}
