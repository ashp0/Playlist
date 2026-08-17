// Copyright 2023 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Taken from brave-ios
// `Sources/Brave/Frontend/UserContent/UserScripts/Scripts_Dynamic/Scripts/Paged/PlaylistSwizzlerScript.js`
// (upstream's commented-out alternatives dropped; behaviour identical).
//
// WHY THIS EXISTS — this is the single most important file for extraction
// actually working on modern video sites.
//
// Media Source Extensions let a player fetch media in chunks with JavaScript
// and feed them to a <video> element through a `blob:` URL. When a site uses
// MSE, `video.src` is a blob handle that is meaningless outside that page's
// JavaScript context: it cannot be downloaded, and it expires with the page.
// Every large streaming site uses MSE by default.
//
// Removing the MediaSource API makes the player's feature detection fail, and
// well-built players then fall back to handing the <video> element a plain
// progressive URL — which *is* downloadable, and which the detector can see.
//
// This must run at document start, before any page script has had a chance to
// capture a reference to `window.MediaSource`.

"use strict";

if (
  window.MediaSource ||
  window.WebKitMediaSource ||
  window.ManagedMediaSource ||
  (window.HTMLMediaElement && HTMLMediaElement.prototype.webkitSourceAddId)
) {
  delete window.MediaSource;
  delete window.WebKitMediaSource;

  // iOS 17.1+, WebKit-only at time of writing. Sites that feature-detect it
  // will use it in preference to the standard API, so it has to go too.
  delete window.ManagedMediaSource;
}
