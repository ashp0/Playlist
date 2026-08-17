// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import AVFoundation
import SwiftUI
import UIKit

/// Hosts the player's `AVPlayerLayer` in SwiftUI.
///
/// The layer belongs to `MediaPlayer`, not to this view. That ownership
/// direction is deliberate and matches Brave's: the layer must survive the view
/// being torn down and rebuilt (rotation, sheet dismissal, tab switches)
/// because it is also what `AVPictureInPictureController` is attached to.
/// Creating a layer per view would break PiP and restart playback on every
/// SwiftUI update.
struct PlayerLayerView: UIViewRepresentable {
  let player: MediaPlayer

  func makeUIView(context: Context) -> PlayerHostingView {
    let view = PlayerHostingView()
    view.backgroundColor = .black
    view.attach(layer: player.attachLayer())
    return view
  }

  func updateUIView(_ uiView: PlayerHostingView, context: Context) {
    // Re-attach after a backgrounding cycle, where MediaPlayer detaches the
    // layer's player to stop video decoding while audio continues.
    uiView.attach(layer: player.attachLayer())
  }

  /// A plain `UIView` that keeps one sublayer sized to its bounds.
  final class PlayerHostingView: UIView {
    private weak var hostedLayer: CALayer?

    func attach(layer: CALayer) {
      guard hostedLayer !== layer else {
        layer.frame = bounds
        return
      }

      hostedLayer?.removeFromSuperlayer()
      layer.frame = bounds
      self.layer.addSublayer(layer)
      hostedLayer = layer
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      // Resizing a player layer animates by default, which shows as the video
      // sliding into place on every rotation.
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      hostedLayer?.frame = bounds
      CATransaction.commit()
    }
  }
}
