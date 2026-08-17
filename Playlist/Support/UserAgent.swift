// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Replaces Brave's `UserAgent` module. Brave builds its strings from Chromium's
// version constants at runtime; here they are static Safari strings, which is
// what matters to the sites we extract from.

import Foundation
import UIKit

/// User agent strings used for page extraction, media probing and downloads.
///
/// The same UA must be used for all three. Media hosts routinely bind a media
/// URL to the session that requested the page, and a CDN that sees the page
/// fetched as desktop Safari but the media fetched as a bare `URLSession` will
/// hand back a 403.
public enum UserAgent {
  /// Whether requests should present as desktop Safari.
  ///
  /// Desktop is the default: several large video sites serve HLS-only or
  /// app-redirect pages to mobile Safari, and the desktop page is far more
  /// likely to expose a `<video src>` the detector can see.
  public static var shouldUseDesktopMode: Bool {
    Preferences.Playlist.useDesktopUserAgent.value
  }

  public static let desktop =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"

  public static let mobile =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

  /// The UA to send right now.
  public static var current: String {
    shouldUseDesktopMode ? desktop : mobile
  }

  /// The UA to request a particular page with.
  ///
  /// The global desktop default is right for most sites and wrong for exactly
  /// one that matters: YouTube omits progressive formats entirely from a watch
  /// page requested as desktop, and includes them for an iPhone — so a desktop
  /// UA leaves the `MediaSource` swizzle with nothing to fall back to. This is
  /// decided before any of our JavaScript runs, so it cannot be fixed later in
  /// the page; it has to be right on the request. See `YouTube`.
  ///
  /// Only the *page* needs this. The media URL the page then produces is not
  /// bound to a user agent — it downloads with any UA, or none.
  public static func userAgent(for url: URL) -> String {
    YouTube.isYouTube(url) ? mobile : current
  }
}
