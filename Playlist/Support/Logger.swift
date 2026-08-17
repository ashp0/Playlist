// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import os.log

extension Logger {
  /// Stand-in for Brave's `Logger.module`, which resolves to a per-SPM-module
  /// logger. This app is a single module, so there is a single category.
  static let module = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.overnight.playlist",
    category: "Playlist"
  )
}
