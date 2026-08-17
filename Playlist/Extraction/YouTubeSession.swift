// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// New in this app. Brave has no equivalent because a browser *is* the session:
// Playlist there runs in the tab you are already signed into. With the browser
// removed, extraction runs in a throwaway web view with no cookies at all,
// which is why age-restricted videos could not be reached.
//
// This is the smallest thing that restores that capability: one persistent
// cookie store, written by a sign-in web view the user drives themselves, and
// read by the extraction loader.
//
// The app never sees, stores, or transmits a password. The sign-in view is a
// plain WebKit view pointed at Google's own login page, restricted to Google's
// own hosts; the user types into Google's form, and all this app keeps is the
// resulting cookie — in WebKit's own store, which is exactly where a browser
// would keep it.

import Combine
import Foundation
import WebKit
import os.log

/// Tracks whether a YouTube session exists, and owns the cookie store it lives in.
@MainActor
public final class YouTubeSession: ObservableObject {
  public static let shared = YouTubeSession()

  /// Cookies live in WebKit's default (persistent) store, so a sign-in survives
  /// relaunches the way it would in a browser.
  public let dataStore: WKWebsiteDataStore = .default()

  @Published public private(set) var isSignedIn = false

  /// Cookies that indicate a signed-in Google/YouTube session.
  ///
  /// `LOGIN_INFO` is YouTube's own and is the one that actually governs whether
  /// a watch page will serve age-restricted content; the `SID` family is
  /// Google-wide. Any of them present means there is a session worth using.
  private static let authCookieNames: Set<String> = [
    "LOGIN_INFO", "SID", "__Secure-1PSID", "__Secure-3PSID",
  ]

  private init() {}

  /// Where a page should be loaded from.
  ///
  /// Extraction stays cookieless by default — nothing about loading a random
  /// pasted page should persist. The signed-in store is used only for YouTube,
  /// and only once the user has deliberately signed in, which is the trade they
  /// opted into by doing so.
  public func dataStore(for url: URL) -> WKWebsiteDataStore {
    (isSignedIn && YouTube.isYouTube(url)) ? dataStore : .nonPersistent()
  }

  /// Re-reads the cookie store. Call after the sign-in view closes, and at launch.
  public func refresh() async {
    let cookies = await dataStore.httpCookieStore.allCookies()
    let signedIn = cookies.contains { cookie in
      Self.authCookieNames.contains(cookie.name)
        && (cookie.domain.hasSuffix("google.com") || cookie.domain.hasSuffix("youtube.com"))
        && !cookie.value.isEmpty
    }

    if signedIn != isSignedIn {
      isSignedIn = signedIn
      Logger.module.debug("YouTube session \(signedIn ? "established" : "cleared")")
    }
  }

  /// Forgets the session entirely: cookies, storage and caches for Google's hosts.
  public func signOut() async {
    let store = dataStore.httpCookieStore
    for cookie in await store.allCookies()
    where cookie.domain.hasSuffix("google.com") || cookie.domain.hasSuffix("youtube.com") {
      await store.deleteCookie(cookie)
    }

    // Cookies alone are not the whole session — a signed-in identity is also
    // cached in local storage and IndexedDB, and leaving those behind lets the
    // next load re-establish what the user just asked to forget.
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    let records = await dataStore.dataRecords(ofTypes: types)
    let googleRecords = records.filter {
      $0.displayName.contains("google") || $0.displayName.contains("youtube")
    }
    if !googleRecords.isEmpty {
      await dataStore.removeData(ofTypes: types, for: googleRecords)
    }

    await refresh()
  }
}
