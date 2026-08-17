// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// The time left on a sleep timer, ticking down once a second.
///
/// `SleepTimer.remaining` is derived from a deadline rather than stored, so
/// nothing publishes when it changes: the controller announces the timer once
/// when it is set and again when it is cancelled, and in between the value goes
/// stale in place. Both places that showed it were therefore frozen at whatever
/// it read when the view was last built — a countdown that never counted.
///
/// A `TimelineView` is the fix rather than a shared `Timer`, because it stops
/// on its own when the view is off screen. A timer feeding published state
/// would keep waking the app once a second for a label nobody is looking at,
/// through the whole of a night's playback, which is precisely the wrong
/// trade for the one feature people leave running while they fall asleep.
struct SleepTimerCountdown: View {
  let timer: PlaybackController.SleepTimer

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      let remaining = timer.remaining ?? 0

      Text(Format.duration(remaining) ?? "0:00")
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: true))
        // Keyed on whole seconds: the timeline redraws on its own schedule, and
        // an animation keyed on the raw interval would restart mid-flight.
        .animation(.snappy(duration: 0.2), value: Int(remaining))
        .accessibilityLabel(accessibilityLabel(remaining))
    }
  }

  private func accessibilityLabel(_ remaining: TimeInterval) -> String {
    let minutes = Int((remaining / 60).rounded())
    switch minutes {
    case 0: return "Less than a minute left"
    case 1: return "1 minute left"
    default: return "\(minutes) minutes left"
    }
  }
}
