// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// No upstream counterpart. Brave plays every item whole.

import Foundation

/// The stretch of one item a segmented playlist wants played this time round.
///
/// A playlist can be given a segment length — say three minutes — which makes
/// it play the first three minutes of each item in turn rather than each item
/// end to end. Coming back to an item plays the *next* three minutes, and so on
/// until every item has been played in full, at which point the playlist starts
/// again from the first segment of the first item.
///
/// The arithmetic lives here, away from `PlaybackController`, because it is the
/// part with edge cases worth testing directly: an item shorter than the
/// segment, a final segment shorter than the rest, and an index that has run
/// past the end of the item and has to wrap.
public struct PlaylistSegment: Equatable {
  /// Which segment of the item this is, counting from zero.
  public let index: Int
  /// How many segments the item divides into.
  public let count: Int
  /// Where playback starts, in seconds from the beginning of the item.
  public let start: TimeInterval
  /// Where playback moves on to the next item, in seconds.
  public let end: TimeInterval

  /// Whether this is the last stretch the item has to give.
  public var isFinal: Bool { index == count - 1 }

  public var duration: TimeInterval { end - start }

  /// A tolerance for the "is this item longer than one segment?" question.
  ///
  /// Durations arrive from `AVAsset` and from page metadata, and neither is
  /// exact. Without slack, a three-minute song in a three-minute playlist can
  /// come back as 180.02 s and get cut a fiftieth of a second before its end,
  /// leaving an item that is chopped for no reason a listener could perceive.
  private static let tolerance: TimeInterval = 1.0

  /// How many times a playlist has to come back to an item before it has played
  /// all of it.
  ///
  /// One is the answer for a playlist with no segment length set, for media
  /// whose duration is unknown or infinite (a live stream cannot be divided),
  /// and — deliberately — for any item no longer than a single segment: a song
  /// shorter than the segment is an ordinary song, played whole, and one pass
  /// is all it takes.
  ///
  /// Expressed as a count rather than as the nil `make` answers with, because
  /// this is the question a playlist asks about every item in the queue —
  /// including the ones it plays whole — when working out whether it has been
  /// through everything.
  public static func count(length: TimeInterval, itemDuration: TimeInterval) -> Int {
    guard length > 0, length.isFinite else { return 1 }
    guard itemDuration.isFinite, itemDuration > 0 else { return 1 }
    guard itemDuration > length + tolerance else { return 1 }

    let count = Int((itemDuration / length).rounded(.up))

    // An item that overruns a whole number of segments by a fraction of a
    // second would otherwise gain a segment lasting that fraction, which is a
    // switch to the next item and back for no audible content. Fold it into the
    // segment before it instead.
    if count > 1, itemDuration - TimeInterval(count - 1) * length < tolerance {
      return count - 1
    }

    return max(1, count)
  }

  /// The segment at `index`, or nil when the item should play whole.
  ///
  /// Nil is the answer wherever `count` is one — see there for which items
  /// those are.
  public static func make(
    index: Int,
    length: TimeInterval,
    itemDuration: TimeInterval
  ) -> PlaylistSegment? {
    let count = count(length: length, itemDuration: itemDuration)
    guard count > 1 else { return nil }

    // A stored index survives the segment length being changed, and a shorter
    // item being re-measured, so it cannot be trusted to be in range. It is
    // also allowed to sit one past the end, which is how an item that has
    // played all of itself is recorded.
    let wrapped = ((index % count) + count) % count
    let start = TimeInterval(wrapped) * length

    return PlaylistSegment(
      index: wrapped,
      count: count,
      start: start,
      // The last segment runs to the end of the item, so that between them the
      // segments cover all of it and nothing is ever skipped.
      end: wrapped == count - 1 ? itemDuration : start + length)
  }

  /// The segment that contains `time`.
  ///
  /// Used when a playlist is given a segment length while one of its items is
  /// already playing: carrying on inside the segment the listener is in is far
  /// less startling than jumping back to a boundary they passed minutes ago.
  public static func make(
    containing time: TimeInterval,
    length: TimeInterval,
    itemDuration: TimeInterval
  ) -> PlaylistSegment? {
    guard length > 0, length.isFinite else { return nil }
    let index = time.isFinite && time > 0 ? Int(time / length) : 0
    return make(index: index, length: length, itemDuration: itemDuration)
  }
}
