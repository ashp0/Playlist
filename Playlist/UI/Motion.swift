// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// No upstream counterpart. Brave's Playlist is UIKit and animates ad hoc at
// each call site.

import SwiftUI
import UIKit

// MARK: - Animation vocabulary

/// The app's motion vocabulary.
///
/// Named springs rather than numbers spread through the views, for the reason
/// any design system exists: a screen where every animation was tuned on its
/// own reads as a collection of parts. These are four, and everything that
/// moves picks one.
extension Animation {

  /// Large surfaces arriving or leaving — the player covering the screen.
  ///
  /// Slower and softer than the rest: a full-screen surface carries more
  /// apparent mass, and moving it at the speed of a button reads as a jump cut.
  static let playerPresent = Animation.spring(response: 0.44, dampingFraction: 0.86)

  /// Content changing inside a surface that is staying put — a row appearing,
  /// a badge arriving, the mini player swapping tracks.
  static let contentChange = Animation.spring(response: 0.34, dampingFraction: 0.82)

  /// A control acknowledging a tap. Short enough to feel like a response to the
  /// finger rather than an animation about it.
  static let controlFeedback = Animation.spring(response: 0.26, dampingFraction: 0.7)

  /// Something appearing or disappearing without moving — a state label, a
  /// progress bar arriving under a row.
  static let stateFade = Animation.easeInOut(duration: 0.22)

  /// The spring the player travels on, launched at the speed the finger left.
  ///
  /// Releasing a drag into a spring that starts from rest is what makes a fast
  /// flick and a slow release look identical — the gesture ends and something
  /// else takes over. Carrying the velocity across means the release is not a
  /// separate event from the drag, it is the same motion continuing without a
  /// hand on it.
  ///
  /// - Parameters:
  ///   - velocity: the finger's speed, in points per second.
  ///   - distance: the points still to travel. `initialVelocity` is a fraction
  ///     of the remaining distance per second, so the two divide; a velocity
  ///     with nowhere left to go would otherwise be an infinite one.
  static func playerTravel(velocity: CGFloat, over distance: CGFloat) -> Animation {
    let normalized = abs(distance) < 1 ? 0 : velocity / distance
    // Clamped because a fast flick over the last few points computes an
    // enormous fraction-per-second, and a spring given one overshoots wildly
    // before it settles.
    let initialVelocity = min(max(normalized, -32), 32)

    // Slightly under critical damping (ζ ≈ 0.93): it settles without a visible
    // bounce, which a surface the size of the screen cannot afford, while still
    // arriving rather than decelerating to a stop.
    return .interpolatingSpring(
      mass: 1, stiffness: 260, damping: 30, initialVelocity: initialVelocity)
  }
}

// MARK: - Button styles

/// A transport control that gives under the finger.
///
/// SwiftUI's default styling for an image-only button in a dark surface is a
/// brief opacity change and nothing else, which on a 66-point play button reads
/// as a flicker rather than a press. Scaling is what makes it read as a key
/// being pushed — and the release is a spring rather than a fade, so the button
/// comes back up the way a physical one would.
struct TransportButtonStyle: ButtonStyle {
  var pressedScale: CGFloat = 0.86

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? pressedScale : 1)
      .opacity(configuration.isPressed ? 0.7 : 1)
      .animation(.controlFeedback, value: configuration.isPressed)
  }
}

// MARK: - Haptics

/// Touch feedback.
///
/// Every generator is created and released per event rather than kept around.
/// Holding one keeps the Taptic Engine warm, which costs power for no benefit
/// at the rate this app fires them — a handful per session, all in response to
/// something the user did.
public enum Haptics {

  /// A physical event: a surface arriving, a card being let go.
  public static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
  }

  /// A mode changing under the finger — shuffle, repeat, a playlist selected.
  public static func selection() {
    UISelectionFeedbackGenerator().selectionChanged()
  }

  /// An outcome worth confirming without looking: items added, a download
  /// finished, a destructive action carried out.
  public static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    UINotificationFeedbackGenerator().notificationOccurred(type)
  }
}
