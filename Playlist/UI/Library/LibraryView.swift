// Copyright 2026 The Playlist Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import SwiftUI

/// The library: everything saved, searchable and sortable.
struct LibraryView: View {
  @StateObject private var viewModel = LibraryViewModel()
  @EnvironmentObject private var playback: PlaybackController

  /// Set when a `playlist://add?url=…` link opened the app, so the add sheet
  /// comes up already pointed at that address.
  @Binding var incomingURL: String?

  /// Set when a Shortcut asked for a particular playlist to be shown.
  @Binding var incomingFolderUUID: String?

  @State private var isShowingAddSheet = false
  @State private var pendingInitialURL: String?
  @State private var isShowingNewFolderAlert = false
  @State private var newFolderName = ""
  @State private var renamingItem: PlaylistInfo?
  @State private var renameText = ""
  @State private var movingItem: PlaylistInfo?
  @State private var segmentingFolder: PlaylistFolder?

  var body: some View {
    NavigationStack {
      Group {
        if showsFullScreenEmptyState {
          emptyState
        } else {
          list
        }
      }
      .navigationTitle(viewModel.selectedFolder?.title ?? "Library")
      .searchable(
        text: $viewModel.searchText,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Search library")
      .toolbar { toolbarContent }
      .sheet(isPresented: $isShowingAddSheet) {
        AddMediaView(
          initialURL: pendingInitialURL,
          // Adding from inside a playlist files into that playlist. Anything
          // else means the item is saved, the user goes looking for it in the
          // playlist they were in, and it is not there.
          destinationFolderUUID: viewModel.selectedFolder?.uuid,
          destinationFolderTitle: viewModel.selectedFolder?.title
        ) { viewModel.reload() }
          .environmentObject(playback)
          .onDisappear { pendingInitialURL = nil }
      }
      .onChange(of: incomingURL) { _, newValue in
        guard let newValue = newValue, !newValue.isEmpty else { return }
        pendingInitialURL = newValue
        isShowingAddSheet = true
        incomingURL = nil
      }
      .onChange(of: incomingFolderUUID) { _, newValue in
        guard let newValue = newValue else { return }
        viewModel.selectFolder(uuid: newValue)
        incomingFolderUUID = nil
      }
      .sheet(item: $movingItem) { item in
        MoveToFolderView(item: item, viewModel: viewModel)
      }
      .sheet(item: $segmentingFolder) { folder in
        SegmentSettingsView(folder: folder, viewModel: viewModel)
      }
      .alert("New Playlist", isPresented: $isShowingNewFolderAlert) {
        TextField("Name", text: $newFolderName)
        Button("Cancel", role: .cancel) { newFolderName = "" }
        Button("Create") {
          viewModel.createFolder(named: newFolderName)
          newFolderName = ""
        }
      }
      // NOTE: a real two-way binding, not the `.constant` this derived
      // condition invites. A constant binding leaves the alert with no way to
      // report that it closed, so any dismissal the system performs itself — a
      // backgrounding, a competing presentation — takes the alert off the
      // screen while `renamingItem` still says one is up, and rename is then
      // dead for the rest of the session.
      .alert("Rename", isPresented: isRenaming) {
        TextField("Title", text: $renameText)
        Button("Cancel", role: .cancel) { renamingItem = nil }
        Button("Save") {
          if let item = renamingItem {
            viewModel.rename(item, to: renameText)
          }
          renamingItem = nil
        }
      } message: {
        Text("Give this item a name of your own. The original stays with the source link.")
      }
      .refreshable { viewModel.reload() }
    }
  }

  /// The list's reorder handler, or nil where reordering is meaningless.
  ///
  /// Passing nil is what tells the list a row cannot be picked up at all. The
  /// alternative — always accepting the drag and discarding it — is a row that
  /// lifts, follows the finger, and snaps back to where the sort order says it
  /// belongs, which reads as the app refusing to do something it just showed
  /// you it could.
  private var reorderAction: ((IndexSet, Int) -> Void)? {
    guard viewModel.canReorder else { return nil }
    return { source, destination in
      viewModel.move(from: source, to: destination)
      Haptics.impact(.light)
    }
  }

  private var isRenaming: Binding<Bool> {
    Binding(
      get: { renamingItem != nil },
      set: { if !$0 { renamingItem = nil } })
  }

  // MARK: - List

  private var list: some View {
    List {
      if !viewModel.folders.isEmpty && viewModel.searchText.isEmpty {
        foldersSection
      }

      Section {
        if viewModel.items.isEmpty {
          emptyItemsRow
        }

        ForEach(viewModel.items) { item in
          Button {
            playback.select(item: item, in: viewModel.items)
          } label: {
            MediaRowView(
              item: item,
              downloadState: viewModel.state(for: item),
              downloadProgress: viewModel.progress(for: item),
              isCurrentlyPlaying: playback.currentItem?.tagId == item.tagId,
              isPlaying: playback.isPlaying && playback.currentItem?.tagId == item.tagId)
          }
          .buttonStyle(.plain)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              viewModel.delete(item)
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
          .swipeActions(edge: .leading, allowsFullSwipe: false) {
            downloadSwipeAction(for: item)

            Button {
              playback.playNext([item])
            } label: {
              Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.indigo)
          }
          .contextMenu { contextMenu(for: item) }
          // Rows arrive and leave rather than blinking in and out, which is
          // what makes a delete or a move to another playlist read as the row
          // going somewhere.
          .transition(.opacity.combined(with: .move(edge: .leading)))
        }
        .onDelete { offsets in
          viewModel.delete(at: offsets)
          Haptics.notify(.success)
        }
        // Handed to the list only in the custom order. `onMove` takes an
        // optional, and passing nil is what tells the list a row cannot be
        // picked up at all — so in every other order a long press does nothing
        // rather than lifting a row, dragging it, and dropping it back where it
        // started because the sort put it there.
        .onMove(perform: reorderAction)
      } header: {
        if !viewModel.folders.isEmpty && viewModel.searchText.isEmpty {
          Text(viewModel.selectedFolder == nil ? "All Media" : "In This Playlist")
        }
      } footer: {
        Text(itemCountLabel)
          .contentTransition(.numericText())
      }
    }
    .listStyle(.insetGrouped)
    // Keyed on identity rather than on the values. A `PlaylistInfo` also
    // carries a resume point and a measured duration, both of which are written
    // back as an item plays — and animating the list every time one of those
    // lands would shuffle rows for a change nothing on screen is showing.
    .animation(.contentChange, value: viewModel.items.map(\.tagId))
    .animation(.contentChange, value: viewModel.downloadStates)
  }

  private var foldersSection: some View {
    Section("Playlists") {
      Button {
        select(nil)
      } label: {
        HStack {
          Label("All Media", systemImage: "square.stack")
          Spacer()
          if viewModel.selectedFolder == nil {
            selectedCheckmark
          }
        }
        // Without this the gap between the label and the checkmark isn't
        // hittable, since a plain button only takes taps on drawn content.
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      ForEach(viewModel.folders, id: \.objectID) { folder in
        Button {
          select(folder)
        } label: {
          HStack {
            Label(folder.title, systemImage: "music.note.list")

            if folder.isAnonymous {
              Image(systemName: "eye.slash.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hidden on the Lock Screen")
            }

            if folder.isSegmented, let length = Format.duration(folder.segmentDuration) {
              HStack(spacing: 2) {
                Image(systemName: "timer")
                Text(length)
              }
              .font(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Plays \(length) of each item")
            }

            Spacer()
            Text("\(folder.itemCount)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .contentTransition(.numericText())
            if viewModel.selectedFolder?.objectID == folder.objectID {
              selectedCheckmark
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
          if !folder.isDefaultFolder {
            Button(role: .destructive) {
              viewModel.deleteFolder(folder)
              Haptics.notify(.success)
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
        }
        .contextMenu {
          Button {
            viewModel.setAnonymous(!folder.isAnonymous, for: folder)
            Haptics.selection()
          } label: {
            Label(
              folder.isAnonymous ? "Show on Lock Screen" : "Hide on Lock Screen",
              systemImage: folder.isAnonymous ? "eye" : "eye.slash")
          }

          Button {
            segmentingFolder = folder
          } label: {
            Label("Play in Segments…", systemImage: "timer")
          }

          if !folder.isDefaultFolder {
            Divider()

            Button(role: .destructive) {
              viewModel.deleteFolder(folder)
              Haptics.notify(.success)
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
      }
    }
    .animation(.contentChange, value: viewModel.folders.map(\.objectID))
    .animation(.contentChange, value: viewModel.selectedFolder?.objectID)
  }

  /// The tick beside the playlist being browsed.
  ///
  /// It grows in rather than appearing, so switching playlists reads as the
  /// mark moving between two rows rather than as two separate redraws.
  private var selectedCheckmark: some View {
    Image(systemName: "checkmark")
      .foregroundStyle(.tint)
      .transition(.scale(scale: 0.4).combined(with: .opacity))
  }

  /// Shows a playlist, and remembers it as the one to open next time.
  private func select(_ folder: PlaylistFolder?) {
    guard viewModel.selectedFolder?.objectID != folder?.objectID else { return }

    Haptics.selection()
    withAnimation(.contentChange) {
      viewModel.selectedFolder = folder
    }
  }

  @ViewBuilder
  private func downloadSwipeAction(for item: PlaylistInfo) -> some View {
    switch viewModel.state(for: item) {
    case .downloaded:
      Button {
        viewModel.removeDownload(item)
      } label: {
        Label("Remove Download", systemImage: "arrow.down.circle.dotted")
      }
      .tint(.orange)

    case .inProgress:
      Button {
        viewModel.cancelDownload(item)
      } label: {
        Label("Cancel", systemImage: "stop.circle")
      }
      .tint(.gray)

    case .invalid:
      Button {
        viewModel.download(item)
      } label: {
        Label("Download", systemImage: "arrow.down.circle")
      }
      .tint(.blue)
    }
  }

  @ViewBuilder
  private func contextMenu(for item: PlaylistInfo) -> some View {
    Button {
      playback.select(item: item, in: viewModel.items)
    } label: {
      Label("Play", systemImage: "play.fill")
    }

    Button {
      playback.playNext([item])
    } label: {
      Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
    }

    Button {
      playback.addToQueue([item])
    } label: {
      Label("Add to Queue", systemImage: "text.append")
    }

    Divider()

    switch viewModel.state(for: item) {
    case .downloaded:
      Button {
        viewModel.removeDownload(item)
      } label: {
        Label("Remove Download", systemImage: "arrow.down.circle.dotted")
      }
    case .inProgress:
      Button {
        viewModel.cancelDownload(item)
      } label: {
        Label("Cancel Download", systemImage: "stop.circle")
      }
    case .invalid:
      Button {
        viewModel.download(item)
      } label: {
        Label("Download", systemImage: "arrow.down.circle")
      }
    }

    Button {
      renameText = item.name
      renamingItem = item
    } label: {
      Label("Rename", systemImage: "pencil")
    }

    Button {
      movingItem = item
    } label: {
      Label("Move to Playlist", systemImage: "folder")
    }

    if let url = URL(string: item.pageSrc) {
      ShareLink(item: url) {
        Label("Share Source Link", systemImage: "square.and.arrow.up")
      }
    }

    Divider()

    Button(role: .destructive) {
      viewModel.delete(item)
    } label: {
      Label("Delete", systemImage: "trash")
    }
  }

  private var itemCountLabel: String {
    let count = viewModel.items.count
    let downloaded = viewModel.items.filter { viewModel.state(for: $0) == .downloaded }.count
    let itemWord = count == 1 ? "item" : "items"
    return "\(count) \(itemWord) · \(downloaded) downloaded"
  }

  // MARK: - Empty state

  /// Whether to replace the whole screen with the empty state.
  ///
  /// It replaces the list, and the list is where the playlist switcher lives —
  /// so showing it whenever the visible items run out strands the user on a
  /// screen with no way back to the rest of the library. That is exactly what
  /// happened after moving the last item out of a playlist and then opening it.
  /// It is only the right answer when there is nowhere else to go: a search
  /// that matched nothing (where the switcher is hidden anyway, and clearing
  /// the search brings it back), or an empty library whose only playlist is the
  /// default one.
  private var showsFullScreenEmptyState: Bool {
    guard viewModel.items.isEmpty else { return false }
    guard viewModel.searchText.isEmpty else { return true }
    return viewModel.selectedFolder == nil && viewModel.folders.count <= 1
  }

  /// Stands in for the items when there are none, keeping the list — and with
  /// it the playlist switcher — on screen.
  private var emptyItemsRow: some View {
    VStack(spacing: 6) {
      Text(viewModel.selectedFolder == nil ? "Nothing Saved Yet" : "Nothing in This Playlist")
        .font(.subheadline.weight(.medium))
      Text(
        viewModel.selectedFolder == nil
          ? "Paste a video or audio link to save it for offline playback."
          : "Move items here, or pick another playlist above."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .listRowBackground(Color.clear)
    .accessibilityElement(children: .combine)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(
        viewModel.searchText.isEmpty ? "Nothing Saved Yet" : "No Matches",
        systemImage: viewModel.searchText.isEmpty ? "music.note.list" : "magnifyingglass")
    } description: {
      Text(
        viewModel.searchText.isEmpty
          ? "Paste a video or audio link to save it for offline playback."
          : "No items match “\(viewModel.searchText)”.")
    } actions: {
      if viewModel.searchText.isEmpty {
        Button {
          isShowingAddSheet = true
        } label: {
          Label("Add Media", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button {
        isShowingAddSheet = true
      } label: {
        Image(systemName: "plus")
      }
      .accessibilityLabel("Add media")
    }

    ToolbarItem(placement: .topBarLeading) {
      Menu {
        Picker("Sort", selection: $viewModel.sortOrder) {
          ForEach(LibrarySortOrder.allCases) { order in
            Text(order.displayName).tag(order)
          }
        }

        Divider()

        Button {
          isShowingNewFolderAlert = true
        } label: {
          Label("New Playlist", systemImage: "folder.badge.plus")
        }

        if let first = viewModel.items.first {
          Button {
            Haptics.impact(.light)
            playback.play(item: first, in: viewModel.items)
          } label: {
            Label("Play All", systemImage: "play.fill")
          }

          Button {
            guard let start = viewModel.items.randomElement() else { return }
            Haptics.impact(.light)
            playback.setShuffle(true)
            playback.play(item: start, in: viewModel.items)
          } label: {
            Label("Shuffle All", systemImage: "shuffle")
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("Library options")
    }
  }
}

// MARK: - Move to folder

/// Picks a destination playlist for an item.
private struct MoveToFolderView: View {
  let item: PlaylistInfo
  @ObservedObject var viewModel: LibraryViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(viewModel.folders, id: \.objectID) { folder in
          Button {
            viewModel.move(item, toFolder: folder)
            dismiss()
          } label: {
            Label(folder.title, systemImage: "music.note.list")
          }
        }
      }
      .navigationTitle("Move to Playlist")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium])
  }
}
