// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// The one place in this app where a web view is visible.
//
// It is deliberately not a browser: no address bar, no tabs, no history, no
// back/forward beyond what the login flow itself needs, and a hard allowlist
// that refuses to navigate anywhere outside Google's own sign-in hosts. Its
// entire job is to put Google's login form on screen so the user can sign in
// with their own hands, and to keep the cookie that results.
//
// The app never reads the form, never fills it, and never stores a credential.

import SwiftUI
import WebKit
import os.log

/// Google's sign-in flow, shown modally.
struct SignInView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var session = YouTubeSession.shared

  @State private var isLoading = true
  @State private var blockedHost: String?

  var body: some View {
    NavigationStack {
      ZStack {
        SignInWebView(
          isLoading: $isLoading,
          blockedHost: $blockedHost,
          onReachedYouTube: {
            Task {
              await session.refresh()
              if session.isSignedIn {
                dismiss()
              }
            }
          })

        if isLoading {
          ProgressView()
            .controlSize(.large)
        }
      }
      .navigationTitle("Sign in to YouTube")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .safeAreaInset(edge: .bottom) {
        footer
      }
      .interactiveDismissDisabled(false)
    }
    .task {
      await session.refresh()
    }
    .onDisappear {
      Task { await session.refresh() }
    }
  }

  private var footer: some View {
    VStack(spacing: 6) {
      if let blockedHost = blockedHost {
        Label(
          "Blocked a link to \(blockedHost) — this window only opens Google sign-in.",
          systemImage: "hand.raised.fill"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }

      Text(
        "You're signing in to Google directly. This app can't see your password — "
          + "it only keeps the sign-in cookie, so age-restricted videos can be saved.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }
}

// MARK: - Web view

private struct SignInWebView: UIViewRepresentable {
  @Binding var isLoading: Bool
  @Binding var blockedHost: String?
  let onReachedYouTube: () -> Void

  /// Google's own sign-in entry point, told to return to YouTube when finished.
  /// Landing back on YouTube is what signals the flow is complete.
  private static let start = URL(
    string: "https://accounts.google.com/ServiceLogin?service=youtube"
      + "&continue=https%3A%2F%2Fm.youtube.com%2F")!

  func makeCoordinator() -> Coordinator {
    Coordinator(isLoading: $isLoading, blockedHost: $blockedHost, onReachedYouTube: onReachedYouTube)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    // The whole point: cookies written here must be the ones extraction reads.
    configuration.websiteDataStore = YouTubeSession.shared.dataStore
    // Google's sign-in uses popups for some challenge types; they are routed
    // back into this same view by the coordinator rather than being dropped.
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    // Match extraction's user agent. Google ties a session to the client it was
    // established from, and signing in as one browser then loading watch pages
    // as another is a good way to have the session quietly ignored.
    webView.customUserAgent = UserAgent.mobile
    webView.allowsBackForwardNavigationGestures = true
    webView.load(URLRequest(url: Self.start))
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    @Binding private var isLoading: Bool
    @Binding private var blockedHost: String?
    private let onReachedYouTube: () -> Void

    /// Hosts this window is allowed to visit.
    ///
    /// Suffix-matched against `host` with a leading-dot guard, so
    /// `accounts.google.com` and `google.com` both pass while
    /// `google.com.example.net` does not. `gstatic` and `googleusercontent`
    /// carry the flow's images and scripts.
    private static let allowedSuffixes = [
      "google.com", "youtube.com", "gstatic.com", "googleusercontent.com",
      "googleapis.com", "youtu.be",
    ]

    init(
      isLoading: Binding<Bool>, blockedHost: Binding<String?>,
      onReachedYouTube: @escaping () -> Void
    ) {
      self._isLoading = isLoading
      self._blockedHost = blockedHost
      self.onReachedYouTube = onReachedYouTube
    }

    private static func isAllowed(_ url: URL) -> Bool {
      guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "about" else {
        return false
      }
      guard let host = url.host?.lowercased() else { return scheme == "about" }
      return allowedSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let url = navigationAction.request.url else { return .cancel }

      guard Self.isAllowed(url) else {
        // Privacy-policy links, "create an account" journeys that wander off to
        // marketing pages, and anything else outside the flow are simply not
        // followed. The user is told which host was refused rather than being
        // left with a window that silently does nothing.
        Logger.module.debug("Sign-in view refused navigation to \(url.host ?? "?")")
        blockedHost = url.host
        return .cancel
      }

      // Reaching YouTube itself means Google finished with us and honoured the
      // `continue` parameter. Whether a session actually resulted is decided by
      // reading the cookie store, not by trusting the URL.
      if YouTube.isYouTube(url) {
        onReachedYouTube()
      }

      return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      isLoading = false
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      isLoading = false
    }

    /// Google opens some challenge steps in a new window. Returning nil would
    /// dead-end the flow, so the request is loaded in place instead.
    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url, Self.isAllowed(url) {
        webView.load(navigationAction.request)
      }
      return nil
    }
  }
}
