// Copyright 2022 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios
// `Sources/Brave/Frontend/UserContent/UserScripts/Scripts_Dynamic/Scripts/Paged/PlaylistScript.js`
//
// This is the media detection engine. Everything downstream — the library, the
// downloader, offline playback — depends on this file producing a usable media
// URL, so the detection strategy is kept faithful to Brave's.
//
// Changes from upstream:
//   * Brave wraps the script in `window.__firefox__.includeOnce(...)` and posts
//     through `$.postNativeMessage`, both provided by a browser-wide bootstrap
//     script (`__firefox__.js`) that also seals functions against page
//     tampering. That bootstrap belongs to the browser, so this file is a plain
//     IIFE talking to `webkit.messageHandlers` directly. The per-load random
//     handler name and security token are preserved.
//   * The long-press entry point is removed — there is no web view to long-press.
//   * The dead `useObservers` branch (upstream hardcodes it to `false`) is removed.
//   * `og:image` / `og:title` are reported alongside the media, so the library
//     can show real artwork instead of a favicon.
//
// Placeholders substituted by PlaylistWebLoader before injection:
//   $<message_handler>  randomized WKScriptMessageHandler name
//   $<security_token>   per-load nonce
//   $<tag_uuid>         randomized property name used to tag media elements
//   $<process_document> randomized window function to force a re-scan

"use strict";

(function () {
  // Guard against double injection into the same document.
  if (window.__playlistDetectorInstalled$<tag_uuid>) {
    return;
  }
  window.__playlistDetectorInstalled$<tag_uuid> = true;

  const SECURITY_TOKEN = "$<security_token>";
  const HANDLER = "$<message_handler>";
  const TAG_KEY = "$<tag_uuid>";

  // MARK: - Numeric helpers

  function is_nan(value) {
    return typeof value === "number" && value !== value;
  }

  function is_infinite(value) {
    return typeof value === "number" && (value === Infinity || value === -Infinity);
  }

  // A live stream reports Infinity, which does not survive JSON. Native side
  // reads Number.MAX_VALUE back as "indefinite".
  function clamp_duration(value) {
    if (is_nan(value)) {
      return 0.0;
    }

    if (is_infinite(value)) {
      return Number.MAX_VALUE;
    }
    return value;
  }

  // Brave's UUIDv4 generator, kept verbatim: `crypto.randomUUID` is unavailable
  // on insecure origins, which some of the pages we load still are.
  function uuid_v4() {
    return ([1e7] + -1e3 + -4e3 + -8e3 + -1e11).replace(/[018]/g, (X) => {
      return (
        X ^
        (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (X >> 2)))
      ).toString(16);
    });
  }

  // MARK: - Element helpers

  function tagNode(node) {
    if (!node) {
      return;
    }

    if (!node[TAG_KEY]) {
      // Stop the page from reacting to fullscreen transitions we may trigger
      // by touching the element.
      node.addEventListener(
        "webkitpresentationmodechanged",
        (e) => e.stopPropagation(),
        true
      );
    }

    // Re-tagged on every notify. Upstream comment, still true: single-page apps
    // reuse one <video> element across navigations, so a stable identity per
    // element is not achievable — identity is carried by page URL + media src.
    node[TAG_KEY] = uuid_v4();
  }

  function isVideoNode(node) {
    return node.constructor.name === "HTMLVideoElement" || node.tagName === "VIDEO";
  }

  function isAudioNode(node) {
    return node.constructor.name === "HTMLAudioElement" || node.tagName === "AUDIO";
  }

  function isSourceNode(node) {
    return node.constructor.name === "HTMLSourceElement" || node.tagName === "SOURCE";
  }

  function getAllVideoElements() {
    // Reversed: the last <video> in the DOM is usually the real content, with
    // earlier ones being ads or previews.
    return [...document.querySelectorAll("video")].reverse();
  }

  function getAllAudioElements() {
    return [...document.querySelectorAll("audio")].reverse();
  }

  // Page-declared artwork. Not in upstream; a standalone library shows artwork
  // far more prominently than a browser does.
  function getPageArtwork() {
    const selectors = [
      'meta[property="og:image"]',
      'meta[name="og:image"]',
      'meta[property="twitter:image"]',
      'meta[name="twitter:image"]',
      'link[rel="image_src"]',
    ];

    for (const selector of selectors) {
      try {
        const element = document.querySelector(selector);
        if (element) {
          const value = element.content || element.href;
          if (value && value !== "") {
            return value;
          }
        }
      } catch (error) {
        // Ignore and try the next selector.
      }
    }
    return null;
  }

  function getPageTitle() {
    const selectors = ['meta[property="og:title"]', 'meta[name="og:title"]'];

    for (const selector of selectors) {
      try {
        const element = document.querySelector(selector);
        if (element && element.content && element.content !== "") {
          return element.content;
        }
      } catch (error) {
        // Ignore and try the next selector.
      }
    }
    return null;
  }

  // MARK: - Reporting

  function post(payload) {
    try {
      payload.securityToken = SECURITY_TOKEN;
      webkit.messageHandlers[HANDLER].postMessage(payload);
    } catch (error) {
      // The handler is torn down as soon as the native side has what it needs;
      // posting after that throws and is expected.
    }
  }

  function sendMessage(name, node, target, type, detected) {
    let location = "";
    let pageTitle = "";

    // Cross-origin iframes throw on `window.top` access. Falling back to the
    // frame's own location is what lets embedded players (which are almost
    // always cross-origin iframes) still be detected.
    try {
      location = window.top.location.href;
      pageTitle = window.top.document.title;
    } catch (error) {
      location = window.location.href;
      pageTitle = document.title;
    }

    const ogTitle = getPageTitle();

    post({
      name: name,
      src: node.src,
      pageSrc: location,
      pageTitle: ogTitle || pageTitle,
      mimeType: type,
      duration: clamp_duration(target.duration),
      detected: detected,
      tagId: target[TAG_KEY],
      // A media element with no parent is a decoder the page is driving
      // manually, not content the user can see. Native side skips these.
      invisible: !target.parentNode,
      artworkURL: getPageArtwork(),
    });
  }

  function notifyNode(target, type, detected, ignoreSource) {
    if (!target) {
      return;
    }

    let name = target.title;
    if (!name || name === "") {
      try {
        name = window.top.document.title;
      } catch (error) {
        name = document.title;
      }
    }

    if (!type || type === "") {
      if (isVideoNode(target)) {
        type = "video";
      }

      if (isAudioNode(target)) {
        type = "audio";
      }

      if (isSourceNode(target)) {
        type = isVideoNode(target.parentNode) ? "video" : "audio";
      }
    }

    if (ignoreSource || (target.src && target.src !== "")) {
      tagNode(target);
      sendMessage(name, target, target, type, detected);
    } else {
      // `<video>` with no src attribute but `<source>` children — the classic
      // multi-format markup pattern.
      for (const node of target.children) {
        if (isSourceNode(node) && node.src && node.src !== "") {
          tagNode(target);
          sendMessage(name, node, target, type, detected);
        }
      }
    }
  }

  // MARK: - Detection

  function setupDetector() {
    function onReady(fn) {
      if (document.readyState === "complete" || document.readyState === "ready") {
        fn();
      } else {
        document.addEventListener("DOMContentLoaded", fn);
      }
    }

    Object.defineProperty(HTMLMediaElement.prototype, TAG_KEY, {
      enumerable: false,
      configurable: false,
      writable: true,
      value: null,
    });

    // Route `.src` through the attribute rather than the internal slot, so that
    // reading it always reflects what the page most recently assigned.
    const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
    Object.defineProperty(HTMLMediaElement.prototype, "src", {
      enumerable: descriptor.enumerable,
      configurable: descriptor.configurable,
      get: function () {
        return this.getAttribute("src");
      },
      set: function (value) {
        this.setAttribute("src", value);
      },
    });

    // Hooking setAttribute is the core trick: players assign the real media URL
    // programmatically, long after the initial HTML has been parsed, so a
    // one-shot scan of the DOM would find nothing. This fires the moment the
    // page commits a source.
    //
    // It requires running in the page's own JavaScript world — an isolated
    // WKContentWorld shares the DOM but not the prototype chain, so a hook
    // installed there would never see the page's calls.
    const setVideoAttribute = HTMLVideoElement.prototype.setAttribute;
    HTMLVideoElement.prototype.setAttribute = function (key, value) {
      setVideoAttribute.call(this, key, value);
      if (key.toLowerCase() === "src") {
        notifyNode(this, "video", true, false);
      }
    };

    const setAudioAttribute = HTMLAudioElement.prototype.setAttribute;
    HTMLAudioElement.prototype.setAttribute = function (key, value) {
      setAudioAttribute.call(this, key, value);
      if (key.toLowerCase() === "src") {
        notifyNode(this, "audio", true, false);
      }
    };

    function checkPageForVideos(ignoreSource) {
      onReady(function () {
        const videos = getAllVideoElements();
        const audios = getAllAudioElements();

        if (videos.length === 0 && audios.length === 0) {
          // Nothing here yet. Give lazily-initialised players time to appear
          // before telling native there is nothing to find.
          setTimeout(function () {
            post({ state: "cancel" });
          }, 10000);
          return;
        }

        videos.forEach(function (node) {
          notifyNode(node, "video", true, ignoreSource);
        });

        audios.forEach(function (node) {
          notifyNode(node, "audio", true, ignoreSource);
        });

        post({ state: document.readyState });
      });
    }

    // Polling backstop. Some players (upstream calls out DailyMotion) construct
    // their media element in a way none of the hooks above observe, and some
    // assign the src before this script's hooks are installed.
    const interval = setInterval(function () {
      getAllVideoElements().forEach(function (node) {
        notifyNode(node, "video", true, false);
      });

      getAllAudioElements().forEach(function (node) {
        notifyNode(node, "audio", true, false);
      });
    }, 1000);

    setTimeout(function () {
      clearInterval(interval);
    }, 15000);

    // Escape hatch for pages that never fire a load event we can hook.
    Object.defineProperty(window, "$<process_document>", {
      enumerable: false,
      configurable: false,
      writable: false,
      value: function (token) {
        if (token !== SECURITY_TOKEN) {
          return;
        }
        checkPageForVideos(true);
      },
    });

    // Single-page apps (YouTube, SoundCloud, BitChute) swap the video without
    // a navigation, so watch for the URL changing under a mutating DOM.
    window.addEventListener("load", () => {
      let lastLocation = document.location.href;
      const body = document.querySelector("body");
      if (!body) {
        return;
      }

      const observer = new MutationObserver(() => {
        if (lastLocation !== document.location.href) {
          lastLocation = document.location.href;
          checkPageForVideos(false);
        }
      });
      observer.observe(body, { childList: true, subtree: true });
    });

    checkPageForVideos(false);
  }

  setupDetector();
})();
