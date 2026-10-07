import SwiftUI

/// MCP 服务：总开关与端点列表；新建后展示一次性令牌，再进入详情。
/// 状态由共享 store 持有，写操作后刷新列表与详情。
struct MCPSettingsView: View {
    @Environment(\.api) private var api
    @State private var store = SettingsBMCPStore()
    @State private var creating = false
    /// 当前推入的端点 id（点行或新建完成后赋值）
    @State private var openEndpoint: String?
    /// 新建弹层关闭后要推入的端点：等弹层完全收起再 push，避免转场打架
    @State private var pendingOpen: String?
    /// 深链 `?endpoint=<slug>&tab=` 直达某端点的某一栏（Web 把视图状态写进地址栏），只消费一次
    @Environment(\.routeQuery) private var routeQuery
    @State private var routeQueryConsumed = false
    @State private var openTab: SettingsBMCPEndpointDetail.Tab = .overview

    var body: some View {
        Group {
            if let status = store.status {
                list(status)
            } else if let error = store.error {
                ErrorState(message: error) { await store.load(api) }
            } else {
                // 首载：布局先占位（Web 骨架屏）
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("loading")
            }
        }
        .appBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建端点", systemImage: "plus") {
                    store.error = nil
                    creating = true
                }
                .disabled(store.busy || store.status == nil)
                .accessibilityIdentifier("mcp-create")
            }
        }
        .task {
            await store.load(api)
            guard !routeQueryConsumed else { return }
            routeQueryConsumed = true
            if let slug = routeQuery["endpoint"], let endpoint = store.status?.endpoints.first(where: { $0.slug == slug }) {
                openTab = SettingsBMCPEndpointDetail.Tab(query: routeQuery["tab"]) ?? .overview
                openEndpoint = endpoint.id
            }
        }
        .navigationDestination(item: $openEndpoint) { id in
            SettingsBMCPEndpointDetail(store: store, endpointId: id, initialTab: openTab)
        }
        .onChange(of: openEndpoint) { _, value in
            // 深链栏目只作用于那一次推入；之后点行进详情一律从概览开始
            if value == nil { openTab = .overview }
        }
        .sheet(isPresented: $creating, onDismiss: {
            if let pendingOpen {
                openEndpoint = pendingOpen
                self.pendingOpen = nil
            }
        }) {
            SettingsBMCPCreateSheet(store: store) { pendingOpen = $0 }
                .sheetFeedback()
        }
    }

    private func list(_ status: API.StatusView) -> some View {
        Form {
            if let error = store.error {
                SettingsFormSection {
                    SettingsBNotice(text: error, tone: .danger).accessibilityIdentifier("mcp-error")
                }
            }

            // 总开关：左边写清地址前缀，右边一个开关（与 Webhook / IM 推送同形态）
            SettingsFormSection {
                Toggle(isOn: Binding(
                    get: { status.enabled },
                    set: { enabled in
                        Task { _ = await store.run(api) { try await api.mcpToggle(body: .init(enabled: enabled)) } }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 MCP 服务")
                        Text("\(status.baseUrl.isEmpty ? "（未配置外部地址）" : status.baseUrl)/mcp/<端点>")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .disabled(store.busy)
                .accessibilityIdentifier("mcp-enabled")
            }

            SettingsFormSection {
                if !status.enabled && !status.endpoints.isEmpty {
                    SettingsBNotice(text: "服务已关闭，下面所有端点一律返回 404。配置与令牌都保留着，打开开关即恢复。", tone: .warn)
                        .accessibilityIdentifier("mcp-disabled-notice")
                }
                if status.endpoints.isEmpty {
                    VStack(spacing: 8) {
                        Text("还没有 MCP 端点").font(.subheadline.weight(.medium))
                        Text("端点是给 AI 客户端用的入口：建一个、勾选要开放的服务，Claude Code 或 Cursor 填上地址和令牌，就能直接查库存、搜资源、管订阅。每个端点的工具目录相互独立。")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("点击右上角加号创建端点。").font(.caption).foregroundStyle(Theme.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mcp-empty")
                } else {
                    ForEach(status.endpoints, id: \.id) { endpoint in
                        row(endpoint)
                    }
                }
            } header: {
                Text("端点")
            } footer: {
                Text("每个端点有独立的访问令牌与工具范围，可供 AI 客户端连接。")
            }

        }
        .settingsBFormStyle()
        .refreshable { await store.load(api) }
    }

    /// 端点行（Web 窄屏卡片）：状态点 + 名称 / 路径 / 服务标签（最多 3）/ 工具数 · 形态 · 最近调用
    private func row(_ endpoint: API.EndpointView) -> some View {
        Button {
            openEndpoint = endpoint.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SettingsBMCPStatusDot(on: endpoint.enabled)
                        Text(endpoint.name).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    Text("/mcp/\(endpoint.slug)").font(.caption.monospaced()).foregroundStyle(Theme.textMuted)
                    Text("\(endpoint.toolCount) 个工具 · \(endpoint.enabled ? "已启用" : "已停用")")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textFaint)
            }
            .contentShape(.rect)
            .opacity(endpoint.enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mcp-endpoint-\(endpoint.slug)")
    }
}
