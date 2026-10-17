import SwiftUI

/// 表单里的一个网盘根目录（docs/design/cloud-storage.md §3.2；网页 library-form-dialog 的 CloudRootRows）。
struct ManageCloudRoot: Hashable {
    var accountId: Int
    var remoteDirId: String
    var displayPath: String
    var isPrimary: Bool
    var accountName: String
    var backendTitle: String
    /// 已挂上的才有：台账里在位的纳管文件数
    var fileCount: Int?

    init(_ folder: API.CloudFolderView) {
        accountId = folder.accountId
        remoteDirId = folder.remoteDirId
        displayPath = folder.displayPath
        isPrimary = folder.isPrimary
        accountName = folder.accountName
        backendTitle = folder.backendTitle
        fileCount = folder.fileCount
    }

    init(account: API.DriveAccountView, dirId: String, path: String) {
        accountId = account.id
        remoteDirId = dirId
        displayPath = path
        isPrimary = false
        accountName = account.name
        backendTitle = account.backendTitle
        fileCount = nil
    }

    var payload: API.CloudFolderPayload {
        API.CloudFolderPayload(accountId: accountId, remoteDirId: remoteDirId, displayPath: displayPath, isPrimary: isPrimary)
    }
}

/// 网盘根目录行：挂上即纳管（按文件名识别、不下载、不改动网盘上的文件），拿掉只删台账。
/// 没有网盘账号时什么都不显示（网盘是插件，没装就当没这回事）。
struct ManageCloudRootsEditor: View {
    @Binding var folders: [ManageCloudRoot]
    let accounts: [API.DriveAccountView]
    /// 正在编辑的库（它自己挂着的目录不算被占用）；新建为 nil
    let libraryId: Int?
    /// 还没有服务器目录：提示要补一个
    let needsLocal: Bool

    @State private var picking = false

    var body: some View {
        ForEach(folders, id: \.self) { folder in
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.icloud").foregroundStyle(Theme.accent.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.displayPath).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                    Text([folder.accountName, folder.fileCount.map { "\($0) 个视频" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if folder.isPrimary {
                    Text("主根")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: .capsule)
                } else {
                    Button("设为主根") { setPrimary(folder) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textMuted)
                }
                Button {
                    folders.removeAll { $0.accountId == folder.accountId && $0.remoteDirId == folder.remoteDirId }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除 \(folder.displayPath)")
            }
        }
        if !accounts.isEmpty {
            Button {
                picking = true
            } label: {
                Label(addTitle, systemImage: "plus").font(.subheadline.weight(.medium))
            }
            .accessibilityIdentifier("form-add-cloud-root")
            .sheet(isPresented: $picking) {
                DriveFolderPicker(accounts: accounts, libraryId: libraryId, taken: folders) { account, id, path in
                    folders.append(ManageCloudRoot(account: account, dirId: id, path: path))
                    picking = false
                }
                .sheetFeedback()
            }
        }
        if !folders.isEmpty && needsLocal {
            Text(folders.contains(where: \.isPrimary)
                 ? "还需要一个服务器目录当本地暂存目录：新片上传前放在这里，海报与字幕也放这里。"
                 : "还需要一个服务器目录当主根：新下载的片子、海报与字幕放在这里。")
                .font(.caption).foregroundStyle(Theme.warning)
        }
    }

    private var addTitle: String {
        let titles = Set(accounts.map(\.backendTitle))
        return titles.count == 1 ? "\(titles.first ?? "网盘")目录" : "网盘目录"
    }

    private func setPrimary(_ target: ManageCloudRoot) {
        folders = folders.map { folder in
            var next = folder
            next.isPrimary = folder.accountId == target.accountId && folder.remoteDirId == target.remoteDirId
            return next
        }
    }
}

/// 网盘根目录区下方的说明：挂上即纳管；主根在网盘意味着什么。
struct ManageCloudRootsFooter: View {
    let folders: [ManageCloudRoot]

    var body: some View {
        if folders.contains(where: \.isPrimary) {
            Text("主根在网盘：新下载的片子入库后立即能看，后台上传到网盘（多数秒传），传完核验后本地自动腾空。网盘目录里已有的片子按文件名识别加进库里，不下载、不改动网盘上的文件。")
        } else if !folders.isEmpty {
            Text("网盘目录里已有的片子会按文件名识别加进库里，不下载、不改动网盘上的文件；之后在网盘里新增、移动、删除的片子会自动跟上。")
        }
    }
}

/// 选网盘上的文件夹（网页 drive-folder-picker.tsx）：点子目录下钻，选当前目录。只列目录、按需展开；
/// 已挂在别的库上的（含上下层）标出库名、不能选。
struct DriveFolderPicker: View {
    let accounts: [API.DriveAccountView]
    let libraryId: Int?
    let taken: [ManageCloudRoot]
    let onSelect: (API.DriveAccountView, String, String) -> Void

    private struct Level: Hashable {
        var id: String
        var path: String
        var name: String
        var libraryId: Int?
        var libraryName: String?
    }

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var accountId: Int
    @State private var stack: [Level] = [Level(id: "", path: "", name: "")]
    @State private var dirs: Loadable<[API.DriveDirView]> = .loading

    init(
        accounts: [API.DriveAccountView], libraryId: Int?, taken: [ManageCloudRoot],
        onSelect: @escaping (API.DriveAccountView, String, String) -> Void
    ) {
        self.accounts = accounts
        self.libraryId = libraryId
        self.taken = taken
        self.onSelect = onSelect
        _accountId = State(initialValue: accounts.first?.id ?? 0)
    }

    private var account: API.DriveAccountView? { accounts.first { $0.id == accountId } ?? accounts.first }
    private var current: Level { stack.last ?? Level(id: "", path: "", name: "") }

    private func usedElsewhere(_ id: Int?) -> Bool { id != nil && id != libraryId }

    private func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.isEmpty || b.isEmpty || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private var blocked: String? {
        if stack.count == 1 { return "点进要挂的文件夹再选" }
        if usedElsewhere(current.libraryId) { return "已在《\(current.libraryName ?? "")》库里" }
        if taken.contains(where: { $0.accountId == accountId && overlaps($0.displayPath, current.path) }) {
            return "与已添加的网盘目录重叠"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                if accounts.count > 1 {
                    Picker("账号", selection: $accountId) {
                        ForEach(accounts, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: accountId) { stack = [Level(id: "", path: "", name: "")] }
                }
                Section {
                    switch dirs {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    case let .failed(message):
                        SettingsNotice(text: message)
                    case let .loaded(rows):
                        if rows.isEmpty {
                            Text("这里没有子目录，可直接选择当前目录").font(.subheadline).foregroundStyle(Theme.textMuted)
                        }
                        ForEach(rows, id: \.id) { dir in
                            Button {
                                stack.append(Level(
                                    id: dir.id, path: dir.path, name: dir.name,
                                    libraryId: dir.libraryId, libraryName: dir.libraryName
                                ))
                            } label: {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(Theme.accent.opacity(0.8))
                                    Text(dir.name).foregroundStyle(Theme.text)
                                    Spacer()
                                    if usedElsewhere(dir.libraryId) {
                                        Text("已在《\(dir.libraryName ?? "")》库").font(.caption).foregroundStyle(Theme.textFaint)
                                    } else if let count = dir.videoCount {
                                        Text("\(count) 个视频").font(.caption).foregroundStyle(Theme.textFaint)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textFaint)
                                }
                            }
                            .accessibilityIdentifier("drive-dir-\(dir.name)")
                        }
                    }
                } header: {
                    Text(([account?.name ?? "网盘"] + stack.dropFirst().map(\.name)).joined(separator: " › "))
                } footer: {
                    if let blocked { Text(blocked) } else { Text("选择「\(current.path)」") }
                }
            }
            .navigationTitle("选择\(account?.backendTitle ?? "网盘")上的文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if stack.count > 1 {
                        Button("上一级") { stack.removeLast() }
                    } else {
                        Button("取消") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择此文件夹") {
                        if let account { onSelect(account, current.id, current.path) }
                    }
                    .disabled(blocked != nil)
                    .accessibilityIdentifier("drive-dir-select")
                }
            }
            .task(id: "\(accountId)/\(current.id)") { await load() }
        }
    }

    private func load() async {
        dirs = .loading
        do {
            dirs = .loaded(try await api.drivesAccountsDirs(accountId: accountId, parentId: current.id, path: current.path))
        } catch {
            dirs = .failed(error.localizedDescription)
        }
    }
}
