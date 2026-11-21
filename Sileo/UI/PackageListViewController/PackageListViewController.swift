//
//  PackageListViewController.swift
//  Sileo
//
//  Created by CoolStar on 8/14/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import Evander
import os
import SwipeCellKit

var searchHistory: [String] {
    get {
        return UserDefaults.standard.stringArray(forKey: "UserSearchHistory") ?? []
    }

    set {
        var newItems: [String] = []
        for item in newValue {
            if !newItems.contains(item) {
                newItems.append(item)
            }
        }
        UserDefaults.standard.set(newItems, forKey: "UserSearchHistory")
    }
}


public class SileoScrollViewController: SileoViewController {
}
    
class PackageListViewController: SileoScrollViewController, UIGestureRecognizerDelegate {
    @IBOutlet final var collectionView: UICollectionView?
//    @IBOutlet final var downloadsButton: UIBarButtonItem?
    
    @IBInspectable final var showSearchField: Bool = false
    @IBInspectable final var showUpdates: Bool = false //=true in InterfaceBuild
    @IBInspectable final var showWishlist: Bool = false
    @IBInspectable final var loadProvisional: Bool = false
    @IBInspectable final var localizableTitle: String = ""
    @IBInspectable final public var packagesLoadIdentifier: String = ""
    
    final public var repoContext: Repo?
    
    final private var packages: [Package] = []
    final private var availableUpdates: [Package] = []
    final private var ignoredUpdates: [Package] = []
    final private var _searchCache: [String: [Package]] = [:]
    private let searchCacheLock = DispatchSemaphore(value: 1)
    final private var searchCache: [String: [Package]] {
        get { searchCacheLock.wait(); defer { searchCacheLock.signal() }; return _searchCache }
        set { searchCacheLock.wait(); defer { searchCacheLock.signal() }; _searchCache = newValue }
        _modify {
            searchCacheLock.wait()
            defer { searchCacheLock.signal() }
            yield &_searchCache
        }
    }
    final private var provisionalPackages: [ProvisionalPackage] = []
    final private var cachedInstalled: [Package]?
    
    private var displaySettings = false
    
    private var refreshPackages = UIRefreshControl()
    
    private var showProvisional: Bool = false
    private var shouldShowUpdates: Bool = false
    
    private var canisterHeartbeat: Timer?
    
    public var searchController = UISearchController(searchResultsController: nil)
    private var prevSearchText: String?
    
    private let searchingQueue = DispatchQueue(label: "Sileo.PackageList.Searching", qos: .userInitiated)
    private var updatingCount = 0 {
        didSet {
            if updatingCount < 0 {
                updatingCount = 0
            }
        }
    }
    private var showSearchHistory: Bool {
        // make sure we're on the search page
        guard let title = navigationItem.title, title == String(localizationKey: "Search_Page") else {
            return false
        }
        return !searchHistory.isEmpty && (searchController.searchBar.text?.isEmpty ?? false)
    }
    
    @objc func updateSileoColors() {
        self.statusBarStyle = .default
        if let textField = searchController.searchBar.value(forKey: "searchField") as? UITextField {
            textField.textColor = .sileoLabel
        }
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        updateSileoColors()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateSileoColors()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.navigationController?.navigationBar._hidesShadow = true
                
        guard #available(iOS 13, *) else {
            if showSearchField {
                self.navigationItem.hidesSearchBarWhenScrolling = false
            }
            return
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationController?.navigationBar._hidesShadow = false
        
        guard let visibleCells = collectionView?.visibleCells else {
            return
        }
        for cell in visibleCells {
            if let packageCell = cell as? PackageCollectionViewCell {
                packageCell.hideSwipe(animated: false)
            }
        }
    }
    
    @objc func refreshInstalledPackages(_ sender: UIRefreshControl?) {
        sender?.beginRefreshing()
        if DownloadManager.shared.queueRunning {
            TabBarController.singleton?.presentPopupController()
        } else {
            PackageListManager.shared.reloadInstalled()
            DownloadManager.shared.reloadData(recheckPackages: true)
            NotificationCenter.default.post(name: PackageListManager.stateChange, object: nil)
            NotificationCenter.default.post(name: PackageListManager.installChange, object: nil)
        }
        sender?.endRefreshing()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if showUpdates {
            shouldShowUpdates = true
        }
        
        if loadProvisional {
            showProvisional = UserDefaults.standard.bool(forKey: "ShowProvisional", fallback: true)
            _ = NotificationCenter.default.addObserver(forName: Notification.Name("ShowProvisional"), object: nil, queue: nil) { _ in
                self.showProvisional = UserDefaults.standard.bool(forKey: "ShowProvisional", fallback: true)
                self.collectionView?.reloadData()
            }
        }
        
        if showWishlist {
            let exportBtn = UIBarButtonItem(title: String(localizationKey: "Export"), style: .plain, target: self, action: #selector(self.exportButtonClicked(_:)))
            self.navigationItem.leftBarButtonItem = exportBtn

            let backupBtn = UIBarButtonItem(image: UIImage(systemName: "archivebox"), style: .plain, target: self, action: #selector(self.showBackupCenter(_:)))
            backupBtn.accessibilityLabel = "插件备份"
            self.navigationItem.rightBarButtonItem = backupBtn
        }
        
        if packagesLoadIdentifier.contains("--wishlist") {
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData), name: WishListManager.changeNotification, object: nil)
        }
        
        if !localizableTitle.isEmpty {
            self.title = String(localizationKey: localizableTitle)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData), name: PackageListManager.installChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData), name: PackageListManager.reloadNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.reloadStates(_:)), name: PackageListManager.stateChange, object: nil)
        if self.showUpdates {
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadDataWithUpdates), name: PackageListManager.prefsNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadDataWithUpdates), name: Notification.Name("ShowIgnoredUpdates"), object: nil)
        }
        if loadProvisional {
            NotificationCenter.default.addObserver(self, selector: #selector(self.reloadData), name: CanisterResolver.refreshList, object: nil)
        }
        
        // A value of exactly 17.0 (the default) causes the text to auto-shrink
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).defaultTextAttributes = [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17.01)
        ]
        
        searchController.searchBar.placeholder = String(localizationKey: "Package_Search.Placeholder")
        if #available(iOS 13, *) {
            searchController.searchBar.searchTextField.semanticContentAttribute = (LanguageHelper.shared.isRtl ?? false) ? .forceRightToLeft : .forceLeftToRight
        } else {
            let textfieldOfSearchBar = searchController.searchBar.value(forKey: "searchField") as? UITextField
            textfieldOfSearchBar?.semanticContentAttribute = (LanguageHelper.shared.isRtl ?? false) ? .forceRightToLeft : .forceLeftToRight
        }
        searchController.searchBar.delegate = self
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = true
        
        self.navigationController?.navigationBar.superview?.tag = WHITE_BLUR_TAG
        
        self.navigationItem.hidesSearchBarWhenScrolling = false
        self.navigationItem.searchController = searchController
        self.definesPresentationContext = true
        
        var sbTextField: UITextField?
        if #available(iOS 13, *) {
            sbTextField = searchController.searchBar.searchTextField
        } else {
            sbTextField = searchController.searchBar.value(forKey: "_searchField") as? UITextField
        }
        sbTextField?.font = UIFont.systemFont(ofSize: 13)
        
        let tapRecognizer = UITapGestureRecognizer(target: searchController.searchBar, action: #selector(UISearchBar.resignFirstResponder))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        
        if let collectionView = collectionView {
            if self.packagesLoadIdentifier == "--installed" {
                refreshPackages.addTarget(self, action: #selector(refreshInstalledPackages(_:)), for: .valueChanged)
                collectionView.refreshControl = refreshPackages
            }
            collectionView.addGestureRecognizer(tapRecognizer)
            collectionView.register(UINib(nibName: "PackageCollectionViewCell", bundle: nil),
                                    forCellWithReuseIdentifier: "PackageListViewCellIdentifier")
        
            let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            flowLayout?.sectionHeadersPinToVisibleBounds = true
        
            collectionView.register(UINib(nibName: "PackageListHeader", bundle: nil),
                                    forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                    withReuseIdentifier: "PackageListHeader")
            collectionView.register(UINib(nibName: "PackageListHeaderBlank", bundle: nil),
                                    forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                    withReuseIdentifier: "PackageListHeaderBlank")
            collectionView.register(SearchHistoryCollectionViewCell.self,
                                    forCellWithReuseIdentifier: "HistoryViewCellIdentifier")
            
            self.registerForPreviewing(with: self, sourceView: collectionView)
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let packageMan = PackageListManager.shared
            
            if !self.showSearchField {
                let pkgs = packageMan.packageList(identifier: self.packagesLoadIdentifier, sortPackages: true, repoContext: self.repoContext, packagePrepend: self.packagesLoadIdentifier=="--contextInstalled" ? (self.repoContext?.installedPackages ?? []) : nil)
                DispatchQueue.main.async {
                    self.packages = pkgs
                    self.searchCache[""] = pkgs
                    self.updateSearchResults(for: self.searchController)
                }
            }
            
            let updates = self.showUpdates ? packageMan.availableUpdates() : []
            
            DispatchQueue.main.async {
                self.availableUpdates = updates.filter({ $0.1?.wantInfo != .hold }).map({ $0.0 })
                if UserDefaults.standard.bool(forKey: "ShowIgnoredUpdates", fallback: true) {
                    self.ignoredUpdates = updates.filter({ $0.1?.wantInfo == .hold }).map({ $0.0 })
                }
                if !self.availableUpdates.isEmpty {
                    self.navigationController?.tabBarItem.badgeValue = String(format: "%ld", self.availableUpdates.count)
                } else {
                    self.navigationController?.tabBarItem.badgeValue = nil
                }
                
                self.updatePackageList()
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        searchController.searchBar.isFirstResponder ?? false
    }
    
    func controller(package: Package) -> PackageActions {
        NSLog("SileoLog: NativePackageViewController=\(package.package), \(package.sourceRepo?.url), \(package.source)")
        return NativePackageViewController.viewController(for: package)
    }
    
    func controller(indexPath: IndexPath) -> PackageActions? {
        switch findWhatFuckingSectionThisIs(indexPath.section) {
            case .canister:
                guard let pro = provisionalPackages[safe: indexPath.row],
                    let package = CanisterResolver.package(pro) else { return nil }
                return controller(package: package)
            case .ignoredUpdates:
                guard let package = ignoredUpdates[safe: indexPath.row] else { return nil }
                return controller(package: package)
            case .packages, .reallyBoringList:
                guard let package = packages[safe: indexPath.row] else { return nil }
                return controller(package: package)
            case .updates:
                guard let package = availableUpdates[safe: indexPath.row] else { return nil }
                return controller(package: package)
            case .searchHistoryList:
                searchController.searchBar.text = searchHistory[safe: indexPath.row]
                return nil
        }
    }
    
    private func updatePackageList()
    {
        self.updateSearchResults(for: self.searchController)
    }

    @objc func reloadData() {
        if showUpdates {
            self.reloadDataWithUpdates()
            return
        }
        
        self.searchCache = [:]
        self.cachedInstalled = nil
        updatePackageList()
    }
    
    @objc func reloadStates(_ notification: Notification) {
        let wasInstall = notification.object as? Bool ?? false
        Thread.mainBlock { [weak self] in
            guard let self = self else { return }
            let packageCells = self.collectionView?.visibleCells.compactMap { $0 as? PackageCollectionViewCell } ?? []
            if wasInstall {
                packageCells.forEach { $0.stateBadgeView?.isHidden = true }
            } else {
                packageCells.forEach { $0.refreshState() }
            }
        }
    }
        
    @objc func reloadDataWithUpdates() {
        DispatchQueue.global(qos: .userInteractive).async {
            let updates = PackageListManager.shared.availableUpdates()
            DispatchQueue.main.async {
                self.availableUpdates = updates.filter({ $0.1?.wantInfo != .hold }).map({ $0.0 })
                if UserDefaults.standard.bool(forKey: "ShowIgnoredUpdates", fallback: true) {
                    self.ignoredUpdates = updates.filter({ $0.1?.wantInfo == .hold }).map({ $0.0 })
                } else {
                    self.ignoredUpdates.removeAll()
                }
                
                if !self.availableUpdates.isEmpty {
                    self.navigationController?.tabBarItem.badgeValue = String(format: "%ld", self.availableUpdates.count)
                    UIApplication.shared.applicationIconBadgeNumber = self.availableUpdates.count
                } else {
                    self.navigationController?.tabBarItem.badgeValue = nil
                    UIApplication.shared.applicationIconBadgeNumber = 0
                }
                self.cachedInstalled = nil
                self.searchCache = [:]
                self.updatePackageList()
            }
        }
    }
    
    @objc func exportButtonClicked(_ button: UIButton?) {
        let alert = UIAlertController(title: String(localizationKey: "Export"), message: String(localizationKey: "Export_Packages"), preferredStyle: .alert)
        
        let defaultAction = UIAlertAction(title: String(localizationKey: "Export_Yes"), style: .default, handler: { _ in
            let pkgs = self.getPackages()
            let activityVC = UIActivityViewController(activityItems: [pkgs], applicationActivities: nil)

            activityVC.popoverPresentationController?.sourceView = self.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)

            self.present(activityVC, animated: true, completion: nil)
        })
        
        alert.addAction(defaultAction)
        
        let cancelAction = UIAlertAction(title: String(localizationKey: "Export_No"), style: .cancel, handler: { _ in
        })
        alert.addAction(cancelAction)
        
        self.present(alert, animated: true)
    }
    
    func getPackages() -> String {
        return packages.map { package in
            "\(package.name):(\(package.package)) \(package.version)"
        }.joined(separator: "\n")
    }
    
    enum SortMode {
        case name
        case installdate
        case size
        
        init(from string: String?) {
            switch string {
            case "installdate": self = .installdate
            case "size": self = .size
            case "name": self = .name
            default: self = .installdate
            }
        }
        
        init() {
            self = .init(from: UserDefaults.standard.string(forKey: "InstallSortType"))
        }
    }
    
    @objc func showWishlist(_ sender: Any?) {
        let wishlistController = PackageListViewController(nibName: "PackageListViewController", bundle: nil)
        wishlistController.title = String(localizationKey: "Wishlist")
        wishlistController.packagesLoadIdentifier = "--wishlist"
        self.navigationController?.pushViewController(wishlistController, animated: true)
    }
    
    private func hapticResponse() {
        if #available(iOS 13, *) {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.impactOccurred()
        } else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }
    
    var isEnabled = true
    @objc func upgradeAllClicked(_ sender: Any?) {
        guard isEnabled else { return }
        
        if DownloadManager.shared.queueRunning {
            TabBarController.singleton?.presentPopupController()
            return
        }
        
        isEnabled = false
        hapticResponse()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            PackageListManager.shared.upgradeAll {
                self?.isEnabled = true
            }
        }
    }
    
    @objc func sortPopup(sender: UIView?) {
        let alert = UIAlertController(title: String(localizationKey: "Sort_By"), message: nil, preferredStyle: .actionSheet)
        alert.modalPresentationStyle = .popover
        alert.popoverPresentationController?.sourceView = sender
        
        let nameAction = UIAlertAction(title: String(localizationKey: "Sort_Name"), style: .default, handler: { _ in
            UserDefaults.standard.set("name", forKey: "InstallSortType")
            self.updatePackageList()
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(nameAction)
        
        let dateAction = UIAlertAction(title: String(localizationKey: "Sort_Date"), style: .default, handler: { _ in
            UserDefaults.standard.set("installdate", forKey: "InstallSortType")
            self.updatePackageList()
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(dateAction)
        
        let sizeAction = UIAlertAction(title: String(localizationKey: "Sort_Install_Size"), style: .default, handler: { _ in
            UserDefaults.standard.set("size", forKey: "InstallSortType")
            self.updatePackageList()
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(sizeAction)
        
        let cancelAction = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(cancelAction)
        
        self.present(alert, animated: true, completion: nil)
    }
    
    @objc
    func clearHistory() {
        searchHistory.removeAll()
        collectionView?.performBatchUpdates({
            collectionView?.deleteSections(.init(integer: 0))
        }, completion: nil)
    }
}

extension PackageListViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        if showSearchHistory { return 1 }
        var count = 0
        if !packages.isEmpty { count += 1 }
        if shouldShowUpdates {
            if !availableUpdates.isEmpty { count += 1 }
            if !ignoredUpdates.isEmpty { count += 1 }
        }
        if showProvisional && loadProvisional {
            if !provisionalPackages.isEmpty { count += 1 }
        }
        return count
    }
    
    private func findWhatFuckingSectionThisIs(_ section: Int) -> PackageListSection {
        if showSearchHistory {
            return .searchHistoryList
        }
        
        if shouldShowUpdates {
            if !availableUpdates.isEmpty && section == 0 {
                return .updates
            } else if availableUpdates.isEmpty && !ignoredUpdates.isEmpty && section == 0 {
                return .ignoredUpdates
            } else if section == 1 && !availableUpdates.isEmpty && !ignoredUpdates.isEmpty {
                return .ignoredUpdates
            }
            if packagesLoadIdentifier != "--installed" {
                return .reallyBoringList
            }
            return .packages
        }
        if loadProvisional {
            if !showProvisional { return .reallyBoringList }
            if section == 1 {
                return .canister
            } else if section == 0 && !packages.isEmpty {
                return .packages
            } else if section == 0 && packages.isEmpty {
                return .canister
            }
        }
        return .reallyBoringList
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch findWhatFuckingSectionThisIs(section) {
        case .canister: return provisionalPackages.count
        case .ignoredUpdates: return ignoredUpdates.count
        case .packages, .reallyBoringList: return packages.count
        case .updates: return availableUpdates.count
        case .searchHistoryList: return searchHistory.count
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let section = findWhatFuckingSectionThisIs(indexPath.section)
        if section == .searchHistoryList {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "HistoryViewCellIdentifier", for: indexPath) as! SearchHistoryCollectionViewCell
            cell.label.text = searchHistory[indexPath.row]
            return cell
        }
        
        let cellIdentifier = "PackageListViewCellIdentifier"
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellIdentifier, for: indexPath) as? PackageCollectionViewCell else {
            fatalError("This is what we call a pro gamer move, where we fatalError because of something horrendous")
        }
        
        switch section {
        case .canister: cell.provisionalTarget = provisionalPackages[safe: indexPath.row]; cell.targetPackage = nil
        case .ignoredUpdates: cell.targetPackage = ignoredUpdates[safe: indexPath.row]; cell.provisionalTarget = nil
        case .packages, .reallyBoringList: cell.targetPackage = packages[safe: indexPath.row]; cell.provisionalTarget = nil
        case .updates: cell.targetPackage = availableUpdates[safe: indexPath.row]; cell.provisionalTarget = nil
        case .searchHistoryList:
            fatalError("Shouldn't have gotten here!")
        }
        
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        NSLog("SileoLog: collectionView kind=\(kind) at=\(indexPath) id=\(packagesLoadIdentifier)")
        let section = findWhatFuckingSectionThisIs(indexPath.section)
        if section == .reallyBoringList {
            if kind == UICollectionView.elementKindSectionHeader {
                let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                                 withReuseIdentifier: "PackageListHeaderBlank",
                                                                                 for: indexPath)
                return headerView
            }
        }
        guard let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                               withReuseIdentifier: "PackageListHeader",
                                                                               for: indexPath) as? PackageListHeader
        else {
            return UICollectionReusableView()
        }
        switch findWhatFuckingSectionThisIs(indexPath.section) {
        case .canister:
            headerView.actionText = nil
//            headerView.separatorView?.isHidden = false
            headerView.sortContainer?.isHidden = true
            headerView.upgradeButton?.isHidden = true
            headerView.label?.text = String(localizationKey: "External_Repo")
            return headerView
        case .ignoredUpdates:
            headerView.actionText = nil
//            headerView.separatorView?.isHidden = false
            headerView.sortContainer?.isHidden = true
            headerView.upgradeButton?.isHidden = true
            headerView.label?.text = String(localizationKey: "Ignored Updates")
            return headerView
        case .updates:
            headerView.label?.text = String(localizationKey: "Updates_Heading")
            headerView.actionText = String(localizationKey: "Upgrade_All_Button")
            headerView.sortContainer?.isHidden = true
//            headerView.separatorView?.isHidden = true
            headerView.upgradeButton?.addTarget(self, action: #selector(self.upgradeAllClicked(_:)), for: .touchUpInside)
            return headerView
        case .packages:
            if shouldShowUpdates {
                headerView.label?.text = String(localizationKey: "Installed_Heading")
                headerView.actionText = nil
                headerView.sortContainer?.isHidden = false
                switch SortMode() {
                case .name: headerView.sortHeader?.text = String(localizationKey: "Sort_Name")
                case .installdate: headerView.sortHeader?.text = String(localizationKey: "Sort_Date")
                case .size: headerView.sortHeader?.text = String(localizationKey: "Sort_Install_Size")
                }
                headerView.sortContainer?.addTarget(self, action: #selector(self.sortPopup(sender:)), for: .touchUpInside)
//                headerView.separatorView?.isHidden = false
                return headerView
            } else if showProvisional && loadProvisional {
                headerView.actionText = nil
//                headerView.separatorView?.isHidden = false
                headerView.sortContainer?.isHidden = true
                headerView.upgradeButton?.isHidden = true
                headerView.label?.text = String(localizationKey: "Internal_Repo")
                return headerView
            }
        case .reallyBoringList: fatalError("Literally impossible to be here")
        case .searchHistoryList:
            headerView.actionText = String(localizationKey: "Clear_Search_History")
//            headerView.separatorView?.isHidden = false
            headerView.sortContainer?.isHidden = true
            headerView.upgradeButton?.isHidden = false
            headerView.upgradeButton?.addTarget(nil, action: #selector(clearHistory), for: .touchUpInside)
            headerView.label?.text = String(localizationKey: "Search_History")
            return headerView
        }
        return UICollectionReusableView()
    }
}

extension PackageListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let pvc = self.controller(indexPath: indexPath) else { return }
        self.navigationController?.pushViewController(pvc, animated: true)
        
        guard UserDefaults.standard.bool(forKey: "ShowSearchHistory", fallback: true) else { return }
        guard navigationItem.title == String(localizationKey: "Search_Page") else { return }
        if let text = searchController.searchBar.text, !text.isEmpty {
            searchHistory.insert(text, at: 0)
        }
    }
}

extension PackageListViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        switch findWhatFuckingSectionThisIs(section) {
        case .reallyBoringList: return .zero
        case .ignoredUpdates, .updates, .canister: return CGSize(width: collectionView.bounds.width, height: 65)
        case .packages, .searchHistoryList:
            return (shouldShowUpdates && displaySettings) ? CGSize(width: collectionView.bounds.width, height: 109) : CGSize(width: collectionView.bounds.width, height: 65)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        var width = collectionView.bounds.size.width
        if UIDevice.current.userInterfaceIdiom == .pad || UIApplication.shared.statusBarOrientation.isLandscape {
            if width > 330 {
                width = 330
            }
        }
        if findWhatFuckingSectionThisIs(indexPath.section) == .searchHistoryList {
            return CGSize(width: width, height: 50)
        }
        
        return CGSize(width: width, height: 73)
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        0
    }
}

extension PackageListViewController: UIViewControllerPreviewingDelegate {
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController? {
        guard let indexPath = collectionView?.indexPathForItem(at: location),
              let pvc = self.controller(indexPath: indexPath)
        else {
            return nil
        }
        return pvc
    }
    
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController) {
        self.navigationController?.pushViewController(viewControllerToCommit, animated: true)
    }
}

@available(iOS 13.0, *)
extension PackageListViewController {
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        if findWhatFuckingSectionThisIs(indexPath.section) == .searchHistoryList {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                let copyItemAction = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = searchHistory[safe: indexPath.row]
                }
                
                return UIMenu(children: [copyItemAction])
            }
        }
        
        guard let pvc = self.controller(indexPath: indexPath) else {
            return nil
        }
        
        let menuItems = pvc.actions()
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: {
            pvc
        }, actionProvider: { _ in
            UIMenu(title: "", options: .displayInline, children: menuItems)
        })
        
        return config
    }
    
    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        if let previewController = animator.previewViewController {
            animator.addAnimations {
                self.show(previewController, sender: self)
            }
        }
    }
}

extension PackageListViewController: UISearchBarDelegate {
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        NSLog("SileoLog: searchBarCancelButtonClicked \(searchBar)")
        self.provisionalPackages.removeAll()
        self.packages.removeAll()
        self.collectionView?.reloadData()
    }
    
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        NSLog("SileoLog: searchBarSearchButtonClicked \(searchBar)")
        guard let text = searchBar.text,
              !text.isEmpty,
              showProvisional,
              loadProvisional
        else {
            return
        }
        
        if UserDefaults.standard.bool(forKey: "ShowSearchHistory", fallback: true) {
            searchHistory.insert(text, at: 0)
        }
        
        CanisterResolver.shared.fetch(text) { change in
            guard change else { return }
            DispatchQueue.main.async {
                self.updateSearchResults(for: self.searchController)
            }
        }
    }

    private enum UpdateType {
       case insert
       case delete
       case refresh
       case nothing
   }
   
   @discardableResult private func updateProvisional() -> UpdateType {
       if !showProvisional {
           return .nothing
       }
       
       let text = (searchController.searchBar.text ?? "").lowercased()
       let oldEmpty = provisionalPackages.isEmpty
       if text.lengthOfBytes(using: String.Encoding.utf8) < 2 {
           self.provisionalPackages.removeAll()
           return oldEmpty ? .nothing : .delete
       }
       
       var newPackages: [Package] = []
       self.provisionalPackages = CanisterResolver.shared.packages.filter {(pro: ProvisionalPackage) -> Bool in
           let searchTerms = [pro.name, pro.package, pro.description, pro.author?.name].compactMap { $0?.lowercased() }
           var contains = false
           for term in searchTerms {
               if strstr(term, text) != nil {
                   contains = true
                   break
               }
           }
           if !contains { return false }
           
           let existingRepo = RepoManager.shared.repo(with: pro.repository.uri, suite: pro.repository.suite, components: pro.repository.component?.components(separatedBy: .whitespaces))

           if let existingRepoPackage = self.packages.first(where: {$0.package==pro.package && $0.sourceRepo==existingRepo}) {
//               return !DpkgWrapper.isVersion(existingRepoPackage.version, greaterThan: pro.version)
               NSLog("SileoLog: existingPackage=\(existingRepoPackage.package)")
               return false
           }
           else if let bestPackage = PackageListManager.shared.newestPackage(identifier: pro.package) {
               if !self.packages.contains(bestPackage) {
                   NSLog("SileoLog: newPackages.append(\(bestPackage.package))")
                   newPackages.append(bestPackage)
               }
           }
           
           //if the repo has already been added then we should skip this ProvisionalPackage anyway
           if existingRepo != nil {
               return false
           }
           
           return true
       }
       if newPackages.count > 0 {
           self.packages.append(contentsOf: newPackages)
           self.collectionView?.reloadData()
           return .nothing
       }
       if oldEmpty && provisionalPackages.isEmpty {
           return .nothing
       } else if !oldEmpty && provisionalPackages.isEmpty {
           return .delete
       } else if oldEmpty && !provisionalPackages.isEmpty {
           return .insert
       } else {
           return .refresh
       }
   }
}

extension PackageListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        NSLog("SileoLog: updateSearchResults \(searchController)")
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateSearchResults(for: searchController)
            }
            return
        }
        func handleResponse(_ response: UpdateType) {
            switch response {
            case .nothing: return
            case .refresh: collectionView?.reloadSections(IndexSet(integer: packages.isEmpty ? 0 : 1))
            case .delete: collectionView?.deleteSections(IndexSet(integer: packages.isEmpty ? 0 : 1))
            case .insert: collectionView?.insertSections(IndexSet(integer: packages.isEmpty ? 0 : 1))
            }
        }
        
        let searchBar = searchController.searchBar
        self.canisterHeartbeat?.invalidate()
        
        if (searchBar.text?.isEmpty ?? true) != (self.prevSearchText?.isEmpty ?? true) {
            NSLog("SileoLog: self.collectionView.scrollRectToVisible")
            self.collectionView?.scrollRectToVisible(CGRectMake(0,0,1,1), animated: false)
        }
        self.prevSearchText = searchBar.text
    
        if searchBar.text?.isEmpty ?? true {
            if showSearchField {
                packages = []
                provisionalPackages = []
            }
        } else {
            canisterHeartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                CanisterResolver.shared.fetch(searchBar.text ?? "") { change in
                    guard change else { return }
                    DispatchQueue.main.async {
                        let response = self?.updateProvisional() ?? .nothing
                        handleResponse(response)
                    }
                }
            }
        }
        
        let query = searchBar.text ?? ""
        if query.isEmpty && packagesLoadIdentifier.isEmpty && repoContext == nil {
            collectionView?.reloadData()
            return
        }
        searchingQueue.async {
            self.updatingCount += 1
            
            let packageManager = PackageListManager.shared
            var packages: [Package] = []

            if self.showUpdates {
                self.shouldShowUpdates = query.isEmpty
            }
            
            if let cachedPackages = self.searchCache[query.lowercased()] {
                packages = cachedPackages
            } else if self.packagesLoadIdentifier == "--contextInstalled" {
                guard let context = self.repoContext else { return }
                let betterContext = RepoManager.shared.repo(with: context) ?? context
                packages = packageManager.packageList(identifier: self.packagesLoadIdentifier,
                                                      search: query,
                                                      sortPackages: true,
                                                      repoContext: nil,
                                                      lookupTable: self.searchCache,
                                                      packagePrepend: betterContext.installedPackages ?? [])
                self.searchCache[query.lowercased()] = packages
            } else {
                packages = packageManager.packageList(identifier: self.packagesLoadIdentifier,
                                                      search: query,
                                                      sortPackages: true,
                                                      repoContext: self.repoContext,
                                                      lookupTable: self.searchCache)
                self.searchCache[query.lowercased()] = packages
            }
            
            if self.packagesLoadIdentifier == "--installed" && query.isEmpty {
                switch SortMode() {
                case .installdate:
                    packages = packages.sorted(by: { package1, package2 -> Bool in
                        guard let date1 = package1.installDate else { return true }
                        guard let date2 = package2.installDate else { return false }
                        return date2.compare(date1) == .orderedAscending
                    })
                case .size:
                    packages = packages.sorted { $0.installedSize ?? 0 > $1.installedSize ?? 0 }
                case .name:
                    packages = packageManager.sortPackages(packages: packages, search: query)
                }
            }
            
            self.updatingCount -= 1
            if self.updatingCount != 0 {
                return
            }
            
//Truncating arrays before transferring it to the main queue when searching to prevent UI lag
            if query.lengthOfBytes(using: String.Encoding.utf8) < 2 {
                packages = Array(packages.prefix(1000))
            }
//
            DispatchQueue.main.async {
                self.packages = packages
                self.updateProvisional()
                
                if self.updatingCount == 0 {
                    UIView.performWithoutAnimation {
                        self.collectionView?.reloadData()
                    }
                }
            }
        }
    }
}

extension PackageListViewController {
    @objc func showBackupCenter(_ sender: UIBarButtonItem?) {
        let sheet = UIAlertController(title: "插件备份", message: nil, preferredStyle: .actionSheet)
        let actions: [(String, UIAlertAction.Style, () -> Void)] = [
            ("全部插件备份", .default, { self.backupAllPackages() }),
            ("选择插件备份", .default, { self.choosePackagesForBackup() }),
            ("配置备份", .default, { self.runBackup { try SileoBackupStore.backupPreferences() } }),
            ("插件源备份", .default, { self.runBackup { try SileoBackupStore.backupSources() } }),
            ("插件恢复", .default, { self.restorePackages() }),
            ("配置恢复", .default, { self.confirmRestore("恢复配置会覆盖现有同名配置文件。") { try SileoBackupStore.restorePreferences() } }),
            ("插件源恢复", .default, { self.confirmRestore("恢复软件源会把备份中的源合并到当前列表。") { try SileoBackupStore.restoreSources() } }),
            ("查看备份", .default, { self.showBackupSummary() }),
            ("清除备份", .destructive, { self.confirmClearBackup() })
        ]
        actions.forEach { item in
            sheet.addAction(UIAlertAction(title: item.0, style: item.1) { _ in item.2() })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = sender
        present(sheet, animated: true)
    }

    private func backupAllPackages() {
        let packages = Array(PackageListManager.shared.installedPackages.values)
        runBackup { try SileoBackupStore.backupPackages(packages) }
    }

    private func choosePackagesForBackup() {
        let packages = Array(PackageListManager.shared.installedPackages.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let controller = SileoPackageBackupSelectionController(packages: packages) { selected in
            self.runBackup { try SileoBackupStore.backupPackages(selected) }
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func runBackup(_ work: @escaping () throws -> Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let count = try work()
                DispatchQueue.main.async { self.showBackupMessage("备份完成", "已保存 \(count) 项。") }
            } catch {
                DispatchQueue.main.async { self.showBackupMessage("操作失败", error.localizedDescription) }
            }
        }
    }

    private func confirmRestore(_ message: String, work: @escaping () throws -> Int) {
        let alert = UIAlertController(title: "确认恢复", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "恢复", style: .default) { _ in
            self.runBackup(work)
        })
        present(alert, animated: true)
    }

    private func restorePackages() {
        guard !DownloadManager.shared.queueRunning else {
            showBackupMessage("无法恢复", "当前安装队列正在运行。")
            return
        }
        do {
            let records = try SileoBackupStore.packageRecords()
            var restored = 0
            var missing: [String] = []
            records.forEach { record in
                var package = SileoBackupStore.offlinePackage(identifier: record.identifier, version: record.version)
                for repo in RepoManager.shared.repoList where package == nil {
                    package = repo.getPackage(identifier: record.identifier, version: record.version, ignoreArch: true)
                }
                package = package ?? PackageListManager.shared.newestPackage(identifier: record.identifier)
                if let package = package {
                    DownloadManager.shared.add(package: package, queue: .installations)
                    restored += 1
                } else {
                    missing.append(record.identifier)
                }
            }
            DownloadManager.shared.reloadData(recheckPackages: true)
            NotificationCenter.default.post(name: PackageQueueButton.actionPerformedNotification, object: nil)
            if restored > 0 { TabBarController.singleton?.presentPopupController() }
            let suffix = missing.isEmpty ? "" : "\n未在当前软件源找到：\n" + missing.joined(separator: "\n")
            showBackupMessage("恢复已加入队列", "已加入 \(restored) 个插件。\(suffix)")
        } catch {
            showBackupMessage("操作失败", error.localizedDescription)
        }
    }

    private func showBackupSummary() {
        showBackupMessage("备份信息", SileoBackupStore.summary())
    }

    private func confirmClearBackup() {
        let alert = UIAlertController(title: "清除备份", message: "将删除全部插件、配置和软件源备份，无法撤销。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { _ in
            do {
                try SileoBackupStore.clear()
                self.showBackupMessage("清除完成", "全部备份已删除。")
            } catch {
                self.showBackupMessage("操作失败", error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func showBackupMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "完成", style: .cancel))
        present(alert, animated: true)
    }
}

extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

enum PackageListSection {
    case updates
    case ignoredUpdates
    case packages
    case canister
    case reallyBoringList
    case searchHistoryList
}


private struct SileoPackageBackupRecord: Codable {
    let identifier: String
    let name: String
    let version: String
    let architecture: String?
    let source: String?
}

private struct SileoSourceBackupRecord: Codable {
    let url: String
    let suite: String
    let components: [String]
    let rawEntry: String
}

private enum SileoBackupStore {
    private static let manager = FileManager.default
    private static let root = URL(fileURLWithPath: "/var/mobile/Documents/SileoBackups", isDirectory: true)
    private static let packagesFile = root.appendingPathComponent("packages.json")
    private static let sourcesFile = root.appendingPathComponent("sources.json")
    private static let debsDirectory = root.appendingPathComponent("debs", isDirectory: true)
    private static let preferencesDirectory = root.appendingPathComponent("preferences", isDirectory: true)
    private static let preferencesSource = URL(fileURLWithPath: "\(CommandPath.prefix)/var/mobile/Library/Preferences", isDirectory: true)

    static func ensureRoot() throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o755])
    }

    static func backupPackages(_ packages: [Package]) throws -> Int {
        try ensureRoot()
        let records = packages.sorted { $0.package < $1.package }.map {
            SileoPackageBackupRecord(identifier: $0.package,
                                     name: $0.name,
                                     version: $0.version,
                                     architecture: $0.architecture,
                                     source: $0.sourceRepo?.rawURL)
        }
        let data = try JSONEncoder.sileoBackup.encode(records)
        try data.write(to: packagesFile, options: .atomic)
        if manager.fileExists(atPath: debsDirectory.path) {
            try manager.removeItem(at: debsDirectory)
        }
        try manager.createDirectory(at: debsDirectory, withIntermediateDirectories: true)
        let script = """
        set -e
        pkg="$1"
        arch="$2"
        out="$3"
        work="$(/usr/bin/mktemp -d /var/tmp/sileo-repack.XXXXXX)"
        trap '/usr/bin/rm -rf "$work"' EXIT
        root="$work/root"
        /usr/bin/mkdir -p "$root/DEBIAN"
        list="/Library/dpkg/info/$pkg.list"
        test -f "$list"
        /usr/bin/sed -e 's#^/##' -e '/^$/d' "$list" > "$work/files"
        cd /
        /usr/bin/tar -cf - -T "$work/files" 2>/dev/null | /usr/bin/tar -xf - -C "$root"
        /usr/bin/dpkg-query -s "$pkg" | /usr/bin/sed '/^Status:/d' > "$root/DEBIAN/control"
        if ! /usr/bin/grep -q '^Architecture:' "$root/DEBIAN/control"; then
            echo "Architecture: $arch" >> "$root/DEBIAN/control"
        fi
        for ext in preinst postinst prerm postrm conffiles triggers md5sums; do
            src="/Library/dpkg/info/$pkg.$ext"
            test ! -f "$src" || /usr/bin/cp -p "$src" "$root/DEBIAN/$ext"
        done
        version="$(/usr/bin/dpkg-query -W -f='${Version}' "$pkg")"
        safe_version="$(printf '%s' "$version" | /usr/bin/sed 's/:/%3a/g; s#/#%2f#g')"
        /usr/bin/dpkg-deb -Zxz --root-owner-group -b "$root" "$out/${pkg}_${safe_version}_${arch}.deb"
        """
        for package in packages {
            _ = spawnAsRoot(args: [CommandPath.sh,
                                   "-c",
                                   script,
                                   "sileo-repack",
                                   package.package,
                                   package.architecture ?? DpkgWrapper.architecture.primary.rawValue,
                                   rootfs(debsDirectory.path)])
        }
        return records.count
    }

    static func offlinePackage(identifier: String, version: String) -> Package? {
        guard let files = try? manager.contentsOfDirectory(at: debsDirectory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) else { return nil }
        let candidates = files.filter { $0.pathExtension.lowercased() == "deb" && $0.lastPathComponent.hasPrefix(identifier + "_") }
        for file in candidates {
            guard let package = PackageListManager.shared.package(url: file), package.version == version else { continue }
            let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("deb")
            do {
                try manager.copyItem(at: file, to: temporary)
                return PackageListManager.shared.package(url: temporary)
            } catch {
                continue
            }
        }
        return nil
    }

    static func packageRecords() throws -> [SileoPackageBackupRecord] {
        guard manager.fileExists(atPath: packagesFile.path) else { throw backupError("没有插件备份。") }
        return try JSONDecoder().decode([SileoPackageBackupRecord].self, from: Data(contentsOf: packagesFile))
    }

    static func backupSources() throws -> Int {
        try ensureRoot()
        let records = RepoManager.shared.repoList.map {
            SileoSourceBackupRecord(url: $0.rawURL, suite: $0.suite, components: $0.components, rawEntry: $0.rawEntry)
        }
        try JSONEncoder.sileoBackup.encode(records).write(to: sourcesFile, options: .atomic)
        return records.count
    }

    static func restoreSources() throws -> Int {
        guard manager.fileExists(atPath: sourcesFile.path) else { throw backupError("没有插件源备份。") }
        let records = try JSONDecoder().decode([SileoSourceBackupRecord].self, from: Data(contentsOf: sourcesFile))
        let before = RepoManager.shared.repoList.count
        let raw = records.map { record -> String in
            if !record.rawEntry.isEmpty { return record.rawEntry }
            return "Types: deb\nURIs: \(record.url)\nSuites: \(record.suite)\nComponents: \(record.components.joined(separator: " "))"
        }.joined(separator: "\n\n")
        let temporaryDirectory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporary = temporaryDirectory.appendingPathComponent("sileo.sources")
        try raw.write(to: temporary, atomically: true, encoding: .utf8)
        RepoManager.shared.parseSourcesFile(at: temporary)
        RepoManager.shared.writeListToFile()
        try? manager.removeItem(at: temporaryDirectory)
        let count = max(RepoManager.shared.repoList.count - before, 0)
        if count > 0 {
            NotificationCenter.default.post(name: SourcesViewController.refreshReposNotification, object: nil)
        }
        return count
    }

    static func backupPreferences() throws -> Int {
        try ensureRoot()
        if manager.fileExists(atPath: preferencesDirectory.path) {
            try manager.removeItem(at: preferencesDirectory)
        }
        try manager.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        let files = try manager.contentsOfDirectory(at: preferencesSource,
                                                    includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
        var count = 0
        for file in files where file.pathExtension.lowercased() == "plist" {
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            if name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") { continue }
            let destination = preferencesDirectory.appendingPathComponent(file.lastPathComponent)
            do {
                try manager.copyItem(at: file, to: destination)
                count += 1
            } catch {
                continue
            }
        }
        return count
    }

    static func restorePreferences() throws -> Int {
        guard manager.fileExists(atPath: preferencesDirectory.path) else { throw backupError("没有配置备份。") }
        let files = try manager.contentsOfDirectory(at: preferencesDirectory,
                                                    includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
        var count = 0
        for file in files where file.pathExtension.lowercased() == "plist" {
            let destination = preferencesSource.appendingPathComponent(file.lastPathComponent)
            let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try manager.copyItem(at: file, to: temp)
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.moveItem(at: temp, to: destination)
                count += 1
            } catch {
                try? manager.removeItem(at: temp)
            }
        }
        return count
    }

    static func summary() -> String {
        let packageCount = (try? packageRecords().count) ?? 0
        let sourceCount: Int = {
            guard let data = try? Data(contentsOf: sourcesFile),
                  let records = try? JSONDecoder().decode([SileoSourceBackupRecord].self, from: data) else { return 0 }
            return records.count
        }()
        let preferenceCount = (try? manager.contentsOfDirectory(atPath: preferencesDirectory.path).count) ?? 0
        let attributes = try? manager.attributesOfItem(atPath: root.path)
        let date = attributes?[.modificationDate] as? Date
        let dateText = date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "无"
        return "位置：\(root.path)\n插件：\(packageCount)\n配置：\(preferenceCount)\n插件源：\(sourceCount)\n更新时间：\(dateText)"
    }

    static func clear() throws {
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
    }

    private static func backupError(_ message: String) -> NSError {
        NSError(domain: "SileoBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension JSONEncoder {
    static var sileoBackup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private final class SileoPackageBackupSelectionController: UITableViewController {
    private let packages: [Package]
    private var selected = Set<String>()
    private let completion: ([Package]) -> Void

    init(packages: [Package], completion: @escaping ([Package]) -> Void) {
        self.packages = packages
        self.completion = completion
        super.init(style: .grouped)
        title = "选择插件备份"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.allowsMultipleSelection = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "备份", style: .done, target: self, action: #selector(backupSelected))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "全选", style: .plain, target: self, action: #selector(selectAllPackages))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        packages.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "SileoPackageBackupSelectionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let package = packages[indexPath.row]
        cell.textLabel?.text = package.name
        cell.detailTextLabel?.text = "\(package.package)  \(package.version)"
        cell.imageView?.image = package.defaultIcon
        cell.accessoryType = selected.contains(package.package) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let package = packages[indexPath.row]
        if selected.contains(package.package) { selected.remove(package.package) } else { selected.insert(package.package) }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    @objc private func selectAllPackages() {
        selected = Set(packages.map { $0.package })
        tableView.reloadData()
    }

    @objc private func backupSelected() {
        let values = packages.filter { selected.contains($0.package) }
        guard !values.isEmpty else { return }
        completion(values)
        navigationController?.popViewController(animated: true)
    }
}
