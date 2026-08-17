// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// This file has no single upstream counterpart. In brave-ios the same
// responsibilities are spread across
// `Playlist/Controllers/PlaylistViewController.swift` (1009 lines),
// `PlaylistListViewController.swift` (973 lines) and
// `Managers & Cache/PlaylistCarplayManager.swift` — all of which are UIKit view
// controllers wired into the browser, holding a `MediaPlayer` and deciding what
// plays next in between managing table views, popovers and browser tabs.
//
// Extracting the browser meant extracting that logic into something a view can
// simply observe. The behaviours themselves — resume-from-offset, repeat modes,
// the expired-media refresh, "next" semantics — follow Brave's.

import AVFoundation
import Combine
import CoreData
import Foundation
import MediaPlayer
import SwiftUI
import os.log

/// Drives playback and owns the queue.
///
/// One instance for the whole app, injected into the SwiftUI environment. It
/// deliberately outlives every view: audio has to keep playing with no UI on
/// screen at all, which is the entire point of a background media player.
@MainActor
public final class PlaybackController: ObservableObject {

  /// The app's one playback controller.
  ///
  /// `RootView` still owns it as a `@StateObject`; the singleton exists so that
  /// code with no view to hang off — an App Intent run from Shortcuts, which
  /// may be executing in a process that has no scene at all — reaches the same
  /// instance rather than starting a second player.
  public static let shared = PlaybackController()

  // MARK: - Published state

  @Published public private(set) var currentItem: PlaylistInfo?
  @Published public private(set) var isPlaying = false
  @Published public private(set) var isBuffering = false
  @Published public private(set) var currentTime: TimeInterval = 0
  @Published public private(set) var duration: TimeInterval = 0
  @Published public private(set) var isVideo = true

  /// The play order. Reordering this reorders playback, not the library.
  @Published public private(set) var queue = [PlaylistInfo]()
  @Published public private(set) var currentIndex: Int?

  @Published public private(set) var repeatMode: MediaPlayer.RepeatMode = .none
  @Published public private(set) var isShuffleEnabled = false
  @Published public var playbackRate: Float = 1.0 {
    didSet {
      guard playbackRate != oldValue else { return }
      player.setPlaybackRate(rate: playbackRate)
      NowPlayingInfo.updateNowPlayingInfo(player)
    }
  }

  /// Non-nil while a sleep timer is counting down.
  @Published public private(set) var sleepTimer: SleepTimer?

  /// User-facing error from the last failed load, if any.
  @Published public var errorMessage: String?

  /// True while a stale media URL is being re-resolved.
  @Published public private(set) var isRefreshingMedia = false

  /// Artwork for the item now playing.
  @Published public private(set) var artwork: UIImage?

  /// The playlist the current item belongs to, and whether it is anonymised.
  @Published public private(set) var currentPlaylist: CurrentPlaylist?

  /// The stretch of the current item this playlist asked for, or nil when the
  /// item plays whole — which is the case for every item in an ordinary
  /// playlist. See `PlaylistSegment`.
  ///
  /// Every assignment hands the same stretch to the player, which is what makes
  /// the lock screen, Control Centre and the remote skip buttons describe and
  /// operate on the segment rather than on the whole track. Done in an observer
  /// rather than at each site because there are eight of those, spread across
  /// loading, skipping, scrubbing and reacting to a setting changed elsewhere,
  /// and a single one of them forgetting is a timeline that quietly reverts to
  /// the track's length mid-playback.
  @Published public private(set) var currentSegment: PlaylistSegment? {
    didSet {
      guard currentSegment != oldValue else { return }
      player.playbackWindow = currentSegment.flatMap { segment in
        // A stored index measured against a length the item no longer has can
        // produce a degenerate stretch. An empty window would tell the lock
        // screen the track is zero seconds long, which is worse than telling it
        // nothing.
        segment.end > segment.start ? segment.start...segment.end : nil
      }
    }
  }

  /// Whether what is playing withholds its identity from the lock screen.
  public var isAnonymous: Bool { currentPlaylist?.isAnonymous ?? false }

  /// How far through the stretch being played playback is, from 0 to 1.
  ///
  /// Measured against the segment when there is one, so the mini player's
  /// hairline agrees with the player's own scrubber and with the lock screen,
  /// rather than creeping through a track the playlist will move on from long
  /// before its end. Zero for live media, which has nowhere to be through.
  public var progressFraction: Double {
    if let segment = currentSegment, segment.duration > 0 {
      return min(1, max(0, (currentTime - segment.start) / segment.duration))
    }

    guard duration > 0, duration.isFinite else { return 0 }
    return min(1, max(0, currentTime / duration))
  }

  /// The folder an item is filed under, as playback needs it: a name to show
  /// in the options menu, a flag to obey, and how much of each item to play. A
  /// snapshot rather than the managed object, so nothing here holds a CoreData
  /// row across a save.
  public struct CurrentPlaylist: Equatable {
    public let uuid: String
    public let title: String
    public let isAnonymous: Bool
    /// Seconds of each item to play before moving on; zero for "all of it".
    public let segmentDuration: TimeInterval
  }

  // MARK: - Internals

  public let player = MediaPlayer()

  /// The queue as it was before shuffle was turned on, so it can be restored.
  private var unshuffledQueue: [PlaylistInfo]?

  private var cancellables = Set<AnyCancellable>()
  private var loadTask: Task<Void, Never>?
  private var artworkTask: Task<Void, Never>?
  private var sleepTimerTask: Task<Void, Never>?
  private var hasSeekedToResumePoint = false

  /// Segment progress per item id.
  ///
  /// Backed by `PlaylistItem.segmentIndex`, but cached here because that write
  /// goes through a background context and lands asynchronously: an item can
  /// finish a segment and be asked for its next one within the same run loop —
  /// a one-item playlist on repeat does exactly that — and a re-read would
  /// still see the old value and replay the segment just finished.
  private var segmentIndices = [String: Int]()

  /// Identifies the stretch of audio being played — a whole item, or one
  /// segment of one — so that its end is acted on exactly once.
  ///
  /// The end of a stretch is reported twice over. The boundary watcher sees
  /// playback pass the end of a segment, and `AVPlayer` posts its own
  /// end-of-item notification for the last segment of an item, which ends where
  /// the item does. Worse, a repeat that reloads the asset already loaded keeps
  /// the very same `AVPlayerItem`, so that notification can arrive *after*
  /// playback has been sent back to an earlier stretch of it. Taking both would
  /// advance the playlist two stretches at a time, which is how a listener ends
  /// up hearing every other segment.
  private var stretchID = 0
  /// The stretch whose end has already been acted on.
  private var finishedStretchID: Int?

  /// Private: there is one player, and a second one would fight the first for
  /// the audio session and the remote command centre.
  private init() {
    repeatMode = player.repeatState
    isShuffleEnabled = player.isShuffleEnabled
    playbackRate = player.playbackRate

    observePlayer()
    observeThumbnailInvalidation()
  }

  // MARK: - Starting playback

  /// Starts playback for an item the user picked out of a list.
  ///
  /// Picking the item that is already playing does nothing, deliberately.
  /// Loading it again would seek back to its stored resume point — so a tap on
  /// the row you are listening to, which is the easiest tap in the app to make
  /// by accident, would throw away your place in it.
  ///
  /// Separate from `play(item:in:)` because that one is the unconditional
  /// primitive: "Play All", a Shortcut and an automatic advance all have to
  /// start a queue whether or not the item at the front of it is the one
  /// already loaded.
  public func select(item: PlaylistInfo, in queue: [PlaylistInfo]) {
    guard currentItem?.tagId != item.tagId else { return }
    play(item: item, in: queue)
  }

  /// Plays the queue entry the user tapped, ignoring a tap on the current one.
  public func select(at index: Int) {
    guard index != currentIndex else { return }
    play(at: index)
  }

  /// Plays `item`, using `queue` as the surrounding play order.
  ///
  /// The queue is passed in rather than read from the library because what
  /// plays next should follow the list the user was actually looking at —
  /// a search result, a folder, a sort order — not the library's global order.
  public func play(item: PlaylistInfo, in queue: [PlaylistInfo]) {
    let resolvedQueue = queue.isEmpty ? [item] : queue

    if isShuffleEnabled {
      unshuffledQueue = resolvedQueue
      self.queue = Self.shuffled(resolvedQueue, startingWith: item)
    } else {
      unshuffledQueue = nil
      self.queue = resolvedQueue
    }

    currentIndex = self.queue.firstIndex(where: { $0.tagId == item.tagId }) ?? 0
    load(item: item, autoPlay: true)
  }

  /// Plays a whole playlist, in the library's current sort order.
  ///
  /// Exists for Shortcuts, which hands over a playlist rather than an item —
  /// and which may be running in a process with no UI at all, so the queue
  /// cannot come from a view the way it does everywhere else.
  ///
  /// - Returns: how many items were queued. Zero means the playlist is gone or
  ///   empty, which the caller reports rather than silently doing nothing.
  @discardableResult
  public func play(folderUUID: String, shuffled: Bool = false) -> Int {
    let items =
      PlaylistItem.all(
        where: NSPredicate(format: "playlistFolder.uuid == %@", folderUUID),
        sortDescriptors: PlaylistItem.sortDescriptors(for: PlaylistManager.shared.sortOrder)
      )?.map { PlaylistInfo(item: $0) } ?? []

    guard !items.isEmpty else { return 0 }

    setShuffle(shuffled)

    // Shuffling from a fixed first item would always open with the same track;
    // starting from a random one is what "shuffle this playlist" means.
    let start = shuffled ? (items.randomElement() ?? items[0]) : items[0]
    play(item: start, in: items)

    return items.count
  }

  /// Plays whatever is at `index` in the existing queue.
  public func play(at index: Int) {
    guard queue.indices.contains(index) else { return }
    currentIndex = index
    load(item: queue[index], autoPlay: true)
  }

  public func togglePlayPause() {
    if isPlaying {
      player.pause()
    } else {
      // Re-claim the audio session: another app may have taken it while we
      // were paused, and playing without it produces silence.
      player.activateAudioSession()
      player.play()
    }
  }

  public func pause() {
    player.pause()
  }

  /// Stops playback and clears Now Playing.
  public func stop() {
    loadTask?.cancel()
    artworkTask?.cancel()
    persistPlaybackPosition()

    player.stop()
    player.deactivateAudioSession()
    NowPlayingInfo.clearNowPlayingInfo()

    currentItem = nil
    currentIndex = nil
    currentPlaylist = nil
    currentSegment = nil
    queue = []
    unshuffledQueue = nil
    artwork = nil
    currentTime = 0
    duration = 0
    cancelSleepTimer()
  }

  // MARK: - Anonymised playlists

  /// Hides (or restores) the current item's playlist on the lock screen.
  ///
  /// The setting belongs to the folder and is written straight through to it,
  /// so it holds for every item in that playlist and survives relaunches.
  public func setAnonymous(_ isAnonymous: Bool) {
    guard let playlist = currentPlaylist, playlist.isAnonymous != isAnonymous else { return }

    currentPlaylist = CurrentPlaylist(
      uuid: playlist.uuid,
      title: playlist.title,
      isAnonymous: isAnonymous,
      segmentDuration: playlist.segmentDuration)
    PlaylistFolder.setAnonymous(uuid: playlist.uuid, isAnonymous: isAnonymous)

    publishNowPlayingIdentity()
  }

  /// Re-reads the current item's playlist and brings playback into line with it.
  ///
  /// For changes made from somewhere other than the player — the library's own
  /// playlist menu — which may well name the folder that is playing: hiding it
  /// from the lock screen, or giving it a segment length.
  public func reapplyPlaylistSettings() {
    guard let item = currentItem else { return }

    let wasAnonymous = isAnonymous
    refreshCurrentPlaylist(for: item)
    adoptSegmentAtCurrentPosition(for: item)
    // A stretch measured against the old setting is not the one playing now.
    rearmStretch()

    guard wasAnonymous != isAnonymous else { return }
    publishNowPlayingIdentity()
  }

  /// Reads the current item's folder back out of the library.
  private func refreshCurrentPlaylist(for item: PlaylistInfo) {
    guard let folder = PlaylistFolder.folder(forItemId: item.tagId), let uuid = folder.uuid else {
      currentPlaylist = nil
      return
    }

    currentPlaylist = CurrentPlaylist(
      uuid: uuid,
      title: folder.title,
      isAnonymous: folder.isAnonymous,
      segmentDuration: folder.segmentDuration)
  }

  /// Brings the lock screen's identifying fields in line with the current
  /// anonymity setting, leaving the timeline alone.
  ///
  /// Re-publishing the whole item would reset `elapsedPlaybackTime` to whatever
  /// the player reports at this instant, which the system reads as a seek.
  private func publishNowPlayingIdentity() {
    guard let item = currentItem else { return }

    guard !isAnonymous else {
      NowPlayingInfo.removeIdentifyingInfo()
      return
    }

    NowPlayingInfo.setNowPlayingInfo(item, withPlayer: player)
    if let index = currentIndex {
      NowPlayingInfo.setQueuePosition(index: index, count: queue.count)
    }
    NowPlayingInfo.setNowPlayingMediaArtwork(image: artwork)
  }

  // MARK: - Segments

  /// Whether the playlist now playing divides its items into segments.
  private var isSegmentedPlaylist: Bool { (currentPlaylist?.segmentDuration ?? 0) > 0 }

  /// Forgets cached segment progress after a playlist has been sent back to
  /// its first segment in the library.
  ///
  /// If that playlist is the one playing, the item on screen goes back to the
  /// top too — "start over" that left the current item mid-way through would
  /// not have started anything over.
  public func forgetSegmentProgress(inPlaylist uuid: String) {
    // Cheaper to drop the lot than to work out which ids belonged to that
    // playlist; anything else is read back from the library on demand.
    segmentIndices.removeAll()

    guard let item = currentItem, currentPlaylist?.uuid == uuid else { return }

    guard let segment = resolveSegment(for: item) else {
      currentSegment = nil
      return
    }

    currentSegment = segment
    beginStretch()
    seek(to: segment.start)
  }

  /// The stretch of `item` this playlist wants, or nil to play it whole.
  private func resolveSegment(for item: PlaylistInfo) -> PlaylistSegment? {
    guard let playlist = currentPlaylist else { return nil }

    return PlaylistSegment.make(
      index: segmentIndex(for: item.tagId),
      length: playlist.segmentDuration,
      itemDuration: resolvedDuration(of: item))
  }

  /// How many stretches this playlist divides `item` into; one for an item it
  /// plays whole.
  private func segmentCount(of item: PlaylistInfo) -> Int {
    PlaylistSegment.count(
      length: currentPlaylist?.segmentDuration ?? 0,
      itemDuration: resolvedDuration(of: item))
  }

  /// Whether `item` still owes this pass through the playlist a stretch.
  ///
  /// False once it has played all of itself, which is what lets the playlist
  /// tell "there is more of this to hear" from "everything has been played".
  private func hasUnplayedSegments(_ item: PlaylistInfo) -> Bool {
    segmentIndex(for: item.tagId) < segmentCount(of: item)
  }

  /// The item's length as well as it is known: what the asset reports for the
  /// item that is loaded, what was stored at add time for the rest of the queue.
  private func resolvedDuration(of item: PlaylistInfo) -> TimeInterval {
    guard item.tagId == currentItem?.tagId else { return item.duration }
    return duration.isFinite && duration > 0 ? duration : item.duration
  }

  /// Re-reads the playlist's segment length against what is playing right now.
  ///
  /// Giving a playlist a segment length while one of its items is playing picks
  /// the segment the listener is already inside, rather than dragging them back
  /// to a boundary they passed minutes ago; the item's stored progress moves to
  /// match, so the next pass carries on from there.
  private func adoptSegmentAtCurrentPosition(for item: PlaylistInfo) {
    guard let playlist = currentPlaylist, playlist.segmentDuration > 0 else {
      currentSegment = nil
      return
    }

    let segment = PlaylistSegment.make(
      containing: currentTime,
      length: playlist.segmentDuration,
      itemDuration: resolvedDuration(of: item))

    currentSegment = segment

    if let segment = segment, segment.index != segmentIndex(for: item.tagId) {
      setSegmentIndex(segment.index, for: item.tagId)
    }
  }

  /// Picks up the current item's segment once its length becomes known.
  ///
  /// An item whose duration could not be measured when it loaded — a stream
  /// that reports nothing until it is actually playing — cannot be divided at
  /// that point, and without this it would go on playing whole in a playlist
  /// that asked for three minutes of it.
  private func resolveSegmentIfPending() {
    // `hasSeekedToResumePoint` stands in for "the item now current is the one
    // the player is playing": between the two, the outgoing item is still
    // playing and still reporting *its* length, and dividing the incoming item
    // by that would land on a boundary belonging to neither.
    guard hasSeekedToResumePoint,
      currentSegment == nil, isSegmentedPlaylist, finishedStretchID != stretchID,
      let item = currentItem,
      let segment = resolveSegment(for: item)
    else { return }

    currentSegment = segment
    setSegmentIndex(segment.index, for: item.tagId)

    // Only if playback is already outside the stretch the playlist asked for:
    // a listener a minute into an item does not want to be sent back to a
    // boundary they have passed.
    if currentTime < segment.start || currentTime >= segment.end {
      seek(to: segment.start)
    }
  }

  /// Where to drop the needle inside a segment about to play.
  ///
  /// The resume point still counts, but only when it falls inside *this*
  /// segment: pausing part-way through and coming back should not restart the
  /// segment, and a resume point left over from a different one must not drag
  /// playback outside the stretch the playlist asked for.
  private func startOfSegment(_ segment: PlaylistSegment, for item: PlaylistInfo) -> TimeInterval {
    guard Preferences.Playlist.playbackLeftOff.value else { return segment.start }

    let resume = item.lastPlayedOffset
    guard resume > segment.start, resume < segment.end - 5.0 else { return segment.start }
    return resume
  }

  /// What was playing has run out.
  ///
  /// One method for two events, because downstream they are the same one: an
  /// item's last segment ends exactly when the item does, and an item played
  /// whole is a single stretch that happens to be all of it.
  private func stretchDidFinish() {
    guard let item = currentItem else { return }

    endCurrentStretch(for: item)

    if sleepTimer?.mode == .endOfTrack {
      sleepTimerFired()
      return
    }

    guard Preferences.Playlist.autoPlayNext.value else {
      player.pause()
      // An item that ran out has already stopped as far as `AVPlayer` is
      // concerned, so `pause` has nothing to do and publishes nothing.
      syncPlaybackFlags()
      return
    }

    next(isAutomatic: true)
  }

  /// Closes off the stretch that is playing, whether it ran out or the listener
  /// skipped past it.
  ///
  /// The item's progress moves on, the boundary watcher is disarmed, and the
  /// place inside the stretch is dropped — coming back to this item plays the
  /// stretch *after* this one, from its start.
  private func endCurrentStretch(for item: PlaylistInfo) {
    advanceSegmentProgress(for: item)
    currentSegment = nil
    finishedStretchID = stretchID

    // Reaching the end of a stretch clears the resume point, the same way
    // reaching the end of an item does.
    PlaylistManager.shared.updateLastPlayed(item: item, playTime: 0)
  }

  /// Marks the start of a stretch: a newly loaded item, or the next segment of
  /// the one already loaded. See `stretchID`.
  private func beginStretch() {
    stretchID &+= 1
  }

  /// Puts a stretch that has already run out back in play.
  ///
  /// Its end counts again, and the resume point starts being recorded again.
  /// No-op for a stretch that is still going, which is all but one of the
  /// times this is asked.
  private func rearmStretch() {
    guard finishedStretchID == stretchID else { return }
    beginStretch()
  }

  /// Moves an item past the stretch of it that has just been played.
  ///
  /// The index counts up to the item's segment count and stops there rather
  /// than wrapping. Reaching it is what records "this item has played all of
  /// itself", which is in turn how the playlist knows it has been through
  /// everything and can start again. An item the playlist plays whole counts as
  /// one segment, so a single pass finishes it too.
  private func advanceSegmentProgress(for item: PlaylistInfo) {
    guard isSegmentedPlaylist else { return }

    let played = currentSegment?.index ?? segmentIndex(for: item.tagId)
    setSegmentIndex(min(played + 1, segmentCount(of: item)), for: item.tagId)
  }

  /// Puts an item back to the stretch it was last heard playing.
  ///
  /// An item's progress moves on the moment its stretch ends, so by the time
  /// "previous" is pressed the item before this one is already pointing at the
  /// stretch *after* the one that was just heard. Going back has to mean going
  /// back to that one.
  private func rewindSegmentProgress(of item: PlaylistInfo) {
    guard isSegmentedPlaylist else { return }

    let index = segmentIndex(for: item.tagId)
    guard index > 0 else { return }
    setSegmentIndex(index - 1, for: item.tagId)
  }

  /// Sends every item in the queue back to its first segment.
  ///
  /// Called once the playlist has been played through in full — every item,
  /// every segment — so the next time round starts from the beginning rather
  /// than from a queue of items that all report having nothing left to give.
  private func restartSegmentCycle() {
    for item in queue {
      segmentIndices[item.tagId] = 0
    }
    PlaylistItem.resetSegmentIndices(uuids: queue.map(\.tagId))

    reshuffleForNextPass()
  }

  private func segmentIndex(for itemId: String) -> Int {
    if let cached = segmentIndices[itemId] { return cached }

    let stored = Int(PlaylistItem.getItem(uuid: itemId)?.segmentIndex ?? 0)
    segmentIndices[itemId] = stored
    return stored
  }

  private func setSegmentIndex(_ index: Int, for itemId: String) {
    guard segmentIndices[itemId] != index else { return }

    segmentIndices[itemId] = index
    PlaylistItem.updateSegmentIndex(uuid: itemId, segmentIndex: index)
  }

  // MARK: - Transport

  public func seek(to time: TimeInterval) {
    player.seek(to: time)
    // Published from where playback is *going*, not from where the player says
    // it is: the seek is asynchronous, and `AVPlayer` reports the old position
    // until it lands. The observer for the landing publishes again.
    currentTime = time

    // Scrubbing back into a stretch that has already run out puts it back in
    // play — it can end a second time, and that end has to count. In a
    // segmented playlist the stretch now playing is whichever one the new
    // position falls inside, not the one the item's progress had moved on to.
    if finishedStretchID == stretchID {
      rearmStretch()
      if let item = currentItem, isSegmentedPlaylist {
        adoptSegmentAtCurrentPosition(for: item)
      }
    }

    publishNowPlayingTimeline()
  }

  public func seekForward() {
    player.seekForwards()
  }

  public func seekBackward() {
    player.seekBackwards()
  }

  /// Republishes the pair the lock screen extrapolates its scrubber from.
  ///
  /// `currentTime` rather than the player's own clock, for the reason given in
  /// `seek(to:)`.
  private func publishNowPlayingTimeline() {
    NowPlayingInfo.updateNowPlayingInfo(player, elapsed: currentTime)
  }

  /// Whether the player is sitting where an item that has just ended would be.
  ///
  /// Distinguishes a real end-of-item from a stale notification about one — see
  /// `stretchID`. An item of unknown length has no other end to be at.
  private var isAtEndOfItem: Bool {
    let end = player.duration.seconds
    guard end.isFinite, end > 0 else { return true }
    return player.currentTime.seconds >= end - 0.5
  }

  /// Advances to whatever the playlist should play next.
  ///
  /// - Parameter isAutomatic: `true` when what was playing ran out on its own.
  ///   Repeat-one only restarts on automatic advance — a user pressing "next"
  ///   with repeat-one on wants to move on, not to hear the same thing again.
  public func next(isAutomatic: Bool = false) {
    guard let currentIndex = currentIndex else { return }

    if isAutomatic, repeatMode == .repeatOne {
      replayCurrentItem()
      return
    }

    // A skip gives up on the stretch that is playing: it counts as played, so
    // the playlist carries on past it rather than coming back to it. Without
    // this, skipping through a segmented playlist leaves every item pointing at
    // the segment it was already on, and the next pass plays exactly the same
    // stretches over again.
    if !isAutomatic, isSegmentedPlaylist, let item = currentItem {
      endCurrentStretch(for: item)
    }

    guard isSegmentedPlaylist else {
      advanceThroughQueue(from: currentIndex)
      return
    }

    advanceThroughCycle(from: currentIndex)
  }

  /// The ordinary advance: the next item along, wrapping when the playlist
  /// repeats.
  private func advanceThroughQueue(from index: Int) {
    let nextIndex = index + 1

    if nextIndex >= queue.count {
      guard repeatMode == .repeatAll, !queue.isEmpty else {
        // End of the queue. Stay on the last item, paused at its end, rather
        // than tearing down — the user can still scrub back.
        stopAtEndOfQueue()
        return
      }

      reshuffleForNextPass()
      play(at: 0)
      return
    }

    play(at: nextIndex)
  }

  /// The advance for a playlist that plays its items in segments.
  ///
  /// Playback moves to the next item that still owes this pass a stretch, so a
  /// repeating playlist works through every segment of every item — a bit of
  /// each in turn — instead of replaying the stretches it has already played.
  /// Once nothing is left the playlist has been through in full, and it starts
  /// again from the first segment of the first item.
  private func advanceThroughCycle(from index: Int) {
    if let next = nextUnplayedIndex(after: index) {
      play(at: next)
      return
    }

    // Repeat-one never leaves the item it is on, so a skip with nowhere else to
    // go means that item's next stretch. Pausing instead would leave the one
    // control that is supposed to move things along stopping playback in the
    // middle of an item with more of itself still to play.
    if repeatMode == .repeatOne, currentItem != nil {
      replayCurrentItem()
      return
    }

    guard repeatMode == .repeatAll, !queue.isEmpty else {
      stopAtEndOfQueue()
      return
    }

    restartSegmentCycle()
    play(at: 0)
  }

  /// Comes to rest at the end of a queue that does not repeat.
  ///
  /// NOTE: `pause` alone is not enough, though it reads as if it should be. An
  /// item that has run out has already stopped as far as `AVPlayer` is
  /// concerned, so `MediaPlayer.pause` guards itself out, publishes nothing, and
  /// leaves `isPlaying` true — every play button in the app then draws as a
  /// pause button that does nothing when pressed. The flags are read back from
  /// the player by hand for that reason.
  private func stopAtEndOfQueue() {
    player.pause()
    syncPlaybackFlags()
    NowPlayingInfo.setPlaybackState(false)
    publishNowPlayingTimeline()
  }

  /// The next item in the queue with a stretch still to play, or nil when there
  /// is nothing left to play this time round.
  ///
  /// The search wraps past the end of the queue only when the playlist repeats,
  /// and the wrap takes in `index` itself: a playlist of one long item has
  /// nowhere else to go, and going on to its next segment is the whole point.
  private func nextUnplayedIndex(after index: Int) -> Int? {
    let reach = repeatMode == .repeatAll ? queue.count : queue.count - 1 - index
    guard reach > 0 else { return nil }

    for offset in 1...reach {
      let candidate = (index + offset) % queue.count
      if hasUnplayedSegments(queue[candidate]) { return candidate }
    }

    return nil
  }

  /// Reshuffles a repeating queue so it is not played in the same order every
  /// time round. No-op unless shuffle is on.
  private func reshuffleForNextPass() {
    guard isShuffleEnabled else { return }
    queue = Self.shuffled(unshuffledQueue ?? queue, startingWith: nil)
  }

  /// Restarts the item that is playing, which is what repeat-one asks for.
  ///
  /// In a segmented playlist "again" means the item's *next* stretch rather
  /// than the same one over and over: one item on repeat is a playlist of one,
  /// and once it has played all of itself it starts again from its first
  /// segment.
  private func replayCurrentItem() {
    guard let item = currentItem else { return }

    if isSegmentedPlaylist, !hasUnplayedSegments(item) {
      setSegmentIndex(0, for: item.tagId)
    }

    let segment = resolveSegment(for: item)
    currentSegment = segment

    beginStretch()
    seek(to: segment?.start ?? 0)
    player.play()
  }

  /// Goes back a track, or restarts the current one.
  ///
  /// Standard media-player behaviour: past a few seconds in, "previous" means
  /// "start this over".
  public func previous() {
    guard let currentIndex = currentIndex else { return }

    // "This" is the stretch being played, which in a segmented playlist is the
    // segment rather than the whole item.
    let start = currentSegment?.start ?? 0

    if currentTime - start > 3.0 {
      seek(to: start)
      return
    }

    let previousIndex = currentIndex - 1

    if previousIndex < 0 {
      guard repeatMode == .repeatAll, !queue.isEmpty else {
        seek(to: start)
        return
      }

      goBack(to: queue.count - 1)
      return
    }

    goBack(to: previousIndex)
  }

  /// Plays the item at `index` again, from the stretch of it that was last
  /// heard.
  private func goBack(to index: Int) {
    guard queue.indices.contains(index) else { return }

    rewindSegmentProgress(of: queue[index])
    play(at: index)
  }

  // MARK: - Modes

  public func toggleRepeatMode() {
    player.toggleRepeatMode()
    repeatMode = player.repeatState
  }

  public func setRepeatMode(_ mode: MediaPlayer.RepeatMode) {
    player.setRepeatMode(mode)
    repeatMode = mode
  }

  public func toggleShuffle() {
    setShuffle(!isShuffleEnabled)
  }

  public func setShuffle(_ enabled: Bool) {
    guard isShuffleEnabled != enabled else { return }

    // Assign before telling the player, not after. `setShuffleEnabled` emits
    // `.changeShuffleMode` synchronously, and the observer for that event
    // compares these two flags to decide whether to call back in here.
    // Assigning afterwards leaves them disagreeing for the duration of the
    // send, so the observer sees a mismatch that never resolves and recurses
    // until the stack is exhausted.
    isShuffleEnabled = enabled
    player.setShuffleEnabled(enabled)

    guard !queue.isEmpty else { return }

    if enabled {
      unshuffledQueue = queue
      queue = Self.shuffled(queue, startingWith: currentItem)
    } else if let original = unshuffledQueue {
      queue = original
      unshuffledQueue = nil
    }

    currentIndex = currentItem.flatMap { item in
      queue.firstIndex(where: { $0.tagId == item.tagId })
    }
  }

  /// Shuffles a queue, optionally pinning one item to the front.
  ///
  /// Pinning matters: turning shuffle on mid-track must not interrupt what is
  /// playing, so the current item stays at index 0 and only the rest moves.
  private static func shuffled(
    _ items: [PlaylistInfo], startingWith item: PlaylistInfo?
  ) -> [PlaylistInfo] {
    guard let item = item else { return items.shuffled() }

    var remainder = items.filter { $0.tagId != item.tagId }
    remainder.shuffle()
    return [item] + remainder
  }

  // MARK: - Queue editing

  public func moveQueueItems(from source: IndexSet, to destination: Int) {
    let playing = currentItem
    queue.move(fromOffsets: source, toOffset: destination)
    unshuffledQueue = nil
    currentIndex = playing.flatMap { item in
      queue.firstIndex(where: { $0.tagId == item.tagId })
    }
  }

  public func removeFromQueue(at offsets: IndexSet) {
    let playing = currentItem
    let removedCurrent = currentIndex.map(offsets.contains) ?? false

    queue.remove(atOffsets: offsets)
    unshuffledQueue = nil

    if queue.isEmpty {
      stop()
      return
    }

    if removedCurrent {
      let index = min(currentIndex ?? 0, queue.count - 1)
      play(at: index)
    } else {
      currentIndex = playing.flatMap { item in
        queue.firstIndex(where: { $0.tagId == item.tagId })
      }
    }
  }

  /// Appends items to the end of the queue.
  ///
  /// An item already queued is moved to the end rather than ignored. Silently
  /// doing nothing is the wrong answer to "add this to the queue": the user
  /// cannot see the whole queue from the library, so a command that no-ops on a
  /// duplicate reads as a broken button rather than as a duplicate refused.
  public func addToQueue(_ items: [PlaylistInfo]) {
    splice(items, immediatelyAfterCurrent: false)
  }

  /// Inserts items immediately after the current one.
  public func playNext(_ items: [PlaylistInfo]) {
    splice(items, immediatelyAfterCurrent: true)
  }

  /// Puts `items` into the queue, taking any of them already in it out first.
  ///
  /// The item playing is never moved: reordering the queue around it is one
  /// thing, but pulling it out from under itself would change what is playing.
  private func splice(_ items: [PlaylistInfo], immediatelyAfterCurrent: Bool) {
    let playing = currentItem?.tagId
    let incoming = items.filter { $0.tagId != playing }
    guard !incoming.isEmpty else { return }

    let moving = Set(incoming.map(\.tagId))
    var reordered = queue.filter { !moving.contains($0.tagId) }

    // Worked out after the removals rather than before: taking an item out from
    // ahead of the current one shifts everything behind it down, so an index
    // measured against the old queue would land a place late.
    let insertionPoint: Int
    if immediatelyAfterCurrent, let playing = playing,
      let index = reordered.firstIndex(where: { $0.tagId == playing })
    {
      insertionPoint = index + 1
    } else {
      insertionPoint = reordered.count
    }

    reordered.insert(contentsOf: incoming, at: insertionPoint)

    queue = reordered
    unshuffledQueue = nil
    currentIndex = playing.flatMap { id in reordered.firstIndex(where: { $0.tagId == id }) }
  }

  // MARK: - Sleep timer

  public struct SleepTimer: Equatable {
    public enum Mode: Equatable {
      case duration(TimeInterval)
      case endOfTrack
    }

    public let mode: Mode
    public let expiresAt: Date?

    public var remaining: TimeInterval? {
      guard let expiresAt = expiresAt else { return nil }
      return max(0, expiresAt.timeIntervalSinceNow)
    }
  }

  public func startSleepTimer(_ mode: SleepTimer.Mode) {
    cancelSleepTimer()

    switch mode {
    case .duration(let interval):
      sleepTimer = SleepTimer(mode: mode, expiresAt: Date().addingTimeInterval(interval))

      sleepTimerTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.sleepTimerFired()
      }

    case .endOfTrack:
      // No deadline — handled when the current item reports it finished.
      sleepTimer = SleepTimer(mode: mode, expiresAt: nil)
    }
  }

  public func cancelSleepTimer() {
    sleepTimerTask?.cancel()
    sleepTimerTask = nil
    sleepTimer = nil
  }

  private func sleepTimerFired() {
    player.pause()
    // Release the audio session so other apps can take over — a sleep timer
    // that leaves the session claimed keeps the phone's audio stack awake.
    player.deactivateAudioSession()
    cancelSleepTimer()
  }

  // MARK: - Loading

  private func load(item: PlaylistInfo, autoPlay: Bool) {
    loadTask?.cancel()
    artworkTask?.cancel()

    // Persist where we got to in the outgoing item before switching away.
    persistPlaybackPosition()

    currentItem = item
    currentTime = 0
    duration = item.duration.isFinite ? item.duration : 0
    errorMessage = nil
    hasSeekedToResumePoint = false
    artwork = nil
    isBuffering = true
    // Resolved once the asset's real duration is known, in `applyLoadedItem`.
    currentSegment = nil
    refreshCurrentPlaylist(for: item)

    loadArtwork(for: item)

    loadTask = Task { [weak self] in
      guard let self = self else { return }
      await self.performLoad(item: item, autoPlay: autoPlay)
    }
  }

  private func performLoad(item: PlaylistInfo, autoPlay: Bool) async {
    let manager = PlaylistManager.shared

    // A downloaded item plays from disk and needs no network at all — this is
    // the offline path, and it must be tried first.
    var asset: AVURLAsset
    if let localURL = manager.localAssetURL(for: item.tagId),
      FileManager.default.fileExists(atPath: localURL.path)
    {
      asset = AVURLAsset(url: localURL, options: AVAsset.defaultOptions)
    } else {
      guard let url = URL(string: item.src) else {
        finishLoadWithFailure(MediaExtractor.ExtractionError.invalidURL)
        return
      }
      asset = AVURLAsset(url: url, options: AVAsset.defaultOptions)
    }

    player.activateAudioSession()

    do {
      let isNewItem = try await player.load(asset: asset)
      guard !Task.isCancelled else { return }

      applyLoadedItem(item, isNewItem: isNewItem, autoPlay: autoPlay)
    } catch {
      guard !Task.isCancelled else { return }

      // A streamed item whose signed URL has expired. Re-run extraction against
      // the original page and try once more — Brave's `streamingFallback`.
      if manager.localAssetURL(for: item.tagId) == nil,
        Reachability.shared.connectionStatus == .online
      {
        isRefreshingMedia = true
        let refreshed = await MediaExtractor.shared.refreshExpiredMedia(for: item)
        isRefreshingMedia = false

        guard !Task.isCancelled else { return }

        if let refreshed = refreshed, let url = URL(string: refreshed.src) {
          let retryAsset = AVURLAsset(url: url, options: AVAsset.defaultOptions)
          if let isNewItem = try? await player.load(asset: retryAsset) {
            guard !Task.isCancelled else { return }
            currentItem = refreshed
            if let index = currentIndex, queue.indices.contains(index) {
              queue[index] = refreshed
            }
            applyLoadedItem(refreshed, isNewItem: isNewItem, autoPlay: autoPlay)
            return
          }
        }
      }

      finishLoadWithFailure(error)
    }
  }

  private func applyLoadedItem(_ item: PlaylistInfo, isNewItem: Bool, autoPlay: Bool) {
    isBuffering = false

    let assetDuration = player.duration.seconds
    if assetDuration.isFinite, assetDuration > 0 {
      duration = assetDuration
    }

    isVideo = player.currentItem?.isVideoTracksAvailable() ?? true

    // How much of this item its playlist wants. Resolved here rather than in
    // `load` because it depends on the item's real length: anything no longer
    // than one segment is played whole.
    let segment = resolveSegment(for: item)
    currentSegment = segment

    // Resolving wraps a stored index back into range — the segment length may
    // have changed under it, or the item been re-measured — so write the answer
    // back. What plays next, and whether this item still owes the playlist
    // anything, are both read from that value, and they have to agree with what
    // is actually playing.
    if let segment = segment {
      setSegmentIndex(segment.index, for: item.tagId)
    }

    // Resume where the user left off, but not if they were essentially at the
    // end — restarting a finished item is what they want, not replaying the
    // last two seconds.
    if !hasSeekedToResumePoint {
      hasSeekedToResumePoint = true

      if let segment = segment {
        let start = startOfSegment(segment, for: item)
        player.seek(to: start)
        currentTime = start
      } else if Preferences.Playlist.playbackLeftOff.value,
        item.lastPlayedOffset > 0,
        duration <= 0 || item.lastPlayedOffset < duration - 5.0
      {
        player.seek(to: item.lastPlayedOffset)
        currentTime = item.lastPlayedOffset
      } else if !isNewItem {
        // Same asset re-selected: start it over.
        player.seek(to: 0)
        currentTime = 0
      }
    }

    // Playing this stretch is now under way, so its end counts again. Done
    // after the seek above rather than in `load`: until playback is positioned,
    // the player is still sitting at the end of the stretch just finished and
    // an end-of-item notification for *that* could still be in flight.
    beginStretch()

    player.setPlaybackRate(rate: playbackRate)

    NowPlayingInfo.setNowPlayingInfo(
      item, withPlayer: player, elapsed: currentTime, isAnonymous: isAnonymous)
    if !isAnonymous {
      if let index = currentIndex {
        NowPlayingInfo.setQueuePosition(index: index, count: queue.count)
      }
      NowPlayingInfo.setNowPlayingMediaArtwork(image: artwork)
    }

    if autoPlay {
      player.play()
    }
  }

  private func finishLoadWithFailure(_ error: Error) {
    isBuffering = false
    isRefreshingMedia = false

    if PlaylistManager.shared.localAssetURL(for: currentItem?.tagId ?? "") == nil,
      Reachability.shared.connectionStatus != .online
    {
      errorMessage =
        "This item isn't downloaded, and there's no network connection to stream it."
    } else {
      errorMessage = error.localizedDescription
    }

    Logger.module.error("Playback load failed: \(error.localizedDescription)")
  }

  // MARK: - Artwork

  /// Re-runs artwork loading when a cached thumbnail is dropped.
  ///
  /// The case that matters: an item is played before its download finishes, so
  /// the only artwork available is the page's poster image. When the download
  /// lands, a real frame becomes obtainable and the cache is invalidated — but
  /// nothing would ask for it again, leaving the Now Playing screen and the
  /// lock screen on the poster for the rest of the session.
  private func observeThumbnailInvalidation() {
    NotificationCenter.default.publisher(for: .thumbnailInvalidated)
      .receive(on: RunLoop.main)
      .sink { [weak self] note in
        guard let self = self,
          let id = note.object as? String,
          let item = self.currentItem, item.tagId == id
        else { return }
        self.loadArtwork(for: item)
      }.store(in: &cancellables)
  }

  private func loadArtwork(for item: PlaylistInfo) {
    artworkTask = Task { [weak self] in
      guard let self = self else { return }

      let image = await ThumbnailRenderer.shared.thumbnail(
        id: item.tagId,
        localURL: PlaylistManager.shared.localAssetURL(for: item.tagId),
        remoteURL: URL(string: item.src),
        artworkURL: item.artworkURL.flatMap(URL.init(string:)))

      guard !Task.isCancelled, self.currentItem?.tagId == item.tagId else { return }

      // The in-app player still shows artwork for an anonymised playlist — the
      // point is what leaves the app, not what the user sees having opened it.
      self.artwork = image
      if !self.isAnonymous {
        NowPlayingInfo.setNowPlayingMediaArtwork(image: image)
      }
    }
  }

  // MARK: - Persistence

  /// Records the resume point for the item currently loaded.
  public func persistPlaybackPosition() {
    guard let item = currentItem, currentTime > 0 else { return }

    // A stretch that has just run out had its resume point cleared as it ended,
    // and the player is sitting at the position it ended on. Writing that back
    // would put the resume point straight to the end of the stretch the item
    // has already finished with.
    guard finishedStretchID != stretchID else { return }

    PlaylistManager.shared.updateLastPlayed(item: item, playTime: currentTime)
  }

  // MARK: - Player observation

  private func observePlayer() {
    player.publisher(for: .periodicPlayTimeChanged)
      .sink { [weak self] _ in
        guard let self = self else { return }
        // Ignore ticks mid-seek: AVPlayer reports the pre-seek time until the
        // seek lands, which makes the scrubber snap backwards under the finger.
        guard !self.player.isSeeking else { return }

        self.currentTime = self.player.currentTime.seconds

        let playerDuration = self.player.duration.seconds
        if playerDuration.isFinite, playerDuration > 0, self.duration != playerDuration {
          self.duration = playerDuration
          self.resolveSegmentIfPending()
        }

        self.syncPlaybackFlags()

        // A segmented playlist stops an item short of its end, and nothing in
        // AVFoundation fires at an arbitrary time, so the boundary is watched
        // here.
        if let segment = self.currentSegment, self.currentTime >= segment.end {
          self.stretchDidFinish()
        }
      }.store(in: &cancellables)

    // Transport state changes that no in-app action caused: buffering starting
    // and ending, a stall, an interruption, the system pausing us. Without
    // this the published flags only move when time advances, so the controls
    // of an item that has been asked to play but has not started yet keep
    // showing the previous item's state until the first frame arrives.
    player.publisher(for: .playbackStatusChanged)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.syncPlaybackFlags()
        NowPlayingInfo.setPlaybackState(self.isPlaying)
      }.store(in: &cancellables)

    player.publisher(for: .play)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.syncPlaybackFlags()
        self.publishNowPlayingTimeline()
        NowPlayingInfo.setPlaybackState(true)
      }.store(in: &cancellables)

    player.publisher(for: .pause)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.syncPlaybackFlags()
        self.persistPlaybackPosition()
        self.publishNowPlayingTimeline()
        NowPlayingInfo.setPlaybackState(false)
      }.store(in: &cancellables)

    player.publisher(for: .finishedPlaying)
      .sink { [weak self] _ in
        guard let self = self else { return }

        // An item's last segment ends when the item does, so this is the same
        // event the boundary watcher above has already acted on — and because a
        // repeat reloading the asset already loaded keeps the very same
        // `AVPlayerItem`, it can arrive after playback has been sent back into
        // an earlier stretch of it. Take it only if this stretch's end has not
        // been dealt with, and only if the player is still sitting at it.
        guard self.finishedStretchID != self.stretchID,
          !self.player.isSeeking,
          self.isAtEndOfItem
        else { return }

        self.stretchDidFinish()
      }.store(in: &cancellables)

    player.publisher(for: .nextTrack)
      .sink { [weak self] _ in self?.next() }
      .store(in: &cancellables)

    player.publisher(for: .previousTrack)
      .sink { [weak self] _ in self?.previous() }
      .store(in: &cancellables)

    player.publisher(for: .changeRepeatMode)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.repeatMode = self.player.repeatState
      }.store(in: &cancellables)

    player.publisher(for: .changeShuffleMode)
      .sink { [weak self] _ in
        guard let self = self else { return }
        // Route through `setShuffle` so a change made from Control Center
        // reorders the queue exactly as an in-app toggle would.
        if self.isShuffleEnabled != self.player.isShuffleEnabled {
          self.setShuffle(self.player.isShuffleEnabled)
        }
      }.store(in: &cancellables)

    player.publisher(for: .changePlaybackRate)
      .sink { [weak self] _ in
        guard let self = self else { return }
        if self.playbackRate != self.player.playbackRate {
          self.playbackRate = self.player.playbackRate
        }
      }.store(in: &cancellables)

    // Where playback ended up after a jump, whichever control asked for it.
    // As far as the timeline is concerned the three are one event, and all
    // three are published once the seek has landed: `AVPlayer` goes on
    // reporting the old position until then, and handing the lock screen the
    // position playback is about to leave is what leaves its scrubber sitting
    // fifteen seconds behind, counting up from the wrong place.
    Publishers.MergeMany(
      player.publisher(for: .changePlaybackPosition),
      player.publisher(for: .seekForward),
      player.publisher(for: .seekBackward)
    )
    .sink { [weak self] _ in
      guard let self = self else { return }
      self.currentTime = self.player.currentTime.seconds
      self.publishNowPlayingTimeline()
    }.store(in: &cancellables)

    // Save the resume point when the app is backgrounded — the process may be
    // killed without any further notice.
    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      .sink { [weak self] _ in
        self?.persistPlaybackPosition()
      }.store(in: &cancellables)
  }

  /// Publishes the player's transport state.
  ///
  /// `isPlaying` follows whether playback has been *requested*, not whether
  /// audio has started. The two differ for as long as an item is buffering —
  /// seconds, on a stream — and reporting "paused" through that window is what
  /// leaves a freshly started item showing a play button that does nothing.
  /// Buffering is reported separately, and the two are true together on purpose.
  private func syncPlaybackFlags() {
    let playing = player.isPlaybackRequested
    if isPlaying != playing {
      isPlaying = playing
    }

    let buffering = player.isWaitingToPlay
    if isBuffering != buffering, !isRefreshingMedia {
      isBuffering = buffering
    }
  }
}
