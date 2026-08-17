// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Playlist/PlaylistAssetFetcher.swift`.

import AVFoundation
import Foundation

/// Ties an in-flight `AVURLAsset` metadata load to the item that requested it.
///
/// `AVURLAsset.loadValuesAsynchronously` has no cancellation token of its own —
/// the only way to stop it is to call `cancelLoading()` on the asset. Pairing
/// the asset with its item id is what lets `PlaylistManager` abandon a duration
/// fetch when the user deletes the item mid-load, instead of leaking a network
/// request that resolves against a row that no longer exists.
public class PlaylistAssetFetcher {
  let itemId: String
  private let asset: AVURLAsset

  public init(itemId: String, asset: AVURLAsset) {
    self.itemId = itemId
    self.asset = asset
  }

  public func cancelLoading() {
    asset.cancelLoading()
  }
}
