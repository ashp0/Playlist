// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// Per-item storage usage, so the largest downloads are easy to find and remove.
struct StorageView: View {
  @State private var usage = PlaylistManager.StorageUsage()
  @State private var isLoading = true

  private var breakdown: [PlaylistManager.StorageUsage.Entry] { usage.largest }
  private var totalUsed: Int64 { usage.total }
  private var thumbnailCacheSize: Int64 { usage.thumbnails }
  private var availableSpace: Int64 { usage.available }

  var body: some View {
    List {
      summarySection

      if isLoading, breakdown.isEmpty {
        Section {
          HStack(spacing: 10) {
            ProgressView()
            Text("Measuring…")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      } else if !breakdown.isEmpty {
        Section {
          ForEach(breakdown) { entry in
            HStack(spacing: 12) {
              ArtworkView(item: entry.item)
                .frame(width: 56, height: 36)

              VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name)
                  .font(.subheadline)
                  .lineLimit(1)

                if let duration = Format.duration(entry.item.duration) {
                  Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              Spacer(minLength: 0)

              Text(Format.fileSize(entry.bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                _ = PlaylistManager.shared.deleteCache(item: entry.item)
                Haptics.notify(.success)
                Task { await refresh() }
              } label: {
                Label("Remove", systemImage: "trash")
              }
            }
          }
        } header: {
          Text("Largest Downloads")
        } footer: {
          Text("Swipe to remove a download. The library entry is kept.")
        }
      } else if !isLoading {
        Section {
          Text("Nothing is downloaded yet.")
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Button {
          ImageCache.shared.clear()
          Haptics.notify(.success)
          Task { await refresh() }
        } label: {
          HStack {
            Label("Clear Artwork Cache", systemImage: "photo.stack")
            Spacer()
            Text(Format.fileSize(thumbnailCacheSize))
              .foregroundStyle(.secondary)
              .contentTransition(.numericText())
          }
        }
      } footer: {
        Text("Artwork is regenerated as needed. Nothing playable is removed.")
      }
    }
    .navigationTitle("Storage")
    .navigationBarTitleDisplayMode(.inline)
    .animation(.contentChange, value: usage)
    .task { await refresh() }
    .refreshable { await refresh() }
  }

  private var summarySection: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(Format.fileSize(totalUsed))
            .font(.system(size: 32, weight: .semibold, design: .rounded))
            .monospacedDigit()

          Text("used by media")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        if availableSpace > 0 {
          usageBar
          Text("\(Format.fileSize(availableSpace)) available on this device")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 6)
    }
  }

  /// Proportion of the device's *remaining* space this app's media occupies.
  private var usageBar: some View {
    GeometryReader { geometry in
      let total = Double(totalUsed + availableSpace)
      let fraction = total > 0 ? Double(totalUsed) / total : 0

      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.2))
        Capsule()
          .fill(Color.accentColor)
          .frame(width: max(2, geometry.size.width * fraction))
      }
    }
    .frame(height: 8)
  }

  /// Re-measures, off the main thread.
  ///
  /// Every figure on this screen is a directory walk — an HLS download is a
  /// bundle of thousands of files — and they used to be taken synchronously
  /// from `.task`, which runs on the main actor. On a large library that was a
  /// visibly frozen screen for as long as the walk took.
  private func refresh() async {
    isLoading = true
    usage = await PlaylistManager.shared.storageUsage()
    isLoading = false
  }
}
