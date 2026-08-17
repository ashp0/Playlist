// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Derived from Brave Browser for iOS (github.com/brave/brave-ios), which is
// licensed under MPL-2.0. See Docs/BRAVE-COMPONENTS.md for the full provenance
// of every file in this project.

import SwiftUI

@main
struct PlaylistApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
