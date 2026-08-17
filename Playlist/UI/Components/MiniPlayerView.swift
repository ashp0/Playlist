// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// The persistent bar above the tab bar showing what is playing.
///
/// Present on every tab so playback stays reachable while browsing the library
/// or changing settings — the same reason Music and Podcasts have one.
struct MiniPlayerView: View {
  @EnvironmentObject private var playback: PlaybackController
  let onTap: () -> Void

  var body: some View {
    if let item = playback.currentItem {
      VStack(spacing: 0) {
        progressBar

        HStack(spacing: 12) {
          // A button rather than a tap gesture on the bar as a whole. The
          // gesture worked for a finger and for nothing else: VoiceOver was
          // offered a container with a label and no action, so the one thing
          // this bar is mostly for — opening the player — could not be done
          // from it at all. A button also gets the press state for free.
          Button(action: openPlayer) {
            HStack(spacing: 12) {
              ArtworkView(item: item, cornerRadius: 6)
                .frame(width: 40, height: 40)

              VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                  .font(.footnote.weight(.medium))
                  .lineLimit(1)
                  .foregroundStyle(.primary)

                subtitle(for: item)
              }

              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(MiniPlayerButtonStyle())
          .accessibilityLabel("Now playing: \(item.name)")
          .accessibilityHint("Opens the full player")

          Button {
            playback.togglePlayPause()
            Haptics.impact(.light)
          } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 18))
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
              .contentTransition(.symbolEffect(.replace))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

          Button {
            playback.next()
          } label: {
            Image(systemName: "forward.fill")
              .font(.system(size: 16))
              .frame(width: 36, height: 36)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
      }
      .background(.regularMaterial)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      // Only the title and subtitle cross-fade on a track change; the artwork
      // has its own fade and the transport must not appear to move.
      .animation(.contentChange, value: item.tagId)
      .animation(.stateFade, value: playback.isPlaying)
      .accessibilityElement(children: .contain)
    }
  }

  /// What the bar says under the title: a problem if there is one, otherwise
  /// what it is doing, otherwise where the item came from.
  ///
  /// The error case matters more than it looks. `errorMessage` is only ever
  /// presented as an alert on the full player, so a load that failed while the
  /// player was closed — which is most of them, since playback is usually
  /// started from a library row — left the bar sitting there with a play button
  /// that did nothing and no indication why.
  @ViewBuilder
  private func subtitle(for item: PlaylistInfo) -> some View {
    Group {
      if let error = playback.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(1)
      } else if playback.isRefreshingMedia {
        Text("Refreshing link…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if playback.isBuffering {
        Text("Loading…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if let segment = playback.currentSegment {
        Text("Part \(segment.index + 1) of \(segment.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if let host = URL(string: item.pageSrc)?.baseDomain {
        Text(host)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .transition(.opacity)
    .animation(.stateFade, value: playback.isBuffering)
    .animation(.stateFade, value: playback.isRefreshingMedia)
    .animation(.stateFade, value: playback.errorMessage)
  }

  private func openPlayer() {
    // A failure the user has now seen and acted on should not follow them into
    // the player as an alert about something they already know.
    playback.errorMessage = nil
    onTap()
  }

  private var progressBar: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(Color.secondary.opacity(0.2))

        Rectangle()
          .fill(Color.accentColor)
          .frame(width: geometry.size.width * playback.progressFraction)
          // The player publishes a position four times a second. Interpolating
          // between those makes the hairline travel rather than tick, and the
          // duration is matched to the interval so it arrives just as the next
          // one lands instead of easing to a halt and jumping.
          .animation(.linear(duration: 0.25), value: playback.progressFraction)
      }
    }
    .frame(height: 2)
    .accessibilityHidden(true)
  }
}

/// The mini player's tap area: a press dims and settles rather than flashing.
///
/// `.plain` gives no feedback at all on a row this size, and `.borderless`
/// tints the title — which reads as the text being the control rather than the
/// bar.
private struct MiniPlayerButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.55 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1, anchor: .leading)
      .animation(.controlFeedback, value: configuration.isPressed)
  }
}
