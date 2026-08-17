// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import UIKit

/// Minimal app delegate.
///
/// Brave performs the equivalent work in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
/// and `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Only the two
/// Playlist-relevant responsibilities are kept here:
///
/// 1. Restoring in-flight background downloads on launch (`PlaylistManager.restoreSession`).
/// 2. Holding the system's completion handler while a background `URLSession` delivers events
///    to a relaunched app, so iOS knows when it is safe to suspend us again.
final class AppDelegate: NSObject, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Ensure the default folder exists before any view tries to fetch from it.
    PlaylistManager.shared.setupPlaylistFolder()
    PlaylistManager.shared.restoreSession()
    return true
  }

  /// iOS relaunches the app in the background when a background download finishes while the
  /// app is suspended. We must hold on to `completionHandler` and only call it once the
  /// URLSession delegate has finished delivering its events.
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    PlaylistManager.shared.setBackgroundSessionCompletionHandler(
      completionHandler,
      forSessionIdentifier: identifier
    )
  }
}
