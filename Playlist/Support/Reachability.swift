// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Replaces the `Reach()` SCNetworkReachability wrapper and
// `DeviceInfo.hasWifiConnection()` that Brave's PlaylistManager calls, using
// Network.framework instead of the deprecated SystemConfiguration API.

import Combine
import Foundation
import Network

/// Ambient network state.
///
/// The Playlist code paths that consult this are all "should I do the expensive
/// thing?" decisions: whether to block on an `AVAsset` load to discover a
/// duration, and whether an auto-download is allowed on the current network.
/// Both tolerate a stale answer, so a cached snapshot updated by a background
/// monitor is sufficient — nothing here needs to await a fresh probe.
public final class Reachability {
  public static let shared = Reachability()

  public enum Status {
    case online
    case offline
    case unknown
  }

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.overnight.playlist.reachability")
  private let subject = CurrentValueSubject<Status, Never>(.unknown)

  private var currentPath: NWPath?

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      self.currentPath = path
      self.subject.send(path.status == .satisfied ? .online : .offline)
    }
    monitor.start(queue: queue)
  }

  /// The last known connection status.
  public var connectionStatus: Status {
    subject.value
  }

  /// Emits on every change of connectivity.
  public var statusPublisher: AnyPublisher<Status, Never> {
    subject.eraseToAnyPublisher()
  }

  /// True when the current path is unmetered — i.e. Wi-Fi or wired, not
  /// cellular and not a personal hotspot.
  public var isOnUnmeteredConnection: Bool {
    guard let path = currentPath, path.status == .satisfied else { return false }
    if path.isExpensive || path.isConstrained { return false }
    return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
  }
}
