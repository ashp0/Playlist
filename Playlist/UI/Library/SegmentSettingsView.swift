// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// How much of each item a playlist plays before moving on.
///
/// The setting belongs to the playlist rather than to the app or to an item,
/// for the same reason the lock-screen one does: it is a property of *this*
/// collection — a practice rotation, a language course, a set of long mixes you
/// want in half-hour bites — while the rest of the library goes on playing
/// items end to end.
struct SegmentSettingsView: View {
  let folder: PlaylistFolder
  @ObservedObject var viewModel: LibraryViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var isEnabled: Bool
  @State private var minutes: Int
  @State private var seconds: Int
  @State private var isConfirmingReset = false

  /// The length to fall back to when the switch is turned on for a playlist
  /// that has never had one.
  private static let defaultMinutes = 3

  init(folder: PlaylistFolder, viewModel: LibraryViewModel) {
    self.folder = folder
    self.viewModel = viewModel

    let stored = Int(folder.segmentDuration.rounded())
    _isEnabled = State(initialValue: stored > 0)
    _minutes = State(initialValue: stored > 0 ? stored / 60 : Self.defaultMinutes)
    _seconds = State(initialValue: stored > 0 ? stored % 60 : 0)
  }

  private var segmentDuration: TimeInterval {
    TimeInterval(minutes * 60 + seconds)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle("Play in Segments", isOn: $isEnabled.animation(.easeInOut(duration: 0.2)))

          if isEnabled {
            durationPickers
          }
        } footer: {
          Text(explanation)
        }

        if folder.isSegmented {
          Section {
            Button(role: .destructive) {
              isConfirmingReset = true
            } label: {
              Label("Start Playlist Over", systemImage: "arrow.counterclockwise")
            }
          } footer: {
            Text("Sends every item in this playlist back to its first segment.")
          }
        }
      }
      .navigationTitle(folder.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { save() }
            // A playlist set to play zero seconds of each item would play
            // nothing at all.
            .disabled(isEnabled && segmentDuration <= 0)
        }
      }
      .confirmationDialog(
        "Start this playlist over?", isPresented: $isConfirmingReset, titleVisibility: .visible
      ) {
        Button("Start Over", role: .destructive) {
          viewModel.resetSegmentProgress(for: folder)
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Every item goes back to its first segment. Nothing is deleted.")
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var durationPickers: some View {
    HStack(spacing: 0) {
      Picker("Minutes", selection: $minutes) {
        ForEach(0..<61) { value in
          Text("\(value) min").tag(value)
        }
      }
      .pickerStyle(.wheel)
      .accessibilityLabel("Minutes")

      Picker("Seconds", selection: $seconds) {
        ForEach(0..<60) { value in
          Text("\(value) sec").tag(value)
        }
      }
      .pickerStyle(.wheel)
      .accessibilityLabel("Seconds")
    }
    .frame(height: 130)
  }

  private var explanation: String {
    guard isEnabled, let length = Format.duration(segmentDuration) else {
      return "Each item plays all the way through before the playlist moves on."
    }

    return """
      Each item plays for \(length), then the playlist moves on to the next one. \
      Coming back to an item plays the following \(length) rather than starting \
      it again, so a playlist on repeat works its way through everything a bit \
      at a time — and once every item has been played in full, it starts again \
      from the beginning. Items shorter than \(length) play in full.
      """
  }

  private func save() {
    viewModel.setSegmentDuration(isEnabled ? segmentDuration : 0, for: folder)
    dismiss()
  }
}
