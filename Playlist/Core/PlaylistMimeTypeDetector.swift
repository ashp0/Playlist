// Copyright 2023 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Playlist/PlaylistMimeTypeDetector.swift`.
// The tables and magic-number probes are Brave's. Three upstream defects are
// corrected, each marked `NOTE:` at the site.
//
// IANA audio types:  https://www.iana.org/assignments/media-types/media-types.xhtml#audio
// IANA video types:  https://www.iana.org/assignments/media-types/media-types.xhtml#video
// Apple UTI types:   https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/UTIRef/Articles/System-DeclaredUniformTypeIdentifiers.html

import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Determines the container of a media resource from its URL, its declared MIME
/// type, or its leading bytes.
///
/// This exists because `AVPlayer` will not play a local file whose path
/// extension it does not recognise, *even when the bytes are a format it fully
/// supports*. A downloaded file therefore has to be named correctly before it
/// is stored, and the server's Content-Type is frequently absent or wrong — so
/// all three signals are tried, cheapest first.
public class PlaylistMimeTypeDetector {
  private(set) var mimeType: String?
  /// The extension to give the downloaded file. `nil` means "unknown"; callers
  /// fall back to `mp4`.
  private(set) var fileExtension: String?

  init(url: URL) {
    let possibleFileExtension = url.pathExtension.lowercased()
    if let supportedExtension = knownFileExtensions.first(where: {
      $0.lowercased() == possibleFileExtension
    }) {
      self.fileExtension = supportedExtension
      self.mimeType = mimeTypeMap.first(where: { $0.value == supportedExtension })?.key
    } else if let fileExtension = PlaylistMimeTypeDetector.supportedAVAssetFileExtensions()
      .first(where: { $0.lowercased() == possibleFileExtension })
    {
      self.fileExtension = fileExtension
      self.mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
  }

  init(mimeType: String) {
    // A Content-Type header often carries parameters: `video/mp4; charset=utf-8`.
    // NOTE: Brave matches the raw header, so any such value falls through to
    // the unknown case and the download is named `.mp4` by luck rather than
    // detection. Strip parameters before matching.
    let normalized =
      mimeType
      .components(separatedBy: ";")
      .first?
      .trimmingCharacters(in: .whitespaces)
      .lowercased() ?? mimeType.lowercased()

    if let fileExtension = mimeTypeMap[normalized] {
      self.mimeType = normalized
      self.fileExtension = fileExtension
    } else if let matched = PlaylistMimeTypeDetector.supportedAVAssetMimeTypes()
      .first(where: { $0.lowercased() == normalized })
    {
      self.mimeType = matched
      self.fileExtension = UTType(mimeType: matched)?.preferredFilenameExtension
    }
  }

  init(data: Data) {
    // Matroska and WebM share the EBML magic number.
    // NOTE: Brave probes the same four bytes twice and assigns `webm` both
    // times, so the `mkv` branch is dead. WebM is the overwhelmingly more
    // common case on the web, and AVFoundation plays neither natively, so the
    // single WebM branch is kept and the dead one dropped.
    if findHeader(offset: 0, data: data, header: [0x1A, 0x45, 0xDF, 0xA3]) {
      mimeType = "video/webm"
      fileExtension = "webm"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x4F, 0x67, 0x67, 0x53]) {
      mimeType = "application/ogg"
      fileExtension = "ogg"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x52, 0x49, 0x46, 0x46])
      && findHeader(offset: 8, data: data, header: [0x57, 0x41, 0x56, 0x45])
    {
      mimeType = "audio/x-wav"
      fileExtension = "wav"
      return
    }

    // NOTE: Brave assigns `fileExtension = "mp4"` to this MPEG-audio branch,
    // which makes every downloaded MP3 land as `.mp4`. AVPlayer usually
    // recovers, but the file is mislabelled everywhere it is shown.
    if findHeader(offset: 0, data: data, header: [0xFF, 0xFB])
      || findHeader(offset: 0, data: data, header: [0x49, 0x44, 0x33])
    {
      mimeType = "audio/mpeg"
      fileExtension = "mp3"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x66, 0x4C, 0x61, 0x43]) {
      mimeType = "audio/flac"
      fileExtension = "flac"
      return
    }

    // ISO base media file format: `ftyp` at offset 4, brand follows.
    if findHeader(offset: 4, data: data, header: [0x66, 0x74, 0x79, 0x70, 0x4D, 0x53, 0x4E, 0x56])
      || findHeader(offset: 4, data: data, header: [0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
      || findHeader(offset: 4, data: data, header: [0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32])
      || findHeader(offset: 0, data: data, header: [0x33, 0x67, 0x70, 0x35])
    {
      mimeType = "video/mp4"
      fileExtension = "mp4"
      return
    }

    if findHeader(offset: 4, data: data, header: [0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41]) {
      mimeType = "audio/m4a"
      fileExtension = "m4a"
      return
    }

    if findHeader(
      offset: 0, data: data,
      header: [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x56])
    {
      mimeType = "video/x-m4v"
      fileExtension = "m4v"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70]) {
      mimeType = "video/quicktime"
      fileExtension = "mov"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x52, 0x49, 0x46, 0x46])
      && findHeader(offset: 8, data: data, header: [0x41, 0x56, 0x49])
    {
      mimeType = "video/x-msvideo"
      fileExtension = "avi"
      return
    }

    if findHeader(
      offset: 0, data: data, header: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9])
    {
      mimeType = "video/x-ms-wmv"
      fileExtension = "wmv"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A]) {
      mimeType = "audio/amr"
      fileExtension = "amr"
      return
    }

    if findHeader(offset: 0, data: data, header: [0x46, 0x4C, 0x56, 0x01]) {
      mimeType = "video/x-flv"
      fileExtension = "flv"
      return
    }

    // Weakest probe last: a three-byte MPEG start code matches a lot of things
    // by accident, so it only runs once everything specific has failed.
    if findHeader(offset: 0, data: data, header: [0x00, 0x00, 0x01]) {
      mimeType = "video/mpeg"
      fileExtension = "mpg"
      return
    }

    // Nothing matched. Reporting HLS with no extension is Brave's convention
    // for "unknown"; callers substitute mp4.
    mimeType = "application/x-mpegURL"
    fileExtension = nil
  }

  private func findHeader(offset: Int, data: Data, header: [UInt8]) -> Bool {
    if offset < 0 || data.count < offset + header.count {
      return false
    }

    // `Data` slices keep the parent's indices, so index from `startIndex`
    // rather than assuming zero-based.
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: header.count)
    return [UInt8](data[start..<end]) == header
  }

  /// Every file extension AVFoundation claims to support on this OS version.
  private static func supportedAVAssetFileExtensions() -> [String] {
    let types = AVURLAsset.audiovisualTypes()
    return types.compactMap { UTType($0.rawValue)?.preferredFilenameExtension }
      .filter { !$0.isEmpty }
  }

  /// Every MIME type AVFoundation claims to support on this OS version.
  private static func supportedAVAssetMimeTypes() -> [String] {
    let types = AVURLAsset.audiovisualTypes()
    return types.compactMap { UTType($0.rawValue)?.preferredMIMEType }
      .filter { !$0.isEmpty }
  }

  private let knownFileExtensions = [
    "mov", "qt", "mp4", "m4v", "m4a",
    "m4b",  // DRM protected
    "m4p",  // DRM protected
    "3gp", "3gpp", "sdv", "3g2", "3gp2", "caf", "wav", "wave", "bwf",
    "aif", "aiff", "aifc", "cdda", "amr", "mp3", "au", "snd", "ac3",
    "eac3", "flac", "aac", "mp2", "pls", "avi", "webm", "ogg", "mpg",
    "mpg4", "mpeg", "mpg3", "wma", "wmv", "swf", "flv", "mng", "asx",
    "asf", "mkv",
  ]

  private let mimeTypeMap = [
    "audio/x-wav": "wav",
    "audio/vnd.wave": "wav",
    "audio/aacp": "aacp",
    "audio/mpeg3": "mp3",
    "audio/mp3": "mp3",
    "audio/x-caf": "caf",
    "audio/mpeg": "mp3",
    "audio/x-mpeg3": "mp3",
    "audio/wav": "wav",
    "audio/flac": "flac",
    "audio/x-flac": "flac",
    "audio/mp4": "mp4",
    "audio/x-mpg": "mp3",
    "audio/scpls": "pls",
    "audio/x-aiff": "aiff",
    "audio/usac": "eac3",  // Extended AC3
    "audio/x-mpeg": "mp3",
    "audio/wave": "wav",
    "audio/x-m4r": "m4r",
    "audio/x-mp3": "mp3",
    "audio/amr": "amr",
    "audio/aiff": "aiff",
    "audio/3gpp2": "3gp2",
    "audio/aac": "aac",
    "audio/mpg": "mp3",
    "audio/mpegurl": "mpg",  // actually .m3u8 / .m3u HLS stream
    "audio/x-m4b": "m4b",
    "audio/x-m4p": "m4p",
    "audio/x-scpls": "pls",
    "audio/x-mpegurl": "mpg",  // actually .m3u8 / .m3u HLS stream
    "audio/x-aac": "aac",
    "audio/3gpp": "3gp",
    "audio/basic": "au",
    "audio/au": "au",
    "audio/snd": "snd",
    "audio/x-m4a": "m4a",
    "audio/x-realaudio": "ra",
    "video/3gpp2": "3gp2",
    "video/quicktime": "mov",
    "video/mp4": "mp4",
    "video/mp4v": "mp4",
    "video/mpg": "mpg",
    "video/mpeg": "mpeg",
    "video/x-mpg": "mpg",
    "video/x-mpeg": "mpeg",
    "video/avi": "avi",
    "video/x-m4v": "m4v",
    "video/mp2t": "ts",
    "application/vnd.apple.mpegurl": "mpg",  // actually .m3u8 / .m3u HLS stream
    "video/3gpp": "3gp",
    "text/vtt": "vtt",  // Subtitles
    "application/mp4": "mp4",
    "application/x-mpegurl": "mpg",  // actually .m3u8 / .m3u HLS stream
    "video/webm": "webm",
    "application/ogg": "ogg",
    "video/msvideo": "avi",
    "video/x-msvideo": "avi",
    "video/x-ms-wmv": "wmv",
    "video/x-ms-wma": "wma",
    "application/x-shockwave-flash": "swf",
    "video/x-flv": "flv",
    "video/x-mng": "mng",
    "video/x-ms-asx": "asx",
    "video/x-ms-asf": "asf",
    "video/matroska": "mkv",
  ]
}

// MARK: - HLS detection

extension PlaylistMimeTypeDetector {
  /// Whether a MIME type denotes an HLS manifest, and therefore has to be
  /// downloaded with `AVAssetDownloadURLSession` rather than `URLSession`.
  ///
  /// Predicate lifted from Brave's `PlaylistManager.download(item:)`, which
  /// inlines the same three substring checks.
  public static func isHLS(mimeType: String) -> Bool {
    let mimeType = mimeType.lowercased()
    return mimeType.contains("x-mpegurl")
      || mimeType.contains("application/vnd.apple.mpegurl")
      || mimeType.contains("mpegurl")
  }

  /// Whether a URL looks like an HLS manifest, used when no MIME type is
  /// available (an offline add, or a server that answers HEAD with nothing).
  public static func isHLS(url: URL) -> Bool {
    ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
  }
}
