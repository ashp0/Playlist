// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// The play queue: what is playing, what is next, and in what order.
struct QueueView: View {
  @EnvironmentObject private var playback: PlaybackController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if playback.queue.isEmpty {
          ContentUnavailableView(
            "Queue Is Empty",
            systemImage: "list.bullet",
            description: Text("Play something from your library to build a queue."))
        } else {
          list
        }
      }
      .navigationTitle("Playing Next")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }

        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Toggle(isOn: shuffleBinding) {
              Label("Shuffle", systemImage: "shuffle")
            }

            Picker("Repeat", selection: repeatBinding) {
              Label("Off", systemImage: "repeat").tag(MediaPlayer.RepeatMode.none)
              Label("Repeat All", systemImage: "repeat").tag(MediaPlayer.RepeatMode.repeatAll)
              Label("Repeat One", systemImage: "repeat.1").tag(MediaPlayer.RepeatMode.repeatOne)
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("Queue options")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var list: some View {
    List {
      Section {
        ForEach(Array(playback.queue.enumerated()), id: \.element.tagId) { index, item in
          Button {
            playback.select(at: index)
          } label: {
            HStack(spacing: 12) {
              ArtworkView(item: item)
                .frame(width: 52, height: 34)

              VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                  .font(.subheadline)
                  .lineLimit(1)
                  .foregroundStyle(index == playback.currentIndex ? Color.accentColor : .primary)

                if let duration = Format.duration(item.duration) {
                  Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              Spacer(minLength: 0)

              if index == playback.currentIndex {
                Image(systemName: playback.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                  .font(.caption)
                  .foregroundStyle(.tint)
                  .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)
                  .contentTransition(.symbolEffect(.replace))
                  .transition(.scale.combined(with: .opacity))
              }
            }
          }
          .buttonStyle(.plain)
          .transition(.opacity.combined(with: .move(edge: .leading)))
        }
        .onMove { source, destination in
          playback.moveQueueItems(from: source, to: destination)
        }
        .onDelete { offsets in
          playback.removeFromQueue(at: offsets)
          Haptics.impact(.light)
        }
      } footer: {
        Text(queueSummary)
          .contentTransition(.numericText())
      }
    }
    .animation(.contentChange, value: playback.queue.map(\.tagId))
    .animation(.contentChange, value: playback.currentIndex)
    .listStyle(.plain)
    // NOTE: this list used to force `editMode` to `.active`, on the reasoning
    // that a list whose purpose is reordering should not need a trip through an
    // Edit button. It does not: a long press picks a row up either way. What
    // edit mode did do was stop a plain tap reaching the row's button, which is
    // how a queue item is played — so the screen's other purpose, jumping
    // straight to a track, could not be used at all.
  }

  private var queueSummary: String {
    let count = playback.queue.count
    let position = (playback.currentIndex ?? 0) + 1
    return "\(position) of \(count)"
  }

  private var shuffleBinding: Binding<Bool> {
    Binding(
      get: { playback.isShuffleEnabled },
      set: { playback.setShuffle($0) })
  }

  private var repeatBinding: Binding<MediaPlayer.RepeatMode> {
    Binding(
      get: { playback.repeatMode },
      set: { playback.setRepeatMode($0) })
  }
}
