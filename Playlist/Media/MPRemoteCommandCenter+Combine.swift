// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Playlist/MPRemoteCommandCenter+Combine.swift`.
// Unchanged in design; the command list is trimmed to the ones this app
// actually handles, and target removal is made robust on deinit.

import Combine
import Foundation
import MediaPlayer

extension MPRemoteCommandCenter {
  /// The remote commands this app responds to.
  ///
  /// `MPRemoteCommandCenter` is a callback API with manual target management;
  /// wrapping each command in a publisher lets `MediaPlayer` register all of
  /// them uniformly and tear them all down by dropping one cancellable set.
  public enum Command: CaseIterable {
    case pauseCommand
    case playCommand
    case stopCommand
    case togglePlayPauseCommand
    case nextTrackCommand
    case previousTrackCommand
    case changeRepeatModeCommand
    case changeShuffleModeCommand
    case changePlaybackRateCommand
    case seekBackwardCommand
    case seekForwardCommand
    case skipBackwardCommand
    case skipForwardCommand
    case changePlaybackPositionCommand

    public var command: MPRemoteCommand {
      let center = MPRemoteCommandCenter.shared()
      switch self {
      case .pauseCommand: return center.pauseCommand
      case .playCommand: return center.playCommand
      case .stopCommand: return center.stopCommand
      case .togglePlayPauseCommand: return center.togglePlayPauseCommand
      case .nextTrackCommand: return center.nextTrackCommand
      case .previousTrackCommand: return center.previousTrackCommand
      case .changeRepeatModeCommand: return center.changeRepeatModeCommand
      case .changeShuffleModeCommand: return center.changeShuffleModeCommand
      case .changePlaybackRateCommand: return center.changePlaybackRateCommand
      case .seekBackwardCommand: return center.seekBackwardCommand
      case .seekForwardCommand: return center.seekForwardCommand
      case .skipBackwardCommand: return center.skipBackwardCommand
      case .skipForwardCommand: return center.skipForwardCommand
      case .changePlaybackPositionCommand: return center.changePlaybackPositionCommand
      }
    }
  }

  /// A publisher that emits every time the system delivers `command`.
  public func publisher(for command: Command) -> AnyPublisher<MPRemoteCommandEvent, Never> {
    RemoteCommandPublisher(command: command.command).eraseToAnyPublisher()
  }
}

/// Bridges one `MPRemoteCommand` to Combine.
private struct RemoteCommandPublisher: Publisher {
  typealias Output = MPRemoteCommandEvent
  typealias Failure = Never

  let command: MPRemoteCommand

  func receive<S>(subscriber: S)
  where S: Subscriber, Never == S.Failure, MPRemoteCommandEvent == S.Input {
    let subscription = RemoteCommandSubscription(subscriber: subscriber, command: command)
    subscriber.receive(subscription: subscription)
  }
}

private final class RemoteCommandSubscription<S: Subscriber>: Subscription
where S.Input == MPRemoteCommandEvent, S.Failure == Never {
  private var subscriber: S?
  private let command: MPRemoteCommand
  private var target: Any?

  init(subscriber: S, command: MPRemoteCommand) {
    self.subscriber = subscriber
    self.command = command

    target = command.addTarget { [weak self] event in
      guard let self = self, let subscriber = self.subscriber else {
        return .commandFailed
      }
      _ = subscriber.receive(event)
      return .success
    }
  }

  func request(_ demand: Subscribers.Demand) {
    // The system decides when commands fire; there is no backpressure to apply.
  }

  func cancel() {
    // Targets are retained by the shared command center, which outlives every
    // player instance — failing to remove this leaks the subscriber and, worse,
    // leaves a dead player responding to lock-screen buttons.
    if let target = target {
      command.removeTarget(target)
    }
    target = nil
    subscriber = nil
  }
}
