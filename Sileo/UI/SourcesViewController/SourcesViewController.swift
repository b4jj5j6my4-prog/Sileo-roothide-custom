//
//  SourcesViewController.swift
//  Sileo
//
//  Created by CoolStar on 9/22/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import Evander
import PhotosUI

final class SourcesViewController: SileoViewController {
    private var sortedRepoList: [Repo] = []
    private var displayedSourceGroups: [SileoSourceDisplayGroup] = []
    private let sourceGroupStore = SileoSourceGroupStore()
    private let sourceSearchController = UISearchController(searchResultsController: nil)
    private var selectedSourceKeys = Set<String>()
    var updatingRepoList: [Repo] = []
    
    var presentRepoUrl: URL?
    var defaultPagePresent = false
    var detailedPageUserPresent = false
    
    private var tableView = SileoTableView(frame: .zero, style: .plain)
    public var refreshControl = UIRefreshControl()
    private var inRefreshing = false
    
    static let refreshReposNotification = Notification.Name("SourcesViewController.refreshReposNotification")
    static let reloadDataNotification = Notification.Name("SourcesViewController.reloadDataNotification")
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        RepoManager.shared.checkUpdatesInBackground()
        
        weak var weakSelf: SourcesViewController? = self
        NotificationCenter.default.addObserver(weakSelf as Any,
                                               selector: #selector(self.reloadRepo(_:)),
                                               name: RepoManager.progressNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(forName: SourcesViewController.refreshReposNotification, object: nil, queue: .main) { _ in
            self.refreshSources(forceUpdate: false, forceReload: false, isBackground: true, useRefreshControl: false, useErrorScreen: false, completion: nil)
        }
        
        NotificationCenter.default.addObserver(forName: SourcesViewController.reloadDataNotification, object: nil, queue: .main) { _ in
            self.reloadData()
        }
    }
    
    func canEditRow(indexPath: IndexPath) -> Bool {
        if indexPath.section == 0 {
            return false
        }
        
        guard let repo = sourceRepo(at: indexPath) else { return false }
        if Jailbreak.bootstrap == .procursus {
            return repo.entryFile.hasSuffix("/sileo.sources")
        }
        return repo.url?.host != "apt.bingner.com"
    }
    
    func controller(indexPath: IndexPath) -> CategoryViewController {
        let categoryVC = CategoryViewController(style: .plain)
        categoryVC.title = String(localizationKey: "All_Packages.Title")
        
        if indexPath.section > 0, let repo = sourceRepo(at: indexPath) {
            categoryVC.repoContext = repo
            categoryVC.title = repo.repoName
        }
        
        let touchGestureRecognizer = TouchGestureRecognizer(target: self, action: #selector(detailedPageUserInteracted))
        categoryVC.view.addGestureRecognizer(touchGestureRecognizer)
        
        return categoryVC
    }

    @objc func detailedPageUserInteracted() {
        self.detailedPageUserPresent = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        #if !targetEnvironment(macCatalyst)
        tableView.refreshControl = refreshControl
        #endif
        refreshControl.addTarget(self, action: #selector(refreshSources(_:)), for: .valueChanged)
        
        self.title = String(localizationKey: "Sources_Page")
        tableView.register(SourcesTableViewFooter.self, forHeaderFooterViewReuseIdentifier: "Sileo.SourcesTableViewFooter")
        
        updateSileoColors()
        weak var weakSelf = self
        NotificationCenter.default.addObserver(weakSelf as Any,
                                               selector: #selector(self.updateSileoColors),
                                               name: SileoThemeManager.sileoChangedThemeNotification,
                                               object: nil)
        
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelectionDuringEditing = true
        sourceSearchController.searchResultsUpdater = self
        sourceSearchController.obscuresBackgroundDuringPresentation = false
        sourceSearchController.searchBar.placeholder = "搜索软件源"
        navigationItem.searchController = sourceSearchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        self.tableView.separatorInset = UIEdgeInsets(top: 72, left: 0, bottom: 0, right: 0)
        self.tableView.separatorColor = UIColor(white: 0, alpha: 0.2)
        self.reSortList()
        self.setEditing(false, animated: false)
        
        self.navigationController?.navigationBar.superview?.tag = WHITE_BLUR_TAG
        #if targetEnvironment(macCatalyst)
        let nav = self.navigationItem
        nav.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addSource(_:)))
        nav.leftBarButtonItem = UIBarButtonItem(title: "Refresh", style: .done, target: self, action: #selector(refreshSources(_:)))
        #endif
    
        NotificationCenter.default.addObserver(weakSelf as Any, selector: #selector(handleImageUpdate(_:)), name: SourcesTableViewCell.repoImageUpdate, object: nil)
        
// self.splitViewController?.isCollapsed may not be ready yet
//        presentDefaultPage()
        
        self.splitViewController?.delegate = self
    }

    private func presentDefaultPage() {
        NSLog("SileoLog: presentDefaultPage \(self.splitViewController) \(self.splitViewController?.isCollapsed)")
        if self.splitViewController?.isCollapsed == false {
            let indexPath = IndexPath(row: 0, section: 0)
            tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
            if !defaultPagePresent || presentRepoUrl != nil {
                presentRepoUrl = nil
                defaultPagePresent = true
                detailedPageUserPresent = false
                self.tableViewSelectRowAt(tableView: tableView, indexPath: indexPath)
            }
        }
    }
    
    private func deselectRepos() {
        if self.splitViewController?.isCollapsed ?? false {
            self.detailedPageUserPresent = false
            if let selectedRows = tableView.indexPathsForSelectedRows {
                 for indexPath in selectedRows {
                     tableView.deselectRow(at: indexPath, animated: false)
                 }
             }
        }
    }
    
    override func viewWillLayoutSubviews() {
        NSLog("SileoLog: SourcesViewController.viewWillLayoutSubviews")
        super.viewDidLayoutSubviews()

    }

    override func viewDidLayoutSubviews() {
        NSLog("SileoLog: SourcesViewController.viewDidLayoutSubviews \(self.splitViewController?.isCollapsed) \(self.presentRepoUrl)")
        super.viewDidLayoutSubviews()

        if self.splitViewController?.isCollapsed == false
        {
            if self.presentRepoUrl == nil
            {
                self.presentDefaultPage()
                return
            }

            for section in 1..<tableView.numberOfSections {
                for row in 0..<tableView.numberOfRows(inSection: section) {
                    let indexPath = IndexPath(row: row, section: section)
                    guard let repo = sourceRepo(at: indexPath) else { continue }
                    if repo.url == self.presentRepoUrl {
                        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
                    }
                }
            }
        }
        else
        {
            deselectRepos()
        }
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        NSLog("SileoLog: SourcesViewController.traitCollectionDidChange")
        updateSileoColors()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        NSLog("SileoLog: SourcesViewController.viewWillTransition \(self.splitViewController?.isCollapsed) \(self.presentRepoUrl)")
        super.viewWillTransition(to: size, with: coordinator)
    }
    
    override var keyCommands: [UIKeyCommand]? {
        return [
            UIKeyCommand(input: "r", modifierFlags: .command, action: #selector(refreshSources(_:)), discoverabilityTitle: "Refresh Sources"),
            UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(addSource(_:)), discoverabilityTitle: "Add Source")
        ]
    }
    
    @objc func updateSileoColors() {
        self.tableView.backgroundColor = .sileoBackgroundColor
        self.tableView.separatorColor = .sileoSeparatorColor
        self.statusBarStyle = .default
        view.backgroundColor = .sileoBackgroundColor
    }
    
    override func viewWillAppear(_ animated: Bool) {
        NSLog("SileoLog: SourcesViewController.viewWillAppear")
        super.viewWillAppear(animated)
        updateSileoColors()
        
        if inRefreshing {
            if let refreshControl = tableView.refreshControl {
                refreshControl.endRefreshing()
                DispatchQueue.main.async { //reactive animate
                    refreshControl.beginRefreshing()
                }
            }
        }
        
        deselectRepos()
    }

    override func viewDidAppear(_ animated: Bool) {
        NSLog("SileoLog: SourcesViewController.viewDidAppear \(self.splitViewController?.isCollapsed) \(self.tableView.indexPathsForSelectedRows)")
        super.viewDidAppear(animated)
        self.navigationController?.navigationBar._hidesShadow = true
        self.tableView.backgroundColor = .sileoBackgroundColor
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if inRefreshing {
            if let refreshControl = tableView.refreshControl {
                refreshControl.endRefreshing()
            }
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.navigationController?.navigationBar._hidesShadow = false
    }
    
    @objc func toggleEditing(_ sender: Any?) {
        self.setEditing(!self.isEditing, animated: true)
    }
    
    #if !targetEnvironment(macCatalyst)
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        self.tableView.setEditing(editing, animated: animated)
        
        FRUIView.animate(withDuration: animated ? 0.2 : 0.0) {
            let nav = self.navigationItem
            
            if editing {
                self.sourceSearchController.isActive = false
                self.sourceSearchController.searchBar.text = ""
                self.selectedSourceKeys.removeAll()
                self.rebuildSourceGroups()
                self.tableView.reloadData()
                nav.leftBarButtonItem = UIBarButtonItem(title: String(localizationKey: "Done"), style: .done, target: self, action: #selector(self.toggleEditing(_:)))
                nav.rightBarButtonItem = UIBarButtonItem(title: String(localizationKey: "Export"), style: .plain, target: self, action: #selector(self.exportSources(_:)))
                self.toolbarItems = [
                    UIBarButtonItem(title: "移动", style: .plain, target: self, action: #selector(self.moveSelectedSources)),
                    UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                    UIBarButtonItem(title: "删除", style: .plain, target: self, action: #selector(self.deleteSelectedSources))
                ]
                self.navigationController?.setToolbarHidden(false, animated: animated)
            } else {
                self.navigationController?.setToolbarHidden(true, animated: animated)
                self.rebuildSourceGroups()
                self.tableView.reloadData()
                nav.leftBarButtonItem = UIBarButtonItem(title: "管理", style: .done, target: self, action: #selector(self.showSourceManagementMenu))
                if #available(iOS 14.0, *) {
                    let promptAddRepoAction = UIAction(title: "Add Repo", image: .init(systemName: "plus.circle")) { _ in
                        self.addSource(nil)
                    }
                    
                    let importReposAction = UIAction(title: "Import Repos", image: .init(systemName: "archivebox")) { _ in
                        self.promptImportRepos()
                    }
                    
                    let menu = UIMenu(title: "Add Repos", children: [promptAddRepoAction, importReposAction])
                    nav.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: promptAddRepoAction, menu: menu)
                } else {
                    nav.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(self.addSource(_:)))
                }
            }
            
        }
    }
    #endif
    
    // keep repo list format parsing consistent with upstream
    private func hasCompatibleSourceFormat(_ source: String, suite: String? = nil, components: [String]? = nil) -> Bool {
        let parts = source.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let uri = parts.first, let url = URL(string: uri),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else { return false }
        let parsedSuite = suite ?? (parts.count > 1 ? parts[1] : "./")
        let parsedComponents = components ?? (parts.count > 2 ? Array(parts[2...]) : [])
        guard parsedSuite == "./", parsedComponents.isEmpty else { return false }
        return true
    }

    func importRepos(fromURL url: URL) {
        let _tmpManager = RepoManager()
        
        if url.pathExtension == "list" {
            _tmpManager.parseListFile(at: url, isImporting: true)
        } else if url.pathExtension == "sources" {
            _tmpManager.parseSourcesFile(at: url)
        } else {
            _tmpManager.parsePlainTextFile(at: url)
        }
        
        var newRepos:[Repo] = []
        for repo in _tmpManager.repoList {
            guard hasCompatibleSourceFormat(repo.rawURL, suite: repo.suite, components: repo.components) else { continue }
            if let url = URL(string: repo.rawURL) {
                if let newRepo = RepoManager.shared.addDistRepo(url: url, suites: repo.suite, components: repo.components.joined(separator: " ")) {
                    newRepos.append(newRepo)
                }
            }
        }

        if newRepos.count > 0 {
            self.reloadData()
            self.updateSpecific(newRepos)
        }
    }
    
    @available(iOS 14.0, *)
    private func promptImportRepos() {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        let delegate = SourcesPickerImporterDelegate.shared
        delegate.sourcesVC = self
        controller.delegate = delegate
        self.present(controller, animated: true, completion: nil)
    }
    
    class SourcesPickerImporterDelegate: NSObject, UIDocumentPickerDelegate {
        var sourcesVC: SourcesViewController? = nil
        
        static var shared = SourcesPickerImporterDelegate()
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let firstURL = urls.first else {
                return
            }
            
            sourcesVC?.importRepos(fromURL: firstURL)
        }
    }
     
    @objc private func handleImageUpdate(_ notification: Notification) {
        NSLog("SileoLog: handleImageUpdate \(notification.object)")
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.handleImageUpdate(notification)
            }
            return
        }
        guard let url = notification.object as? String else { return }
        for cell in tableView.loadedCells {
            guard let cell = cell as? SourcesTableViewCell, let repo = cell.repo else { continue }
            if repo.rawURL == url {
                NSLog("SileoLog: cell.image=\(repo.repoIcon)")
                cell.image(repo)
                return
            }
        }
    }
    
    @objc func refreshSources(_ sender: UIRefreshControl?) {
        self.refreshSources(forceUpdate: false, forceReload: true)
    }
    
    func refreshSources(forceUpdate: Bool, forceReload: Bool) {
        self.refreshSources(forceUpdate: forceUpdate, forceReload: forceReload, isBackground: false, useRefreshControl: false, useErrorScreen: true, completion: nil)
    }
    
    private func addToQueue(_ repo: Repo) {
        if !updatingRepoList.contains(where: { $0.rawURL == repo.rawURL }) {
            updatingRepoList.append(repo)
        }
    }
    
    private func removeFromQueue(_ repo: Repo) {
        if let index = updatingRepoList.firstIndex(where: { $0.rawURL == repo.rawURL }) {
            updatingRepoList.remove(at: index)
        }
    }
    
    private func killIndicator() {
        let item = self.splitViewController?.tabBarItem
        item?.badgeValue = ""
        let badge = item?.view()?.value(forKey: "_badge") as? UIView ?? UIView()
        self.refreshControl.endRefreshing()
        self.inRefreshing = false
        let indicators = badge.subviews.filter { $0 is UIActivityIndicatorView }
        for indicator in indicators {
            if let indicator = indicator as? UIActivityIndicatorView {
                indicator.removeFromSuperview()
                indicator.stopAnimating()
            }
        }
        item?.badgeValue = nil
    }
    
    func refreshSources(forceUpdate: Bool, forceReload: Bool, isBackground: Bool, useRefreshControl: Bool, useErrorScreen: Bool, completion: ((Bool, NSAttributedString) -> Void)?) {
        NSLog("SileoLog: refreshSources \(forceUpdate) \(forceReload) \(isBackground) \(useRefreshControl) \(useErrorScreen)")
        let item = self.splitViewController?.tabBarItem
        item?.badgeValue = ""
        guard let style = UIActivityIndicatorView.Style(rawValue: 5) else {
            fatalError("OK iOS...")
        }
        let indicatorView = UIActivityIndicatorView(style: style)
        let badge = item?.view()?.value(forKey: "_badge") as? UIView
        
        if updatingRepoList.isEmpty {
            indicatorView.frame = indicatorView.frame.offsetBy(dx: 2, dy: 2)
            indicatorView.startAnimating()
            badge?.addSubview(indicatorView)
            
            self.inRefreshing = true
            if let refreshControl = tableView.refreshControl, !refreshControl.isRefreshing {
                refreshControl.beginRefreshing()
            }
        }
        
        for repo in sortedRepoList {
            addToQueue(repo)
        }
        RepoManager.shared.update(force: forceUpdate, forceReload: forceReload, isBackground: isBackground, completion: { didFindErrors, errorOutput in
            NSLog("SileoLog: useErrorScreen=\(useErrorScreen) didFindErrors=\(didFindErrors):\(errorOutput)")
            for repo in self.sortedRepoList {
                self.removeFromQueue(repo)
            }
            self.killIndicator()
            
            if didFindErrors, useErrorScreen {
                self.showRefreshErrorViewController(errorOutput: errorOutput, completion: nil)
            }
            
            if let completion = completion {
                completion(didFindErrors, errorOutput)
            }
        })
    }
    
    func updateSingleRepo(_ repo: Repo) {

        let item = self.splitViewController?.tabBarItem
        item?.badgeValue = ""
        
        if updatingRepoList.isEmpty {
            let badge = item?.view()?.value(forKey: "_badge") as? UIView
            guard let style = UIActivityIndicatorView.Style(rawValue: 5) else {
                fatalError("OK iOS...")
            }
            let indicatorView = UIActivityIndicatorView(style: style)
            indicatorView.frame = indicatorView.frame.offsetBy(dx: 2, dy: 2)
            indicatorView.startAnimating()
            badge?.addSubview(indicatorView)
        }
        
        RepoManager.shared.update(force: true, forceReload: true, isBackground: false, repos: [repo], completion: { didFindErrors, errorOutput in
            self.removeFromQueue(repo)
            if self.updatingRepoList.isEmpty {
                self.killIndicator()
            }

            if didFindErrors {
                self.showRefreshErrorViewController(errorOutput: errorOutput, completion: nil)
            }
        })
    }
    
    func updateSpecific(_ repos: [Repo]) {
        let item = self.splitViewController?.tabBarItem
        item?.badgeValue = ""

        if updatingRepoList.isEmpty {
            let badge = item?.view()?.value(forKey: "_badge") as? UIView
            guard let style = UIActivityIndicatorView.Style(rawValue: 5) else {
                fatalError("OK iOS...")
            }
            let indicatorView = UIActivityIndicatorView(style: style)
            indicatorView.frame = indicatorView.frame.offsetBy(dx: 2, dy: 2)
            indicatorView.startAnimating()
            badge?.addSubview(indicatorView)
        }
        
        for repo in repos {
            addToQueue(repo)
        }
        
        RepoManager.shared.update(force: true, forceReload: true, isBackground: false, repos: repos) { [weak self] didFindErrors, errorOutput in
            guard let strongSelf = self else { return }
            for repo in repos {
                strongSelf.removeFromQueue(repo)
            }
            if strongSelf.updatingRepoList.isEmpty {
                strongSelf.killIndicator()
            }
            if didFindErrors {
                strongSelf.showRefreshErrorViewController(errorOutput: errorOutput, completion: nil)
            }
        }
    }
    
    func showRefreshErrorViewController(errorOutput: NSAttributedString, completion: (() -> Void)?) {
        let errorVC = SourcesErrorsViewController(nibName: "SourcesErrorsViewController", bundle: nil)
        errorVC.attributedString = errorOutput
        let navController = UINavigationController(rootViewController: errorVC)
        navController.navigationBar.barStyle = .blackTranslucent
        navController.modalPresentationStyle = .formSheet
        self.present(navController, animated: true, completion: completion)
    }
    
    func reSortList() {
        sortedRepoList = RepoManager.shared.sortedRepoList()
        rebuildSourceGroups()
    }

    private func rebuildSourceGroups() {
        displayedSourceGroups = sourceGroupStore.build(repos: sortedRepoList,
                                                       query: sourceSearchController.searchBar.text ?? "",
                                                       editing: isEditing)
    }

    private func sourceRepo(at indexPath: IndexPath) -> Repo? {
        guard indexPath.section > 0, let group = displayedSourceGroups[safe: indexPath.section - 1], !group.collapsed else { return nil }
        return group.repos[safe: indexPath.row]
    }

    private func sourceIndexPath(for repo: Repo) -> IndexPath? {
        for (section, group) in displayedSourceGroups.enumerated() where !group.collapsed {
            if let row = group.repos.firstIndex(of: repo) { return IndexPath(row: row, section: section + 1) }
        }
        return nil
    }

    private var displayedSourceOrder: [String] {
        displayedSourceGroups.flatMap(\.repos).map { sourceGroupStore.identity(for: $0) }
    }
    
    private func deleteRepo(at indexPath: IndexPath) {
        if DownloadManager.shared.queueRunning {
            TabBarController.singleton?.presentPopupController()
            return
        }
        
        guard let repo = sourceRepo(at: indexPath) else { return }
        let key = sourceGroupStore.identity(for: repo)
        RepoManager.shared.remove(repo: repo)
        sourceGroupStore.removeMetadata(keys: [key])
        self.reSortList()
        tableView.reloadData()
        updatingRepoList.removeAll { $0 == repo }
        self.updateFooterCount()
        NotificationCenter.default.post(name: PackageListManager.reloadNotification, object: nil)
        
        if repo.url == self.presentRepoUrl {
            presentDefaultPage()
        }
    }
    
    @objc func reloadRepo(_ notification: NSNotification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.reloadRepo(notification)
            }
            return
        }
        if let repo = notification.object as? Repo {
            guard let indexPath = sourceIndexPath(for: repo),
                  let cell = self.tableView.cellForRow(at: indexPath) as? SourcesTableViewCell else {
                return
            }
            let cellRepo = cell.repo
            cell.repo = cellRepo
            cell.layoutSubviews()
        } else if let count = notification.object as? Int {
            DispatchQueue.main.async {
                guard let cell = self.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? SourcesTableViewCell else { return }
                cell.installedLabel.text = "\(count)"
            }
        } else {
            for cell in tableView.loadedCells {
                if let sourcesCell = cell as? SourcesTableViewCell {
                    let cellRepo = sourcesCell.repo
                    sourcesCell.repo = cellRepo
                    sourcesCell.layoutSubviews()
                }
            }
        }
    }
    
    func reloadData() {
        self.reSortList()
        self.tableView.reloadData()
    }
    
    @objc func exportSources(_ sender: Any?) {
        let titleString = String(localizationKey: "Export")
        let msgString = String(localizationKey: "Export_Sources")
        let alert = UIAlertController(title: titleString, message: msgString, preferredStyle: .alert)
        
        let yesString = String(localizationKey: "Export_Yes")
        let yesAction = UIAlertAction(title: yesString, style: .default, handler: { _ in
            let repos = self.sortedRepoList.filter({$0.aptSource != nil}).map({ $0.aptSource! }).joined(separator: "\n")
            let activityVC = UIActivityViewController(activityItems: [repos], applicationActivities: nil)
            
            activityVC.popoverPresentationController?.sourceView = self.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
            
            self.present(activityVC, animated: true, completion: nil)
        })
        
        alert.addAction(yesAction)
        
        let noString = String(localizationKey: "Export_No")
        let noAction = UIAlertAction(title: noString, style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(noAction)
        
        self.present(alert, animated: true, completion: nil)
    }
    
    public func presentAddSourceEntryField(url: URL?) {
        let title = String(localizationKey: "Add_Source.Title")
        let msg = String(localizationKey: "Add_Source.Body")
        let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "URL"
            if let urlString = url?.absoluteString {
                let parsedURL = urlString.replacingOccurrences(of: "sileo://source/", with: "")
                textField.text = parsedURL
            } else {
                textField.text = "https://"
            }
            textField.keyboardType = .URL
            textField.addTarget(self, action: #selector(Self.textFieldDidChange(_:)), for: .editingChanged)
        }
        
        let addAction = UIAlertAction(title: String(localizationKey: "Add_Source.Button.Add"), style: .default, handler: { [weak alert] _ in
            self.dismiss(animated: true, completion: nil)
            if let repoURL = alert?.textFields?[0].text, let url = URL(string: repoURL) {
                if ["http","https"].contains(url.scheme?.lowercased()) && url.host != nil {
                    self.handleSourceAdd(sources: [url.absoluteString], bypassFlagCheck: false)
                }
            }
        })
        alert.addAction(addAction)
        
        let distRepoAction = UIAlertAction(title: String(localizationKey: "Add_Dist_Repo"), style: .default, handler: { [weak alert]  _ in
            self.dismiss(animated: true, completion: nil)
            self.addDistRepo(string: alert?.textFields?[0].text)
        })
        alert.addAction(distRepoAction)
        
        let cancelAcction = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(cancelAcction)
        
        present(alert, animated: true, completion: nil)
    }
    
    func presentAddClipBoardPrompt(sources: [String]) {
        let sources = sources.filter { hasCompatibleSourceFormat($0) }
        if sources.isEmpty {
            // I'm not quite sure how this happens, but it does sooooo
            return self.presentAddSourceEntryField(url: nil)
        }
        let count = sources.count

        let titleText = String(format: String(localizationKey: "Auto_Add_Pasteboard_Sources.Title"), count, count)
        let addText = String(format: String(localizationKey: "Auto_Add_Pasteboard_Sources.Button.Add"), count, count)
        let manualText = String(localizationKey: "Auto_Add_Pasteboard_Sources.Button.Manual")
        
        var msg = String(format: String(localizationKey: "Auto_Add_Pasteboard_Sources.Body_Intro"), sources.count)
        msg.append(contentsOf: "\n\n")
        msg.append(sources.compactMap { source -> String in
            "\"\(source)\""
        }.joined(separator: "\n"))
        
        let alert = UIAlertController(title: titleText, message: msg, preferredStyle: .alert)
        
        let addAction = UIAlertAction(title: addText, style: .default, handler: { _ in
            self.handleSourceAdd(sources: sources, bypassFlagCheck: false)
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(addAction)
        
        let manualAction = UIAlertAction(title: manualText, style: .default, handler: { _ in
            self.presentAddSourceEntryField(url: nil)
        })
        alert.addAction(manualAction)
        
        let cancelAction = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(cancelAction)
        
        self.present(alert, animated: true, completion: nil)
    }
    
    func addDistRepo(string: String?, suites: String?=nil, components: String?=nil) {
        let title = String(localizationKey: "Add_Source.Title")
        let msg = String(localizationKey: "Add_Dist_Repo")
        let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "URL"
            textField.text = string
            textField.keyboardType = .URL
            textField.addTarget(self, action: #selector(Self.textFieldDidChange(_:)), for: .editingChanged)
        }
        alert.addTextField { textField in
            textField.placeholder = "Suites"
            textField.text = suites
            textField.keyboardType = .URL
        }
        alert.addTextField { textField in
            textField.placeholder = "Components"
            textField.text = components
            textField.keyboardType = .URL
        }
        
        let addAction = UIAlertAction(title: String(localizationKey: "Add_Source.Button.Add"), style: .default, handler: { [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
            guard let urlField = alert.textFields?[0],
                  let suiteField = alert.textFields?[1],
                  let componentField = alert.textFields?[2],
                  let url = URL(string: urlField.text ?? "") else { return }
            guard ["http","https"].contains(url.scheme?.lowercased()) && url.host != nil else { return }
            guard (urlField.text?.count ?? 0)>0, (suiteField.text?.count ?? 0)>0, (componentField.text?.count ?? 0)>0 else { return }
            guard let repo = RepoManager.shared.addDistRepo(url: url, suites: suiteField.text ?? "", components: componentField.text ?? "") else {
                return
            }
            self?.reloadData()
            self?.updateSingleRepo(repo)
        })
        alert.addAction(addAction)
        
        let cancel = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(cancel)
        
        self.present(alert, animated: true, completion: nil)
    }
    
    #if !targetEnvironment(macCatalyst)
    @objc func addSource(_ sender: Any?) {
        // If URL(s) are copied, we ask the user if they want to add those.
        // Otherwise, we present the entry field dialog for the user to type a URL.
        if #available(iOS 14.0, *) {
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let pattern) where pattern.contains(.probableWebURL):
                        let newSources = UIPasteboard.general.newSources()
                        self.presentAddClipBoardPrompt(sources: newSources)
                    case .success, .failure:
                        self.presentAddSourceEntryField(url: nil)
                    }
                }
            }
        } else {
            let newSources = UIPasteboard.general.newSources()
            if newSources.isEmpty {
                self.presentAddSourceEntryField(url: nil)
            } else {
                self.presentAddClipBoardPrompt(sources: newSources)
            }
        }
    }
    #else
    @objc func addSource(_ sender: Any?) {
        self.presentAddSourceEntryField(url: nil)
    }
    #endif
    
    func handleSourceAdd(sources: [String], bypassFlagCheck: Bool) {
        let sources = sources.filter { hasCompatibleSourceFormat($0) }

        var newRepos: [Repo] = []
        for source in sources {
            
            let parts = source.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter({$0.isEmpty==false})
            guard let url = URL(string: parts[0]) else { continue }
            
            if parts.count == 1 {
                let repos = RepoManager.shared.addRepos(with: [url])
                if !repos.isEmpty {
                    newRepos.append(contentsOf: repos)
                }
                continue
            }
            
            let suite = (parts.count > 1) ? parts[1] : "./"
            let components = (parts.count > 2) ? Array(parts[2...]) : []
            
            if let repo = RepoManager.shared.addDistRepo(url: url, suites: suite, components: components.joined(separator: " ")) {
                newRepos.append(repo)
            }
        }
        
        self.reloadData()
        self.updateSpecific(newRepos)
        
//        if newRepos.count > 1 {
//            self.updateSpecific(newRepos)
//            return
//        }
//
//        if newRepos.count == 1 {
//            let repo = newRepos[0]
//            guard let url = repo.url else { return }
//            EvanderNetworking.head(url: url.appendingPathComponent("Release")) { success in
//                if success {
//                    DispatchQueue.main.async {
//                        self.updateSingleRepo(repo)
//                    }
//                } else {
//                    DispatchQueue.main.async { [self] in
//                        let alert = UIAlertController(title: String(localizationKey: "Warning"),
//                                                      message: String(format: String(localizationKey: "Incorrect_Repo"), url.absoluteString),
//                                                      preferredStyle: .alert)
//                        alert.addAction(UIAlertAction(title: String(localizationKey: "Add_Source.Title"), style: .default, handler: { _ in
//                            self.updateSingleRepo(repo)
//                        }))
//                        alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: { _ in
//                            RepoManager.shared.remove(repo: repo)
//                            self.reloadData()
//
//                            alert.dismiss(animated: true)
//                        }))
//                        self.present(alert, animated: true)
//                    }
//                }
//            }
//        }
    }
    
    // Smart Handling of pasted in sources
    @objc func textFieldDidChange(_ textField: UITextField) {
        guard var text = textField.text,
              text.count >= 15 else { return }
        if text.prefix(16).lowercased() == "https://https://" || text.prefix(15).lowercased() == "https://http://" {
            text = String(text.dropFirst(8))
        } else if text.prefix(15).lowercased() == "https://file://" {
            text = String(text.dropFirst(7))
        }
        
        textField.text = text
    }

    @objc private func showSourceManagementMenu(_ sender: UIBarButtonItem) {
        let sheet = UIAlertController(title: "软件源管理", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "编辑软件源", style: .default) { _ in self.toggleEditing(nil) })
        sheet.addAction(UIAlertAction(title: "新建分组", style: .default) { _ in self.showSourceGroupManager(createGroup: true) })
        sheet.addAction(UIAlertAction(title: "管理分组", style: .default) { _ in self.showSourceGroupManager(createGroup: false) })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = sender
        present(sheet, animated: true)
    }

    private func showSourceGroupManager(createGroup: Bool) {
        guard #available(iOS 14.0, *) else {
            let alert = UIAlertController(title: "管理分组", message: "分组图片和管理界面需要 iOS 14 或更高版本。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "完成", style: .cancel))
            present(alert, animated: true)
            return
        }
        let manager = SileoSourceGroupManagerViewController(store: sourceGroupStore) { [weak self] in
            self?.rebuildSourceGroups()
            self?.tableView.reloadData()
        }
        let navigation = UINavigationController(rootViewController: manager)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true) {
            if createGroup { manager.promptNewGroup() }
        }
    }

    @objc private func moveSelectedSources() {
        guard !selectedSourceKeys.isEmpty else { return }
        let model = sourceGroupStore.load()
        var targets: [(String, String)] = [(sileoPinnedSourceGroupID, "置顶")]
        for case let group as NSDictionary in model["groups"] as? NSArray ?? [] {
            if let identifier = group["id"] as? String, let name = group["name"] as? String { targets.append((identifier, name)) }
        }
        targets.append((sileoUngroupedSourceGroupID, "移出分组"))
        let sheet = UIAlertController(title: "移动到分组", message: nil, preferredStyle: .actionSheet)
        for target in targets {
            sheet.addAction(UIAlertAction(title: target.1, style: .default) { _ in
                self.sourceGroupStore.move(keys: Array(self.selectedSourceKeys), to: target.0, displayOrder: self.displayedSourceOrder)
                self.selectedSourceKeys.removeAll()
                self.rebuildSourceGroups(); self.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = toolbarItems?.first
        present(sheet, animated: true)
    }

    @objc private func deleteSelectedSources() {
        let repos = sortedRepoList.filter { selectedSourceKeys.contains(sourceGroupStore.identity(for: $0)) }
        let allowed = repos.filter(canDeleteSource)
        let protected = repos.filter { !canDeleteSource($0) }
        guard !allowed.isEmpty || !protected.isEmpty else { return }
        var message = allowed.isEmpty ? "" : "将删除：\n" + allowed.map(\.displayName).joined(separator: "\n")
        if !protected.isEmpty { message += (message.isEmpty ? "" : "\n\n") + "受保护，不会删除：\n" + protected.map(\.displayName).joined(separator: "\n") }
        let alert = UIAlertController(title: "删除软件源", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if !allowed.isEmpty {
            alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
                let keys = allowed.map { self.sourceGroupStore.identity(for: $0) }
                RepoManager.shared.remove(repos: allowed)
                self.sourceGroupStore.removeMetadata(keys: keys)
                self.selectedSourceKeys.removeAll()
                self.reSortList(); self.tableView.reloadData()
                NotificationCenter.default.post(name: PackageListManager.reloadNotification, object: nil)
            })
        }
        present(alert, animated: true)
    }

    private func canDeleteSource(_ repo: Repo) -> Bool {
        if Jailbreak.bootstrap == .procursus { return repo.entryFile.hasSuffix("/sileo.sources") }
        return repo.url?.host != "apt.bingner.com"
    }
}

extension SourcesViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        rebuildSourceGroups()
        tableView.reloadData()
    }
}

extension SourcesViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        if displayedSourceGroups.isEmpty && !sortedRepoList.isEmpty { rebuildSourceGroups() }
        return 1 + displayedSourceGroups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        guard let group = displayedSourceGroups[safe: section - 1] else { return 0 }
        if group.collapsed { return 0 }
        if isEditing && group.repos.isEmpty && !group.builtin { return 1 }
        return group.repos.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section > 0, let group = displayedSourceGroups[safe: section - 1], group.identifier != sileoUngroupedSourceGroupID else { return nil }
        let header = SileoSourceGroupHeaderView()
        header.configure(group: group) { [weak self] in
            self?.sourceGroupStore.toggleCollapsed(group.identifier)
            self?.rebuildSourceGroups()
            self?.tableView.reloadData()
        }
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard section > 0, let group = displayedSourceGroups[safe: section - 1] else { return section == 0 ? 5 : 0 }
        return group.identifier == sileoUngroupedSourceGroupID ? 4 : 44
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard section == displayedSourceGroups.count else { return UIView() }
        let footer = SourcesTableViewFooter(reuseIdentifier: "Sileo.SourcesTableViewFooter")
        footer.setCount(sortedRepoList.count)
        return footer
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        section == displayedSourceGroups.count ? 30 : 2
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = (tableView.dequeueReusableCell(withIdentifier: "SourcesViewControllerCellidentifier") as? SourcesTableViewCell) ?? SourcesTableViewCell(style: .subtitle, reuseIdentifier: "SourcesViewControllerCellidentifier")
            cell.repo = nil
            return cell
        }
        if let group = displayedSourceGroups[safe: indexPath.section - 1], group.repos.isEmpty {
            let identifier = "SileoEmptySourceGroupCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
            cell.textLabel?.text = "拖到这里"
            cell.textLabel?.textColor = UIColor(white: 0.55, alpha: 1)
            cell.selectionStyle = .none
            return cell
        }
        let cell = (tableView.dequeueReusableCell(withIdentifier: "SourcesViewControllerCellidentifier") as? SourcesTableViewCell) ?? SourcesTableViewCell(style: .subtitle, reuseIdentifier: "SourcesViewControllerCellidentifier")
        cell.repo = sourceRepo(at: indexPath)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 55 }

    private func updateFooterCount() {
        guard let footer = tableView.footerView(forSection: displayedSourceGroups.count) as? SourcesTableViewFooter else { return }
        footer.setCount(sortedRepoList.count)
    }
}

extension SourcesViewController: UITableViewDelegate { // UITableViewDelegate
    func tableView(_ tableView: UITableView, shouldShowMenuForRowAt indexPath: IndexPath) -> Bool { false }

    @available(iOS 13.0, *)
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing, let repo = sourceRepo(at: indexPath) else { return nil }
        let key = sourceGroupStore.identity(for: repo)
        let pinned = sourceGroupStore.load()["assignments"] as? NSDictionary
        let pinTitle = pinned?[key] as? String == sileoPinnedSourceGroupID ? "取消置顶" : "置顶"
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            let copy = UIAction(title: "复制源地址", image: UIImage(systemNameOrNil: "doc.on.doc")) { _ in UIPasteboard.general.string = repo.rawURL }
            let pin = UIAction(title: pinTitle, image: UIImage(systemNameOrNil: "pin")) { _ in
                self.sourceGroupStore.togglePin(repo: repo, displayOrder: self.displayedSourceOrder)
                self.rebuildSourceGroups(); self.tableView.reloadData()
            }
            let refresh = UIAction(title: "刷新", image: UIImage(systemNameOrNil: "arrow.clockwise")) { _ in self.updateSpecific([repo]) }
            var actions: [UIMenuElement] = [copy, pin, refresh]
            if self.canEditRow(indexPath: indexPath) {
                actions.append(UIAction(title: "删除", image: UIImage(systemNameOrNil: "trash"), attributes: .destructive) { _ in self.deleteRepo(at: indexPath) })
            }
            return UIMenu(title: repo.displayName, children: actions)
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section > 0 && sourceRepo(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    
    func tableViewSelectRowAt(tableView: UITableView, indexPath: IndexPath) {
        
        let categoryVC = self.controller(indexPath: indexPath)
        let navController = SileoNavigationController(rootViewController: categoryVC)
        self.splitViewController?.showDetailViewController(navController, sender: self)
        
        self.presentRepoUrl = categoryVC.repoContext?.url
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing, let repo = sourceRepo(at: indexPath) {
            selectedSourceKeys.insert(sourceGroupStore.identity(for: repo))
            return
        }
        tableViewSelectRowAt(tableView: tableView, indexPath: indexPath)
        detailedPageUserPresent = true
        if indexPath.section == 0 && indexPath.row == 0 { defaultPagePresent = true }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isEditing, let repo = sourceRepo(at: indexPath) else { return }
        selectedSourceKeys.remove(sourceGroupStore.identity(for: repo))
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        isEditing && sourceRepo(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        guard proposedDestinationIndexPath.section > 0 else { return sourceIndexPath }
        let section = min(proposedDestinationIndexPath.section, displayedSourceGroups.count)
        let group = displayedSourceGroups[section - 1]
        return IndexPath(row: min(proposedDestinationIndexPath.row, group.repos.count), section: section)
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard let sourceGroup = displayedSourceGroups[safe: sourceIndexPath.section - 1],
              let targetGroup = displayedSourceGroups[safe: destinationIndexPath.section - 1],
              let repo = sourceGroup.repos[safe: sourceIndexPath.row] else { return }
        let key = sourceGroupStore.identity(for: repo)
        let targetKeys = targetGroup.repos.map { sourceGroupStore.identity(for: $0) }
        sourceGroupStore.move(key: key, from: sourceGroup.identifier, to: targetGroup.identifier, index: destinationIndexPath.row, targetKeys: targetKeys)
        rebuildSourceGroups(); tableView.reloadData()
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        // We don't want to be able to delete the top section so we just return early here
        if indexPath.section == 0 { return nil }
        guard let repo = sourceRepo(at: indexPath) else { return nil }
        let refresh = UIContextualAction(style: .normal, title: String(localizationKey: "Refresh")) { _, _, completionHandler in
            self.updateSingleRepo(repo)
            completionHandler(true)
        }
        refresh.backgroundColor = .systemGreen
        if !self.canEditRow(indexPath: indexPath) {
            return UISwipeActionsConfiguration(actions: [refresh])
        }
        let remove = UIContextualAction(style: .destructive, title: String(localizationKey: "Remove")) { [weak self] _, _, completionHandler in
            self?.deleteRepo(at: indexPath)
            completionHandler(true)
        }
        return UISwipeActionsConfiguration(actions: [remove, refresh])
    }
}

@available(iOS 14.0, *)
extension SourcesViewController: UISplitViewControllerDelegate {
    func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController: UIViewController, onto primaryViewController: UIViewController) -> Bool {
        NSLog("SileoLog: splitViewController:collapseSecondary \(presentRepoUrl) \(detailedPageUserPresent)")
        return !detailedPageUserPresent
    }
}

class TouchGestureRecognizer: UIGestureRecognizer {
    private var target: Any?
    private var action: Selector?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.target = target
        self.action = action
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        self.state = .failed
        _ = (self.target as AnyObject).perform(action, with: nil)
    }
//    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
//        super.touchesMoved(touches, with: event)
//    }
//
//    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
//        super.touchesEnded(touches, with: event)
//    }
//    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
//        super.touchesCancelled(touches, with: event)
//    }
}


private let sileoPinnedSourceGroupID = "__pinned"
private let sileoUngroupedSourceGroupID = "__ungrouped"

private struct SileoSourceDisplayGroup {
    let identifier: String
    let name: String
    let iconData: Data?
    var repos: [Repo]
    let builtin: Bool
    let collapsed: Bool
}

private final class SileoSourceGroupStore {
    private let defaults = UserDefaults(suiteName: "shijian.sileosourcegroups")

    func load() -> NSMutableDictionary {
        guard let stored = defaults?.dictionary(forKey: "model") else { return defaultModel() }
        let model = (stored as NSDictionary).mutableCopy() as! NSMutableDictionary
        let sourceGroups = model["groups"] as? [Any] ?? []
        model["groups"] = NSMutableArray(array: sourceGroups.compactMap { ($0 as? NSDictionary)?.mutableCopy() })
        for key in ["assignments", "orders", "previous"] {
            model[key] = ((model[key] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
        }
        model["collapsed"] = NSMutableArray(array: model["collapsed"] as? [Any] ?? [])
        let name = (model["ungroupedName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        model["ungroupedName"] = name.isEmpty ? localized("未分组", "Ungrouped") : name
        model["migrated"] = (model["migrated"] as? NSNumber)?.boolValue ?? false
        model["version"] = 2
        return model
    }

    func save(_ model: NSDictionary) {
        defaults?.set(model, forKey: "model")
        defaults?.synchronize()
    }

    func identity(for repo: Repo) -> String {
        let components = repo.components.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: " ")
        return "\(normalizedURL(repo.rawURL))\n\(repo.suite.trimmingCharacters(in: .whitespacesAndNewlines))\n\(components)"
    }

    func build(repos: [Repo], query: String, editing: Bool) -> [SileoSourceDisplayGroup] {
        let model = load()
        migrateOldPins(model, repos: repos)
        clean(model, repos: repos)
        let assignments = model["assignments"] as! NSMutableDictionary
        let customGroups = model["groups"] as! NSMutableArray
        let validIDs = Set(customGroups.compactMap { ($0 as? NSDictionary)?["id"] as? String })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var buckets: [String: [Repo]] = [sileoPinnedSourceGroupID: [], sileoUngroupedSourceGroupID: []]
        validIDs.forEach { buckets[$0] = [] }
        for repo in repos where matches(repo, query: needle) {
            let key = identity(for: repo)
            var groupID = assignments[key] as? String ?? sileoUngroupedSourceGroupID
            if groupID != sileoPinnedSourceGroupID && groupID != sileoUngroupedSourceGroupID && !validIDs.contains(groupID) {
                groupID = sileoUngroupedSourceGroupID
            }
            buckets[groupID, default: []].append(repo)
        }
        let collapsed = Set((model["collapsed"] as? [String]) ?? [])
        let orders = model["orders"] as! NSMutableDictionary
        var result: [SileoSourceDisplayGroup] = []
        let pinned = ordered(buckets[sileoPinnedSourceGroupID] ?? [], keys: orders[sileoPinnedSourceGroupID] as? [String] ?? [])
        if !pinned.isEmpty {
            result.append(.init(identifier: sileoPinnedSourceGroupID, name: localized("置顶", "Pinned"), iconData: nil, repos: pinned, builtin: true, collapsed: !editing && collapsed.contains(sileoPinnedSourceGroupID)))
        }
        for case let group as NSDictionary in customGroups {
            guard let identifier = group["id"] as? String, let name = group["name"] as? String else { continue }
            let groupRepos = ordered(buckets[identifier] ?? [], keys: orders[identifier] as? [String] ?? [])
            result.append(.init(identifier: identifier, name: name, iconData: group["icon"] as? Data, repos: groupRepos, builtin: false, collapsed: !editing && collapsed.contains(identifier)))
        }
        let ungrouped = buckets[sileoUngroupedSourceGroupID] ?? []
        if !ungrouped.isEmpty {
            result.append(.init(identifier: sileoUngroupedSourceGroupID, name: "", iconData: nil, repos: ungrouped, builtin: true, collapsed: false))
        }
        save(model)
        return result
    }

    func move(keys: [String], to targetID: String, displayOrder: [String]) {
        let model = load()
        let assignments = model["assignments"] as! NSMutableDictionary
        let orders = model["orders"] as! NSMutableDictionary
        let previous = model["previous"] as! NSMutableDictionary
        for case let groupID as String in orders.allKeys {
            let order = NSMutableArray(array: orders[groupID] as? [Any] ?? [])
            order.removeObjects(in: keys)
            orders[groupID] = order
        }
        let target = NSMutableArray(array: orders[targetID] as? [Any] ?? [])
        target.removeObjects(in: keys)
        let chosen = Set(keys)
        for key in displayOrder where chosen.contains(key) {
            let old = assignments[key] as? String ?? sileoUngroupedSourceGroupID
            if targetID == sileoPinnedSourceGroupID && old != sileoPinnedSourceGroupID { previous[key] = old }
            if targetID != sileoPinnedSourceGroupID { previous.removeObject(forKey: key) }
            assignments[key] = targetID
            target.add(key)
        }
        orders[targetID] = target
        save(model)
    }

    func move(key: String, from sourceID: String, to targetID: String, index: Int, targetKeys: [String]) {
        let model = load()
        let assignments = model["assignments"] as! NSMutableDictionary
        let orders = model["orders"] as! NSMutableDictionary
        let previous = model["previous"] as! NSMutableDictionary
        for case let groupID as String in orders.allKeys {
            let order = NSMutableArray(array: orders[groupID] as? [Any] ?? [])
            order.remove(key)
            orders[groupID] = order
        }
        let target = NSMutableArray(array: targetKeys.filter { $0 != key })
        target.insert(key, at: min(max(index, 0), target.count))
        let old = assignments[key] as? String ?? sourceID
        if targetID == sileoPinnedSourceGroupID && old != sileoPinnedSourceGroupID { previous[key] = old }
        if targetID != sileoPinnedSourceGroupID { previous.removeObject(forKey: key) }
        assignments[key] = targetID
        orders[targetID] = target
        save(model)
    }

    func togglePin(repo: Repo, displayOrder: [String]) {
        let model = load()
        let key = identity(for: repo)
        let assignments = model["assignments"] as! NSMutableDictionary
        let current = assignments[key] as? String ?? sileoUngroupedSourceGroupID
        var target = sileoPinnedSourceGroupID
        if current == sileoPinnedSourceGroupID {
            let old = (model["previous"] as! NSMutableDictionary)[key] as? String
            target = groupExists(model, old) ? old! : sileoUngroupedSourceGroupID
        }
        move(keys: [key], to: target, displayOrder: displayOrder)
    }

    func toggleCollapsed(_ identifier: String) {
        let model = load()
        let collapsed = model["collapsed"] as! NSMutableArray
        collapsed.contains(identifier) ? collapsed.remove(identifier) : collapsed.add(identifier)
        save(model)
    }

    func removeMetadata(keys: [String]) {
        let model = load()
        for key in keys {
            (model["assignments"] as! NSMutableDictionary).removeObject(forKey: key)
            (model["previous"] as! NSMutableDictionary).removeObject(forKey: key)
        }
        let orders = model["orders"] as! NSMutableDictionary
        for case let groupID as String in orders.allKeys {
            let order = NSMutableArray(array: orders[groupID] as? [Any] ?? [])
            order.removeObjects(in: keys)
            orders[groupID] = order
        }
        save(model)
    }

    private func defaultModel() -> NSMutableDictionary {
        ["version": 2, "groups": NSMutableArray(), "ungroupedName": localized("未分组", "Ungrouped"), "assignments": NSMutableDictionary(), "orders": NSMutableDictionary(), "collapsed": NSMutableArray(), "previous": NSMutableDictionary(), "migrated": false]
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? chinese : english
    }

    private func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.host != nil else { return trimmed.lowercased() }
        components.scheme = "sg"
        components.host = components.host?.lowercased()
        components.fragment = nil
        while components.percentEncodedPath.count > 1 && components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        let value = components.string ?? trimmed
        return value.hasPrefix("sg://") ? String(value.dropFirst(5)) : value
    }

    private func matches(_ repo: Repo, query: String) -> Bool {
        if query.isEmpty { return true }
        return [repo.repoName, repo.rawURL, repo.suite, repo.components.joined(separator: " ")].joined(separator: "\n").range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func ordered(_ repos: [Repo], keys: [String]) -> [Repo] {
        var byKey: [String: Repo] = [:]
        for repo in repos { byKey[identity(for: repo)] = repo }
        var result: [Repo] = []
        for key in keys { if let repo = byKey.removeValue(forKey: key) { result.append(repo) } }
        result += byKey.values.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? identity(for: $0) < identity(for: $1) : comparison == .orderedAscending
        }
        return result
    }

    private func groupExists(_ model: NSDictionary, _ identifier: String?) -> Bool {
        guard let identifier = identifier else { return false }
        if identifier == sileoPinnedSourceGroupID || identifier == sileoUngroupedSourceGroupID { return true }
        return (model["groups"] as? [NSDictionary])?.contains { $0["id"] as? String == identifier } == true
    }

    private func migrateOldPins(_ model: NSMutableDictionary, repos: [Repo]) {
        if (model["migrated"] as? NSNumber)?.boolValue == true { return }
        let old = UserDefaults.standard.stringArray(forKey: "com.shijian.sileosourcepin.urls") ?? []
        let normalized = old.map(normalizedURL)
        let assignments = model["assignments"] as! NSMutableDictionary
        let order = NSMutableArray()
        for url in normalized { for repo in repos where normalizedURL(repo.rawURL) == url {
            let key = identity(for: repo)
            assignments[key] = sileoPinnedSourceGroupID
            if !order.contains(key) { order.add(key) }
        }}
        (model["orders"] as! NSMutableDictionary)[sileoPinnedSourceGroupID] = order
        model["migrated"] = true
        UserDefaults.standard.removeObject(forKey: "com.shijian.sileosourcepin.urls")
    }

    private func clean(_ model: NSMutableDictionary, repos: [Repo]) {
        let live = Set(repos.map(identity))
        for name in ["assignments", "previous"] {
            let dictionary = model[name] as! NSMutableDictionary
            for case let key as String in dictionary.allKeys where !live.contains(key) { dictionary.removeObject(forKey: key) }
        }
        let orders = model["orders"] as! NSMutableDictionary
        for case let groupID as String in orders.allKeys {
            var seen = Set<String>()
            orders[groupID] = (orders[groupID] as? [String] ?? []).filter { live.contains($0) && seen.insert($0).inserted }
        }
    }
}


private final class SileoSourceGroupHeaderView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .sileoBackgroundColor
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 5
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        chevron.tintColor = UIColor(white: 0.55, alpha: 1)
        [iconView, titleLabel, chevron].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), iconView.centerYAnchor.constraint(equalTo: centerYAnchor), iconView.widthAnchor.constraint(equalToConstant: 28), iconView.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10), titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), chevron.centerYAnchor.constraint(equalTo: centerYAnchor), chevron.widthAnchor.constraint(equalToConstant: 14), chevron.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8)
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(group: SileoSourceDisplayGroup, action: @escaping () -> Void) {
        self.action = action
        titleLabel.text = "\(group.name) (\(group.repos.count))"
        iconView.image = group.iconData.flatMap(UIImage.init(data:)) ?? UIImage(systemNameOrNil: group.identifier == sileoPinnedSourceGroupID ? "pin.fill" : "folder.fill")
        chevron.image = UIImage(systemNameOrNil: group.collapsed ? "chevron.right" : "chevron.down")
    }

    @objc private func tapped() { action?() }
}

@available(iOS 14.0, *)
private final class SileoSourceGroupManagerViewController: UITableViewController, PHPickerViewControllerDelegate {
    private let store: SileoSourceGroupStore
    private var model: NSMutableDictionary
    private let completion: () -> Void
    private var imageGroupIndex = 0

    init(store: SileoSourceGroupStore, completion: @escaping () -> Void) {
        self.store = store
        self.model = store.load()
        self.completion = completion
        super.init(style: .insetGrouped)
        title = "管理分组"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addGroup))
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
    }

    @objc private func done() { dismiss(animated: true) { self.completion() } }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { (model["groups"] as? NSArray)?.count ?? 0 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "group") ?? UITableViewCell(style: .default, reuseIdentifier: "group")
        let group = (model["groups"] as! NSArray)[indexPath.row] as! NSDictionary
        cell.textLabel?.text = group["name"] as? String
        cell.imageView?.image = (group["icon"] as? Data).flatMap(UIImage.init(data:)) ?? UIImage(systemNameOrNil: "folder")
        cell.imageView?.layer.cornerRadius = 6; cell.imageView?.clipsToBounds = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let groups = model["groups"] as! NSMutableArray
        let group = groups[sourceIndexPath.row]
        groups.removeObject(at: sourceIndexPath.row); groups.insert(group, at: destinationIndexPath.row)
        store.save(model)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .delete }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let groups = model["groups"] as! NSMutableArray
        let groupID = (groups[indexPath.row] as! NSDictionary)["id"] as! String
        let assignments = model["assignments"] as! NSMutableDictionary
        for case let key as String in assignments.allKeys where assignments[key] as? String == groupID { assignments[key] = sileoUngroupedSourceGroupID }
        (model["orders"] as! NSMutableDictionary).removeObject(forKey: groupID)
        (model["collapsed"] as! NSMutableArray).remove(groupID)
        groups.removeObject(at: indexPath.row)
        store.save(model); tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let group = (model["groups"] as! NSArray)[indexPath.row] as! NSDictionary
        let sheet = UIAlertController(title: group["name"] as? String, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "重命名", style: .default) { _ in self.promptName(index: indexPath.row) })
        sheet.addAction(UIAlertAction(title: "选择图片", style: .default) { _ in self.chooseImage(index: indexPath.row) })
        if group["icon"] is Data { sheet.addAction(UIAlertAction(title: "移除图片", style: .destructive) { _ in
            ((self.model["groups"] as! NSMutableArray)[indexPath.row] as! NSMutableDictionary).removeObject(forKey: "icon")
            self.store.save(self.model); self.tableView.reloadData()
        }) }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
        present(sheet, animated: true)
    }

    func promptNewGroup() { promptName(index: nil) }
    @objc private func addGroup() { promptName(index: nil) }
    private func promptName(index: Int?) {
        let alert = UIAlertController(title: index == nil ? "新建分组" : "重命名分组", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "分组名称"
            if let index = index { field.text = (((self.model["groups"] as! NSArray)[index] as! NSDictionary)["name"] as? String) }
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let groups = self.model["groups"] as! NSMutableArray
            let duplicate = groups.enumerated().contains { offset, value in offset != index && ((value as? NSDictionary)?["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }
            guard !name.isEmpty, !duplicate else { return }
            if let index = index { (groups[index] as! NSMutableDictionary)["name"] = name }
            else { groups.add(NSMutableDictionary(dictionary: ["id": UUID().uuidString, "name": name])) }
            self.store.save(self.model); self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func chooseImage(index: Int) {
        imageGroupIndex = index
        var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        let index = imageGroupIndex
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { return }
            UIGraphicsBeginImageContextWithOptions(CGSize(width: 96, height: 96), false, 2)
            image.draw(in: CGRect(x: 0, y: 0, width: 96, height: 96))
            let data = UIGraphicsGetImageFromCurrentImageContext()?.jpegData(compressionQuality: 0.82)
            UIGraphicsEndImageContext()
            DispatchQueue.main.async {
                guard let data = data, index < (self.model["groups"] as! NSMutableArray).count else { return }
                ((self.model["groups"] as! NSMutableArray)[index] as! NSMutableDictionary)["icon"] = data
                self.store.save(self.model); self.tableView.reloadData()
            }
        }
    }
}
