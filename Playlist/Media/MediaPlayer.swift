// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Playlist/MediaPlayer.swift`.
//
// This is the layer that makes background audio, lock-screen controls and
// Picture-in-Picture work, and it is kept close to upstream. Changes:
//
//   * The `#unavailable(iOS 16)` `previousRate` shadowing — an involved
//     workaround for `AVPlayer` lacking `defaultRate` before iOS 16 — is gone;
//     this app targets iOS 17.
//   * `toggleRepeatMode` and `toggleShuffleMode` are corrected (upstream
//     publishes the wrong repeat type to Control Center by one step, and never
//     updates its own `shuffleState`), and both now persist across launches.
//   * Playback rates extended from Brave's `[1.0, 1.5, 2.0]` to a full set.
//   * The audio session is configured once at `activate()` rather than in
//     `init`, so merely constructing a player does not interrupt other apps'
//     audio.
//   * Picture-in-Picture is a preference rather than always-on.
//   * `timeControlStatus` is observed, and `play`/`pause` are gated on whether
//     playback has been *requested* rather than on whether audio is already
//     flowing — see `isPlaybackRequested`.

import AVFoundation
import AVKit
import Combine
import Foundation
import MediaPlayer
import os.log

public enum MediaPlaybackError: Error {
  case cancelled
  case cannotLoadAsset
  case other(Error)
}

/// A thin, observable wrapper over `AVPlayer`.
///
/// `MediaPlayer` owns exactly one concern: driving a single `AVPlayer` and
/// reporting what it does. It knows nothing about the library, the queue or
/// what plays next — that is `PlaybackController`'s job. Keeping the split is
/// what let Brave drive the same player from a browser tab, a full-screen
/// controller and CarPlay, and it is why the player survived the browser being
/// deleted from around it.
public class MediaPlayer: NSObject {
  public enum RepeatMode: String, CaseIterable {
    case none
    case repeatOne
    case repeatAll
  }

  // MARK: - Public state

  private(set) public var isSeeking = false
  private(set) public var pendingMediaItem: AVPlayerItem?
  private(set) public var pictureInPictureController: AVPictureInPictureController?

  /// How far the skip controls jump, in seconds. Mirrored to Control Center.
  public var seekInterval: TimeInterval = Preferences.Playlist.seekInterval.value {
    didSet {
      let center = MPRemoteCommandCenter.shared()
      center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
      center.skipForwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
      Preferences.Playlist.seekInterval.value = seekInterval
    }
  }

  public let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

  /// The stretch of the current item the transport operates within.
  ///
  /// Nil — the usual case — means the whole item. A playlist that plays its
  /// items in segments sets it to the segment being played, and three things
  /// follow from that: the lock screen is told the length of *that* stretch and
  /// how far into it playback is rather than the whole track's, a scrub from
  /// the lock screen is a position inside it, and the skip buttons stop at its
  /// edges instead of walking out of it.
  ///
  /// This stays inside `MediaPlayer` — rather than being applied by the caller
  /// at each site — because it is the answer to "what is playing right now" as
  /// far as anything outside the app can see, and the lock screen, Control
  /// Centre and the remote command centre all read that through this class.
  /// It says nothing about playlists, queues or what plays next, which remain
  /// entirely `PlaybackController`'s business.
  public var playbackWindow: ClosedRange<TimeInterval>?

  /// The length the outside world should be told the current item is.
  public var presentedDuration: TimeInterval {
    guard let window = playbackWindow else {
      let measured = duration.seconds
      return measured.isFinite && measured > 0 ? measured : 0
    }
    return max(0, window.upperBound - window.lowerBound)
  }

  /// Converts an absolute position in the item into one the outside world can
  /// read against `presentedDuration`.
  public func presentedTime(for absolute: TimeInterval) -> TimeInterval {
    guard absolute.isFinite else { return 0 }
    guard let window = playbackWindow else { return max(0, absolute) }
    return min(max(absolute - window.lowerBound, 0), presentedDuration)
  }

  /// The inverse: a position the lock screen's scrubber reported, in the item's
  /// own timebase.
  public func absoluteTime(forPresented presented: TimeInterval) -> TimeInterval {
    guard let window = playbackWindow else { return max(0, presented) }
    return min(max(window.lowerBound + presented, window.lowerBound), window.upperBound)
  }

  private(set) public var repeatState: RepeatMode = {
    RepeatMode(rawValue: Preferences.Playlist.repeatMode.value) ?? .none
  }()

  private(set) public var isShuffleEnabled: Bool = Preferences.Playlist.shuffleEnabled.value

  /// Whether video is allowed to float out into Picture-in-Picture.
  ///
  /// Turning it off leaves the controller in place but forbids it from starting
  /// itself, and closes the window if one is already up. Audio is unaffected.
  public var isPictureInPictureEnabled: Bool = Preferences.Playlist.pictureInPictureEnabled.value {
    didSet {
      Preferences.Playlist.pictureInPictureEnabled.value = isPictureInPictureEnabled
      applyPictureInPictureSetting()
    }
  }

  /// Whether audio is actually coming out.
  ///
  /// Deliberately derived from `timeControlStatus` rather than a tracked flag:
  /// Control Center, the lock screen, PiP and CarPlay can all start or stop
  /// playback without going through this class, and only the player's own
  /// status reflects that.
  public var isPlaying: Bool {
    player.timeControlStatus == .playing
  }

  /// Whether playback has been asked for, whether or not audio has started.
  ///
  /// This — not `isPlaying` — is what the transport controls must be driven
  /// from. A freshly started item spends its first moments in
  /// `.waitingToPlayAtSpecifiedRate`, during which `isPlaying` is false; gating
  /// `pause()` on that reads the state as "paused" and turns the pause button
  /// into a second play button, which does nothing. The window is short for a
  /// downloaded file and several seconds for a stream.
  public var isPlaybackRequested: Bool {
    player.timeControlStatus != .paused
  }

  /// Buffering — playback was requested but no audio is flowing yet.
  public var isWaitingToPlay: Bool {
    player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }

  public var currentItem: AVPlayerItem? { player.currentItem }
  public var currentTime: CMTime { player.currentTime() }
  public var rate: Float { player.rate }

  /// The rate to resume at, independent of whether we are paused right now.
  public var playbackRate: Float {
    get { player.defaultRate }
    set { setPlaybackRate(rate: newValue) }
  }

  public var duration: CMTime {
    player.currentItem?.duration ?? .indefinite
  }

  /// A live stream has no meaningful duration or scrub bar.
  public var isLiveMedia: Bool {
    (player.currentItem ?? pendingMediaItem)?.duration.isIndefinite == true
  }

  public var isAttachedToDisplay: Bool {
    playerLayer.superlayer != nil
  }

  /// The layer video is rendered into. Handed to a `UIViewRepresentable`.
  public var displayLayer: AVPlayerLayer { playerLayer }

  public override init() {
    super.init()

    playerLayer.player = self.player

    registerNotifications()
    registerControlCenterNotifications()
    registerPictureInPictureNotifications()

    player.defaultRate = Float(Preferences.Playlist.defaultPlaybackRate.value)

    // Reflect persisted modes into Control Center immediately, so the lock
    // screen is not lying about repeat/shuffle before the user touches them.
    MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType =
      repeatState.remoteRepeatType
    MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType =
      isShuffleEnabled ? .items : .off

    UIApplication.shared.beginReceivingRemoteControlEvents()
  }

  deinit {
    notificationObservers.removeAll()

    if let periodicTimeObserver = periodicTimeObserver {
      player.removeTimeObserver(periodicTimeObserver)
    }

    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation)

    UIApplication.shared.endReceivingRemoteControlEvents()
  }

  // MARK: - Audio session

  /// Claims the audio session for playback.
  ///
  /// `.playback` is the category that keeps audio running when the screen locks
  /// or the app is backgrounded, and it is what pairs with the `audio`
  /// `UIBackgroundMode` in Info.plist. Without both, iOS silences the app the
  /// moment it leaves the foreground.
  public func activateAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true, options: [])
    } catch {
      Logger.module.error("Failed to activate audio session: \(error.localizedDescription)")
    }
  }

  /// Releases the audio session so other apps can resume.
  public func deactivateAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    } catch {
      Logger.module.error("Failed to deactivate audio session: \(error.localizedDescription)")
    }
  }

  // MARK: - Loading

  public func clear() {
    player.replaceCurrentItem(with: nil)
    pendingMediaItem = nil
  }

  @MainActor
  public func load(url: URL) async throws -> Bool {
    try await load(asset: AVURLAsset(url: url, options: AVAsset.defaultOptions))
  }

  /// Loads an asset, returning whether a *new* item was installed.
  ///
  /// `false` means the same asset was already loaded, in which case the caller
  /// should seek to zero to restart rather than calling `play()` — replacing
  /// the item would drop the buffer and restart the network fetch for nothing.
  /// `@MainActor` because `AVPlayerItem.asset` is main-actor isolated; the only
  /// caller (`PlaybackController`) is main-actor anyway.
  @MainActor
  @discardableResult
  public func load(asset: AVURLAsset) async throws -> Bool {
    if let currentItem = player.currentItem,
      let currentAsset = currentItem.asset as? AVURLAsset,
      player.status == .readyToPlay,
      currentAsset.url.absoluteString == asset.url.absoluteString
    {
      pendingMediaItem = nil
      return false
    }

    let item = AVPlayerItem(asset: asset)
    pendingMediaItem = item

    // Loading these three keys up front is what turns a "the video is black for
    // two seconds" experience into an immediate start, and it surfaces an
    // unplayable asset as a thrown error instead of silent failure.
    _ = try await asset.load(.isPlayable, .tracks, .duration)

    guard !Task.isCancelled else {
      pendingMediaItem = nil
      throw MediaPlaybackError.cancelled
    }

    player.replaceCurrentItem(with: item)
    pendingMediaItem = nil
    return true
  }

  // MARK: - Transport

  public func play() {
    guard !isPlaybackRequested else { return }
    player.play()
    playSubscriber.send(EventNotification(mediaPlayer: self, event: .play))
  }

  public func pause() {
    guard isPlaybackRequested else { return }
    player.pause()
    pauseSubscriber.send(EventNotification(mediaPlayer: self, event: .pause))
  }

  public func stop() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    stopSubscriber.send(EventNotification(mediaPlayer: self, event: .stop))
  }

  public func seekPreviousTrack() {
    previousTrackSubscriber.send(EventNotification(mediaPlayer: self, event: .previousTrack))
  }

  public func seekNextTrack() {
    nextTrackSubscriber.send(EventNotification(mediaPlayer: self, event: .nextTrack))
  }

  public func seekBackwards() {
    guard player.currentItem != nil else { return }

    // Never before the start of the stretch being played. Skipping back out of
    // a segment would drop the listener into audio the playlist did not ask
    // for, and the boundary watcher would not bring them back.
    let floor = playbackWindow?.lowerBound ?? 0

    performSeek(to: max(floor, seekOrigin - seekInterval)) { player in
      player.seekBackwardSubscriber.send(
        EventNotification(mediaPlayer: player, event: .seekBackward))
    }
  }

  public func seekForwards() {
    guard let currentItem = player.currentItem else { return }

    let position = seekOrigin
    // The end of the stretch being played, which for a segmented playlist comes
    // before the end of the item.
    let end = playbackWindow?.upperBound ?? currentItem.duration.seconds
    var target = position + seekInterval

    // Landing on the end reports the item as finished and advances the queue,
    // which is not what a skip-forward button should do. Near the end it stops
    // just short of it instead of refusing to move: a button that does nothing
    // at all for the last stretch of every track reads as broken, and upstream
    // kept it inert for the final two intervals.
    if end.isFinite, end > 0 {
      let limit = end - 0.5
      guard position < limit else { return }
      target = min(target, limit)
    }

    performSeek(to: target) { player in
      player.seekForwardSubscriber.send(
        EventNotification(mediaPlayer: player, event: .seekForward))
    }
  }

  public func seek(to time: TimeInterval) {
    guard player.currentItem != nil else { return }

    performSeek(to: time) { player in
      player.changePlaybackPositionSubscriber.send(
        EventNotification(mediaPlayer: player, event: .changePlaybackPosition))
    }
  }

  /// Where a skip should measure from.
  ///
  /// The seek in flight, if there is one: `AVPlayer` goes on reporting the
  /// position it is leaving until a seek lands, so two taps of "forward 30"
  /// in quick succession would otherwise both measure from the same place and
  /// move thirty seconds between them rather than a minute.
  private var seekOrigin: TimeInterval {
    pendingSeekTarget ?? player.currentTime().seconds
  }

  /// Seeks, and reports where playback ended up once it is actually there.
  ///
  /// Reporting from the completion handler rather than straight away is the
  /// point of this: for the same reason a skip cannot measure from the player's
  /// clock, nothing reading that clock in response to a seek — the lock
  /// screen's scrubber above all — can be told about one before it lands.
  /// Seeks superseded by a later one report nothing, so a burst of taps
  /// publishes a single answer: the one that is true.
  private func performSeek(to time: TimeInterval, then report: @escaping (MediaPlayer) -> Void) {
    guard let currentItem = player.currentItem else { return }

    var seekTime = max(0.0, time)
    let duration = currentItem.duration.seconds
    if duration.isFinite, seekTime >= duration {
      seekTime = duration
    }

    let absoluteTime = CMTimeMakeWithSeconds(
      seekTime, preferredTimescale: currentItem.currentTime().timescale)

    seeksInFlight += 1
    isSeeking = true
    pendingSeekTarget = seekTime

    // Generous tolerance: an exact seek forces a decode from the previous
    // keyframe, which visibly stalls on long videos for no user benefit.
    player.seek(
      to: absoluteTime, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity
    ) { [weak self] _ in
      guard let self = self else { return }

      self.seeksInFlight -= 1
      guard self.seeksInFlight == 0 else { return }

      self.isSeeking = false
      self.pendingSeekTarget = nil
      report(self)
    }
  }

  // MARK: - Modes

  public func setRepeatMode(_ mode: RepeatMode) {
    repeatState = mode
    Preferences.Playlist.repeatMode.value = mode.rawValue
    MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType =
      mode.remoteRepeatType

    // Repeat-one is implemented by not advancing at end-of-item; telling
    // AVPlayer to hold at the end rather than blank the display keeps the last
    // frame on screen while we restart.
    player.actionAtItemEnd = .none

    changeRepeatModeSubscriber.send(
      EventNotification(mediaPlayer: self, event: .changeRepeatMode))
  }

  /// Cycles none → repeat all → repeat one → none.
  ///
  /// NOTE: Brave's version publishes the *outgoing* mode to Control Center, so
  /// the lock screen shows the previous state; and its order is
  /// none → one → all, which is the reverse of the platform convention.
  public func toggleRepeatMode() {
    switch repeatState {
    case .none: setRepeatMode(.repeatAll)
    case .repeatAll: setRepeatMode(.repeatOne)
    case .repeatOne: setRepeatMode(.none)
    }
  }

  public func setShuffleEnabled(_ enabled: Bool) {
    // Redundant sets are dropped rather than re-broadcast. The system re-issues
    // the current shuffle mode when it takes over transport — entering PiP is
    // the common case — and echoing that back out is what turns a no-op sync
    // into a round trip through every observer.
    guard isShuffleEnabled != enabled else { return }

    isShuffleEnabled = enabled
    Preferences.Playlist.shuffleEnabled.value = enabled
    MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType =
      enabled ? .items : .off

    changeShuffleModeSubscriber.send(
      EventNotification(mediaPlayer: self, event: .changeShuffleMode))
  }

  /// NOTE: Brave's `toggleShuffleMode` updates Control Center but never assigns
  /// `shuffleState`, so the player's own view of shuffle never changes.
  public func toggleShuffleMode() {
    setShuffleEnabled(!isShuffleEnabled)
  }

  public func toggleGravity() {
    switch playerLayer.videoGravity {
    case .resizeAspect: playerLayer.videoGravity = .resizeAspectFill
    default: playerLayer.videoGravity = .resizeAspect
    }

    playerGravitySubscriber.send(
      EventNotification(mediaPlayer: self, event: .playerGravityChanged))
  }

  public func setPlaybackRate(rate: Float) {
    // `defaultRate` is the rate playback resumes at; setting only `rate` would
    // be reset to 1.0 by the next play/pause cycle.
    player.defaultRate = rate
    if isPlaying {
      player.rate = rate
    }
    Preferences.Playlist.defaultPlaybackRate.value = Double(rate)

    changePlaybackRateSubscriber.send(
      EventNotification(mediaPlayer: self, event: .changePlaybackRate))
  }

  // MARK: - Display

  @discardableResult
  public func attachLayer() -> CALayer {
    playerLayer.player = player
    return playerLayer
  }

  public func addTimeObserver(interval: Int, onTick: @escaping (CMTime) -> Void) -> Any {
    let interval = CMTimeMake(value: Int64(interval), timescale: 1000)
    return player.addPeriodicTimeObserver(forInterval: interval, queue: .main, using: onTick)
  }

  // MARK: - Private

  private let player: AVPlayer = {
    let player = AVPlayer()
    player.seek(to: .zero)
    // `.none` rather than `.pause`: end-of-item handling is the queue's
    // decision, and pausing here would race with advancing to the next track.
    player.actionAtItemEnd = .none
    // Let AVPlayer stall rather than skip when the buffer runs dry.
    player.automaticallyWaitsToMinimizeStalling = true
    return player
  }()

  private let playerLayer: AVPlayerLayer = {
    let layer = AVPlayerLayer()
    layer.videoGravity = .resizeAspect
    layer.needsDisplayOnBoundsChange = true
    return layer
  }()

  private var periodicTimeObserver: Any?
  private var notificationObservers = Set<AnyCancellable>()

  /// Seeks asked for but not yet landed. See `performSeek`.
  private var seeksInFlight = 0
  private var pendingSeekTarget: TimeInterval?

  private let pauseSubscriber = PassthroughSubject<EventNotification, Never>()
  private let playSubscriber = PassthroughSubject<EventNotification, Never>()
  private let stopSubscriber = PassthroughSubject<EventNotification, Never>()
  private let changePlaybackRateSubscriber = PassthroughSubject<EventNotification, Never>()
  private let changeRepeatModeSubscriber = PassthroughSubject<EventNotification, Never>()
  private let changeShuffleModeSubscriber = PassthroughSubject<EventNotification, Never>()
  private let nextTrackSubscriber = PassthroughSubject<EventNotification, Never>()
  private let previousTrackSubscriber = PassthroughSubject<EventNotification, Never>()
  private let seekForwardSubscriber = PassthroughSubject<EventNotification, Never>()
  private let seekBackwardSubscriber = PassthroughSubject<EventNotification, Never>()
  private let changePlaybackPositionSubscriber = PassthroughSubject<EventNotification, Never>()
  private let finishedPlayingSubscriber = PassthroughSubject<EventNotification, Never>()
  private let periodicTimeSubscriber = PassthroughSubject<EventNotification, Never>()
  private let playbackStatusSubscriber = PassthroughSubject<EventNotification, Never>()
  private let pictureInPictureStatusSubscriber = PassthroughSubject<EventNotification, Never>()
  private let playerGravitySubscriber = PassthroughSubject<EventNotification, Never>()
}

// MARK: - Events

extension MediaPlayer {
  public enum Event {
    case pause
    case play
    case stop
    case changePlaybackRate
    case changeRepeatMode
    case changeShuffleMode
    case nextTrack
    case previousTrack
    case seekForward
    case seekBackward
    case changePlaybackPosition
    case finishedPlaying
    case periodicPlayTimeChanged
    case playbackStatusChanged
    case pictureInPictureStatusChanged
    case playerGravityChanged
  }

  public struct EventNotification {
    public let mediaPlayer: MediaPlayer
    public let event: Event
  }

  public func publisher(for event: Event) -> AnyPublisher<EventNotification, Never> {
    switch event {
    case .pause: return pauseSubscriber.eraseToAnyPublisher()
    case .play: return playSubscriber.eraseToAnyPublisher()
    case .stop: return stopSubscriber.eraseToAnyPublisher()
    case .changePlaybackRate: return changePlaybackRateSubscriber.eraseToAnyPublisher()
    case .changeRepeatMode: return changeRepeatModeSubscriber.eraseToAnyPublisher()
    case .changeShuffleMode: return changeShuffleModeSubscriber.eraseToAnyPublisher()
    case .nextTrack: return nextTrackSubscriber.eraseToAnyPublisher()
    case .previousTrack: return previousTrackSubscriber.eraseToAnyPublisher()
    case .seekForward: return seekForwardSubscriber.eraseToAnyPublisher()
    case .seekBackward: return seekBackwardSubscriber.eraseToAnyPublisher()
    case .changePlaybackPosition: return changePlaybackPositionSubscriber.eraseToAnyPublisher()
    case .finishedPlaying: return finishedPlayingSubscriber.eraseToAnyPublisher()
    case .periodicPlayTimeChanged: return periodicTimeSubscriber.eraseToAnyPublisher()
    case .playbackStatusChanged: return playbackStatusSubscriber.eraseToAnyPublisher()
    case .pictureInPictureStatusChanged:
      return pictureInPictureStatusSubscriber.eraseToAnyPublisher()
    case .playerGravityChanged: return playerGravitySubscriber.eraseToAnyPublisher()
    }
  }
}

// MARK: - Notifications

extension MediaPlayer {
  private func registerNotifications() {
    // Detaching the player from its layer in the background is what lets audio
    // keep playing while video decoding stops. Skipped during PiP, where the
    // layer must stay live precisely because the app is backgrounded.
    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      .sink { [weak self] _ in
        guard let self = self else { return }
        if self.pictureInPictureController?.isPictureInPictureActive == true { return }
        self.playerLayer.player = nil
      }.store(in: &notificationObservers)

    NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
      .sink { [weak self] _ in
        guard let self = self else { return }
        if self.pictureInPictureController?.isPictureInPictureActive == true { return }
        self.playerLayer.player = self.player
      }.store(in: &notificationObservers)

    // A phone call or a Siri request interrupts us; `.shouldResume` tells us
    // whether the system expects playback to come back afterwards.
    NotificationCenter.default.publisher(
      for: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
    )
    .sink { [weak self] notification in
      guard let self = self,
        let userInfo = notification.userInfo,
        let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      switch type {
      case .began:
        self.pause()

      case .ended:
        guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
          return
        }
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if options.contains(.shouldResume) {
          self.activateAudioSession()
          self.play()
        }

      @unknown default:
        break
      }
    }.store(in: &notificationObservers)

    // Headphones unplugged / Bluetooth disconnected: pause rather than blast
    // audio out of the speaker.
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .sink { [weak self] notification in
        guard let self = self,
          let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
          reason == .oldDeviceUnavailable
        else { return }

        self.pause()
      }.store(in: &notificationObservers)

    NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
      .sink { [weak self] notification in
        guard let self = self else { return }
        // Several players can exist during a transition; only react to ours.
        guard let item = notification.object as? AVPlayerItem,
          item === self.player.currentItem
        else { return }

        self.finishedPlayingSubscriber.send(
          EventNotification(mediaPlayer: self, event: .finishedPlaying))
      }.store(in: &notificationObservers)

    // The transport state has to be observed, not polled. The periodic time
    // observer only ticks while time is advancing, so on its own it cannot
    // report "started buffering" or "stalled" — which is exactly when the
    // player's own controls need to change. Every transition is published.
    player.publisher(for: \.timeControlStatus, options: [.initial, .new])
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.playbackStatusSubscriber.send(
          EventNotification(mediaPlayer: self, event: .playbackStatusChanged))
      }.store(in: &notificationObservers)

    // A replaced item is the other half of it: the controls are bound to the
    // item's duration and tracks, and both change the instant this fires.
    player.publisher(for: \.currentItem, options: [.new])
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.playbackStatusSubscriber.send(
          EventNotification(mediaPlayer: self, event: .playbackStatusChanged))
      }.store(in: &notificationObservers)

    periodicTimeObserver = addTimeObserver(interval: 250) { [weak self] _ in
      guard let self = self else { return }
      self.periodicTimeSubscriber.send(
        EventNotification(mediaPlayer: self, event: .periodicPlayTimeChanged))
    }
  }

  private func registerControlCenterNotifications() {
    let center = MPRemoteCommandCenter.shared()

    center.publisher(for: .pauseCommand).sink { [weak self] _ in
      self?.pause()
    }.store(in: &notificationObservers)

    center.publisher(for: .playCommand).sink { [weak self] _ in
      self?.play()
    }.store(in: &notificationObservers)

    center.publisher(for: .stopCommand).sink { [weak self] _ in
      self?.stop()
    }.store(in: &notificationObservers)

    center.publisher(for: .togglePlayPauseCommand).sink { [weak self] _ in
      guard let self = self else { return }
      self.isPlaying ? self.pause() : self.play()
    }.store(in: &notificationObservers)

    center.changePlaybackRateCommand.supportedPlaybackRates =
      supportedPlaybackRates.map { NSNumber(value: $0) }
    center.publisher(for: .changePlaybackRateCommand).sink { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackRateCommandEvent else { return }
      self.setPlaybackRate(rate: event.playbackRate)
    }.store(in: &notificationObservers)

    center.publisher(for: .changeRepeatModeCommand).sink { [weak self] event in
      guard let self = self else { return }
      if let event = event as? MPChangeRepeatModeCommandEvent {
        // Honour the exact mode the system asked for rather than cycling, so
        // Control Center's three-way control lands where the user tapped.
        switch event.repeatType {
        case .off: self.setRepeatMode(.none)
        case .one: self.setRepeatMode(.repeatOne)
        case .all: self.setRepeatMode(.repeatAll)
        @unknown default: self.toggleRepeatMode()
        }
      } else {
        self.toggleRepeatMode()
      }
    }.store(in: &notificationObservers)

    center.publisher(for: .changeShuffleModeCommand).sink { [weak self] event in
      guard let self = self else { return }
      if let event = event as? MPChangeShuffleModeCommandEvent {
        self.setShuffleEnabled(event.shuffleType != .off)
      } else {
        self.toggleShuffleMode()
      }
    }.store(in: &notificationObservers)

    center.publisher(for: .previousTrackCommand).sink { [weak self] _ in
      self?.seekPreviousTrack()
    }.store(in: &notificationObservers)

    center.publisher(for: .nextTrackCommand).sink { [weak self] _ in
      self?.seekNextTrack()
    }.store(in: &notificationObservers)

    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
    center.publisher(for: .skipBackwardCommand).sink { [weak self] _ in
      self?.seekBackwards()
    }.store(in: &notificationObservers)

    center.skipForwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
    center.publisher(for: .skipForwardCommand).sink { [weak self] _ in
      self?.seekForwards()
    }.store(in: &notificationObservers)

    center.publisher(for: .seekBackwardCommand).sink { [weak self] _ in
      self?.seekBackwards()
    }.store(in: &notificationObservers)

    center.publisher(for: .seekForwardCommand).sink { [weak self] _ in
      self?.seekForwards()
    }.store(in: &notificationObservers)

    center.publisher(for: .changePlaybackPositionCommand).sink { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else {
        return
      }
      // The lock screen scrubs against the timeline it was published, which for
      // a segmented playlist is the segment rather than the item — so the
      // position it reports has to be put back into the item's own timebase
      // before the player is asked to go there.
      self.seek(to: self.absoluteTime(forPresented: event.positionTime))
    }.store(in: &notificationObservers)
  }

  private func registerPictureInPictureNotifications() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      pictureInPictureStatusSubscriber.send(
        EventNotification(mediaPlayer: self, event: .pictureInPictureStatusChanged))
      return
    }

    pictureInPictureController = AVPictureInPictureController(playerLayer: playerLayer)
    applyPictureInPictureSetting()

    pictureInPictureController?
      .publisher(for: \AVPictureInPictureController.isPictureInPicturePossible)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.pictureInPictureStatusSubscriber.send(
          EventNotification(mediaPlayer: self, event: .pictureInPictureStatusChanged))
      }.store(in: &notificationObservers)
  }

  /// Applies the Picture-in-Picture preference to the live controller.
  ///
  /// `canStartPictureInPictureAutomaticallyFromInline` is the whole feature from
  /// the user's point of view — there is no PiP button in this app, so leaving
  /// the app while a video plays is the only way a window ever appears. The
  /// controller itself is kept rather than torn down, so the setting can be
  /// turned back on mid-playback without rebuilding it against the layer.
  private func applyPictureInPictureSetting() {
    guard let controller = pictureInPictureController else { return }

    controller.canStartPictureInPictureAutomaticallyFromInline = isPictureInPictureEnabled

    if !isPictureInPictureEnabled, controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    }
  }
}

extension MediaPlayer.RepeatMode {
  var remoteRepeatType: MPRepeatType {
    switch self {
    case .none: return .off
    case .repeatOne: return .one
    case .repeatAll: return .all
    }
  }
}

// MARK: - AVFoundation helpers

extension AVPlayerItem {
  private var isReadyToPlay: Bool {
    if case .loaded = asset.status(of: .tracks) { return true }
    return false
  }

  /// Whether this item has any audio.
  public func isAudioTracksAvailable() -> Bool {
    tracks.contains { $0.assetTrack?.mediaType == .audio }
  }

  /// Whether to render this as video.
  ///
  /// Intentionally biased towards "yes". For HLS streams tracks are often not
  /// resolved yet, and guessing "audio" would show the audio-only artwork UI
  /// over a video that is about to start — a far more jarring mistake than
  /// briefly showing a black video surface for an audio file.
  public func isVideoTracksAvailable() -> Bool {
    if !isReadyToPlay { return true }
    if tracks.isEmpty { return true }
    if tracks.allSatisfy({ $0.assetTrack == nil }) { return true }

    return tracks.contains { $0.assetTrack?.mediaType == .video }
  }
}

extension AVAsset {
  /// Options every `AVURLAsset` in the app is created with.
  ///
  /// The user agent has to match the one used for extraction and download:
  /// media CDNs commonly bind a URL to the requesting client, and a mismatched
  /// UA turns a working URL into a 403.
  public static var defaultOptions: [String: Any] {
    [AVURLAssetHTTPUserAgentKey: UserAgent.current]
  }
}
