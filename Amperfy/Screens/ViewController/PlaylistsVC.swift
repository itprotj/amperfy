//
//  PlaylistsVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import CoreData
import UIKit

// MARK: - PlaylistsDiffableDataSource

class PlaylistsDiffableDataSource: BasicUITableViewDiffableDataSource {
  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    false
  }

  func playlistAt(indexPath: IndexPath) -> Playlist? {
    let objectID = itemIdentifier(for: indexPath)
    guard let objectID,
          let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
    else {
      return nil
    }

    let playlist = Playlist(
      library: appDelegate.storage.main.library,
      managedObject: playlistMO
    )
    return playlist
  }

  // Override to support editing the table view.
  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }

    guard let playlist = playlistAt(indexPath: indexPath)
    else {
      return
    }

    let playlistId = playlist.id
    appDelegate.storage.main.library.deletePlaylist(playlist)
    appDelegate.storage.main.saveContext()

    guard let account = playlist.account else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer
        .syncUpload(playlistIdToDelete: playlistId)
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Upload Deletion", error: error)
    }}
  }
}

// MARK: - PlaylistsVC

class PlaylistsVC: SingleSnapshotFetchedResultsTableViewController<PlaylistMO> {
  override var sceneTitle: String? { "Playlists" }

  private var fetchedResultsController: PlaylistFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var sortType: PlaylistSortType = .name

  init(account: Account) {
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistsDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
        else {
          return UITableViewCell()
        }
        let playlist = Playlist(
          library: self.appDelegate.storage.main.library,
          managedObject: playlistMO
        )
        return self.createCell(tableView, forRowAt: indexPath, playlist: playlist)
      }
    return source
  }

  func playlistAt(indexPath: IndexPath) -> Playlist? {
    (diffableDataSource as? PlaylistsDiffableDataSource)?.playlistAt(indexPath: indexPath)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.playlists)

    optionsButton = UIBarButtonItem.createSortBarButton()

    change(sortType: appDelegate.storage.settings.user.playlistsSortSetting)

    var searchTiles: [String]? = nil
    if account.apiType.asServerApiType == .ampache {
      searchTiles = ["All", "Cached", "User", "Smart"]
    } else if account.apiType.asServerApiType == .subsonic {
      searchTiles = ["All", "Cached"]
    }
    configureSearchController(
      placeholder: "Search in \"Playlists\"",
      scopeButtonTitles: searchTiles
    )
    setNavBarTitle(title: "Playlists")
    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.rowHeight = PlaylistTableCell.rowHeight
    tableView.estimatedRowHeight = PlaylistTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif
    refreshControl?.addTarget(
      self,
      action: #selector(Self.handleRefresh),
      for: UIControl.Event.valueChanged
    )

    containableAtIndexPathCallback = { indexPath in
      self.playlistAt(indexPath: indexPath)
    }
    playContextAtIndexPathCallback = { indexPath in
      guard let entity = self.playlistAt(indexPath: indexPath) else { return nil }
      return PlayContext(containable: entity)
    }
    swipeCallback = { indexPath, completionHandler in
      guard let playlist = self.playlistAt(indexPath: indexPath) else { return }
      Task { @MainActor in
        do {
          try await playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
        }
        completionHandler(SwipeActionContext(containable: playlist))
      }
    }
    snapshotDidChange = {
      self.updateContentUnavailable()
    }
  }

  func updateContentUnavailable() {
    if fetchedResultsController.fetchedObjects?.count ?? 0 == 0 {
      if fetchedResultsController.isSearchActive {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
      } else {
        contentUnavailableConfiguration = emptyContentConfig
      }
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  lazy var emptyContentConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = .playlist
    config.text = "No Playlists"
    config.secondaryText = "Your playlists will appear here."
    return config
  }()

  func change(sortType: PlaylistSortType) {
    self.sortType = sortType
    appDelegate.storage.settings.user.playlistsSortSetting = sortType
    singleFetchedResultsController?.clearResults()
    fetchedResultsController = PlaylistFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: sortType.asSectionIndexType != .none
    )
    fetchedResultsController.fetchResultsController.sectionIndexType = sortType.asSectionIndexType
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()
    tableView.reloadData()
    updateRightBarButtonItems()
    updateContentUnavailable()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    if appDelegate.storage.settings.user.isOfflineMode {
      isEditing = false
    }
    updateRightBarButtonItems()
    updateContentUnavailable()
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer
        .syncDownPlaylistsWithoutSongs()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
    }}
  }

  func updateRightBarButtonItems() {
    var actions = [UIMenu]()
    actions.append(createSortButtonMenu())
    actions.append(createOptionsButtonMenu())
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu(children: actions)
    var barButtons = [UIBarButtonItem]()
    barButtons.append(optionsButton)
    if appDelegate.storage.settings.user.isOnlineMode {
      barButtons.append(editButtonItem)
    }
    navigationItem.rightBarButtonItems = barButtons
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlist: Playlist
  )
    -> UITableViewCell {
    let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(playlist: playlist, rootView: self)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let playlist = playlistAt(indexPath: indexPath) else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
      animated: true
    )
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortByName = UIAction(
      title: "Name",
      image: sortType == .name ? .check : nil,
      handler: { _ in
        self.change(sortType: .name)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByLastTimePlayed = UIAction(
      title: "Last time played",
      image: sortType == .lastPlayed ? .check : nil,
      handler: { _ in
        self.change(sortType: .lastPlayed)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByChangeDate = UIAction(
      title: "Change date",
      image: sortType == .lastChanged ? .check : nil,
      handler: { _ in
        self.change(sortType: .lastChanged)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByDuration = UIAction(
      title: "Duration",
      image: sortType == .duration ? .check : nil,
      handler: { _ in
        self.change(sortType: .duration)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    return UIMenu(
      title: "Sort",
      image: .sort,
      options: [.displayInline],
      children: [sortByName, sortByLastTimePlayed, sortByChangeDate, sortByDuration]
    )
  }

  private func createOptionsButtonMenu() -> UIMenu {
    let fetchAllPlaylists = UIAction(title: "Sync All Playlists", image: .refresh, handler: { _ in
      Task { @MainActor in do {
        let accountObjectId = self.account.managedObject.objectID
        let playlistsIds = try await self.appDelegate.storage.async
          .performAndGet { asyncCompanion in
            let accoundAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
            let playlists = asyncCompanion.library.getPlaylists(for: accoundAsync)
            return playlists.compactMap { $0.managedObject.objectID }
          }
        for moId in playlistsIds {
          let playlistMainMO = self.appDelegate.storage.main.context
            .object(with: moId) as! PlaylistMO
          let playlistMain = Playlist(
            library: self.appDelegate.storage.main.library,
            managedObject: playlistMainMO
          )
          try await playlistMain.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        }
        self.appDelegate.eventLogger.info(
          topic: "Sync All Playlists",
          message: "All playlists have been synced."
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Sync All Playlists", error: error)
      }}
    })
    return UIMenu(
      title: "Options",
      image: .sort,
      options: [.displayInline],
      children: [fetchAllPlaylists]
    )
  }

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
      }
      self.refreshControl?.endRefreshing()
    }
  }

  override func updateSearchResults(for searchController: UISearchController) {
    let searchText = searchController.searchBar.text ?? ""
    let playlistSearchCategory = PlaylistSearchCategory(
      rawValue: searchController.searchBar
        .selectedScopeButtonIndex
    ) ?? PlaylistSearchCategory.defaultValue
    fetchedResultsController.search(
      searchText: searchText,
      playlistSearchCategory: playlistSearchCategory
    )
    tableView.reloadData()
    updateContentUnavailable()
  }
}

// MARK: - Navidrome playlist folders

/// A playlist folder from the Navidrome fork's native API (/api/playlistFolder). Folders belong to
/// the logged-in user; an empty parentId means the folder is at the top level.
struct NavidromePlaylistFolder: Codable, Hashable {
  let id: String
  let parentId: String
  let name: String
  let sortOrder: Int

  private enum CodingKeys: String, CodingKey {
    case id, parentId, name, sortOrder
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    parentId = try container.decodeIfPresent(String.self, forKey: .parentId) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
  }
}

/// Which folder a playlist is filed in. Playlists without an item are at the top level.
struct NavidromePlaylistFolderItem: Codable, Hashable {
  let playlistId: String
  let folderId: String
  let sortOrder: Int

  private enum CodingKeys: String, CodingKey {
    case playlistId, folderId, sortOrder
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    playlistId = try container.decode(String.self, forKey: .playlistId)
    folderId = try container.decodeIfPresent(String.self, forKey: .folderId) ?? ""
    sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
  }
}

struct NavidromeFolderTree: Codable {
  var folders: [NavidromePlaylistFolder]
  var items: [NavidromePlaylistFolderItem]

  static let empty = NavidromeFolderTree(folders: [], items: [])

  func childFolders(of parentId: String) -> [NavidromePlaylistFolder] {
    folders
      .filter { $0.parentId == parentId }
      .sorted {
        $0.sortOrder != $1.sortOrder
          ? $0.sortOrder < $1.sortOrder
          : $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
  }

  /// Every playlist id filed in a folder or any folder inside it
  func playlistIds(inTreeOf folderId: String) -> [String] {
    var ids = items.filter { $0.folderId == folderId }.map(\.playlistId)
    for child in childFolders(of: folderId) {
      ids.append(contentsOf: playlistIds(inTreeOf: child.id))
    }
    return ids
  }

  func countPlaylists(inTreeOf folderId: String) -> Int {
    playlistIds(inTreeOf: folderId).count
  }
}

enum NavidromeFolderError: LocalizedError {
  case noCredentials
  case badResponse(Int)

  var errorDescription: String? {
    switch self {
    case .noCredentials: return "No login details for this server."
    case let .badResponse(status): return "Navidrome answered \(status)."
    }
  }
}

/// Reads the folder tree from Navidrome's native API and keeps a copy on the device, so folders
/// still show when offline.
@MainActor
final class NavidromeFolderService {
  static let shared = NavidromeFolderService()

  private var tokens = [String: String]()

  private var appDelegate: AppDelegate {
    (UIApplication.shared.delegate as! AppDelegate)
  }

  private func cacheURL(for account: Account) -> URL? {
    guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first else { return nil }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("navidrome-playlist-folders-\(account.info.ident).json")
  }

  func cachedTree(for account: Account) -> NavidromeFolderTree? {
    guard let url = cacheURL(for: account),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(NavidromeFolderTree.self, from: data)
  }

  func refreshTree(for account: Account) async throws -> NavidromeFolderTree {
    guard let credentials = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .loginCredentials else { throw NavidromeFolderError.noCredentials }

    let folders: [NavidromePlaylistFolder] = try await get(
      "api/playlistFolder", account: account, credentials: credentials
    )
    let items: [NavidromePlaylistFolderItem] = try await get(
      "api/playlistFolder/items", account: account, credentials: credentials
    )
    let tree = NavidromeFolderTree(folders: folders, items: items)
    if let url = cacheURL(for: account), let data = try? JSONEncoder().encode(tree) {
      try? data.write(to: url, options: .atomic)
    }
    return tree
  }

  private func baseURL(_ credentials: LoginCredentials) -> String {
    var base = credentials.activeBackendServerUrl.isEmpty
      ? credentials.serverUrl
      : credentials.activeBackendServerUrl
    while base.hasSuffix("/") { base.removeLast() }
    return base
  }

  private func login(account: Account, credentials: LoginCredentials) async throws -> String {
    guard let url = URL(string: "\(baseURL(credentials))/auth/login") else {
      throw NavidromeFolderError.noCredentials
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    credentials.httpHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "username": credentials.username,
      "password": credentials.password,
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["token"] as? String
    else { throw NavidromeFolderError.badResponse(status) }
    tokens[account.info.ident] = token
    return token
  }

  private func get<T: Decodable>(
    _ path: String,
    account: Account,
    credentials: LoginCredentials
  ) async throws -> T {
    let data = try await send(path, method: "GET", body: nil, account: account, credentials: credentials)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func send(
    _ path: String,
    method: String,
    body: Data?,
    account: Account,
    credentials: LoginCredentials,
    isRetry: Bool = false
  ) async throws -> Data {
    let token: String
    if let cached = tokens[account.info.ident] {
      token = cached
    } else {
      token = try await login(account: account, credentials: credentials)
    }
    guard let url = URL(string: "\(baseURL(credentials))/\(path)") else {
      throw NavidromeFolderError.noCredentials
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    credentials.httpHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401, !isRetry {
      // The token expired: log in again once
      tokens[account.info.ident] = nil
      return try await send(
        path, method: method, body: body, account: account, credentials: credentials, isRetry: true
      )
    }
    guard status == 200 else { throw NavidromeFolderError.badResponse(status) }
    return data
  }

  // MARK: Tick boxes (set in Feishin; unticked songs are left out of offline saves)

  private struct UncheckedSongsResponse: Decodable {
    let unchecked: [String]
  }

  /// Fetches which songs are unticked, keeping the saved list if the server can't be reached
  func refreshUncheckedSongs(for account: Account) async {
    guard let credentials = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .loginCredentials else { return }
    do {
      let response: UncheckedSongsResponse = try await get(
        "api/songCheck", account: account, credentials: credentials
      )
      UncheckedSongs.shared.replaceAll(response.unchecked)
    } catch {
      // Offline, or a Navidrome without tick boxes: keep what's saved
    }
  }

  /// Ticks or unticks songs on the server
  func setSongs(_ songIds: [String], checked: Bool, account: Account) async throws {
    guard let credentials = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .loginCredentials else { throw NavidromeFolderError.noCredentials }
    let body = try JSONSerialization.data(withJSONObject: ["ids": songIds, "checked": checked])
    _ = try await send(
      "api/songCheck", method: "PUT", body: body, account: account, credentials: credentials
    )
  }
}

// MARK: - PlaylistFoldersVC

/// The Playlists screen as a folder tree, like iTunes: the folders at this level, then the
/// playlists filed here. The top level also shows every playlist that isn't in a folder.
final class PlaylistFoldersVC: UITableViewController {
  private let account: Account
  private let folderId: String
  private let folderName: String
  private var tree = NavidromeFolderTree.empty
  private var childFolders = [NavidromePlaylistFolder]()
  private var playlists = [Playlist]()

  private var isRoot: Bool { folderId.isEmpty }

  private static let folderCellId = "PlaylistFolderCell"

  init(account: Account, folderId: String = "", folderName: String = "Playlists") {
    self.account = account
    self.folderId = folderId
    self.folderName = folderName
    super.init(style: .grouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = folderName
    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.folderCellId)
    tableView.backgroundColor = .backgroundColor
    tableView.sectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
      refreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    #endif

    var buttons = [UIBarButtonItem]()
    if isRoot {
      // The original list, with search and sorting, for every playlist
      buttons.append(UIBarButtonItem(
        image: UIImage(systemName: "list.bullet"),
        primaryAction: UIAction { [weak self] _ in
          guard let self else { return }
          self.navigationController?.pushViewController(
            PlaylistsVC(account: self.account),
            animated: true
          )
        }
      ))
    } else {
      buttons.append(UIBarButtonItem(
        image: UIImage(systemName: "arrow.down.circle"),
        primaryAction: UIAction { [weak self] _ in
          guard let self else { return }
          self.download(folderId: self.folderId, name: self.folderName)
        }
      ))
    }
    navigationItem.rightBarButtonItems = buttons

    tree = NavidromeFolderService.shared.cachedTree(for: account) ?? .empty
    rebuild()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = isRoot
    rebuild()
    refresh()
  }

  @objc
  private func handleRefresh() {
    refresh()
  }

  private func refresh() {
    guard appDelegate.storage.settings.user.isOnlineMode else {
      refreshControl?.endRefreshing()
      return
    }
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
      }
      do {
        self.tree = try await NavidromeFolderService.shared.refreshTree(for: self.account)
        await NavidromeFolderService.shared.refreshUncheckedSongs(for: self.account)
      } catch {
        // Keep showing the saved folders (or a flat list) when Navidrome can't be reached
      }
      self.rebuild()
      self.refreshControl?.endRefreshing()
    }
  }

  private func rebuild() {
    let library = appDelegate.storage.main.library
    childFolders = tree.childFolders(of: folderId)

    if isRoot {
      let filed = Set(tree.items.map(\.playlistId))
      playlists = library.getPlaylists(for: account)
        .filter { !filed.contains($0.id) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    } else {
      playlists = tree.items
        .filter { $0.folderId == folderId }
        .sorted {
          $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.playlistId < $1.playlistId
        }
        .compactMap { library.getPlaylist(for: account, id: $0.playlistId) }
    }
    tableView.reloadData()

    if childFolders.isEmpty, playlists.isEmpty {
      var config = UIContentUnavailableConfiguration.empty()
      config.image = isRoot ? .playlist : .folder
      config.text = isRoot ? "No Playlists" : "Empty Folder"
      contentUnavailableConfiguration = config
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  /// Downloads every song in every playlist in a folder (and the folders inside it)
  private func download(folderId: String, name: String) {
    let ids = tree.playlistIds(inTreeOf: folderId)
    guard !ids.isEmpty else { return }
    let meta = appDelegate.getMeta(account.info)
    Task { @MainActor in
      // Make sure the latest ticks from Feishin are used: unticked songs aren't downloaded
      await NavidromeFolderService.shared.refreshUncheckedSongs(for: self.account)
      do {
        for id in ids {
          guard let playlist = self.appDelegate.storage.main.library
            .getPlaylist(for: self.account, id: id) else { continue }
          try await playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: meta.librarySyncer,
            playableDownloadManager: meta.playableDownloadManager
          )
          meta.playableDownloadManager.download(objects: playlist.playables)
        }
        self.appDelegate.eventLogger.info(
          topic: "Download Folder",
          message: "Downloading the songs in \"\(name)\"."
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Download Folder", error: error)
      }
    }
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? childFolders.count : playlists.count
  }

  override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    indexPath.section == 0 ? 52.0 : PlaylistTableCell.rowHeight
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    if indexPath.section == 0 {
      let folder = childFolders[indexPath.row]
      let cell = tableView.dequeueReusableCell(withIdentifier: Self.folderCellId, for: indexPath)
      var content = UIListContentConfiguration.subtitleCell()
      content.image = UIImage(systemName: "folder.fill")
      content.imageProperties.tintColor = .secondaryLabel
      content.text = folder.name
      let count = tree.countPlaylists(inTreeOf: folder.id)
      content.secondaryText = count == 1 ? "1 playlist" : "\(count) playlists"
      content.secondaryTextProperties.color = .secondaryLabel
      cell.contentConfiguration = content
      cell.accessoryType = .disclosureIndicator
      cell.backgroundColor = .clear
      return cell
    }
    let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(playlist: playlists[indexPath.row], rootView: self)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      let folder = childFolders[indexPath.row]
      navigationController?.pushViewController(
        PlaylistFoldersVC(account: account, folderId: folder.id, folderName: folder.name),
        animated: true
      )
    } else {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(
          account: account,
          playlist: playlists[indexPath.row]
        ),
        animated: true
      )
    }
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    guard indexPath.section == 0 else { return nil }
    let folder = childFolders[indexPath.row]
    let action = UIContextualAction(style: .normal, title: "Download") { [weak self] _, _, done in
      self?.download(folderId: folder.id, name: folder.name)
      done(true)
    }
    action.image = UIImage(systemName: "arrow.down.circle")
    action.backgroundColor = .systemBlue
    return UISwipeActionsConfiguration(actions: [action])
  }
}
