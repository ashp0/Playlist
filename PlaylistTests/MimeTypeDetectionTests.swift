// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import XCTest

@testable import Playlist

/// Container detection is what decides the on-disk filename, and `AVPlayer`
/// refuses to play a file whose extension it does not recognise — so a wrong
/// answer here means a download that completes and then silently will not play.
final class MimeTypeDetectionTests: XCTestCase {

  // MARK: - From URL

  func testDetectsCommonExtensionsFromURL() {
    let cases: [(String, String)] = [
      ("https://example.com/a/video.mp4", "mp4"),
      ("https://example.com/a/audio.mp3", "mp3"),
      ("https://example.com/a/clip.mov", "mov"),
      ("https://example.com/a/song.m4a", "m4a"),
      ("https://example.com/a/movie.webm", "webm"),
    ]

    for (urlString, expected) in cases {
      let url = try! XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(
        PlaylistMimeTypeDetector(url: url).fileExtension, expected,
        "Wrong extension for \(urlString)")
    }
  }

  func testIgnoresQueryStringWhenReadingExtension() throws {
    // Signed CDN URLs carry the extension before a long query string.
    let url = try XCTUnwrap(
      URL(string: "https://cdn.example.com/v/clip.mp4?Expires=123&Signature=abc"))
    XCTAssertEqual(PlaylistMimeTypeDetector(url: url).fileExtension, "mp4")
  }

  func testUnknownExtensionYieldsNoAnswer() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/videoplayback"))
    XCTAssertNil(PlaylistMimeTypeDetector(url: url).fileExtension)
  }

  // MARK: - From MIME type

  func testDetectsFromMimeType() {
    XCTAssertEqual(PlaylistMimeTypeDetector(mimeType: "video/mp4").fileExtension, "mp4")
    XCTAssertEqual(PlaylistMimeTypeDetector(mimeType: "audio/mpeg").fileExtension, "mp3")
    XCTAssertEqual(PlaylistMimeTypeDetector(mimeType: "video/webm").fileExtension, "webm")
  }

  /// Regression test for a fix over upstream: Brave matches the raw header, so
  /// a perfectly ordinary `Content-Type` with parameters falls through.
  func testStripsContentTypeParameters() {
    XCTAssertEqual(
      PlaylistMimeTypeDetector(mimeType: "video/mp4; charset=utf-8").fileExtension, "mp4")
    XCTAssertEqual(
      PlaylistMimeTypeDetector(mimeType: "AUDIO/MPEG ; foo=bar").fileExtension, "mp3")
  }

  // MARK: - From bytes

  func testDetectsMP4FromMagicBytes() {
    // 4 bytes of size, then `ftyp` + `isom`.
    var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
    bytes += [0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
    bytes += [UInt8](repeating: 0, count: 16)

    let detector = PlaylistMimeTypeDetector(data: Data(bytes))
    XCTAssertEqual(detector.fileExtension, "mp4")
    XCTAssertEqual(detector.mimeType, "video/mp4")
  }

  /// Regression test for a fix over upstream: Brave labels this branch `mp4`,
  /// so every downloaded MP3 lands with the wrong extension.
  func testDetectsMP3FromID3Header() {
    var bytes: [UInt8] = [0x49, 0x44, 0x33, 0x03, 0x00]  // "ID3"
    bytes += [UInt8](repeating: 0, count: 16)

    let detector = PlaylistMimeTypeDetector(data: Data(bytes))
    XCTAssertEqual(detector.fileExtension, "mp3")
    XCTAssertEqual(detector.mimeType, "audio/mpeg")
  }

  func testDetectsWavFromRIFFHeader() {
    var bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46]  // "RIFF"
    bytes += [0x00, 0x00, 0x00, 0x00]
    bytes += [0x57, 0x41, 0x56, 0x45]  // "WAVE"
    bytes += [UInt8](repeating: 0, count: 8)

    XCTAssertEqual(PlaylistMimeTypeDetector(data: Data(bytes)).fileExtension, "wav")
  }

  func testUnrecognisedBytesFallBackToHLSSentinel() {
    let detector = PlaylistMimeTypeDetector(data: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22]))
    XCTAssertNil(detector.fileExtension, "Unknown data must report no extension")
    XCTAssertEqual(detector.mimeType, "application/x-mpegURL")
  }

  func testShortDataDoesNotCrash() {
    // Guards the offset arithmetic in `findHeader`.
    for count in 0...8 {
      let data = Data([UInt8](repeating: 0x66, count: count))
      _ = PlaylistMimeTypeDetector(data: data).fileExtension
    }
  }

  /// `Data` slices keep their parent's indices; indexing from zero would trap.
  func testWorksOnASlicedBuffer() {
    var bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]  // prefix to be dropped
    bytes += [0x00, 0x00, 0x00, 0x18]
    bytes += [0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
    bytes += [UInt8](repeating: 0, count: 8)

    let slice = Data(bytes).dropFirst(4)
    XCTAssertEqual(PlaylistMimeTypeDetector(data: slice).fileExtension, "mp4")
  }

  // MARK: - HLS

  func testRecognisesHLS() throws {
    XCTAssertTrue(PlaylistMimeTypeDetector.isHLS(mimeType: "application/x-mpegURL"))
    XCTAssertTrue(PlaylistMimeTypeDetector.isHLS(mimeType: "application/vnd.apple.mpegurl"))
    XCTAssertTrue(PlaylistMimeTypeDetector.isHLS(mimeType: "audio/x-mpegurl"))
    XCTAssertFalse(PlaylistMimeTypeDetector.isHLS(mimeType: "video/mp4"))

    let manifest = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
    XCTAssertTrue(PlaylistMimeTypeDetector.isHLS(url: manifest))

    let file = try XCTUnwrap(URL(string: "https://example.com/clip.mp4"))
    XCTAssertFalse(PlaylistMimeTypeDetector.isHLS(url: file))
  }
}
