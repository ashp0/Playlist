// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// Everything about the offline copies: what is transferring, what is stored,
/// what failed, and how much space it all takes.
struct DownloadsView: View {
  /// Scoped to the whole library on purpose. What is downloaded has nothing to
  /// do with which playlist the Library tab happens to be showing, and the
  /// default scope follows that selection — so this screen went empty whenever
  /// an empty playlist was open in the other tab.
  @StateObject private var viewModel = LibraryViewModel(scope: .wholeLibrary)
  @EnvironmentObject private var playback: PlaybackController

  /// Sizes, measured once off the main thread rather than per row per frame.
  @State private var usage = PlaylistManager.StorageUsage()

  private var storageUsed: Int64 { usage.total }
  private var availableSpace: Int64 { usage.available }

  var body: some View {
    NavigationStack {
      Group {
        if active.isEmpty && downloaded.isEmpty && notDownloaded.isEmpty {
          ContentUnavailableView(
            "No Downloads",
            systemImage: "arrow.down.circle",
            description: Text("Items you download for offline use will appear here."))
          .transition(.opacity)
        } else {
          list
        }
      }
      .navigationTitle("Downloads")
      .toolbar {
        if !notDownloaded.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              downloadAll()
            } label: {
              Label("Download All", systemImage: "arrow.down.circle")
            }
            .accessibilityLabel("Download all remaining items")
          }
        }
      }
      .animation(.contentChange, value: viewModel.items.map(\.tagId))
      .animation(.contentChange, value: viewModel.downloadStates)
      .task { await refreshStorage() }
      // A finished download changes both what is in each section and how much
      // room it all takes, and the sizes cannot be read from the row.
      .onChange(of: viewModel.downloadStates) { _, _ in
        Task { await refreshStorage() }
      }
      .refreshable {
        viewModel.reload()
        await refreshStorage()
      }
    }
  }

  private var list: some View {
    List {
      storageSection

      if !active.isEmpty {
        Section("In Progress") {
          ForEach(active) { item in
            activeRow(item)
          }
        }
      }

      if !downloaded.isEmpty {
        Section {
          ForEach(downloaded) { item in
            Button {
              playback.select(item: item, in: downloaded)
            } label: {
              HStack {
                MediaRowView(
                  item: item,
                  downloadState: .downloaded,
                  downloadProgress: nil,
                  isCurrentlyPlaying: playback.currentItem?.tagId == item.tagId,
                  isPlaying: playback.isPlaying && playback.currentItem?.tagId == item.tagId)

                if let bytes = usage.perItem[item.tagId] {
                  Text(Format.fileSize(bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                viewModel.removeDownload(item)
                Haptics.notify(.success)
                Task { await refreshStorage() }
              } label: {
                Label("Remove", systemImage: "trash")
              }
            }
          }
        } header: {
          Text("Available Offline")
        } footer: {
          Text("These play with no network connection.")
        }
      }

      if !notDownloaded.isEmpty {
        Section {
          ForEach(notDownloaded) { item in
            HStack {
              MediaRowView(
                item: item,
                downloadState: .invalid,
                downloadProgress: nil)

              Button {
                viewModel.download(item)
                Haptics.impact(.light)
              } label: {
                Image(systemName: "arrow.down.circle")
                  .font(.system(size: 20))
              }
              .buttonStyle(TransportButtonStyle(pressedScale: 0.82))
              .accessibilityLabel("Download \(item.name)")
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .transition(.opacity.combined(with: .move(edge: .leading)))
          }
        } header: {
          Text("Online Only")
        } footer: {
          Text(
            "These stream from their original source. Media links expire, so download "
              + "anything you want to keep.")
        }
      }
    }
  }

  private func activeRow(_ item: PlaylistInfo) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        ArtworkView(item: item)
          .frame(width: 68, height: 44)

        VStack(alignment: .leading, spacing: 3) {
          Text(item.name)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)

          Text(progressLabel(for: item))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 0)

        Button {
          viewModel.cancelDownload(item)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel download")
      }

      if let progress = viewModel.progress(for: item), progress > 0 {
        ProgressView(value: progress, total: 100)
          .tint(.accentColor)
          // Progress arrives in bursts as the transfer reports in. Interpolating
          // makes the bar advance rather than jump, which is the difference
          // between a download that looks alive and one that looks stuck
          // between updates.
          .animation(.easeOut(duration: 0.3), value: progress)
      } else {
        // No Content-Length: the transfer is running but its size is unknown.
        ProgressView().progressViewStyle(.linear)
      }
    }
    .padding(.vertical, 2)
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  private func progressLabel(for item: PlaylistInfo) -> String {
    if let error = PlaylistManager.shared.downloadErrors[item.tagId] {
      return error
    }
    if let progress = viewModel.progress(for: item), progress > 0 {
      return "\(Int(progress))%"
    }
    return "Starting…"
  }

  // MARK: - Storage

  private var storageSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Downloaded Media", systemImage: "internaldrive")
            .font(.subheadline.weight(.medium))
          Spacer()
          Text(Format.fileSize(storageUsed))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }

        if availableSpace > 0 {
          Text("\(Format.fileSize(availableSpace)) available on this device")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 2)
      .animation(.contentChange, value: usage)
    }
  }

  private func refreshStorage() async {
    usage = await PlaylistManager.shared.storageUsage()
  }

  // MARK: - Partitions

  private var active: [PlaylistInfo] {
    viewModel.items.filter { viewModel.state(for: $0) == .inProgress }
  }

  private var downloaded: [PlaylistInfo] {
    viewModel.items.filter { viewModel.state(for: $0) == .downloaded }
  }

  private var notDownloaded: [PlaylistInfo] {
    viewModel.items.filter { viewModel.state(for: $0) == .invalid }
  }

  private func downloadAll() {
    Haptics.impact(.medium)
    for item in notDownloaded {
      viewModel.download(item)
    }
  }
}
