import SwiftUI

/// 模型接入：列表展示供应商状态，连接信息与操作放入详情。
/// 保存后服务端异步测试连接；只有待测试 / 测试中时每两秒刷新。
struct LLMSettingsView: View {
    /// 表单打开参数：provider 为 nil = 新建
    private struct SettingsBLLMEditing: Identifiable {
        let id = UUID()
        var provider: API.LlmProviderView?
    }

    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @State private var providers: [API.LlmProviderView]?
    @State private var presets: [API.LlmPresetView] = []
    @State private var error: String?
    @State private var editing: SettingsBLLMEditing?
    /// 任一卡片操作进行中：禁用全部卡片按钮（同 Web busy）
    @State private var busy = false
    @State private var selectedProvider: Int?

    private var inProgress: Bool {
        providers?.contains { SettingsBLLMStatus.inProgress($0.status) } ?? false
    }

    var body: some View {
        Form {
            if let error {
                SettingsFormSection {
                    SettingsBNotice(text: error, tone: .danger)
                        .accessibilityIdentifier("llm-error")
                }
            }
            if let providers {
                if providers.isEmpty {
                    emptySection
                } else {
                    SettingsFormSection {
                        ForEach(providers, id: \.id) { provider in
                            Button { selectedProvider = provider.id } label: {
                                HStack(spacing: 12) {
                                    SettingsBDot(tone: SettingsBLLMStatus.tone(provider.status), size: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(provider.name).foregroundStyle(Theme.text)
                                        Text(SettingsBLLMStatus.label(provider.status))
                                            .font(.caption).foregroundStyle(Theme.textMuted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                            .accessibilityIdentifier("llm-provider-\(provider.id)")
                        }
                    } header: { Text("模型供应商") } footer: { Text(introText) }

                }
            } else {
                SettingsFormSection {
                    ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("loading")
                }
            }
        }
        .settingsBFormStyle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("接入模型供应商", systemImage: "plus") { editing = SettingsBLLMEditing() }
                    .disabled(busy || presets.isEmpty)
                    .accessibilityIdentifier("llm-create")
            }
        }
        .navigationDestination(item: $selectedProvider) { id in
            if let provider = providers?.first(where: { $0.id == id }) {
                SettingsBLLMProviderCard(
                    provider: provider, preset: presets.first { $0.id == provider.providerType }, busy: busy,
                    error: error,
                    onEdit: { editing = SettingsBLLMEditing(provider: provider) },
                    onReverify: { await reverify(provider) }, onDelete: { await remove(provider) }
                )
            }
        }
        .task { await initialLoad() }
        // 只有实例处于中间态时才真的请求；间隔每轮重新取值
        .polling(every: inProgress ? 2 : 10) {
            guard inProgress else { return }
            // 轮询失败静默重试，不打断页面
            if let list = try? await api.llmProvidersList() { providers = list }
        }
        .refreshable { await initialLoad() }
        .sheet(item: $editing) { target in
            SettingsBLLMProviderForm(
                provider: target.provider,
                presets: presets,
                // 其它实例已占用的名字：留空按供应商名保存时据此加序号，避免撞唯一名
                takenNames: (providers ?? []).filter { $0.id != target.provider?.id }.map(\.name)
            ) {
                Task { await load() }
            }
            .sheetFeedback()
        }
    }

    private var introText: String {
        guard let providers else { return "加载中…" }
        return providers.isEmpty
            ? "接入一个或多个大语言模型供应商，AI 能力（对话助手、字幕处理、智能识别等）将由它们驱动。"
            : "接入后该供应商目录里的全部模型都可在对话框里选用；各场景默认用哪个模型，在「AI 设定」里配置。"
    }

    /// 空态：一个都没接入
    private var emptySection: some View {
        SettingsFormSection {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 14))
                Text("还没有接入模型供应商").font(.body.weight(.medium))
                Text("支持 OpenAI、阿里云百炼，以及任何 OpenAI 兼容端点（如自建 vLLM / Ollama）。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                Button {
                    editing = SettingsBLLMEditing()
                } label: {
                    Text("接入模型供应商").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .discoverProminentButton()
                .disabled(presets.isEmpty)
                .accessibilityIdentifier("llm-create-empty")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 数据

    private func initialLoad() async {
        do {
            async let loadedPresets = api.llmPresets()
            async let loadedProviders = api.llmProvidersList()
            let (presets, providers) = try await (loadedPresets, loadedProviders)
            self.presets = presets
            self.providers = providers
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            if providers == nil { providers = [] }
        }
    }

    private func load() async {
        do {
            providers = try await api.llmProvidersList()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            if providers == nil { providers = [] }
        }
    }

    private func reverify(_ provider: API.LlmProviderView) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await api.llmProvidersVerify(providerId: provider.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ provider: API.LlmProviderView) async {
        guard await feedback.confirm(
            "删除「\(provider.name)」？",
            message: "它目录里的模型将不可再选；AI 设定中指向它的默认模型会自动兜底到其它已接入的供应商。",
            confirmTitle: "删除",
            destructive: true
        ) else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await api.llmProvidersDelete(providerId: provider.id)
            selectedProvider = nil
            LLMCapabilityProbe.shared.invalidate()
            AgentCatalog.invalidateModels()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
