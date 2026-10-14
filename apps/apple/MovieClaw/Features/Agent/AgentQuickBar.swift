import SwiftUI

/// 「我的」页的 AI 快捷输入：未展开时保持一行小入口；展开后与会话页共用完整输入框，
/// 上方输入文字，下方加号、模型 / 思维链、发送，沿用上次选择（AgentComposerPrefs）。发送 = 新建会话并进入。
///
/// 展开与收起都在「我的」导航栈的安全区内完成，共用一个玻璃背板；
/// 不在页面输入框与全局标签栏附件之间交换视图，切页时不会留下附件的背景层。
@Observable
@MainActor
final class AgentQuickDraft {
    /// 切页时保留草稿、图片和技能，下次回到快捷输入时继续。
    var draft = AgentDraft()
    /// 正在打字：同一个容器内展开完整输入框
    var editing = false
    var sending = false
    var askingConsent = false
    var consentProviders: [String] = []
    var modelOptions: [API.LlmModelOptionView] = []
    var choice = AgentComposerPrefs.load()

    var canSend: Bool { !draft.isEmpty && !sending }

    func loadModels(api: APIClient) async {
        applyModelOptions(await AgentCatalog.modelOptions(api: api))
    }

    func applyModelOptions(_ options: [API.LlmModelOptionView]) {
        modelOptions = options
        choice = AgentComposerPrefs.load().reconciled(with: options)
    }

    func chooseModel(_ ref: String?) {
        choice = AgentComposerPrefs(model: ref, thinking: nil).reconciled(with: modelOptions)
        choice.save()
    }

    func chooseThinking(_ level: String?) {
        choice.thinking = level
        choice = choice.reconciled(with: modelOptions)
        choice.save()
    }

    /// 收起或离开「我的」只结束编辑，草稿与模型选择留到下次展开。
    func endEditing() {
        editing = false
    }

    /// 第一次发给 AI 前先说明去向、取得同意（AgentAIConsent），同新会话页
    func submit(api: APIClient, router: Router, feedback: Feedback) {
        guard canSend else { return }
        guard AgentAIConsent.granted else {
            Task {
                consentProviders = AgentAIConsent.providers(await AgentCatalog.modelOptions(api: api))
                askingConsent = true
            }
            return
        }
        send(api: api, router: router, feedback: feedback)
    }

    func send(api: APIClient, router: Router, feedback: Feedback) {
        let message = draft.message
        let images = draft.images.map { AgentTurnImage(attachmentId: $0.attachmentId, name: $0.name) }
        let selected = choice
        sending = true
        Task {
            defer { sending = false }
            do {
                let choice = selected.reconciled(with: await AgentCatalog.modelOptions(api: api))
                let id = try await AgentConversationRegistry.start(
                    api: api, input: message, images: images, thinking: choice.thinking, model: choice.model
                )
                draft.clear()
                editing = false
                router.push(.session(id: id))
            } catch {
                feedback.error(error)
            }
        }
    }
}

/// 页面内的快捷输入容器：一块玻璃只改变高度，始终跟随键盘和底部安全区。
struct AgentQuickInput: View {
    let quick: AgentQuickDraft

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback

    var body: some View {
        @Bindable var quick = quick
        AgentComposer(
            draft: $quick.draft,
            placeholder: "给 AI 助手发消息",
            busy: quick.sending,
            expansion: $quick.editing,
            modelOptions: quick.modelOptions,
            modelValue: quick.choice.model,
            onModelChange: quick.chooseModel,
            thinkingValue: quick.choice.thinking,
            onThinkingChange: quick.chooseThinking,
            onSubmit: { quick.submit(api: api, router: router, feedback: feedback) }
        )
        .padding(.horizontal, AgentQuickInput.sideInset)
        .padding(.bottom, AgentQuickInput.bottomGap)
        .task { await quick.loadModels(api: api) }
        .onDisappear { quick.endEditing() }
    }

    /// 展开后与会话页输入框使用相同的左右留白。
    static let sideInset: CGFloat = 12
    static let bottomGap: CGFloat = 8
}

/// 首次发送前的同意说明：挂在常驻的标签栏层上（附件上的发送键不经真输入框也能发）
struct AgentQuickConsentModifier: ViewModifier {
    let quick: AgentQuickDraft?

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { quick?.askingConsent ?? false }, set: { quick?.askingConsent = $0 })) {
            if let quick {
                AgentAIConsentSheet(providers: quick.consentProviders) {
                    quick.send(api: api, router: router, feedback: feedback)
                }
            }
        }
    }
}
