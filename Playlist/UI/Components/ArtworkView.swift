// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// Artwork for a media item, generating it on first appearance.
///
/// Thumbnail generation is expensive (see `ThumbnailRenderer`), so this is
/// deliberately lazy: the work starts when the row scrolls into view and is
/// abandoned if it scrolls away before finishing. `ThumbnailRenderer` handles
/// the caching and request coalescing, so a fast scroll costs one generation
/// per item at most.
struct ArtworkView: View {
  let item: PlaylistInfo
  var cornerRadius: CGFloat = 8

  @State private var image: UIImage?

  /// Which item `image` was loaded for.
  ///
  /// A plain "did I already try?" flag is wrong here: this view is reused
  /// across items rather than rebuilt (the mini player keeps one instance
  /// alive as the track changes), so a flag that survives the item change
  /// suppresses every load after the first and leaves the previous item's
  /// artwork on screen. Comparing against the item makes the load re-run
  /// exactly when the item is genuinely different.
  @State private var loadedTagId: String?

  /// What to paint right now.
  ///
  /// The memory-cache fallback is what removes the flicker. SwiftUI recycles
  /// these views constantly — every list row reuse, and every time the mini
  /// player's enclosing branch is rebuilt — and each recycle hands the view
  /// fresh `@State`, so `image` starts nil again. Waiting for `load()` to hop
  /// through the actor and come back meant a frame or two of placeholder each
  /// time, which reads as the artwork blinking between the real thumbnail and
  /// the film icon. If the image is already in memory, it is painted on the
  /// very first pass and no blink is possible.
  private var displayImage: UIImage? {
    image ?? ThumbnailRenderer.cachedThumbnail(id: item.tagId)
  }

  var body: some View {
    // `Color.clear` is what fixes the layout size to whatever the caller's
    // `.frame` proposed. A bare `Image.resizable().aspectRatio(.fill)` reports
    // a size *larger* than the proposal on its short axis, the enclosing stack
    // grows to match, and `clipShape` then clips to that oversized bound — so
    // the artwork spills outside its frame and paints over its neighbours. That
    // is invisible at 16:9 call sites but gross at the mini player's 40×40.
    Color.clear
      .overlay {
        if let image = displayImage {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          placeholder
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .task(id: item.tagId) {
        guard loadedTagId != item.tagId else { return }
        // Drop the outgoing item's artwork only when this really is a different
        // item, so a slow load never shows the wrong picture next to the right
        // title. Blanking unconditionally would throw away a perfectly good
        // image on a mere view recycle — the flicker again.
        if let loadedTagId = loadedTagId, loadedTagId != item.tagId {
          image = nil
        }
        await load()
      }
      // A download finishing means a real frame can replace the poster image.
      // Long-lived views need telling: the mini player resolves its artwork
      // once and would otherwise keep the first answer for the whole session,
      // including a nil one.
      .onReceive(NotificationCenter.default.publisher(for: .thumbnailInvalidated)) { note in
        guard note.object as? String == item.tagId else { return }
        loadedTagId = nil
        Task { await load() }
      }
  }

  private var placeholder: some View {
    ZStack {
      LinearGradient(
        colors: [Color(.secondarySystemFill), Color(.tertiarySystemFill)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

      Image(systemName: item.mimeType.contains("audio") ? "music.note" : "film")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  private func load() async {
    let localURL = PlaylistManager.shared.localAssetURL(for: item.tagId)

    let loaded = await ThumbnailRenderer.shared.thumbnail(
      id: item.tagId,
      localURL: localURL,
      remoteURL: URL(string: item.src),
      artworkURL: item.artworkURL.flatMap(URL.init(string:)))

    // Cancelled means scrolled away mid-flight: leave `loadedTagId` unset so
    // the load is retried if the row comes back, rather than being recorded
    // as a completed attempt that produced nothing.
    guard !Task.isCancelled else { return }

    // Only animate the arrival of a real image. Animating a transition *to*
    // nil fades the artwork out into the placeholder, which is the flicker the
    // user sees rather than a fix for it.
    if let loaded = loaded {
      withAnimation(.easeIn(duration: 0.2)) {
        image = loaded
      }
    }
    // Set even when `loaded` is nil: an item with no obtainable artwork has
    // been tried, and should not be retried on every redraw. It is retried when
    // the thumbnail is explicitly invalidated — a finished download being the
    // case that matters.
    loadedTagId = item.tagId
  }
}
