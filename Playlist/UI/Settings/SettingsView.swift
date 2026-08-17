// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// App settings.
///
/// The extraction options are the ones that most affect whether a given site
/// works, so each carries an explanation of the trade-off rather than a bare
/// toggle — they are the knobs a user will actually reach for when a link fails.
struct SettingsView: View {
  @EnvironmentObject private var playback: PlaybackController

  @State private var autoDownload = PlayListDownloadType(
    rawValue: Preferences.Playlist.autoDownloadVideo.value) ?? .on
  @State private var resumePlayback = Preferences.Playlist.playbackLeftOff.value
  @State private var autoPlayNext = Preferences.Playlist.autoPlayNext.value
  @State private var useDesktopUA = Preferences.Playlist.useDesktopUserAgent.value
  @State private var allowMediaSource = Preferences.Playlist.webMediaSourceCompatibility.value
  @State private var seekInterval = Preferences.Playlist.seekInterval.value
  @State private var pictureInPicture = Preferences.Playlist.pictureInPictureEnabled.value

  @State private var isShowingDeleteAllConfirmation = false
  @State private var isShowingClearCacheConfirmation = false
  @State private var isShowingSignIn = false
  @State private var isSigningOut = false

  /// Measured off the main thread and held here.
  ///
  /// The storage row used to call `totalStorageUsed()` inline in `body`, which
  /// walks the whole media directory — so every redraw of this screen, and
  /// there is one per toggle, stat-ed every downloaded file before it could
  /// draw a single row.
  @State private var storageUsed: Int64?

  @ObservedObject private var youTubeSession = YouTubeSession.shared

  var body: some View {
    NavigationStack {
      Form {
        playbackSection
        downloadSection
        extractionSection
        accountSection
        storageSection
        aboutSection
      }
      .navigationTitle("Settings")
      // Presented from the root rather than from `accountSection`: a `.sheet`
      // attached to a `Section` inside a `Form` is not reliably presented.
      .sheet(isPresented: $isShowingSignIn) {
        SignInView()
      }
      .task {
        await YouTubeSession.shared.refresh()
      }
      .task {
        storageUsed = await PlaylistManager.shared.storageUsage().total
      }
    }
  }

  // MARK: - Playback

  private var playbackSection: some View {
    Section {
      Toggle("Resume Where You Left Off", isOn: $resumePlayback)
        .onChange(of: resumePlayback) { _, newValue in
          Preferences.Playlist.playbackLeftOff.value = newValue
        }

      Toggle("Play Next Automatically", isOn: $autoPlayNext)
        .onChange(of: autoPlayNext) { _, newValue in
          Preferences.Playlist.autoPlayNext.value = newValue
        }

      Toggle("Picture in Picture", isOn: $pictureInPicture)
        .onChange(of: pictureInPicture) { _, newValue in
          playback.player.isPictureInPictureEnabled = newValue
        }

      Picker("Default Speed", selection: $playback.playbackRate) {
        ForEach(playback.player.supportedPlaybackRates, id: \.self) { rate in
          Text(rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate))
            .tag(rate)
        }
      }

      Picker("Skip Interval", selection: $seekInterval) {
        ForEach([10.0, 15.0, 30.0, 45.0], id: \.self) { interval in
          Text("\(Int(interval)) seconds").tag(interval)
        }
      }
      .onChange(of: seekInterval) { _, newValue in
        playback.player.seekInterval = newValue
      }
    } header: {
      Text("Playback")
    } footer: {
      Text(
        "Playback continues when the screen locks or you switch apps.\n\n"
          + "With Picture in Picture off, leaving the app during a video keeps the audio "
          + "playing without floating the video into a window.")
    }
  }

  // MARK: - Downloads

  private var downloadSection: some View {
    Section {
      Picker("Download New Items", selection: $autoDownload) {
        ForEach(PlayListDownloadType.allCases) { type in
          Text(type.displayName).tag(type)
        }
      }
      .onChange(of: autoDownload) { _, newValue in
        Preferences.Playlist.autoDownloadVideo.value = newValue.rawValue
      }
    } header: {
      Text("Downloads")
    } footer: {
      Text(
        "Media links from most sites expire after a few hours. Downloading immediately is the "
          + "only reliable way to keep an item playable.")
    }
  }

  // MARK: - Extraction

  private var extractionSection: some View {
    Section {
      Toggle("Request Desktop Pages", isOn: $useDesktopUA)
        .onChange(of: useDesktopUA) { _, newValue in
          Preferences.Playlist.useDesktopUserAgent.value = newValue
        }

      Toggle("Allow Streaming APIs", isOn: $allowMediaSource)
        .onChange(of: allowMediaSource) { _, newValue in
          Preferences.Playlist.webMediaSourceCompatibility.value = newValue
        }
    } header: {
      Text("Finding Media")
    } footer: {
      Text(
        "Desktop pages more often expose a downloadable video file. YouTube is the exception "
          + "and is always requested as mobile, because that is the only way it offers a "
          + "saveable format at all.\n\n"
          + "Streaming APIs (Media Source Extensions) let sites deliver video in chunks that "
          + "can't be saved. They are blocked by default, which is what makes many sites fall "
          + "back to a downloadable file. Turn this on only if a site refuses to load at all — "
          + "media found this way usually can't be downloaded.")
    }
  }

  // MARK: - Storage

  // MARK: - Account

  /// Signing in exists for one reason: YouTube will not serve an age-restricted
  /// video to an anonymous client, so no amount of cleverness in the extractor
  /// can reach one. Everything else works signed out.
  private var accountSection: some View {
    Section {
      if youTubeSession.isSignedIn {
        HStack {
          Label("Signed in to YouTube", systemImage: "person.crop.circle.fill.badge.checkmark")
            .foregroundStyle(.primary)
          Spacer()
        }

        Button(role: .destructive) {
          isSigningOut = true
          Task {
            await YouTubeSession.shared.signOut()
            isSigningOut = false
          }
        } label: {
          HStack {
            Text("Sign Out")
            if isSigningOut {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(isSigningOut)
      } else {
        Button {
          isShowingSignIn = true
        } label: {
          Label("Sign in to YouTube", systemImage: "person.crop.circle")
        }
      }
    } header: {
      Text("YouTube Account")
    } footer: {
      Text(
        "Optional. Signing in lets age-restricted and members-only videos be saved — "
          + "YouTube refuses those to signed-out clients.\n\n"
          + "Sign-in opens Google's own page. This app never sees your password; it keeps "
          + "only the resulting cookie, and uses it for YouTube pages and nothing else.")
    }
  }

  private var storageSection: some View {
    Section {
      NavigationLink {
        StorageView()
      } label: {
        HStack {
          Label("Storage", systemImage: "internaldrive")
          Spacer()
          if let storageUsed = storageUsed {
            Text(Format.fileSize(storageUsed))
              .foregroundStyle(.secondary)
              .contentTransition(.numericText())
              .transition(.opacity)
          }
        }
        .animation(.stateFade, value: storageUsed)
      }

      Button(role: .destructive) {
        isShowingClearCacheConfirmation = true
      } label: {
        Label("Remove All Downloads", systemImage: "arrow.down.circle.dotted")
      }

      Button(role: .destructive) {
        isShowingDeleteAllConfirmation = true
      } label: {
        Label("Delete Everything", systemImage: "trash")
      }
    } header: {
      Text("Storage")
    }
    .confirmationDialog(
      "Remove all downloaded files?",
      isPresented: $isShowingClearCacheConfirmation,
      titleVisibility: .visible
    ) {
      Button("Remove Downloads", role: .destructive) {
        PlaylistManager.shared.deleteAllItems(cacheOnly: true) {
          Haptics.notify(.success)
          Task { storageUsed = await PlaylistManager.shared.storageUsage().total }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your library entries are kept, but nothing will play offline until re-downloaded.")
    }
    .confirmationDialog(
      "Delete your entire library?",
      isPresented: $isShowingDeleteAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Everything", role: .destructive) {
        playback.stop()
        PlaylistManager.shared.deleteAllItems(cacheOnly: false) {
          Haptics.notify(.success)
          Task { storageUsed = await PlaylistManager.shared.storageUsage().total }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every item and every downloaded file is removed. This can't be undone.")
    }
  }

  // MARK: - About

  private var aboutSection: some View {
    Section {
      LabeledContent("Version", value: Self.versionString)

      NavigationLink {
        AcknowledgementsView()
      } label: {
        Label("Acknowledgements", systemImage: "info.circle")
      }
    } header: {
      Text("About")
    } footer: {
      Text(
        "Media detection, downloading and offline playback are adapted from Brave Browser "
          + "for iOS, which is licensed under MPL-2.0.")
    }
  }

  private static var versionString: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    return "\(version) (\(build))"
  }
}

// MARK: - Acknowledgements

struct AcknowledgementsView: View {
  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 10) {
          Text("Brave Browser for iOS")
            .font(.headline)

          Text(
            "The media detection script, download manager, offline storage model and "
              + "playback engine in this app are adapted from Brave's Playlist feature.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          Link(
            "github.com/brave/brave-ios",
            destination: URL(string: "https://github.com/brave/brave-ios")!)
            .font(.subheadline)
        }
        .padding(.vertical, 4)
      } header: {
        Text("Adapted From")
      } footer: {
        Text(
          "Licensed under the Mozilla Public License 2.0. Adapted source files carry their "
            + "original copyright notices and document what was changed.")
      }

      Section {
        Text("No third-party packages are bundled with this app.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } header: {
        Text("Dependencies")
      }
    }
    .navigationTitle("Acknowledgements")
    .navigationBarTitleDisplayMode(.inline)
  }
}
