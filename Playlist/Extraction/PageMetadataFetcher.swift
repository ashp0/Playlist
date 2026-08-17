// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Replaces Brave's `Favicon` module, which is a Chromium-backed favicon
// database. Artwork here comes from Open Graph metadata, with the favicon as a
// last resort — better artwork for a media library than a 32px site icon.

import Foundation
import os.log

/// Reads `og:image` / `og:title` out of a page's `<head>`.
public enum PageMetadataFetcher {

  public struct Metadata {
    public let title: String?
    public let imageURL: String?
  }

  /// Only the first 64 KB of the document is fetched: Open Graph tags live in
  /// `<head>`, and a video page's full HTML can be several megabytes of
  /// inlined application state that is pure waste to download here.
  private static let maximumBytes = 64 * 1024

  public static func fetch(url: URL) async -> Metadata? {
    var request = URLRequest(
      url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10.0)
    request.addValue(UserAgent.current, forHTTPHeaderField: "User-Agent")
    request.addValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    request.addValue("bytes=0-\(maximumBytes)", forHTTPHeaderField: "Range")

    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }

    do {
      let (data, response) = try await session.data(for: request)

      guard let response = response as? HTTPURLResponse,
        (200...299).contains(response.statusCode) || response.statusCode == 206
      else { return nil }

      // A truncated response may cut a multi-byte character in half, so decode
      // leniently rather than failing the whole fetch.
      let html =
        String(data: data, encoding: .utf8)
        ?? String(decoding: data, as: UTF8.self)

      let title = firstMatch(in: html, patterns: Self.titlePatterns)
      let image = firstMatch(in: html, patterns: Self.imagePatterns)

      // Resolve protocol-relative and root-relative artwork against the page.
      let resolvedImage = image.map { PlaylistInfo.fixSchemelessURLs(src: $0, pageSrc: url.absoluteString) }

      guard title != nil || resolvedImage != nil else { return nil }
      return Metadata(title: title?.decodingHTMLEntities, imageURL: resolvedImage)
    } catch {
      Logger.module.debug("Page metadata fetch failed: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Parsing

  // Regex rather than a parser: this reads two well-known tags out of a
  // truncated, frequently malformed document, where a strict parser would
  // simply refuse. Attribute order varies by site, so both orderings are tried.
  private static let imagePatterns = [
    #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
    #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
    #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
    #"<link[^>]+rel=["']image_src["'][^>]+href=["']([^"']+)["']"#,
  ]

  private static let titlePatterns = [
    #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
    #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']"#,
    #"<title[^>]*>([^<]+)</title>"#,
  ]

  private static func firstMatch(in html: String, patterns: [String]) -> String? {
    for pattern in patterns {
      guard
        let regex = try? NSRegularExpression(
          pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
      else { continue }

      let range = NSRange(html.startIndex..<html.endIndex, in: html)
      guard let match = regex.firstMatch(in: html, options: [], range: range),
        match.numberOfRanges > 1,
        let captureRange = Range(match.range(at: 1), in: html)
      else { continue }

      let value = String(html[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty {
        return value
      }
    }
    return nil
  }
}

extension String {
  /// Expands the handful of HTML entities that routinely appear in page titles.
  fileprivate var decodingHTMLEntities: String {
    var result = self
    let entities = [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
      ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
      ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/"),
    ]
    for (entity, character) in entities {
      result = result.replacingOccurrences(of: entity, with: character)
    }
    return result
  }
}
