// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import AVKit
import SwiftUI

/// The full-screen player.
///
/// Presented as an overlay by `RootView` rather than as a sheet or a
/// `fullScreenCover`, which is what lets the app show through as it is dragged
/// away — see the comment on the swipe gesture below.
struct NowPlayingView: View {
  @EnvironmentObject private var playback: PlaybackController

  /// Sends the player back down. Owned by `RootView`, because the presentation
  /// is a piece of that view's state rather than a system presentation.
  let onDismiss: () -> Void

  /// Whether the player has the screen to itself. Cleared as soon as a drag
  /// starts uncovering the library, so `RootView` can hand the window's colour
  /// scheme back to the user's own appearance — see the comment there.
  @Binding var isCoveringScreen: Bool

  @State private var isShowingQueue = false
  @State private var isShowingSleepTimer = false
  @State private var scrubPosition: TimeInterval?

  /// How far the player has been dragged down, in points. Tracks the finger
  /// directly, so it is deliberately not animated while a drag is in flight.
  @State private var dragOffset: CGFloat = 0

  /// How far the player has to travel to be off the bottom of the screen.
  ///
  /// Measured rather than assumed, because it is what the release animates to
  /// and what every proportion below is expressed against — so the same drag
  /// reads identically on a small phone and a large one.
  @State private var travelDistance: CGFloat = 0

  /// Set once a dismissal has been committed to.
  ///
  /// The player finishes its own journey off the screen before asking to be
  /// removed, and for the length of that journey the gesture stops tracking:
  /// a stray touch that re-grabbed the card would otherwise leave it stranded
  /// mid-screen with nothing left to remove it.
  @State private var isDismissing = false

  /// Travel needed before lifting the finger dismisses rather than springs back.
  private let dismissThreshold: CGFloat = 110

  /// Downward speed, in points per second, that dismisses however short the
  /// drag was. A flick is a complete gesture, not an incomplete swipe.
  private let dismissVelocity: CGFloat = 350

  /// Distance the finger must cover before the gesture is recognised.
  ///
  /// It exists to leave the transport buttons tappable — a tap never travels
  /// this far — and it is subtracted back out of every translation, so the
  /// travel the player is given starts from zero rather than from here.
  private static let slop: CGFloat = 10

  var body: some View {
    ZStack {
      scrim
      card
    }
    .gesture(swipeDownToDismiss)
    // The player is dark whatever the rest of the app is. Overriding the
    // environment keeps that scoped to this subtree, so the tabs behind it stay
    // in the user's own appearance — which matters, because they are visible
    // for the whole of the drag. The window's own scheme (what the status bar
    // reads) is `RootView`'s to decide, since a `preferredColorScheme` set here
    // would apply to everything in the window, the library included.
    .environment(\.colorScheme, .dark)
    // A part-finished scrub belongs to the track it was started on.
    .onChange(of: playback.currentItem?.tagId) { _, _ in
      scrubPosition = nil
    }
    // VoiceOver's two-finger scrub is the assistive equivalent of the swipe.
    .accessibilityAction(.escape) { beginDismissal() }
    // A `fullScreenCover` used to take the library out of the window, and with
    // it out of VoiceOver's reach. As an overlay the library is still there, so
    // the modal trait is what now stops the rotor walking into a screen the
    // user cannot see.
    .accessibilityAddTraits(.isModal)
    // The sheets belong to the player, so they are dark with it. Stated on the
    // sheet itself rather than inherited from the window, which is no longer
    // dark on the player's behalf.
    .sheet(isPresented: $isShowingQueue) {
      QueueView()
        .environmentObject(playback)
        .preferredColorScheme(.dark)
    }
    .sheet(isPresented: $isShowingSleepTimer) {
      SleepTimerView()
        .environmentObject(playback)
        .preferredColorScheme(.dark)
    }
    .alert(
      "Playback Problem",
      isPresented: Binding(
        get: { playback.errorMessage != nil },
        set: { if !$0 { playback.errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) { playback.errorMessage = nil }
    } message: {
      Text(playback.errorMessage ?? "")
    }
  }

  // MARK: - Travelling

  /// Everything that moves with the finger.
  ///
  /// Separated from the scrim behind it because the two must not travel
  /// together: the card leaves, the shadow it was casting over the library
  /// stays put and lifts.
  private var card: some View {
    ZStack {
      backdrop

      VStack(spacing: 0) {
        header
        Spacer(minLength: 8)
        stage
        Spacer(minLength: 8)
        metadata
        scrubber
        transportControls
        secondaryControls
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
    }
    .scaleEffect(dragScale)
    .offset(y: dragOffset)
  }

  /// Dims the library the player is being pulled away from, and measures how
  /// far the player has to go to leave the screen.
  ///
  /// What a drag uncovers should come up out of shadow rather than simply be
  /// exposed. Without this the bright library appearing under the player's dark
  /// edge reads as a seam — the join between two screens that do not belong
  /// together — which is most of what made the old swipe look broken even on
  /// the frames it did not drop.
  private var scrim: some View {
    GeometryReader { proxy in
      Color.black
        .opacity(0.55 * (1 - travelFraction))
        .onAppear { travelDistance = proxy.size.height }
        .onChange(of: proxy.size.height) { _, height in travelDistance = height }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  /// How far through its journey off the screen the player is: 0 covering it,
  /// 1 gone. Every proportion below is expressed against this rather than
  /// against a fixed number of points, so the gesture feels the same whatever
  /// the display.
  private var travelFraction: CGFloat {
    min(1, max(0, dragOffset) / dismissDistance)
  }

  /// The measured travel, with a fallback for the frame before it is known.
  private var dismissDistance: CGFloat {
    travelDistance > 0 ? travelDistance : 1000
  }

  /// Pulls the player back off the glass as it travels, which reads as the
  /// screen being put down rather than merely sliding away.
  private var dragScale: CGFloat {
    1 - 0.08 * min(1, travelFraction * 3)
  }

  /// Corners round off as the player lifts away from the edges of the display,
  /// so the shrinking rectangle reads as a card over the library rather than a
  /// screenshot that has come loose.
  private var dragCornerRadius: CGFloat {
    40 * min(1, travelFraction * 9)
  }

  // MARK: - Swipe to dismiss

  /// Drag the player downwards to send it back to the tabs it came from.
  ///
  /// The gesture sits on the player as a whole rather than on a grab handle,
  /// so it has to share the screen with the controls. `minimumDistance` leaves
  /// the transport buttons tappable — a tap never travels far enough to start
  /// a drag — and a plain `.gesture` yields to gestures declared further down
  /// the hierarchy, so the scrubber still wins any touch that starts on it.
  ///
  /// What the drag uncovers is the library, not a void: the player is a sibling
  /// of the tab view inside `RootView`'s `ZStack`. A `fullScreenCover` takes the
  /// presenting view out of the window once it is up, so anything the player
  /// moved off would have been blank — which is why this is not one.
  private var swipeDownToDismiss: some Gesture {
    DragGesture(minimumDistance: Self.slop)
      .onChanged { value in
        guard !isDismissing else { return }

        // Anything the drag uncovers belongs to the library and has to be drawn
        // in the library's appearance, so the window stops being the player's
        // as soon as the first pixel of it shows.
        //
        // NOTE: assigned only where it actually changes. This is `RootView`'s
        // state, and writing it unconditionally — which is the obvious way to
        // write this line — re-evaluated that view, and with it the whole tab
        // view, the tab bar and the mini player, on every frame of the gesture.
        // Those are the most expensive views in the app to rebuild and they sit
        // along the bottom edge, which is precisely where the swipe used to
        // come apart.
        if isCoveringScreen { isCoveringScreen = false }

        dragOffset = resisted(travel(from: value))
      }
      .onEnded { value in
        guard !isDismissing else { return }

        let velocity = value.velocity.height

        // A flick dismisses however little ground it covered: speed says as
        // much about intent as distance, and requiring both is what makes a
        // quick throw bounce back in the user's face.
        if travel(from: value) > dismissThreshold || velocity > dismissVelocity {
          finishDismissal(velocity: velocity)
        } else {
          springBack(velocity: velocity)
        }
      }
  }

  /// Sends the player the rest of the way down, then asks to be removed.
  ///
  /// The `dragOffset` that tracked the finger carries on to the bottom of the
  /// screen, so the scale, the corner radius and the scrim all keep moving
  /// exactly as they were. Handing that last stretch to the overlay's own
  /// `.move` transition instead — which is what used to happen — froze all
  /// three wherever the finger left them and restarted the motion over a
  /// different distance, which is the discontinuity a release used to have.
  private func finishDismissal(velocity: CGFloat) {
    isDismissing = true
    isCoveringScreen = false
    Haptics.impact(.soft)

    let remaining = dismissDistance - dragOffset

    withAnimation(.playerTravel(velocity: velocity, over: remaining)) {
      dragOffset = dismissDistance
    } completion: {
      onDismiss()
    }
  }

  /// Dismisses from a control rather than a drag — the chevron, or VoiceOver's
  /// escape gesture. The player travels the same way it would from a swipe.
  private func beginDismissal() {
    guard !isDismissing else { return }
    finishDismissal(velocity: 0)
  }

  /// Returns the player to the top, carrying whatever speed the finger had.
  private func springBack(velocity: CGFloat) {
    withAnimation(.playerTravel(velocity: velocity, over: -dragOffset)) {
      dragOffset = 0
    } completion: {
      // Springing back re-covers the library, so the window is the player's
      // again once it has — unless another drag has started in the meantime.
      if dragOffset == 0, !isDismissing {
        isCoveringScreen = true
      }
    }
  }

  /// How far the player should have moved for a given drag.
  ///
  /// `minimumDistance` means the first event a gesture delivers already carries
  /// the distance the recogniser needed to make up its mind. Passing that
  /// straight through makes the player jump that far the instant a drag is
  /// admitted; taking it back off starts the travel from where the finger is.
  private func travel(from value: DragGesture.Value) -> CGFloat {
    let height = value.translation.height
    return height >= 0 ? max(0, height - Self.slop) : min(0, height + Self.slop)
  }

  /// Downward drags track the finger; upward ones give a little and then hold,
  /// so the player never lifts off the top of the screen.
  private func resisted(_ translation: CGFloat) -> CGFloat {
    translation >= 0 ? translation : -sqrt(-translation) * 3
  }

  // MARK: - Backdrop

  /// A blurred, darkened blow-up of the artwork.
  ///
  /// The colour comes from the content rather than a fixed palette, which is
  /// what makes an otherwise plain layout feel like it belongs to the media.
  private var backdrop: some View {
    // `Color.black` as the base, with the artwork as a *clipped overlay*, is
    // load-bearing. A bare `Image.resizable().aspectRatio(.fill)` reports a
    // layout size larger than the space it was offered — and a 16:9 video
    // frame filling a portrait screen is far wider than that screen. Left in
    // a `ZStack`, that oversized child sizes the whole player: the control
    // column is laid out wider and taller than the display, so the header
    // scrolls off the top, the shuffle/speed/sleep/repeat row off the bottom,
    // and the horizontal padding lands off-screen entirely.
    Color.black
      .overlay {
        if let artwork = playback.artwork {
          Image(uiImage: artwork)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .blur(radius: 60, opaque: true)
            .overlay(Color.black.opacity(0.55))
            .animation(.easeInOut(duration: 0.4), value: playback.currentItem?.tagId)
        }
      }
      .clipped()
      // Rounded *before* the safe area is ignored, not after: a clip applied
      // afterwards is sized to the inset frame and leaves the home-indicator
      // strip of the library showing through the bottom of the player.
      .clipShape(RoundedRectangle(cornerRadius: dragCornerRadius, style: .continuous))
      .ignoresSafeArea()
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Button {
        beginDismissal()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 40, height: 40)
          .background(.ultraThinMaterial, in: Circle())
      }
      .accessibilityLabel("Close player")

      Spacer()

      HStack(spacing: 8) {
        if playback.isAnonymous {
          hiddenBadge
        }

        if let sleepTimer = playback.sleepTimer {
          sleepTimerBadge(sleepTimer)
        }
      }
      .animation(.contentChange, value: playback.isAnonymous)
      .animation(.contentChange, value: playback.sleepTimer == nil)

      Spacer()

      Button {
        isShowingQueue = true
      } label: {
        Image(systemName: "list.bullet")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 40, height: 40)
          .background(.ultraThinMaterial, in: Circle())
      }
      .accessibilityLabel("Show queue")
    }
    .padding(.top, 8)
  }

  /// Shown while the playlist in play is withheld from the lock screen, so that
  /// state is visible somewhere other than inside a menu.
  private var hiddenBadge: some View {
    HStack(spacing: 5) {
      Image(systemName: "eye.slash.fill")
      Text("Hidden")
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.white.opacity(0.9))
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(.ultraThinMaterial, in: Capsule())
    .accessibilityLabel("Hidden on the Lock Screen")
    .transition(.scale(scale: 0.8).combined(with: .opacity))
  }

  private func sleepTimerBadge(_ timer: PlaybackController.SleepTimer) -> some View {
    Button {
      isShowingSleepTimer = true
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "moon.zzz.fill")
        switch timer.mode {
        case .endOfTrack:
          Text("End of track")
        case .duration:
          SleepTimerCountdown(timer: timer)
        }
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.white.opacity(0.9))
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.ultraThinMaterial, in: Capsule())
    }
    .accessibilityLabel("Sleep timer active")
    .transition(.scale(scale: 0.8).combined(with: .opacity))
  }

  // MARK: - Stage

  /// Video surface or artwork, depending on what is playing.
  private var stage: some View {
    ZStack {
      if playback.isVideo {
        PlayerLayerView(player: playback.player)
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
      } else {
        artworkStage
      }

      if playback.isBuffering || playback.isRefreshingMedia {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.large)
            .tint(.white)

          if playback.isRefreshingMedia {
            Text("Refreshing media link…")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.8))
          }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity)
    // Buffering is often over in a few hundred milliseconds. Fading the spinner
    // in and out stops a brief stall reading as a flash of unrelated UI.
    .animation(.stateFade, value: playback.isBuffering)
    .animation(.stateFade, value: playback.isRefreshingMedia)
  }

  private var artworkStage: some View {
    Group {
      if let artwork = playback.artwork {
        Image(uiImage: artwork)
          .resizable()
          .aspectRatio(contentMode: .fill)
          // Keyed on the item, not the image: without an identity SwiftUI
          // swaps the bitmap inside one view and the cross-fade has nothing to
          // fade between, so a track change replaces the artwork in a single
          // frame.
          .id(playback.currentItem?.tagId)
          .transition(.opacity)
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
          Image(systemName: "music.note")
            .font(.system(size: 64, weight: .light))
            .foregroundStyle(.white.opacity(0.5))
        }
        .transition(.opacity)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(maxWidth: 340)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
    .animation(.easeInOut(duration: 0.35), value: playback.artwork)
    // A subtle lift while playing, the way a record player's platter reads as
    // "running" without any explicit indicator.
    .scaleEffect(playback.isPlaying ? 1.0 : 0.94)
    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: playback.isPlaying)
  }

  // MARK: - Metadata

  private var metadata: some View {
    VStack(spacing: 4) {
      Text(playback.currentItem?.name ?? "Nothing Playing")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.center)

      if let pageSrc = playback.currentItem?.pageSrc,
        let host = URL(string: pageSrc)?.baseDomain
      {
        Text(host)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.6))
      }

      if let segment = playback.currentSegment {
        segmentLabel(segment)
      }
    }
    .padding(.top, 20)
    .padding(.bottom, 16)
    // The whole block is replaced as one when the track changes, so the title
    // and its source cross-fade together instead of the shorter of the two
    // landing first.
    .id(playback.currentItem?.tagId)
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.3), value: playback.currentItem?.tagId)
    .animation(.contentChange, value: playback.currentSegment)
  }

  /// Says that this item is being played in parts, and which part this is.
  ///
  /// Without it the player is lying by omission: the countdown runs out well
  /// before the track does, and nothing else on screen explains why.
  private func segmentLabel(_ segment: PlaylistSegment) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "timer")
      Text("Part \(segment.index + 1) of \(segment.count)")
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.white.opacity(0.7))
    .padding(.top, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Playing part \(segment.index + 1) of \(segment.count) of this item")
    .transition(.scale(scale: 0.9).combined(with: .opacity))
  }

  // MARK: - Scrubber

  private var scrubber: some View {
    VStack(spacing: 4) {
      if playback.duration > 0, playback.duration < TimeInterval(Int32.max) {
        Slider(
          value: Binding(
            get: { scrubberPosition },
            set: { scrubPosition = $0 }),
          in: scrubRange,
          onEditingChanged: { isEditing in
            // Commit only when the finger lifts. Seeking continuously while
            // dragging thrashes the decoder and makes the slider fight the
            // periodic time observer.
            if !isEditing, let position = scrubPosition {
              playback.seek(to: position)
              scrubPosition = nil
            }
          }
        )
        .tint(.white)

        HStack {
          Text(Format.duration(elapsedInScrubRange) ?? "0:00")
          Spacer()
          Text("-" + (Format.duration(max(0, scrubRange.upperBound - scrubberPosition)) ?? "0:00"))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
        .contentTransition(.numericText())
      } else {
        HStack(spacing: 6) {
          Circle().fill(.red).frame(width: 7, height: 7)
          Text("LIVE").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.8))
        .frame(height: 40)
      }
    }
  }

  /// What the scrubber spans: the segment while one is playing, the whole item
  /// otherwise.
  ///
  /// Bounding it to the segment keeps the countdown on the right honest — it
  /// runs down to the moment the playlist moves on — and stops a scrub from
  /// landing outside the stretch this playlist asked for, which would only
  /// bounce straight to the next item.
  private var scrubRange: ClosedRange<TimeInterval> {
    guard let segment = playback.currentSegment else {
      return 0...max(playback.duration, 0.1)
    }
    return segment.start...max(segment.end, segment.start + 0.1)
  }

  /// The scrubber's value, held inside its range: the player can report a time
  /// from just before a seek into the segment lands.
  private var scrubberPosition: TimeInterval {
    let position = scrubPosition ?? playback.currentTime
    return min(max(position, scrubRange.lowerBound), scrubRange.upperBound)
  }

  /// How far into the stretch being played the listener is.
  ///
  /// Counted from the start of the segment, not of the item, so it agrees with
  /// what the lock screen and Control Centre are being told — and with the
  /// countdown beside it, which has always run down to the end of the segment.
  /// Where in the *item* this falls is what the "Part 2 of 4" label above is
  /// for; two different numbers for the same thing, on the same screen, is the
  /// confusion worth avoiding here.
  private var elapsedInScrubRange: TimeInterval {
    scrubberPosition - scrubRange.lowerBound
  }

  // MARK: - Transport

  private var transportControls: some View {
    HStack(spacing: 28) {
      Button {
        playback.previous()
      } label: {
        Image(systemName: "backward.fill").font(.system(size: 26))
      }
      .buttonStyle(TransportButtonStyle())
      .accessibilityLabel("Previous")

      Button {
        playback.seekBackward()
      } label: {
        Image(systemName: skipBackSymbol).font(.system(size: 26))
      }
      .buttonStyle(TransportButtonStyle())
      .accessibilityLabel("Skip back \(Int(playback.player.seekInterval)) seconds")

      Button {
        playback.togglePlayPause()
        Haptics.impact(.light)
      } label: {
        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.system(size: 66))
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(TransportButtonStyle(pressedScale: 0.9))
      .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

      Button {
        playback.seekForward()
      } label: {
        Image(systemName: skipForwardSymbol).font(.system(size: 26))
      }
      .buttonStyle(TransportButtonStyle())
      .accessibilityLabel("Skip forward \(Int(playback.player.seekInterval)) seconds")

      Button {
        playback.next()
      } label: {
        Image(systemName: "forward.fill").font(.system(size: 26))
      }
      .buttonStyle(TransportButtonStyle())
      .accessibilityLabel("Next")
    }
    .foregroundStyle(.white)
    .padding(.vertical, 20)
  }

  /// The skip buttons name the interval they actually jump.
  ///
  /// The setting offers 10, 15, 30 and 45 seconds, and the glyphs were fixed at
  /// 15 — so three of the four choices left the player drawing a number it did
  /// not obey. SF Symbols ships a glyph for each, and anything unexpected falls
  /// back to the plain arrow rather than to the wrong figure.
  private var skipBackSymbol: String {
    switch Int(playback.player.seekInterval) {
    case 10: return "gobackward.10"
    case 15: return "gobackward.15"
    case 30: return "gobackward.30"
    case 45: return "gobackward.45"
    default: return "gobackward"
    }
  }

  private var skipForwardSymbol: String {
    switch Int(playback.player.seekInterval) {
    case 10: return "goforward.10"
    case 15: return "goforward.15"
    case 30: return "goforward.30"
    case 45: return "goforward.45"
    default: return "goforward"
    }
  }

  // MARK: - Secondary controls

  private var secondaryControls: some View {
    HStack {
      Button {
        playback.toggleShuffle()
        Haptics.selection()
      } label: {
        Image(systemName: "shuffle")
          .secondaryControlStyle(isActive: playback.isShuffleEnabled)
      }
      .accessibilityLabel("Shuffle")
      .accessibilityValue(playback.isShuffleEnabled ? "On" : "Off")

      Spacer()

      Menu {
        Picker("Speed", selection: $playback.playbackRate) {
          ForEach(playback.player.supportedPlaybackRates, id: \.self) { rate in
            Text(rateLabel(rate)).tag(rate)
          }
        }
      } label: {
        Text(rateLabel(playback.playbackRate))
          .font(.footnote.weight(.semibold).monospacedDigit())
          .secondaryControlStyle(isActive: playback.playbackRate != 1.0)
      }
      .accessibilityLabel("Playback speed")

      Spacer()

      optionsMenu

      Spacer()

      Button {
        playback.toggleRepeatMode()
        Haptics.selection()
      } label: {
        Image(systemName: repeatSymbol)
          .secondaryControlStyle(isActive: playback.repeatMode != .none)
          .contentTransition(.symbolEffect(.replace))
      }
      .accessibilityLabel("Repeat")
      .accessibilityValue(repeatAccessibilityValue)
    }
    .foregroundStyle(.white)
  }

  // MARK: - Options

  /// What used to be the sleep-timer button.
  ///
  /// The timer is still one tap away, but the slot now holds the settings that
  /// belong to *this* playback session rather than to the app: how long it
  /// keeps going, and whether the playlist announces itself outside the app.
  private var optionsMenu: some View {
    Menu {
      if let playlist = playback.currentPlaylist {
        Section(playlist.title) {
          Toggle(isOn: anonymousBinding) {
            Label("Hide on Lock Screen", systemImage: "eye.slash")
          }
        }
      }

      Section {
        Button {
          isShowingSleepTimer = true
        } label: {
          Label(sleepTimerMenuTitle, systemImage: "moon.zzz")
        }

        if playback.sleepTimer != nil {
          Button(role: .destructive) {
            playback.cancelSleepTimer()
          } label: {
            Label("Cancel Sleep Timer", systemImage: "xmark")
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .secondaryControlStyle(isActive: playback.sleepTimer != nil || playback.isAnonymous)
    }
    .accessibilityLabel("Player options")
  }

  /// Writes straight through to the folder, which is what makes the choice
  /// stick to the playlist rather than to this playback session.
  private var anonymousBinding: Binding<Bool> {
    Binding(
      get: { playback.isAnonymous },
      set: { playback.setAnonymous($0) })
  }

  private var sleepTimerMenuTitle: String {
    guard let timer = playback.sleepTimer else { return "Sleep Timer" }

    switch timer.mode {
    case .endOfTrack:
      return "Sleep Timer — End of Track"
    case .duration:
      guard let remaining = timer.remaining, let formatted = Format.duration(remaining) else {
        return "Sleep Timer"
      }
      return "Sleep Timer — \(formatted) Left"
    }
  }

  private var repeatSymbol: String {
    switch playback.repeatMode {
    case .none, .repeatAll: return "repeat"
    case .repeatOne: return "repeat.1"
    }
  }

  private var repeatAccessibilityValue: String {
    switch playback.repeatMode {
    case .none: return "Off"
    case .repeatAll: return "Repeat all"
    case .repeatOne: return "Repeat one"
    }
  }

  private func rateLabel(_ rate: Float) -> String {
    rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
  }
}

// MARK: - Styling

extension View {
  /// Shared treatment for the row of mode toggles under the transport controls.
  fileprivate func secondaryControlStyle(isActive: Bool) -> some View {
    self
      .font(.system(size: 16, weight: .semibold))
      .frame(width: 46, height: 34)
      .background(
        Capsule().fill(isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
      )
      .animation(.easeOut(duration: 0.15), value: isActive)
  }
}
