// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// Sleep timer picker.
///
/// No counterpart in Brave — a browser feature has no reason to stop playing
/// after twenty minutes, but a bedtime media player does.
struct SleepTimerView: View {
  @EnvironmentObject private var playback: PlaybackController
  @Environment(\.dismiss) private var dismiss

  private static let durations: [TimeInterval] = [
    5 * 60, 10 * 60, 15 * 60, 30 * 60, 45 * 60, 60 * 60, 90 * 60,
  ]

  var body: some View {
    NavigationStack {
      List {
        if let timer = playback.sleepTimer {
          Section {
            HStack {
              Label {
                switch timer.mode {
                case .endOfTrack:
                  Text("Stops at end of track")
                case .duration:
                  HStack(spacing: 0) {
                    Text("Stops in ")
                    SleepTimerCountdown(timer: timer)
                  }
                }
              } icon: {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.tint)
              }

              Spacer()

              Button("Cancel", role: .destructive) {
                playback.cancelSleepTimer()
                dismiss()
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }
        }

        Section {
          ForEach(Self.durations, id: \.self) { duration in
            Button {
              playback.startSleepTimer(.duration(duration))
              dismiss()
            } label: {
              HStack {
                Text(label(for: duration))
                Spacer()
                if case .duration(let active) = playback.sleepTimer?.mode, active == duration {
                  Image(systemName: "checkmark").foregroundStyle(.tint)
                }
              }
            }
            .buttonStyle(.plain)
          }
        } header: {
          Text("Stop After")
        }

        Section {
          Button {
            playback.startSleepTimer(.endOfTrack)
            dismiss()
          } label: {
            HStack {
              Label("End of Current Track", systemImage: "music.note")
              Spacer()
              if playback.sleepTimer?.mode == .endOfTrack {
                Image(systemName: "checkmark").foregroundStyle(.tint)
              }
            }
          }
          .buttonStyle(.plain)
        } footer: {
          Text("Playback pauses when the timer runs out. Nothing is deleted.")
        }
      }
      .navigationTitle("Sleep Timer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  private func label(for duration: TimeInterval) -> String {
    let minutes = Int(duration / 60)
    if minutes >= 60 {
      let hours = minutes / 60
      let remainder = minutes % 60
      if remainder == 0 {
        return hours == 1 ? "1 hour" : "\(hours) hours"
      }
      return "\(hours) hr \(remainder) min"
    }
    return "\(minutes) minutes"
  }
}
