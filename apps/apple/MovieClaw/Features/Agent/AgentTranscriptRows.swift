import SwiftUI

// 会话消息列的「行」：懒加载列表（LazyVStack）的最小单位。
//
// 为什么不按「一轮」懒加载：一轮对话常有几千 pt 高（长回答、表格、代码），懒加载只能整行进行，
// 进页面定位到底部时要把最后一两轮整块构建、排版——模拟器实测主线程一口气冻住 0.4～0.7 秒，
// 录屏里这段时间一帧都没有（2026-09-27，4 个最长会话点开到看到字 0.8～1.3 秒，约 75% 耗在这里）。
// 拆成段落级的行（提问气泡 / 处理过程 / 卡片组 / 每个 Markdown 块 / 页脚）之后，屏幕外的段落
// 既不构建也不排版，进页面只处理最底下的一屏。
//
// 气泡式呈现（仿个人助理）：一个正文段是一个助手气泡。普通长度的正文整段占一行——长按时整个气泡一起
// 压下浮起（拆成几截的话系统只压按到的那一截，看着像裂开，2026-10-12 用户真机发现）；超长正文才按块拆行，
// 每行画气泡的一截——首截带上圆角、末截带下圆角，块间距画在气泡底色里（行与行之间不留缝），懒加载照旧按块进行。
//
// 行由轮次派生、按轮缓存（`AgentTranscriptRowCache`）：流式输出时只有正在生成的那一轮重新拆行，
// 历史轮次原样复用；每行的视图是 Equatable 的，没变的行不重绘。
// 间距摊到每行的 `spacing` 上（轮与轮之间 28、提问到回答 12、气泡/卡片之间 8）；气泡内 Markdown 块之间
// 0.75em、标题前再多 0.65em，记在气泡截的 `gap` 里。

/// 消息列的一行
struct AgentTranscriptRow: Identifiable, Equatable {
    /// 提问气泡要的字段（不整轮携带：流式时这一轮在变，气泡本身没变，不该跟着重绘）
    struct Question: Equatable {
        var messageId: String?
        var input: String
        var images: [AgentTurnImage]
    }

    /// 助手气泡的一截（一个正文段 = 一个气泡；超长时按 Markdown 块拆成多行，否则整个气泡就是唯一的一截）
    struct Bubble: Equatable {
        var first: Bool
        var last: Bool
        /// 整个气泡只有一块：贴合内容宽度（短回复不拉满整行）；多块的各截必须同宽，一律铺满
        var hug: Bool
        /// 与上一截之间的块间距，画在气泡底色里；首截为 0
        var gap: CGFloat
        /// 整个气泡的正文：长按任意一截复制的都是整段
        var text: String
    }

    enum Content: Equatable {
        /// 从旧会话续开的来源卡片（整列第一行）
        case handoff(sourceId: String, sourceTitle: String?)
        /// 一组对话（一次提问 + 它的全部回复）顶部居中的时间，组内的气泡不再各自标时间
        case time(Date)
        case question(Question)
        case process(items: [AgentProcessItem], active: Bool)
        /// 生成式 UI 的卡片组，紧跟在所属处理过程块之后常显
        case mediaCards(AgentMediaCardGroup)
        /// 正文块（整个气泡或其中一截）；streaming = 正在生成的末截，尾部带呼吸光标
        case markdown([AgentMarkdownBlock], bubble: Bubble, streaming: Bool)
        /// 本轮进行中、正文没在流式输出（思考、调工具、等下一步）：「正在输入」的三点气泡
        case typing
        case compaction(summary: String, tokensBefore: Int?, tokensAfter: Int?)
        case error(String)
        case footer(AgentTurn)
    }

    let id: String
    let content: Content
    /// 与上一行之间的间距
    var spacing: CGFloat

    var isQuestion: Bool {
        if case .question = content { return true }
        return false
    }
}

/// 轮次 → 行的拆分规则（纯函数，单元测试见 AgentLogicTests）
enum AgentTranscriptLayout {
    /// 回答正文字号（同 AgentMarkdownView 的阅读档）
    static let textSize: CGFloat = 17
    static let turnSpacing: CGFloat = 28
    /// 组时间到提问气泡
    static let timeSpacing: CGFloat = 10
    static let answerSpacing: CGFloat = 12
    /// 气泡、卡片、处理过程之间
    static let segmentSpacing: CGFloat = 8
    static let footerSpacing: CGFloat = 6
    /// 正文不超过这么多字就整段一个行（一个完整气泡）；超过才按块拆行保懒加载——
    /// 长回答整块排版会冻住主线程（见文件头），普通回答一屏左右，整块排版无感
    static let wholeBubbleMaxChars = 1500
    /// 是否显示处理过程胶囊（思维链 + 工具调用）。2026-10-12 用户要求先隐藏、代码保留，改回 true 即恢复；
    /// 工具产出的媒体卡片不受影响
    nonisolated static let showsProcess = false

    /// 一轮拆成行。首行（组时间）的间距按「与上一轮之间」给，整列第一行由调用方清零。
    /// 行 id = 轮 id + 段序号 + 块序号：流式追加时已有的行 id 不变，只有末尾的行内容在变。
    static func rows(for turn: AgentTurn, showsProcess: Bool = showsProcess) -> [AgentTranscriptRow] {
        var rows = [
            AgentTranscriptRow(id: "\(turn.id).time", content: .time(turn.startedAt), spacing: turnSpacing),
            AgentTranscriptRow(
                id: "\(turn.id).q",
                content: .question(.init(messageId: turn.messageId, input: turn.input, images: turn.images)),
                spacing: timeSpacing
            ),
        ]
        var gap = answerSpacing
        func add(_ suffix: String, _ content: AgentTranscriptRow.Content) {
            rows.append(AgentTranscriptRow(id: "\(turn.id).\(suffix)", content: content, spacing: gap))
            gap = segmentSpacing
        }

        // 正文正在流式输出：气泡里已有光标，不再叠一个三点气泡
        var streamingText = false
        for (index, segment) in turn.segments.enumerated() {
            let active = turn.isRunning && index == turn.segments.count - 1
            switch segment {
            case let .process(items):
                if showsProcess, !AgentProcessBlock.visibleItems(items).isEmpty {
                    add("\(index)p", .process(items: items, active: active))
                }
                for entry in AgentMediaCards.groups(in: items) {
                    add("\(index)m\(entry.id)", .mediaCards(entry.group))
                }
            case let .text(text):
                let blocks = AgentMarkdownParser.parse(text)
                let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
                streamingText = active && !blocks.isEmpty
                if !blocks.isEmpty, whole.count <= wholeBubbleMaxChars {
                    // 行 id 与拆行时的首截相同：流式写长了改拆行时，首行身份不变
                    let bubble = AgentTranscriptRow.Bubble(first: true, last: true, hug: blocks.count == 1, gap: 0, text: whole)
                    add("\(index)b0", .markdown(blocks, bubble: bubble, streaming: active))
                } else {
                    for (b, block) in blocks.enumerated() {
                        let bubble = AgentTranscriptRow.Bubble(
                            first: b == 0,
                            last: b == blocks.count - 1,
                            hug: false,
                            gap: b == 0 ? 0 : textSize * 0.75 + (block.isHeading ? textSize * 0.65 : 0),
                            text: whole
                        )
                        // 气泡的后续截紧贴上一截，间距在气泡里面
                        if b > 0 { gap = 0 }
                        add("\(index)b\(b)", .markdown([block], bubble: bubble, streaming: active && bubble.last))
                    }
                }
            case let .compaction(summary, before, after):
                add("\(index)z", .compaction(summary: summary, tokensBefore: before, tokensAfter: after))
            }
        }

        if turn.status == .error, let error = turn.error {
            add("e", .error(error))
        }
        if turn.isRunning {
            if !streamingText { add("t", .typing) }
        } else if AgentTurnFooter.hasContent(turn) {
            // 页脚是最后一个气泡的附注，贴近一点（还没有回答时照常与提问隔开）
            if rows.count > 2 { gap = footerSpacing }
            add("f", .footer(turn))
        }
        return rows
    }
}

/// 按轮缓存拆好的行：轮次没变就原样复用，流式时只有正在生成的那一轮重新拆
final class AgentTranscriptRowCache {
    private var cache: [String: (turn: AgentTurn, rows: [AgentTranscriptRow])] = [:]

    func rows(turns: [AgentTurn], handoff: (sourceId: String, sourceTitle: String?)?) -> [AgentTranscriptRow] {
        var result: [AgentTranscriptRow] = []
        if let handoff {
            result.append(AgentTranscriptRow(id: "handoff", content: .handoff(sourceId: handoff.sourceId, sourceTitle: handoff.sourceTitle), spacing: 0))
        }
        for turn in turns {
            if let hit = cache[turn.id], hit.turn == turn {
                result.append(contentsOf: hit.rows)
            } else {
                let rows = AgentTranscriptLayout.rows(for: turn)
                cache[turn.id] = (turn, rows)
                result.append(contentsOf: rows)
            }
        }
        // 改写重问会整段替换后面的轮次：清掉已不存在的轮，免得缓存越积越多
        if cache.count > turns.count {
            let alive = Set(turns.map(\.id))
            cache = cache.filter { alive.contains($0.key) }
        }
        if !result.isEmpty { result[0].spacing = 0 }
        return result
    }
}

/// 一行的视图。Equatable：没变的行跳过重绘（流式时只有末尾几行在变）
struct AgentTranscriptRowView: View, Equatable {
    let row: AgentTranscriptRow
    let sessionId: String
    /// 已知技能名（小写）；nil = 名单未就绪。只有提问气泡用得到
    let knownSkills: Set<String>?
    /// 改写重问（messageId, 原文）；nil = 运行中不给入口。只有提问气泡用得到
    let onEdit: ((String, String) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.row == rhs.row, lhs.sessionId == rhs.sessionId else { return false }
        // 技能名单晚到、运行状态切换只影响提问气泡，其余行不跟着整列重绘
        guard lhs.row.isQuestion else { return true }
        return lhs.knownSkills == rhs.knownSkills && (lhs.onEdit == nil) == (rhs.onEdit == nil)
    }

    var body: some View {
        switch row.content {
        case let .handoff(sourceId, sourceTitle):
            AgentHandoffCard(sourceId: sourceId, sourceTitle: sourceTitle)
        case let .time(date):
            Text(AgentTimeline.groupTime(date))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("agent-group-time")
        case let .question(question):
            AgentUserBubble(
                text: question.input,
                images: question.images,
                sessionId: sessionId,
                knownSkills: knownSkills,
                onEdit: onEdit.flatMap { edit in question.messageId.map { id in { edit(id, question.input) } } }
            )
        case let .process(items, active):
            AgentProcessBlock(items: items, active: active)
        case let .mediaCards(group):
            AgentMediaCardsBlock(group: group)
        case let .markdown(blocks, bubble, streaming):
            AgentAnswerBubbleSlice(bubble: bubble) {
                VStack(alignment: .leading, spacing: 6) {
                    if let only = blocks.first, blocks.count == 1 {
                        // 单块不走 AgentMarkdownBlocks：它会铺满整行，短回复的气泡就不贴合内容了
                        AgentMarkdownBlockView(block: only, size: AgentTranscriptLayout.textSize)
                    } else {
                        AgentMarkdownBlocks(blocks: blocks, size: AgentTranscriptLayout.textSize)
                    }
                    if streaming { AgentStreamingCursor() }
                }
            }
        case .typing:
            AgentTypingBubble()
        case let .compaction(summary, before, after):
            AgentCompactionCard(summary: summary, tokensBefore: before, tokensAfter: after)
        case let .error(message):
            AgentTurnErrorView(message: message)
        case let .footer(turn):
            AgentTurnFooter(turn: turn)
        }
    }
}
