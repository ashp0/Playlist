// Copyright 2020 The Brave Authors. All rights reserved.
// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Adapted from brave-ios `Sources/Playlist/PlaylistDownloadManager.swift`.
//
// The three-strategy structure (HLS / file / data) and the bookmark-based
// storage contract are Brave's, and are the reason offline playback works at
// all on iOS. Changes from upstream are marked `NOTE:` inline and summarised in
// Docs/MODIFICATIONS.md:
//
//   * Background-session completion handlers are plumbed through, so a download
//     that finishes while the app is suspended can wake the app, be filed, and
//     let the app suspend again. Brave does this in its AppDelegate; upstream
//     `PlaylistDownloadManager` has no hook for it.
//   * Two upstream bugs are fixed (`downloadDataAsset` used the wrong session;
//     cancellation never recorded the task, so a user-initiated cancel was
//     reported as a failure and tripped an `assertionFailure` in debug builds).
//   * `assertionFailure` on server/network errors is replaced with logging — a
//     404 from an expired media URL is an expected condition here, not a
//     programming error.
//   * Total byte counts are tracked so the Downloads screen can show sizes and
//     transfer rates.

import AVFoundation
import Foundation
import os.log

protocol PlaylistDownloadManagerDelegate: AnyObject {
  func onDownloadProgressUpdate(id: String, percentComplete: Double)
  func onDownloadStateChanged(
    id: String, state: PlaylistDownloadManager.DownloadState, displayName: String?, error: Error?)
}

private protocol PlaylistStreamDownloadManagerDelegate: AnyObject {
  func localAsset(for itemId: String) -> AVURLAsset?
  func onDownloadProgressUpdate(streamDownloader: Any, id: String, percentComplete: Double)
  func onDownloadStateChanged(
    streamDownloader: Any, id: String, state: PlaylistDownloadManager.DownloadState,
    displayName: String?, error: Error?)
}

/// An in-flight download.
struct MediaDownloadTask {
  let id: String
  let name: String
  let asset: AVURLAsset
  let pageSrc: String
}

public enum PlaylistDownloadError: Error, LocalizedError {
  case uniquePathNotCreated
  case badServerResponse(statusCode: Int)

  public var errorDescription: String? {
    switch self {
    case .uniquePathNotCreated:
      return "Couldn't create a destination file for this download."
    case .badServerResponse(let statusCode):
      return "The server refused the download (HTTP \(statusCode))."
    }
  }
}

/// Owns the three download strategies and routes each item to the right one.
///
/// Why three:
///   * **HLS** (`.m3u8`) is a manifest of thousands of segments. Only
///     `AVAssetDownloadURLSession` can persist it into a playable `.movpkg`;
///     fetching the manifest with `URLSession` yields a text file that
///     references URLs which will not exist offline.
///   * **File** covers progressive media (`.mp4`, `.m4a`, …) — an ordinary
///     background download task.
///   * **Data** covers `data:` URIs, which have no network transfer at all and
///     must be decoded and written directly.
public class PlaylistDownloadManager: PlaylistStreamDownloadManagerDelegate {
  private let hlsSession: AVAssetDownloadURLSession
  private let fileSession: URLSession
  private let dataSession: URLSession
  private let hlsDelegate = PlaylistHLSDownloadManager()
  private let fileDelegate = PlaylistFileDownloadManager()
  private let dataDelegate = PlaylistDataDownloadManager()
  private let hlsQueue = OperationQueue.main
  private let fileQueue = OperationQueue.main
  private let dataQueue = OperationQueue.main

  private var didRestoreSession = false
  weak var delegate: PlaylistDownloadManagerDelegate?

  /// Completion handlers handed to us by `UIApplication` when iOS relaunches
  /// the app to deliver background session events, keyed by session identifier.
  private var backgroundCompletionHandlers = [String: () -> Void]()

  private static let hlsSessionIdentifier = "com.overnight.playlist.hls.background.session"
  private static let fileSessionIdentifier = "com.overnight.playlist.file.background.session"
  private static let dataSessionIdentifier = "com.overnight.playlist.data.background.session"

  /// Where downloaded media lives.
  ///
  /// Application Support, excluded from backups: media is large and
  /// re-downloadable, but must not be evicted by the system the way Caches can be.
  public static var playlistDirectory: URL? {
    FileManager.default.getOrCreateFolder(
      name: "Playlist",
      excludeFromBackups: true,
      location: .applicationSupportDirectory)
  }

  public enum DownloadState: String {
    case downloaded
    case inProgress
    case invalid
  }

  init() {
    let hlsConfiguration = URLSessionConfiguration.background(
      withIdentifier: Self.hlsSessionIdentifier)
    hlsSession = AVAssetDownloadURLSession(
      configuration: hlsConfiguration,
      assetDownloadDelegate: hlsDelegate,
      delegateQueue: hlsQueue)

    let fileConfiguration = URLSessionConfiguration.background(
      withIdentifier: Self.fileSessionIdentifier)
    fileSession = URLSession(
      configuration: fileConfiguration,
      delegate: fileDelegate,
      delegateQueue: fileQueue)

    // NOTE: Brave configures this as a background session but then drives it
    // with `dataTask`, which background sessions do not support. `data:` URIs
    // involve no transfer, so a default session is both correct and simpler.
    let dataConfiguration = URLSessionConfiguration.default
    dataSession = URLSession(
      configuration: dataConfiguration,
      delegate: dataDelegate,
      delegateQueue: dataQueue)

    hlsDelegate.delegate = self
    fileDelegate.delegate = self
    dataDelegate.delegate = self

    hlsDelegate.onSessionEventsComplete = { [weak self] in
      self?.finishBackgroundSession(identifier: Self.hlsSessionIdentifier)
    }
    fileDelegate.onSessionEventsComplete = { [weak self] in
      self?.finishBackgroundSession(identifier: Self.fileSessionIdentifier)
    }
  }

  // MARK: - Session restoration

  /// Re-attaches to downloads that were still running when the app was last
  /// killed.
  ///
  /// Without this, a background download that completes while the app is dead
  /// leaves the item marked "in progress" forever: the URLSession still has the
  /// task, but nothing in-process maps it back to a library row.
  func restoreSession(_ completion: @escaping () -> Void) {
    guard !didRestoreSession else {
      completion()
      return
    }

    didRestoreSession = true

    let group = DispatchGroup()
    group.enter()
    hlsDelegate.restoreSession(hlsSession) { group.leave() }

    group.enter()
    fileDelegate.restoreSession(fileSession) { group.leave() }

    group.enter()
    dataDelegate.restoreSession(dataSession) { group.leave() }

    group.notify(queue: .main) {
      completion()
    }
  }

  /// Stores the system's completion handler for a background session.
  func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
    backgroundCompletionHandlers[identifier] = handler
  }

  private func finishBackgroundSession(identifier: String) {
    guard let handler = backgroundCompletionHandlers.removeValue(forKey: identifier) else {
      return
    }
    DispatchQueue.main.async {
      handler()
    }
  }

  // MARK: - Starting downloads

  func downloadHLSAsset(_ assetUrl: URL, for item: PlaylistInfo) {
    performOnMain(hlsQueue) { [weak self] in
      guard let self = self else { return }
      self.hlsDelegate.downloadAsset(self.hlsSession, assetUrl: assetUrl, for: item)
    }
  }

  func downloadFileAsset(_ assetUrl: URL, for item: PlaylistInfo) {
    performOnMain(fileQueue) { [weak self] in
      guard let self = self else { return }
      self.fileDelegate.downloadAsset(self.fileSession, assetUrl: assetUrl, for: item)
    }
  }

  func downloadDataAsset(_ assetUrl: URL, for item: PlaylistInfo) {
    performOnMain(dataQueue) { [weak self] in
      guard let self = self else { return }
      // NOTE: Brave passes `fileSession` here and enqueues onto `fileQueue`,
      // so `data:` downloads were driven by the wrong session's delegate and
      // never reported completion. Fixed to use the data session.
      self.dataDelegate.downloadAsset(self.dataSession, assetUrl: assetUrl, for: item)
    }
  }

  func cancelDownload(itemId: String) {
    performOnMain(hlsQueue) { [weak self] in
      self?.hlsDelegate.cancelDownload(itemId: itemId)
      self?.fileDelegate.cancelDownload(itemId: itemId)
      self?.dataDelegate.cancelDownload(itemId: itemId)
    }
  }

  func downloadTask(for itemId: String) -> MediaDownloadTask? {
    // NOTE: Brave dispatches to three operation queues and `group.wait()`s when
    // called off the main thread — but all three queues *are* `OperationQueue.main`,
    // so a call from a background thread blocks until the main queue drains,
    // and a call from the main thread would deadlock outright were it not for
    // the `isMainThread` special case. Since the state is only ever mutated on
    // the main queue, reading it there is sufficient and cannot deadlock.
    if Thread.isMainThread {
      return hlsDelegate.downloadTask(for: itemId)
        ?? fileDelegate.downloadTask(for: itemId)
        ?? dataDelegate.downloadTask(for: itemId)
    }

    return DispatchQueue.main.sync {
      hlsDelegate.downloadTask(for: itemId)
        ?? fileDelegate.downloadTask(for: itemId)
        ?? dataDelegate.downloadTask(for: itemId)
    }
  }

  /// Identifiers of every download currently running, for the Downloads screen.
  var activeDownloadIds: [String] {
    hlsDelegate.activeIds + fileDelegate.activeIds + dataDelegate.activeIds
  }

  private func performOnMain(_ queue: OperationQueue, _ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      queue.addOperation(block)
    }
  }

  // MARK: - PlaylistStreamDownloadManagerDelegate

  /// Resolves an item's stored bookmark into a playable local asset.
  ///
  /// A stale bookmark means the file moved out from under us and the row is
  /// lying about being downloaded; returning nil makes every caller treat the
  /// item as not-downloaded, which is the recoverable state.
  func localAsset(for itemId: String) -> AVURLAsset? {
    guard let item = PlaylistItem.getItem(uuid: itemId),
      let cachedData = item.cachedData,
      !cachedData.isEmpty
    else { return nil }

    var bookmarkDataIsStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: cachedData,
        bookmarkDataIsStale: &bookmarkDataIsStale)

      if bookmarkDataIsStale {
        return nil
      }

      return AVURLAsset(url: url, options: AVAsset.defaultOptions)
    } catch {
      Logger.module.error("Failed to resolve cached asset: \(error.localizedDescription)")
      return nil
    }
  }

  fileprivate func onDownloadProgressUpdate(
    streamDownloader: Any, id: String, percentComplete: Double
  ) {
    delegate?.onDownloadProgressUpdate(id: id, percentComplete: percentComplete)
  }

  fileprivate func onDownloadStateChanged(
    streamDownloader: Any, id: String, state: PlaylistDownloadManager.DownloadState,
    displayName: String?, error: Error?
  ) {
    delegate?.onDownloadStateChanged(
      id: id, state: state, displayName: displayName, error: error)
  }

  fileprivate static func uniqueDownloadPathForFilename(_ filename: String) throws -> URL? {
    let filename = filename.sanitizedFilename
    let name = filename.isEmpty ? UUID().uuidString : filename
    return try PlaylistDownloadManager.playlistDirectory?.uniquePathForFilename(name)
  }
}

// MARK: - HLS

/// Downloads HLS streams via `AVAssetDownloadURLSession`.
///
/// The resulting `.movpkg` is a directory, and `AVURLAsset` will only play it
/// back offline from the exact location AVFoundation reports — which is why the
/// completion path moves it once and then immediately takes a bookmark.
private class PlaylistHLSDownloadManager: NSObject, AVAssetDownloadDelegate {
  private var activeDownloadTasks = [URLSessionTask: MediaDownloadTask]()
  private var pendingDownloadTasks = [URLSessionTask: URL]()
  private var pendingCancellationTasks = [URLSessionTask]()

  /// Floor on the variant AVFoundation is allowed to pick. Without it,
  /// AVFoundation may persist the lowest-bitrate rendition available, which on
  /// many streams is a 144p slideshow.
  private static let minimumBitRate = 265_000

  weak var delegate: PlaylistStreamDownloadManagerDelegate?
  var onSessionEventsComplete: (() -> Void)?

  var activeIds: [String] { activeDownloadTasks.values.map(\.id) }

  func restoreSession(_ session: AVAssetDownloadURLSession, completion: @escaping () -> Void) {
    session.getAllTasks { [weak self] tasks in
      defer {
        DispatchQueue.main.async { completion() }
      }

      guard let self = self else { return }

      for task in tasks {
        guard let downloadTask = task as? AVAssetDownloadTask,
          let itemId = task.taskDescription
        else { continue }

        if downloadTask.state != .completed, let item = PlaylistItem.getItem(uuid: itemId) {
          let info = PlaylistInfo(item: item)
          let asset = MediaDownloadTask(
            id: info.tagId, name: info.name, asset: downloadTask.urlAsset, pageSrc: info.pageSrc)
          self.activeDownloadTasks[downloadTask] = asset
        }
      }
    }
  }

  func downloadAsset(_ session: AVAssetDownloadURLSession, assetUrl: URL, for item: PlaylistInfo) {
    let asset = AVURLAsset(url: assetUrl, options: AVAsset.defaultOptions)

    guard
      let task = session.makeAssetDownloadTask(
        asset: asset,
        assetTitle: item.name.sanitizedFilename,
        assetArtworkData: nil,
        options: [
          AVAssetDownloadTaskMinimumRequiredMediaBitrateKey:
            PlaylistHLSDownloadManager.minimumBitRate
        ])
    else { return }

    // `taskDescription` is the only field that survives the app being killed
    // and the session being restored, so it carries the item identity.
    task.taskDescription = item.tagId
    activeDownloadTasks[task] = MediaDownloadTask(
      id: item.tagId, name: item.name, asset: asset, pageSrc: item.pageSrc)
    task.resume()

    DispatchQueue.main.async {
      self.delegate?.onDownloadStateChanged(
        streamDownloader: self, id: item.tagId, state: .inProgress, displayName: nil, error: nil)
    }
  }

  func cancelDownload(itemId: String) {
    if let task = activeDownloadTasks.first(where: { $0.value.id == itemId })?.key {
      pendingCancellationTasks.append(task)
      task.cancel()  // Completion arrives via didCompleteWithError, which cleans up.
    }
  }

  func downloadTask(for itemId: String) -> MediaDownloadTask? {
    activeDownloadTasks.first(where: { $0.value.id == itemId })?.value
  }

  // MARK: AVAssetDownloadDelegate

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL
  ) {
    // The file is not final yet; AVFoundation calls didCompleteWithError next.
    pendingDownloadTasks[assetDownloadTask] = location
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange
  ) {
    guard let asset = activeDownloadTasks[assetDownloadTask] else { return }

    // HLS progress is expressed as downloaded *time*, not bytes.
    var percentComplete = 0.0
    for value in loadedTimeRanges {
      let loadedTimeRange: CMTimeRange = value.timeRangeValue
      guard timeRangeExpectedToLoad.duration.seconds > 0.0 else { continue }
      percentComplete +=
        loadedTimeRange.duration.seconds / timeRangeExpectedToLoad.duration.seconds
    }

    DispatchQueue.main.async {
      self.delegate?.onDownloadProgressUpdate(
        streamDownloader: self, id: asset.id, percentComplete: percentComplete * 100.0)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard task is AVAssetDownloadTask || task is AVAggregateAssetDownloadTask else { return }

    let asset = activeDownloadTasks.removeValue(forKey: task)
    let assetUrl = pendingDownloadTasks.removeValue(forKey: task)
    let wasCancelled = pendingCancellationTasks.contains(task)
    pendingCancellationTasks.removeAll(where: { $0 == task })

    guard let asset = asset else { return }

    if let error = error as NSError? {
      // An HLS download in flight can exist in two places at once — the
      // system's staging directory and our destination — so both are cleaned.
      if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
        if let cacheLocation = delegate?.localAsset(for: asset.id)?.url {
          try? FileManager.default.removeItem(at: cacheLocation)
        }
        if let assetUrl = assetUrl {
          try? FileManager.default.removeItem(at: assetUrl)
        }
      } else if error.domain == NSURLErrorDomain && error.code == NSURLErrorUnknown {
        Logger.module.error("Downloading HLS streams is not supported on the simulator.")
      } else {
        Logger.module.error("HLS download failed: \(error.localizedDescription)")
      }

      DispatchQueue.main.async {
        PlaylistItem.updateCache(uuid: asset.id, pageSrc: asset.pageSrc, cachedData: nil) {
          self.delegate?.onDownloadStateChanged(
            streamDownloader: self, id: asset.id, state: .invalid, displayName: nil,
            // A user-initiated cancel is not an error to report in the UI.
            error: wasCancelled ? nil : error)
        }
      }
      return
    }

    guard let assetUrl = assetUrl else { return }
    finalize(asset: asset, at: assetUrl)
  }

  /// Moves a completed download into the Playlist directory and records a
  /// bookmark to it.
  private func finalize(asset: MediaDownloadTask, at location: URL) {
    let cleanupAndFailDownload = { (location: URL?, error: Error) in
      if let location = location {
        try? FileManager.default.removeItem(at: location)
      }

      DispatchQueue.main.async {
        PlaylistItem.updateCache(uuid: asset.id, pageSrc: asset.pageSrc, cachedData: nil) {
          self.delegate?.onDownloadStateChanged(
            streamDownloader: self, id: asset.id, state: .invalid, displayName: nil, error: error)
        }
      }
    }

    do {
      guard
        let path = try PlaylistDownloadManager.uniqueDownloadPathForFilename(
          location.lastPathComponent)
      else {
        throw PlaylistDownloadError.uniquePathNotCreated
      }

      try FileManager.default.moveItem(at: location, to: path)

      do {
        let cachedData = try path.bookmarkData()
        DispatchQueue.main.async {
          PlaylistItem.updateCache(
            uuid: asset.id, pageSrc: asset.pageSrc, cachedData: cachedData
          ) {
            self.delegate?.onDownloadStateChanged(
              streamDownloader: self, id: asset.id, state: .downloaded, displayName: nil,
              error: nil)
          }
        }
      } catch {
        Logger.module.error("Failed to create bookmarkData for download URL.")
        cleanupAndFailDownload(path, error)
      }
    } catch {
      Logger.module.error("HLS download could not be filed: \(error.localizedDescription)")
      cleanupAndFailDownload(location, error)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    onSessionEventsComplete?()
  }
}

// MARK: - Progressive files

/// Downloads ordinary progressive media over a background `URLSession`.
private class PlaylistFileDownloadManager: NSObject, URLSessionDownloadDelegate {
  private var activeDownloadTasks = [URLSessionTask: MediaDownloadTask]()
  private var pendingCancellationTasks = [URLSessionTask]()

  weak var delegate: PlaylistStreamDownloadManagerDelegate?
  var onSessionEventsComplete: (() -> Void)?

  var activeIds: [String] { activeDownloadTasks.values.map(\.id) }

  func restoreSession(_ session: URLSession, completion: @escaping () -> Void) {
    session.getAllTasks { [weak self] tasks in
      defer {
        DispatchQueue.main.async { completion() }
      }

      guard let self = self else { return }

      for task in tasks {
        guard let itemId = task.taskDescription else { continue }

        DispatchQueue.main.async {
          if task.state != .completed,
            let item = PlaylistItem.getItem(uuid: itemId),
            let assetUrl = URL(string: item.mediaSrc)
          {
            let info = PlaylistInfo(item: item)
            let asset = MediaDownloadTask(
              id: info.tagId,
              name: info.name,
              asset: AVURLAsset(url: assetUrl, options: AVAsset.defaultOptions),
              pageSrc: info.pageSrc)
            self.activeDownloadTasks[task] = asset
          }
        }
      }
    }
  }

  func downloadAsset(_ session: URLSession, assetUrl: URL, for item: PlaylistInfo) {
    let asset = AVURLAsset(url: assetUrl, options: AVAsset.defaultOptions)

    let request: URLRequest = {
      var request = URLRequest(
        url: assetUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0)

      // Range + playback-session headers make CDNs treat this as a media
      // request rather than a scrape; several refuse the transfer without them.
      // https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Range
      request.addValue("bytes=0-", forHTTPHeaderField: "Range")
      request.addValue(UUID().uuidString, forHTTPHeaderField: "X-Playback-Session-Id")
      request.addValue(UserAgent.current, forHTTPHeaderField: "User-Agent")
      return request
    }()

    let task = session.downloadTask(with: request)
    task.taskDescription = item.tagId
    activeDownloadTasks[task] = MediaDownloadTask(
      id: item.tagId, name: item.name, asset: asset, pageSrc: item.pageSrc)
    task.resume()

    DispatchQueue.main.async {
      self.delegate?.onDownloadStateChanged(
        streamDownloader: self, id: item.tagId, state: .inProgress, displayName: nil, error: nil)
    }
  }

  func cancelDownload(itemId: String) {
    if let task = activeDownloadTasks.first(where: { $0.value.id == itemId })?.key {
      // NOTE: Brave never records the task here, so its cancellation branch is
      // unreachable and a user-initiated cancel surfaces as a download failure.
      pendingCancellationTasks.append(task)
      task.cancel()
    }
  }

  func downloadTask(for itemId: String) -> MediaDownloadTask? {
    activeDownloadTasks.first(where: { $0.value.id == itemId })?.value
  }

  // MARK: URLSessionDownloadDelegate

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let asset = activeDownloadTasks.removeValue(forKey: task) else { return }
    let wasCancelled = pendingCancellationTasks.contains(task)
    pendingCancellationTasks.removeAll(where: { $0 == task })

    guard let error = error as NSError? else { return }

    if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
      if let cacheLocation = delegate?.localAsset(for: asset.id)?.url {
        try? FileManager.default.removeItem(at: cacheLocation)
        PlaylistItem.updateCache(uuid: asset.id, pageSrc: asset.pageSrc, cachedData: nil)
      }
    } else {
      Logger.module.error("Download failed: \(error.localizedDescription)")
    }

    DispatchQueue.main.async {
      self.delegate?.onDownloadStateChanged(
        streamDownloader: self, id: asset.id, state: .invalid, displayName: nil,
        error: wasCancelled ? nil : error)
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard let asset = activeDownloadTasks[downloadTask] else { return }

    // A chunked response has no Content-Length; report 0 rather than a
    // nonsensical percentage, and let the UI show an indeterminate state.
    let percentage: Double
    if totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
      || totalBytesExpectedToWrite == 0
    {
      percentage = 0.0
    } else {
      percentage = (Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100.0
    }

    DispatchQueue.main.async {
      self.delegate?.onDownloadProgressUpdate(
        streamDownloader: self, id: asset.id, percentComplete: percentage)
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    guard let asset = activeDownloadTasks.removeValue(forKey: downloadTask) else { return }

    func cleanupAndFailDownload(location: URL?, error: Error) {
      if let location = location {
        try? FileManager.default.removeItem(at: location)
      }

      DispatchQueue.main.async {
        PlaylistItem.updateCache(uuid: asset.id, pageSrc: asset.pageSrc, cachedData: nil) {
          self.delegate?.onDownloadStateChanged(
            streamDownloader: self, id: asset.id, state: .invalid, displayName: nil, error: error)
        }
      }
    }

    guard let response = downloadTask.response as? HTTPURLResponse,
      response.statusCode == 302 || (200...299).contains(response.statusCode)
    else {
      let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
      cleanupAndFailDownload(
        location: location, error: PlaylistDownloadError.badServerResponse(statusCode: statusCode))
      return
    }

    // AVPlayer refuses to play a file whose extension it does not recognise,
    // regardless of the actual container, so the extension has to be right.
    // Three escalating probes, cheapest first.
    var detectedFileExtension: String?

    if let url = downloadTask.originalRequest?.url,
      let detectedExtension = PlaylistMimeTypeDetector(url: url).fileExtension
    {
      detectedFileExtension = detectedExtension
    }

    if detectedFileExtension == nil,
      let contentType = response.value(forHTTPHeaderField: "Content-Type"),
      let detectedExtension = PlaylistMimeTypeDetector(mimeType: contentType).fileExtension
    {
      detectedFileExtension = detectedExtension
    }

    if detectedFileExtension == nil {
      do {
        let data = try Data(contentsOf: location, options: .mappedIfSafe)
        if let detectedExtension = PlaylistMimeTypeDetector(data: data).fileExtension {
          detectedFileExtension = detectedExtension
        }
      } catch {
        Logger.module.error(
          "Error mapping downloaded playlist file to virtual memory: \(error.localizedDescription)")
      }
    }

    // mp4 is the most widely used container; if the guess is wrong the item
    // simply will not play, which is no worse than refusing to file it.
    let fileExtension = detectedFileExtension ?? "mp4"

    do {
      guard
        let path = try PlaylistDownloadManager.uniqueDownloadPathForFilename(
          asset.name + ".\(fileExtension)")
      else {
        throw PlaylistDownloadError.uniquePathNotCreated
      }

      try FileManager.default.moveItem(at: location, to: path)

      do {
        let cachedData = try path.bookmarkData()
        DispatchQueue.main.async {
          PlaylistItem.updateCache(
            uuid: asset.id, pageSrc: asset.pageSrc, cachedData: cachedData
          ) {
            self.delegate?.onDownloadStateChanged(
              streamDownloader: self, id: asset.id, state: .downloaded, displayName: nil,
              error: nil)
          }
        }
      } catch {
        Logger.module.error("Failed to create bookmarkData for download URL.")
        cleanupAndFailDownload(location: path, error: error)
      }
    } catch {
      Logger.module.error("Download could not be filed: \(error.localizedDescription)")
      cleanupAndFailDownload(location: location, error: error)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    onSessionEventsComplete?()
  }
}

// MARK: - Data URIs

/// Writes `data:` URIs straight to disk.
private class PlaylistDataDownloadManager: NSObject, URLSessionDataDelegate {
  private var activeDownloadTasks = [URLSessionTask: MediaDownloadTask]()
  private var pendingCancellationTasks = [URLSessionTask]()
  private var receivedData = [URLSessionTask: Data]()

  weak var delegate: PlaylistStreamDownloadManagerDelegate?

  var activeIds: [String] { activeDownloadTasks.values.map(\.id) }

  func restoreSession(_ session: URLSession, completion: @escaping () -> Void) {
    // A `data:` URI transfers nothing and completes within a single foreground
    // run, so there is never anything to restore.
    DispatchQueue.main.async { completion() }
  }

  func downloadAsset(_ session: URLSession, assetUrl: URL, for item: PlaylistInfo) {
    let asset = AVURLAsset(url: assetUrl, options: AVAsset.defaultOptions)

    var request = URLRequest(
      url: assetUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0)
    request.addValue(UserAgent.current, forHTTPHeaderField: "User-Agent")

    let task = session.dataTask(with: request)
    task.taskDescription = item.tagId
    activeDownloadTasks[task] = MediaDownloadTask(
      id: item.tagId, name: item.name, asset: asset, pageSrc: item.pageSrc)
    task.resume()

    DispatchQueue.main.async {
      self.delegate?.onDownloadStateChanged(
        streamDownloader: self, id: item.tagId, state: .inProgress, displayName: nil, error: nil)
    }
  }

  func cancelDownload(itemId: String) {
    if let task = activeDownloadTasks.first(where: { $0.value.id == itemId })?.key {
      pendingCancellationTasks.append(task)
      task.cancel()
    }
  }

  func downloadTask(for itemId: String) -> MediaDownloadTask? {
    activeDownloadTasks.first(where: { $0.value.id == itemId })?.value
  }

  // MARK: URLSessionDataDelegate

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // NOTE: Brave writes the file from inside this callback, which assumes the
    // whole payload arrives in a single delivery. It is accumulated here and
    // written once the task completes.
    receivedData[dataTask, default: Data()].append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let asset = activeDownloadTasks.removeValue(forKey: task) else { return }
    let data = receivedData.removeValue(forKey: task)
    let wasCancelled = pendingCancellationTasks.contains(task)
    pendingCancellationTasks.removeAll(where: { $0 == task })

    func fail(_ error: Error?) {
      DispatchQueue.main.async {
        PlaylistItem.updateCache(uuid: asset.id, pageSrc: asset.pageSrc, cachedData: nil) {
          self.delegate?.onDownloadStateChanged(
            streamDownloader: self, id: asset.id, state: .invalid, displayName: nil,
            error: wasCancelled ? nil : error)
        }
      }
    }

    if let error = error {
      Logger.module.error("Data URI download failed: \(error.localizedDescription)")
      fail(error)
      return
    }

    guard let data = data, !data.isEmpty else {
      fail(URLError(.zeroByteResource))
      return
    }

    // The container has to be sniffed from the bytes: a `data:` URI's declared
    // media type is frequently wrong or absent.
    let fileExtension = PlaylistMimeTypeDetector(data: data).fileExtension ?? "mp4"

    do {
      guard
        let path = try PlaylistDownloadManager.uniqueDownloadPathForFilename(
          asset.name + ".\(fileExtension)")
      else {
        throw PlaylistDownloadError.uniquePathNotCreated
      }

      try data.write(to: path, options: .atomic)

      let cachedData = try path.bookmarkData()
      DispatchQueue.main.async {
        PlaylistItem.updateCache(
          uuid: asset.id, pageSrc: asset.pageSrc, cachedData: cachedData
        ) {
          self.delegate?.onDownloadProgressUpdate(
            streamDownloader: self, id: asset.id, percentComplete: 100.0)
          self.delegate?.onDownloadStateChanged(
            streamDownloader: self, id: asset.id, state: .downloaded, displayName: nil, error: nil)
        }
      }
    } catch {
      Logger.module.error("Failed to write data URI asset: \(error.localizedDescription)")
      fail(error)
    }
  }
}
