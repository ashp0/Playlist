// Copyright 2021 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `LivePlaylistWebLoader` in
// `Sources/Brave/Frontend/Browser/Playlist/Managers & Cache/PlaylistCacheLoader.swift`.
//
// This is the component that makes a browserless build of Playlist possible.
// Upstream, `LivePlaylistWebLoader` is a *fallback*: Playlist normally detects
// media in the tab the user is already browsing, and this offscreen loader only
// runs when a saved media URL has expired and needs re-resolving. With the
// browser removed it becomes the primary — and only — extraction path, which is
// exactly the seam that lets the feature stand alone.
//
// Changes from upstream:
//   * `Tab`, `BrowserViewController`, `CertStore`, `ContentBlockerManager`,
//     `Domain`/Shields, `UserScriptManager` and Brave's certificate pinning are
//     all gone. What remains is a bare `WKWebView` plus two user scripts.
//   * Brave resolves the *first* acceptable item and immediately navigates away.
//     Here, candidates are collected for a short settle window and ranked,
//     because a paste-a-URL flow has no page context to disambiguate with, and
//     the first `<video>` to report is frequently a pre-roll ad or a trailer.
//   * A hard deadline replaces upstream's chain of `DispatchWorkItem`
//     rescheduling, which could extend a single load to five minutes.

import Foundation
import UIKit
import WebKit
import os.log

/// Loads a page offscreen and reports the media it finds.
///
/// Not a browser: there is no navigation UI, no back/forward, no persistence,
/// and the web view is discarded as soon as extraction finishes.
@MainActor
final class PlaylistWebLoader: NSObject {

  /// How long to wait for a page to yield any media at all.
  private static let pageLoadTimeout: TimeInterval = 45.0

  /// Once the first candidate arrives, how long to keep listening for better
  /// ones. Players commonly report a low-quality or advertising source first
  /// and the real media a beat later.
  private static let settleInterval: TimeInterval = 2.5

  /// The same window for YouTube, which needs longer: a pre-roll advert holds
  /// the player for several seconds before the feature's source is assigned,
  /// and stopping at 2.5s would reliably save the advert instead.
  private static let youTubeSettleInterval: TimeInterval = 8.0

  private var webView: WKWebView?
  private var containerView: UIView?
  private var continuation: CheckedContinuation<[PlaylistInfo], Never>?

  /// Randomized per load so a hostile page cannot address our handler by a
  /// known name. Mirrors Brave's `messageHandlerName` / `scriptId` scheme.
  private let handlerName = "playlist_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
  private let securityToken = UUID().uuidString
  private let tagKey = "tag_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
  private let processDocumentName =
    "processDocument_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

  private var candidates = [String: PlaylistInfo]()
  private var timeoutTask: Task<Void, Never>?
  private var settleTask: Task<Void, Never>?
  private var hasFinished = false

  /// Whether this load is a YouTube watch page, which needs a forced mobile
  /// user agent, a longer settle window, and a metadata pass on the way out.
  private var isYouTubeLoad = false

  /// Guards the async metadata read at the end of a YouTube load, so a timeout
  /// firing mid-read cannot resolve the continuation twice.
  private var isFinishing = false

  /// Why a YouTube page yielded nothing, when the page was willing to say.
  ///
  /// Read by `MediaExtractor` after `load` returns. Without it every failure
  /// collapses into "no media found", which is unhelpful for the one case the
  /// user can actually fix by signing in.
  private(set) var playabilityIssue: PlayabilityIssue?

  enum PlayabilityIssue {
    case signInRequired
    /// YouTube's own explanation — "This live event has ended", and similar.
    case unavailable(String)
  }

  // MARK: - Loading

  /// Loads `url` and returns every distinct media item the page exposed.
  ///
  /// Never throws and never hangs: an unreachable page, a page with no media,
  /// or a page that simply refuses to cooperate all resolve to an empty array
  /// once the deadline elapses.
  func load(url: URL) async -> [PlaylistInfo] {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      self.start(url: url)
    }
  }

  /// Abandons an in-flight load.
  func cancel() {
    finish(with: [])
  }

  private func start(url: URL) {
    isYouTubeLoad = YouTube.isYouTube(url)

    let configuration = WKWebViewConfiguration()
    // Nothing about extraction should persist: no cookies, no cache, no local
    // storage carried between one paste and the next.
    //
    // The single exception is a YouTube load once the user has signed in, which
    // needs that session's cookies to reach age-restricted videos at all. That
    // is the trade they opted into by signing in, and it applies to no other
    // site. See `YouTubeSession.dataStore(for:)`.
    configuration.websiteDataStore = YouTubeSession.shared.dataStore(for: url)
    configuration.allowsInlineMediaPlayback = true
    configuration.allowsPictureInPictureMediaPlayback = false
    configuration.ignoresViewportScaleLimits = true
    configuration.suppressesIncrementalRendering = true
    // Media must be allowed to begin loading on its own — that is the event
    // the detector is waiting for. Requiring a user gesture would mean the
    // media element never gets a source at all.
    configuration.mediaTypesRequiringUserActionForPlayback = []

    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    let contentController = configuration.userContentController
    contentController.add(
      ScriptMessageProxy(handler: self), name: handlerName)

    // Order matters: the swizzler must land before any page script can capture
    // `window.MediaSource`, and before the detector installs its hooks.
    if Preferences.Playlist.webMediaSourceCompatibility.value == false,
      let swizzler = Self.loadScript(named: "PlaylistSwizzler")
    {
      contentController.addUserScript(
        WKUserScript(
          source: swizzler,
          injectionTime: .atDocumentStart,
          // `false`: embedded players live in cross-origin iframes, and that is
          // exactly where the media element usually is.
          forMainFrameOnly: false,
          // `.page`, not an isolated world — prototype patches are only visible
          // to page scripts if they are installed in the page's own world.
          in: .page))
    }

    if let detector = Self.loadScript(named: "PlaylistDetector") {
      let source =
        detector
        .replacingOccurrences(of: "$<message_handler>", with: handlerName)
        .replacingOccurrences(of: "$<security_token>", with: securityToken)
        .replacingOccurrences(of: "$<tag_uuid>", with: tagKey)
        .replacingOccurrences(of: "$<process_document>", with: processDocumentName)

      contentController.addUserScript(
        WKUserScript(
          source: source,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: false,
          in: .page))
    } else {
      Logger.module.error("PlaylistDetector.js is missing from the bundle.")
      finish(with: [])
      return
    }

    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
    webView.navigationDelegate = self
    // Per-site, not the global preference: YouTube serves a progressive format
    // only to a mobile UA, and that choice is made server-side before any of
    // our scripts run. See `UserAgent.userAgent(for:)`.
    webView.customUserAgent = UserAgent.userAgent(for: url)
    webView.isUserInteractionEnabled = false
    self.webView = webView

    // The web view has to be in a window, not merely allocated. WebKit
    // aggressively throttles timers and defers media loading for views it
    // believes are not on screen, and the detector depends on both. Brave
    // solves this by inserting the loader behind its player; here it is parked
    // offscreen in the key window at zero alpha.
    if let window = Self.keyWindow {
      let container = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
      container.alpha = 0.01
      container.isUserInteractionEnabled = false
      container.clipsToBounds = true
      container.addSubview(webView)
      window.insertSubview(container, at: 0)
      containerView = container
    }

    timeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.pageLoadTimeout * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard let self = self else { return }
      Logger.module.debug("Extraction timed out for \(url.absoluteString)")
      self.finishWithCandidates()
    }

    if url.isFileURL {
      // WKWebView refuses a plain `load(URLRequest:)` for `file:` URLs — it has
      // to be granted explicit read access to the containing directory.
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      webView.load(
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0))
    }
  }

  // MARK: - Message handling

  fileprivate func handle(messageBody: Any) {
    guard !hasFinished else { return }

    guard let body = messageBody as? [String: Any],
      let token = body["securityToken"] as? String,
      token == securityToken
    else {
      // A page trying to talk to a handler it should not know about.
      Logger.module.error("Rejected script message with a missing or bad security token.")
      return
    }

    // A readyState/cancel ping rather than a media item.
    if let state = body["state"] as? String {
      if state == "cancel" {
        // The page told us it has no media at all. If nothing has been found
        // by now, stop waiting for the full timeout.
        if candidates.isEmpty {
          finish(with: [])
        }
      }
      return
    }

    guard var item = PlaylistInfo.from(messageBody: body), item.detected else { return }

    // A detached media element is a decoder, not content.
    if item.isInvisible { return }

    // `blob:` is an MSE handle that only means anything inside that page, and
    // `data:` here would mean re-encoding the entire media through JSON. Both
    // are unusable as download sources — the swizzler exists to prevent the
    // former from ever being the only option.
    guard !item.src.isEmpty,
      !item.src.hasPrefix("blob:"),
      URL(string: item.src) != nil
    else { return }

    // Two corrections before the candidate is recorded.
    //
    // `pageSrc`: prefer the web view's own URL over whatever an iframe
    // reported, so the item can be re-extracted later from a URL the user
    // recognises.
    //
    // `duration`: a `googlevideo.com` URL states its own length in a `dur`
    // parameter, and the DOM has none yet — the element's `duration` is still 0
    // at the instant a source is assigned, because it has not loaded metadata.
    // Reading it off the URL is what lets ranking tell a pre-roll advert from
    // the feature without waiting for either to load.
    let currentURL = webView?.url?.absoluteString ?? ""
    var duration = item.duration
    if duration <= 0, let mediaURL = URL(string: item.src),
      let advertised = YouTube.advertisedDuration(ofMediaURL: mediaURL)
    {
      duration = advertised
    }

    item = PlaylistInfo(
      name: item.name,
      src: item.src,
      pageSrc: currentURL.isEmpty ? item.pageSrc : currentURL,
      pageTitle: item.pageTitle.isEmpty ? (webView?.title ?? "") : item.pageTitle,
      mimeType: item.mimeType,
      duration: duration,
      lastPlayedOffset: 0.0,
      detected: item.detected,
      dateAdded: item.dateAdded,
      tagId: item.tagId,
      order: item.order,
      isInvisible: item.isInvisible,
      artworkURL: item.artworkURL)

    // Keyed on media URL: the same element re-reports on every poll tick, and
    // a later report carries better metadata (a resolved duration) than the
    // first, so overwriting is correct.
    let isFirst = candidates.isEmpty
    candidates[item.src] = item

    if isFirst {
      // Got something. Give the page a moment to offer something better, then
      // stop regardless.
      let interval = isYouTubeLoad ? Self.youTubeSettleInterval : Self.settleInterval
      settleTask?.cancel()
      settleTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.finishWithCandidates()
      }
    }
  }

  // MARK: - Finishing

  private func finishWithCandidates() {
    guard !hasFinished, !isFinishing else { return }

    let items = Array(candidates.values)

    // Ordinary sites are done here. A YouTube page has one more thing worth
    // asking for on the way out, and by now — a settle window after the player
    // committed a source — the page is certainly parsed enough to answer.
    //
    // Asked even when nothing was found, because that is exactly when the
    // page's own explanation is worth having.
    guard isYouTubeLoad, let webView = webView else {
      finish(with: Self.rank(items))
      return
    }

    isFinishing = true
    webView.evaluateJavaScript(YouTube.metadataScript, in: nil, in: .page) {
      [weak self] result in
      guard let self = self else { return }
      let metadata = YouTube.metadata(from: try? result.get())
      self.isFinishing = false

      if items.isEmpty, let metadata = metadata, !metadata.isPlayable {
        self.playabilityIssue =
          metadata.requiresSignIn
          ? .signInRequired
          : .unavailable(metadata.playabilityReason ?? "")
      }

      self.finish(with: Self.rank(Self.applying(metadata, to: items), matching: metadata?.duration))
    }
  }

  /// Fills a YouTube item in from what the watch page says about itself.
  ///
  /// The detector can only report what the DOM exposes, and on YouTube that is
  /// a document title with a " - YouTube" suffix, no artwork the library would
  /// want, and no duration. All three are sitting in `ytInitialPlayerResponse`.
  static func applying(_ metadata: YouTube.Metadata?, to items: [PlaylistInfo]) -> [PlaylistInfo] {
    guard let metadata = metadata else { return items }

    return items.map { item in
      // The advert in front of a video is not that video: giving it the
      // feature's title and artwork would mislabel it in the library. Only the
      // item whose length matches gets the page's identity.
      let isFeature = metadata.duration <= 0 || Self.durationMatches(item.duration, metadata.duration)

      return PlaylistInfo(
        name: isFeature && !metadata.title.isEmpty
          ? metadata.title : YouTube.cleanedTitle(item.name),
        src: item.src,
        pageSrc: item.pageSrc,
        pageTitle: metadata.title.isEmpty
          ? YouTube.cleanedTitle(item.pageTitle) : metadata.title,
        mimeType: item.mimeType,
        duration: item.duration > 0 ? item.duration : metadata.duration,
        lastPlayedOffset: item.lastPlayedOffset,
        detected: item.detected,
        dateAdded: item.dateAdded,
        tagId: item.tagId,
        order: item.order,
        isInvisible: item.isInvisible,
        artworkURL: isFeature ? (metadata.artworkURL ?? item.artworkURL) : item.artworkURL)
    }
  }

  /// Whether a candidate's length is the one the page claims.
  ///
  /// Loose by a few seconds: the URL's advertised `dur` is the media's exact
  /// length, while `lengthSeconds` is rounded, and the two disagree slightly on
  /// almost every video.
  private static func durationMatches(_ duration: TimeInterval, _ expected: TimeInterval) -> Bool {
    duration > 0 && abs(duration - expected) <= 3.0
  }

  /// Orders candidates best-first.
  ///
  /// Duration is the strongest signal available: on a page with a pre-roll ad
  /// and a feature, the feature is the long one. Progressive files sort above
  /// HLS because they download faster and play back more reliably offline.
  ///
  /// When the page has told us how long the video is, that beats every
  /// heuristic — an advert that happens to run longer than a short video would
  /// otherwise win on duration alone.
  static func rank(_ items: [PlaylistInfo], matching expectedDuration: TimeInterval? = nil)
    -> [PlaylistInfo]
  {
    items.sorted { lhs, rhs in
      if let expected = expectedDuration, expected > 0 {
        let lhsMatches = durationMatches(lhs.duration, expected)
        let rhsMatches = durationMatches(rhs.duration, expected)
        if lhsMatches != rhsMatches {
          return lhsMatches
        }
      }

      let lhsIsHLS = PlaylistMimeTypeDetector.isHLS(mimeType: lhs.mimeType)
        || (URL(string: lhs.src).map(PlaylistMimeTypeDetector.isHLS(url:)) ?? false)
      let rhsIsHLS = PlaylistMimeTypeDetector.isHLS(mimeType: rhs.mimeType)
        || (URL(string: rhs.src).map(PlaylistMimeTypeDetector.isHLS(url:)) ?? false)

      // Treat an unknown (zero) duration as worse than any known one.
      let lhsDuration = lhs.duration > 0 ? lhs.duration : -1
      let rhsDuration = rhs.duration > 0 ? rhs.duration : -1

      if lhsDuration != rhsDuration {
        return lhsDuration > rhsDuration
      }

      if lhsIsHLS != rhsIsHLS {
        return !lhsIsHLS
      }

      return lhs.src < rhs.src
    }
  }

  private func finish(with items: [PlaylistInfo]) {
    guard !hasFinished else { return }
    hasFinished = true

    timeoutTask?.cancel()
    settleTask?.cancel()
    timeoutTask = nil
    settleTask = nil

    teardown()

    let continuation = self.continuation
    self.continuation = nil
    continuation?.resume(returning: items)
  }

  private func teardown() {
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    // Removing the handler breaks the retain cycle WebKit holds on it, and
    // stops any late-firing page script from reaching a torn-down loader.
    webView?.configuration.userContentController
      .removeScriptMessageHandler(forName: handlerName)
    webView?.configuration.userContentController.removeAllUserScripts()
    webView?.removeFromSuperview()
    webView = nil

    containerView?.removeFromSuperview()
    containerView = nil
  }

  // MARK: - Helpers

  private static func loadScript(named name: String) -> String? {
    guard let path = Bundle.main.path(forResource: name, ofType: "js"),
      let source = try? String(contentsOfFile: path, encoding: .utf8)
    else {
      Logger.module.error("Could not load \(name).js from the bundle.")
      return nil
    }
    return source
  }

  private static var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }
}

// MARK: - WKNavigationDelegate

extension PlaylistWebLoader: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    // Nudge pages whose players never fire an event we hook. Upstream added
    // this for sites (tver.jp is the cited example) that otherwise never load.
    webView.evaluateJavaScript(
      "window.\(processDocumentName) && window.\(processDocumentName)('\(securityToken)')",
      in: nil,
      in: .page
    ) { _ in }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleNavigationFailure(error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    handleNavigationFailure(error)
  }

  private func handleNavigationFailure(_ error: Error) {
    // WebKit reports a spurious failure for pages it is about to reload itself,
    // flagged with a recovery attempter. Treating that as fatal would abandon
    // loads that were going to succeed. Upstream carries the same guard.
    if (error as NSError).userInfo["_WKRecoveryAttempterErrorKey"] != nil {
      return
    }

    // A cancelled navigation is never a failed page. It means either we refused
    // the navigation ourselves in `decidePolicyFor` — which is how the YouTube
    // sign-in bounce is turned away — or the page superseded one navigation
    // with another. In both cases the document we care about is still loaded
    // and may not have produced its media yet, so giving up here would throw
    // away a load that was about to succeed.
    if (error as NSError).domain == NSURLErrorDomain,
      (error as NSError).code == NSURLErrorCancelled
    {
      return
    }

    Logger.module.debug("Extraction navigation failed: \(error.localizedDescription)")

    // Media may already have been detected before the failure — a subresource
    // failing does not invalidate what we found.
    finishWithCandidates()
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url else { return .cancel }

    // Only web content. App-store, tel:, mailto: and similar schemes would
    // otherwise try to leave the app entirely during a background extraction.
    guard ["http", "https", "data", "blob", "about", "file"].contains(url.scheme) else {
      return .cancel
    }

    // A cookieless web view has no Google session, so a few seconds into a
    // YouTube load the page navigates itself to `accounts.google.com` to do a
    // "passive" sign-in — which unloads the watch page, and with it the player
    // that was about to hand over a media URL. Observed consistently, and it
    // lands right around when a longer video commits its source. There is
    // nothing for us behind a sign-in, so the navigation is refused and the
    // watch page stays where it is.
    if navigationAction.targetFrame?.isMainFrame != false, YouTube.isSignInRedirect(url) {
      Logger.module.debug("Refused a sign-in redirect to \(url.host ?? "")")
      return .cancel
    }

    return .allow
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
  ) async -> WKNavigationResponsePolicy {
    .allow
  }

  nonisolated func webView(
    _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    // Brave pins certificates here through BraveCore. Without Chromium, the
    // system's own trust evaluation is the right answer — and notably this
    // does *not* blanket-accept invalid certificates.
    (.performDefaultHandling, nil)
  }
}

// MARK: - Message proxy

/// Breaks the retain cycle `WKUserContentController` would otherwise create.
///
/// The content controller retains its message handlers strongly, and the web
/// view retains the controller, so a loader that registered itself directly
/// would never deallocate.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
  private weak var handler: PlaylistWebLoader?

  init(handler: PlaylistWebLoader) {
    self.handler = handler
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    let body = message.body
    Task { @MainActor [weak handler] in
      handler?.handle(messageBody: body)
    }
  }
}
