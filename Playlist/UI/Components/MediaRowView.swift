// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// One item in the library list.
struct MediaRowView: View {
  let item: PlaylistInfo
  let downloadState: PlaylistDownloadManager.DownloadState
  let downloadProgress: Double?
  var isCurrentlyPlaying: Bool = false
  var isPlaying: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        ArtworkView(item: item)
          .frame(width: 68, height: 44)

        if isCurrentlyPlaying {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.black.opacity(0.45))
            .frame(width: 68, height: 44)
            .transition(.opacity)

          Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .contentTransition(.symbolEffect(.replace))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
      }
      .animation(.contentChange, value: isCurrentlyPlaying)
      .animation(.stateFade, value: isPlaying)

      VStack(alignment: .leading, spacing: 3) {
        Text(item.name)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
          .foregroundStyle(isCurrentlyPlaying ? Color.accentColor : Color.primary)

        HStack(spacing: 6) {
          if let duration = Format.duration(item.duration) {
            Text(duration)
          } else if item.duration >= TimeInterval(Int32.max) {
            Text("LIVE")
          }

          if let host = URL(string: item.pageSrc)?.baseDomain {
            if Format.duration(item.duration) != nil {
              Text("·")
            }
            Text(host).lineLimit(1)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 4)

      statusIndicator
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .animation(.contentChange, value: downloadState)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch downloadState {
    case .downloaded:
      Image(systemName: "arrow.down.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(.green)
        .accessibilityLabel("Downloaded")

    case .inProgress:
      // An indeterminate spinner when the server sent no Content-Length,
      // otherwise a real progress ring.
      if let progress = downloadProgress, progress > 0 {
        CircularProgressView(progress: progress / 100.0)
          .frame(width: 18, height: 18)
          .accessibilityLabel("Downloading, \(Int(progress)) percent")
      } else {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Downloading")
      }

    case .invalid:
      Image(systemName: "icloud")
        .font(.system(size: 15))
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Not downloaded, streams online")
    }
  }
}

/// A thin determinate ring, sized to sit inline in a list row.
struct CircularProgressView: View {
  let progress: Double

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.25), lineWidth: 2)

      Circle()
        .trim(from: 0, to: max(0.02, min(1, progress)))
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.easeInOut(duration: 0.25), value: progress)
    }
  }
}
