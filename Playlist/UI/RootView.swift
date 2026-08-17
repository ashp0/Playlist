// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// The app shell: three tabs, with the mini player docked above the tab bar.
struct RootView: View {
  /// Held here and injected into the environment so it outlives every view.
  /// Audio must keep playing with no UI on screen, so playback state cannot
  /// belong to a view's lifetime. The instance is shared with App Intents,
  /// which can run without any of this existing.
  @StateObject private var playback = PlaybackController.shared

  @ObservedObject private var intents = AppIntentRouter.shared

  @State private var selectedTab = Tab.library
  @State private var isShowingNowPlaying = false
  @State private var incomingURL: String?
  @State private var incomingFolderUUID: String?

  /// True only while the player is at rest with the whole screen to itself.
  ///
  /// It gates the window's colour scheme — see `body`. `NowPlayingView` clears
  /// it the moment a drag begins, because from then on the library behind is
  /// visible and the window belongs to the library again.
  @State private var isPlayerCoveringScreen = false

  private enum Tab: Hashable {
    case library
    case downloads
    case settings
  }

  var body: some View {
    // The player is a sibling of the tab view, not a `fullScreenCover` over it.
    // A cover removes what it covers from the window, so dragging the player
    // down uncovered nothing but the black behind it; as an overlay, the drag
    // reveals the library that is still sitting there.
    ZStack {
      tabs
        .environmentObject(playback)

      if isShowingNowPlaying {
        NowPlayingView(
          onDismiss: dismissNowPlaying,
          isCoveringScreen: $isPlayerCoveringScreen)
          .environmentObject(playback)
          // Insertion only. On the way out the player sees itself off the
          // bottom of the screen under its own animation — carrying the drag's
          // scale, corner radius and scrim continuously with it — and only then
          // asks to be removed. A removal transition would take that motion
          // over halfway through and restart it over a different distance.
          .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .identity))
          .zIndex(1)
      }
    }
    // The player is dark whatever the rest of the app is, and while it covers
    // the screen the window may as well be too — that is what the status bar
    // over it reads. The moment any of the library is visible, though, the
    // window goes back to the user's own appearance: a `preferredColorScheme`
    // set from inside the overlay applies to the whole window, so leaving it on
    // through the swipe is what made a light-mode library slide out dark.
    .preferredColorScheme(isPlayerCoveringScreen ? .dark : nil)
    .onOpenURL { url in
      handle(incoming: url)
    }
    // A playlist asked for from Shortcuts, which may have launched the app to
    // ask. Routed through the same binding the URL scheme uses.
    .onChange(of: intents.requestedFolderUUID) { _, _ in
      consumeIntentRequests()
    }
    .task {
      // On a cold launch the intent runs before there is a view to notice it,
      // so the pending request is collected here as well as on change.
      consumeIntentRequests()

      // A sign-in survives relaunches in WebKit's cookie store, so the state
      // has to be read back at launch rather than assumed signed-out.
      await YouTubeSession.shared.refresh()
    }
  }

  /// Hands anything an App Intent left behind to the library.
  private func consumeIntentRequests() {
    guard let uuid = intents.requestedFolderUUID else { return }

    selectedTab = .library
    incomingFolderUUID = uuid
    intents.requestedFolderUUID = nil
  }

  // MARK: - Presenting the player

  private func presentNowPlaying() {
    guard !isShowingNowPlaying else { return }

    Haptics.impact(.soft)

    // The window only turns dark once the player has finished travelling up
    // over the library. Flipping it at the start of the animation would recolour
    // the library while it is still on screen, which is the same flaw as the
    // one the swipe used to have, in reverse.
    withAnimation(.playerPresent) {
      isShowingNowPlaying = true
    } completion: {
      if isShowingNowPlaying {
        isPlayerCoveringScreen = true
      }
    }
  }

  /// Takes the player out of the hierarchy once it has finished leaving.
  ///
  /// Deliberately unanimated: by the time `NowPlayingView` calls this it has
  /// already travelled off the bottom of the screen, so there is nothing left
  /// to animate and wrapping it would only delay the removal of a view nobody
  /// can see.
  private func dismissNowPlaying() {
    isPlayerCoveringScreen = false
    isShowingNowPlaying = false
  }

  /// The tab shell, with the mini player docked above the tab bar.
  ///
  /// The mini player deliberately is *not* a `safeAreaInset` on the `TabView`
  /// itself. From iOS 26 the tab bar is a floating bar that lives in the
  /// TabView's own bottom safe area, so an inset there lands on top of it and
  /// covers the tab buttons outright — leaving every tab but the current one
  /// unreachable for as long as anything is playing.
  @ViewBuilder private var tabs: some View {
    if #available(iOS 26.0, *) {
      // The system accessory slot: the same one Music uses for its mini
      // player. It sits above the tab bar and adopts its material.
      tabContent
        .tabViewBottomAccessory {
          miniPlayer
        }
    } else {
      // Before iOS 26 the inset belongs on each tab's *content*, which puts
      // the bar above the tab bar and insets that tab's scroll view so the
      // last row is never stranded behind it.
      tabContent
    }
  }

  private var tabContent: some View {
    TabView(selection: $selectedTab) {
      docked(LibraryView(incomingURL: $incomingURL, incomingFolderUUID: $incomingFolderUUID))
        .tabItem { Label("Library", systemImage: "music.note.list") }
        .tag(Tab.library)

      docked(DownloadsView())
        .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
        .tag(Tab.downloads)

      docked(SettingsView())
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(Tab.settings)
    }
  }

  /// Adds the mini player above a tab's content on iOS 17–25. On iOS 26 the
  /// accessory slot already carries it, so this is a no-op there.
  @ViewBuilder private func docked(_ content: some View) -> some View {
    if #available(iOS 26.0, *) {
      content
    } else {
      content.safeAreaInset(edge: .bottom, spacing: 0) {
        miniPlayer
      }
    }
  }

  private var miniPlayer: some View {
    MiniPlayerView { presentNowPlaying() }
      .environmentObject(playback)
      // The bar arriving and leaving, not its contents changing — that is the
      // bar's own business. Keyed on whether there is anything playing rather
      // than on which item, so a track change does not animate the whole bar
      // out and back in underneath the tab bar.
      .animation(.contentChange, value: playback.currentItem == nil)
  }

  /// Handles `playlist://add?url=<percent-encoded address>`.
  ///
  /// Lets a link reach the app from Safari's share sheet (via a Shortcut),
  /// another app, or the command line, without the user having to copy, switch
  /// apps and paste.
  private func handle(incoming url: URL) {
    guard url.scheme == "playlist", url.host == "add" else { return }

    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
      !value.isEmpty
    else { return }

    selectedTab = .library
    incomingURL = value
  }
}
