// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// The paste-a-URL flow: paste → extract → review → download.
///
/// This is the app's primary entry point, and the screen with no counterpart in
/// Brave — where items arrive from the tab the user is already browsing.
struct AddMediaView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var playback: PlaybackController

  /// Prefilled address. When present, extraction starts immediately — the
  /// address came from somewhere the user already chose it (a share, a
  /// Shortcut), so making them tap Find again is pure friction.
  var initialURL: String?

  /// Where what is added is filed.
  ///
  /// The playlist being browsed, when one is — adding from inside a playlist
  /// and having the item land somewhere else is a surprise the user only
  /// discovers later, by not finding it. Nil means the library at large, which
  /// files into the default folder the way it always has.
  var destinationFolderUUID: String?

  /// Its name, for saying so before the user commits.
  var destinationFolderTitle: String?

  let onAdded: () -> Void

  @State private var urlText = ""
  @State private var phase: Phase = .idle
  @State private var results = [PlaylistInfo]()
  @State private var selection = Set<String>()
  @State private var extractionTask: Task<Void, Never>?
  @FocusState private var isFieldFocused: Bool

  private enum Phase: Equatable {
    case idle
    case extracting
    case results
    case failed(String)
  }

  var body: some View {
    NavigationStack {
      Form {
        inputSection

        Group {
          switch phase {
          case .idle:
            hintSection
          case .extracting:
            extractingSection
          case .results:
            resultsSection
          case .failed(let message):
            failureSection(message)
          }
        }
        .transition(.opacity)
      }
      .animation(.contentChange, value: phase)
      .navigationTitle("Add Media")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            extractionTask?.cancel()
            MediaExtractor.shared.cancel()
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          if phase == .results {
            Button("Add") { addSelected() }
              .disabled(selection.isEmpty)
              .fontWeight(.semibold)
          } else {
            Button("Find") { startExtraction() }
              .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || phase == .extracting)
              .fontWeight(.semibold)
          }
        }
      }
      .onAppear {
        if let initialURL = initialURL, !initialURL.isEmpty {
          urlText = initialURL
          startExtraction()
        } else {
          isFieldFocused = true
        }
      }
      .onDisappear {
        extractionTask?.cancel()
      }
    }
  }

  // MARK: - Sections

  private var inputSection: some View {
    Section {
      HStack {
        Image(systemName: "link")
          .foregroundStyle(.secondary)

        TextField("https://…", text: $urlText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .submitLabel(.search)
          .focused($isFieldFocused)
          .onSubmit(startExtraction)
          .onChange(of: urlText) { _, _ in
            // Editing the address invalidates whatever was found for the old one.
            if phase != .idle && phase != .extracting {
              phase = .idle
              results = []
              selection = []
            }
          }

        if urlText.isEmpty {
          pasteButton
        } else {
          Button {
            urlText = ""
            phase = .idle
            results = []
            selection = []
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear address")
        }
      }
      .animation(.stateFade, value: urlText.isEmpty)
    } header: {
      Text("Page or Media Address")
    }
  }

  /// Offers the clipboard, without reading it.
  ///
  /// NOTE: this screen used to fill the field in from the clipboard as it
  /// appeared. Since iOS 16 an unprompted read puts a system alert in front of
  /// the user asking them to allow it — so the convenience cost a modal on
  /// every visit, and the app took a look at the pasteboard whether or not
  /// there was anything on it for us. `PasteButton` hands the value over on an
  /// explicit tap with no alert and no read until then, which is both the
  /// private answer and the smaller amount of UI.
  private var pasteButton: some View {
    PasteButton(payloadType: URL.self) { urls in
      guard let url = urls.first, url.scheme == "http" || url.scheme == "https" else { return }
      urlText = url.absoluteString
      startExtraction()
    }
    .labelStyle(.iconOnly)
    .buttonBorderShape(.capsule)
    .accessibilityLabel("Paste address")
  }

  private var hintSection: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text("Paste a page address").font(.subheadline.weight(.medium))
          Text("The page is loaded in the background and any video or audio on it is detected.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.tint)
      }

      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text("Or a direct media address").font(.subheadline.weight(.medium))
          Text("A link ending in .mp4, .m3u8, .mp3 and so on is added straight away.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "waveform").foregroundStyle(.tint)
      }
    } footer: {
      Text(
        "Some sites deliver video in a form that can't be saved for offline use. "
          + "If nothing is found, that's usually why.")
    }
  }

  private var extractingSection: some View {
    Section {
      HStack(spacing: 12) {
        ProgressView()
        VStack(alignment: .leading, spacing: 2) {
          Text("Looking for media…").font(.subheadline)
          Text("This can take a few seconds.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func failureSection(_ message: String) -> some View {
    Section {
      Label {
        Text(message).font(.subheadline)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      .padding(.vertical, 2)
    }
  }

  private var resultsSection: some View {
    Section {
      ForEach(results) { item in
        Button {
          toggle(item)
        } label: {
          HStack(spacing: 12) {
            Image(
              systemName: selection.contains(item.tagId)
                ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 20))
              .foregroundStyle(
                selection.contains(item.tagId) ? Color.accentColor : Color.secondary.opacity(0.4))
              .contentTransition(.symbolEffect(.replace))
              .animation(.controlFeedback, value: selection.contains(item.tagId))

            ArtworkView(item: item)
              .frame(width: 68, height: 44)

            VStack(alignment: .leading, spacing: 3) {
              Text(item.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

              HStack(spacing: 6) {
                if let duration = Format.duration(item.duration) {
                  Text(duration)
                } else if item.duration >= TimeInterval(Int32.max) {
                  Text("LIVE")
                }
                Text(mediaKindLabel(for: item))
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
          }
        }
        .buttonStyle(.plain)
      }
    } header: {
      Text(results.count == 1 ? "1 Item Found" : "\(results.count) Items Found")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if let destination = destinationFolderTitle {
          Label("Saving to “\(destination)”", systemImage: "folder")
        }
        if results.count > 1 {
          Text("The first result is usually the main video. Others may be ads or previews.")
        }
      }
    }
  }

  // MARK: - Actions

  private func mediaKindLabel(for item: PlaylistInfo) -> String {
    if let url = URL(string: item.src), PlaylistMimeTypeDetector.isHLS(url: url) {
      return "Stream"
    }
    if PlaylistMimeTypeDetector.isHLS(mimeType: item.mimeType) {
      return "Stream"
    }
    if item.mimeType.contains("audio") {
      return "Audio"
    }
    return "Video"
  }

  private func toggle(_ item: PlaylistInfo) {
    Haptics.selection()

    if selection.contains(item.tagId) {
      selection.remove(item.tagId)
    } else {
      selection.insert(item.tagId)
    }
  }

  private func startExtraction() {
    let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Accept "youtube.com/watch?v=…" without a scheme, the way an address bar
    // would.
    let normalized =
      trimmed.contains("://") ? trimmed : "https://\(trimmed)"

    guard let url = URL(string: normalized), url.host != nil else {
      phase = .failed(MediaExtractor.ExtractionError.invalidURL.localizedDescription)
      return
    }

    isFieldFocused = false
    phase = .extracting
    results = []
    selection = []

    extractionTask?.cancel()
    extractionTask = Task {
      do {
        let found = try await MediaExtractor.shared.extract(from: url)
        guard !Task.isCancelled else { return }

        results = found
        // Preselect the best candidate — the common case is one item and an
        // immediate tap on Add.
        selection = Set(found.prefix(1).map(\.tagId))
        phase = .results
        Haptics.notify(.success)
      } catch {
        guard !Task.isCancelled else { return }
        phase = .failed(error.localizedDescription)
        Haptics.notify(.error)
      }
    }
  }

  private func addSelected() {
    let chosen = results.filter { selection.contains($0.tagId) }
    guard !chosen.isEmpty else { return }

    for item in chosen {
      PlaylistItem.addItem(item, folderUUID: destinationFolderUUID, cachedData: nil) {
        // Auto-download runs after the row exists, because the download manager
        // writes the resulting bookmark back onto that row.
        PlaylistManager.shared.autoDownload(item: item)
      }
    }

    Haptics.notify(.success)
    onAdded()
    dismiss()
  }
}
