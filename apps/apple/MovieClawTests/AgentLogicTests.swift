import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Testing
@testable import MovieClaw

/// AI 会话模块的纯逻辑：轨迹回放、事件归约、技能 token、Markdown 块级解析、媒体卡片参数
@MainActor
struct AgentLogicTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func transcriptReplayBuildsTurnsAndInterruptedFlag() throws {
        let entries: [AgentEntry] = try decode(#"""
        [
          {"type":"message","message_id":"u1","timestamp":"2026-09-11T15:02:41+00:00","thinking_level":"high","model":null,
           "message":{"role":"user","content":[{"type":"text","text":"这个电影怎么样"},{"type":"image","attachment_id":"a1","name":"图.jpg"}]}},
          {"type":"message","message_id":"m2","timestamp":"2026-09-11T15:02:46+00:00",
           "message":{"role":"assistant","content":[{"type":"thinking","text":"想一想"}],"tool_calls":[{"id":"c1","name":"bash","arguments":{"command":"ls  -la"}}]}},
          {"type":"message","message_id":"m3","timestamp":"2026-09-11T15:02:47+00:00","message":{"role":"tool","tool_call_id":"c1","content":"ok"}},
          {"type":"message","message_id":"m4","timestamp":"2026-09-11T15:02:50+00:00","message":{"role":"assistant","content":"答案"}},
          {"type":"compaction","compaction_id":"k","timestamp":"2026-09-11T15:03:00+00:00","summary":"摘要","tokens_before":9000,"tokens_after":800,"replacement_history":[]},
          {"type":"message","message_id":"u2","timestamp":"2026-09-11T15:05:00+00:00","message":{"role":"user","content":"再来"}},
          {"type":"message","message_id":"m5","timestamp":"2026-09-11T15:05:02+00:00","message":{"role":"assistant","content":[],"tool_calls":[{"id":"c2","name":"mclaw","arguments":{"args":"status"}}]}}
        ]
        """#)
        let turns = AgentTimeline.turns(from: entries)
        #expect(turns.count == 2)
        #expect(turns[0].images == [AgentTurnImage(attachmentId: "a1", name: "图.jpg")])
        #expect(turns[0].thinkingLevel == .some("high"))
        #expect(turns[0].interrupted == false)
        #expect(turns[0].segments.contains(.text("答案")))
        guard case let .process(items) = turns[0].segments.first, case let .tool(tool) = items.last else {
            Issue.record("首段应是处理过程块")
            return
        }
        #expect(tool.output == "ok")
        #expect(tool.summary == "ls -la")
        #expect(AgentTimeline.processSummary(items) == "已思考，执行 1 次命令")
        if case .compaction = turns[0].segments.last {} else { Issue.record("压缩卡片应并入上一轮") }
        // 第二轮没有以无工具调用的正文收尾：已中断
        #expect(turns[1].interrupted)
    }

    @Test func streamEventsReduceIntoTimeline() throws {
        var turn = AgentTurn(id: "t", input: "q", status: .running, startedAt: .now)
        let events: [AgentStreamEvent] = try decode(#"""
        [
          {"type":"thinking_delta","delta":"想"},
          {"type":"tool_call_start","tool_call":{"id":"c1","name":"mclaw"}},
          {"type":"tool_call_delta","tool_call_id":"c1","delta":"{\"args\":"},
          {"type":"tool_call","tool_call":{"id":"c1","name":"mclaw","arguments":{"args":"library list"}}},
          {"type":"tool_result","tool_result":{"tool_call_id":"c1","name":"mclaw","output":"[]","is_error":false,"elapsed_ms":3}},
          {"type":"text_delta","delta":"你好"},
          {"type":"text_delta","delta":"世界"},
          {"type":"agent_done","result":{"elapsed_ms":1234,"steps":2,"usage":{"prompt_tokens":1,"completion_tokens":2}}}
        ]
        """#)
        for event in events { AgentTimeline.apply(event, to: &turn) }
        #expect(turn.status == .done)
        #expect(turn.segments.contains(.text("你好世界")))
        #expect(turn.result?.elapsedMs == 1234)
        guard case let .process(items) = turn.segments.first, case let .tool(tool) = items.last else {
            Issue.record("首段应是处理过程块")
            return
        }
        #expect(tool.label == #"mclaw({"args":"library list"})"#)
        #expect(tool.argsDone == true)
        #expect(tool.output == "[]")
        var cancelled = AgentTurn(id: "x", input: "q", status: .running, startedAt: .now)
        AgentTimeline.apply(try decode(#"{"type":"agent_cancelled"}"#), to: &cancelled)
        #expect(cancelled.stopped && cancelled.status == .done)
    }

    @Test func skillTokensRoundTrip() {
        let expanded = "<skill name=\"diagnose\" location=\"/x/SKILL.md\">\n正文\n</skill>\n\n帮我看看"
        #expect(AgentSkillText.toTokenForm(expanded) == "/skill:diagnose 帮我看看")
        let parsed = AgentSkillText.parseTokens("/skill:diagnose /skill:typo 帮我看看", allow: ["diagnose"])
        #expect(parsed.names == ["diagnose"])
        #expect(parsed.text == "/skill:typo 帮我看看")
        #expect(AgentSkillText.slashQuery(in: "你好 /dia")?.query == "dia")
        #expect(AgentSkillText.slashQuery(in: "a/b") == nil)
        var draft = AgentDraft()
        draft.load("/skill:diagnose 帮我看看")
        #expect(draft.skills == ["diagnose"] && draft.text == "帮我看看")
        #expect(draft.message == "/skill:diagnose 帮我看看")
    }

    @Test func markdownBlocks() {
        let blocks = AgentMarkdownParser.parse("""
        ## 标题
        第一行
        第二行

        - 项一
          - 嵌套
        - [x] 完成

        | 剧集 | 评分 |
        |---|---|
        | 猎犬 | 8.5 |

        ```bash
        ls -la
        ```
        > 引用
        ---
        """)
        #expect(blocks.count == 7)
        #expect(blocks[0] == .heading(level: 2, text: "标题"))
        #expect(blocks[1] == .paragraph("第一行 第二行"))
        if case let .list(ordered, _, items) = blocks[2] {
            #expect(!ordered && items.count == 2)
            #expect(items[1].checked == true)
            if case .list = items[0].blocks.last {} else { Issue.record("嵌套列表应归入第一项") }
        } else { Issue.record("应解析出列表") }
        #expect(blocks[3] == .table(header: ["剧集", "评分"], rows: [["猎犬", "8.5"]]))
        #expect(blocks[4] == .code(language: "bash", text: "ls -la"))
        #expect(blocks[5] == .quote([.paragraph("引用")]))
        #expect(blocks[6] == .rule)
    }

    @Test func markdownImagesBecomeBlocks() {
        let blocks = AgentMarkdownParser.parse("""
        海报如下：![沙丘](https://image.tmdb.org/t/p/w500/a.jpg "标题") 请查看

        ![](/images/assets/1.jpg)
        """)
        #expect(blocks == [
            .paragraph("海报如下："),
            .image(alt: "沙丘", url: "https://image.tmdb.org/t/p/w500/a.jpg"),
            .paragraph("请查看"),
            .image(alt: "", url: "/images/assets/1.jpg"),
        ])
        #expect(AgentMarkdownParser.parse("普通 [链接](https://a.b) 文本") == [.paragraph("普通 [链接](https://a.b) 文本")])
    }

    @Test func attachmentNamesFollowWeb() throws {
        // 压缩/转码后换 .jpg，没有原名兜底「图片」（同 Web compressImage）
        #expect(AgentImageCompressor.jpegName("IMG_0001.HEIC") == "IMG_0001.jpg")
        #expect(AgentImageCompressor.jpegName("截图.png") == "截图.jpg")
        #expect(AgentImageCompressor.jpegName(nil) == "图片.jpg")
        // 小图原样上传保留原名
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        #expect(try AgentImageCompressor.prepare(png, contentType: .png, filename: "a.png").filename == "a.png")
        #expect(try AgentImageCompressor.prepare(png, contentType: .png).filename == "图片.png")
        #expect(try AgentImageCompressor.prepare(png, contentType: .heic, filename: "IMG_1.HEIC").filename == "IMG_1.jpg")
    }

    @Test func mediaCardArgs() throws {
        let args: AgentJSONObject = try decode(#"{"component":"title","title":"你说的这部","items":[{"title_ref":"tmdb:tv:232766"},{"tmdb_id":5,"media_type":"movie"},{"title_ref":"bad"},{"title_ref":"tmdb:tv:232766"}]}"#)
        let group = try #require(AgentMediaCards.parse(name: "show_media_cards_v1", args: args))
        #expect(group.title == "你说的这部")
        #expect(group.cards == [.title(titleRef: "tmdb:tv:232766"), .title(titleRef: "tmdb:movie:5")])
        #expect(AgentMediaCards.parse(name: "show_media_cards_v2", args: args) == nil)
    }

    @Test func subscriptionCardRibbonMarksInLibrary() throws {
        func sub(kind: String, status: String = "active", followFuture: Bool, imported: Int) throws -> API.SubscriptionView {
            try decode(#"""
            {"id":1,"media":{"media_item_id":9,"kind":"\#(kind)","tmdb_id":100,"douban_id":null,"title":"作品","original_title":"Work",
             "year":2024,"poster_url":null,"status":null},
             "status":"\#(status)","selected_seasons":[1],"follow_future":\#(followFuture),"rule_set_id":1,"library_id":null,
             "progress":{"total":10,"wanted":\#(10 - imported),"grabbed":0,"downloaded":0,"imported":\#(imported),"upgrading":0},
             "season_collection":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
            """#)
        }
        let ribbon = AgentMediaCards.subscriptionRibbon
        // 追更中只到了几集：在库时「已入库」压过「自动续订」，不在库仍是「自动续订」
        let tracking = try sub(kind: "tv", followFuture: true, imported: 3)
        #expect(ribbon(tracking, true) == DiscoverRibbon(label: "已入库", tone: .owned))
        #expect(ribbon(tracking, false) == DiscoverRibbon(label: "自动续订", tone: .subscribed))
        // 收齐的说法不被覆盖：剧集仍是「已收齐」
        let completed = try sub(kind: "tv", status: "completed", followFuture: false, imported: 10)
        #expect(ribbon(completed, true) == DiscoverRibbon(label: "已收齐", tone: .owned))
        // 还没入库的电影：不在库没有斜标
        let movie = try sub(kind: "movie", followFuture: false, imported: 0)
        #expect(ribbon(movie, false) == nil)
        #expect(ribbon(movie, true) == DiscoverRibbon(label: "已入库", tone: .owned))
    }

    // MARK: 消息列拆行（段落级懒加载，见 AgentTranscriptRows）

    private func turn(_ id: String, _ segments: [AgentSegment], status: AgentTurn.Status = .done) -> AgentTurn {
        var turn = AgentTurn(id: id, messageId: id, input: "问\(id)", status: status, startedAt: .now)
        turn.segments = segments
        if status == .done { turn.endedAt = .now }
        return turn
    }

    /// 一轮的行，去掉组首的时间行（先核对它：每组一个、标本轮开始时间、与上一轮隔一个轮间距）
    private func groupRows(_ turn: AgentTurn, showsProcess: Bool = AgentTranscriptLayout.showsProcess) -> [AgentTranscriptRow] {
        let rows = AgentTranscriptLayout.rows(for: turn, showsProcess: showsProcess)
        #expect(rows.first == AgentTranscriptRow(id: "\(turn.id).time", content: .time(turn.startedAt), spacing: 28))
        #expect(rows.dropFirst().allSatisfy { if case .time = $0.content { false } else { true } }, "组内其余气泡不再标时间")
        return Array(rows.dropFirst())
    }

    @Test func normalAnswerIsOneWholeBubbleRow() {
        let text = "# 标题\n\n段落一\n\n## 小标题"
        let rows = groupRows(turn("t", [
            .process([.thinking("想"), .tool(AgentToolCall(id: "c", name: "bash", label: "bash"))]),
            .text(text),
            .compaction(summary: "摘要", tokensBefore: 9000, tokensAfter: 800),
        ]), showsProcess: true)
        // 提问（组时间之下 10）→ 处理过程（提问到回答 12）→ 整个气泡一行（段间 8）→ 压缩卡片（段间 8）；正常跑完不出页脚
        // 普通长度的正文不拆行：长按时整个气泡一起浮起，不会只压下按到的那一截
        #expect(rows.map(\.id) == ["t.q", "t.0p", "t.1b0", "t.2z"])
        #expect(rows.map(\.spacing) == [10, 12, 8, 8])
        #expect(rows[2].content == .markdown(
            [.heading(level: 1, text: "标题"), .paragraph("段落一"), .heading(level: 2, text: "小标题")],
            bubble: .init(first: true, last: true, hug: false, gap: 0, text: text),
            streaming: false
        ))
    }

    @Test func longAnswerSlicesIntoOneBubble() {
        let long = String(repeating: "长", count: AgentTranscriptLayout.wholeBubbleMaxChars)
        let text = "# 标题\n\n\(long)\n\n## 小标题"
        let rows = groupRows(turn("t", [.text(text)]))
        // 超长正文按块拆行保懒加载：提问在组时间下 10，首截与提问隔回答间距，后续截紧贴（0）
        #expect(rows.map(\.id) == ["t.q", "t.0b0", "t.0b1", "t.0b2"])
        #expect(rows.map(\.spacing) == [10, 12, 0, 0])
        // 三截拼成一个气泡：首截上圆角、末截下圆角，块间距（0.75em，标题前再加 0.65em）画在气泡里；长按任一截复制整段
        let bubbles: [AgentTranscriptRow.Bubble] = rows.compactMap {
            if case let .markdown(_, bubble, _) = $0.content { return bubble }
            return nil
        }
        #expect(bubbles == [
            .init(first: true, last: false, hug: false, gap: 0, text: text),
            .init(first: false, last: false, hug: false, gap: 12.75, text: text),
            .init(first: false, last: true, hug: false, gap: 12.75 + 17 * 0.65, text: text),
        ])
    }

    @Test func singleBlockAnswerHugsAndStreamingCarriesCursor() {
        let tool = AgentProcessItem.tool(AgentToolCall(id: "c", name: "bash", label: "bash"))
        // 正文是最后一段：光标长在末块里、不再叠三点气泡，前面的处理过程不是进行中；只有一块的气泡贴合内容宽度
        let writing = groupRows(turn("r", [.process([tool]), .text("写到一半")], status: .running), showsProcess: true)
        #expect(writing.map(\.id) == ["r.q", "r.0p", "r.1b0"])
        #expect(writing[1].content == .process(items: [tool], active: false))
        #expect(writing[2].content == .markdown([.paragraph("写到一半")], bubble: .init(first: true, last: true, hug: true, gap: 0, text: "写到一半"), streaming: true))
        // 写完了：同一个气泡，只是不再带光标，下面什么都没有（不出耗时）
        let done = groupRows(turn("d", [.text("写完了")]))
        #expect(done.map(\.id) == ["d.q", "d.0b0"])
        #expect(done[1].content == .markdown([.paragraph("写完了")], bubble: .init(first: true, last: true, hug: true, gap: 0, text: "写完了"), streaming: false))
        // 思考 / 调工具 / 正文段开了头还没字：末尾是三点气泡（代替原来的进度环 + 秒数）
        let working = groupRows(turn("w", [.process([tool])], status: .running), showsProcess: true)
        #expect(working.map(\.id) == ["w.q", "w.0p", "w.t"])
        #expect(working[1].content == .process(items: [tool], active: true))
        #expect(working[2].content == .typing && working[2].spacing == 8)
        let empty = groupRows(turn("e", [.process([tool]), .text("")], status: .running), showsProcess: true)
        #expect(empty.map(\.id) == ["e.q", "e.0p", "e.t"])
        // 刚发出、还什么都没有：三点气泡与提问隔一个回答间距
        let fresh = groupRows(turn("n", [], status: .running))
        #expect(fresh.map(\.content) == [.question(.init(messageId: "n", input: "问n", images: [])), .typing])
        #expect(fresh.map(\.spacing) == [10, 12])
    }

    @Test func transcriptRowsFollowProcessAndFooterRules() throws {
        let args: AgentJSONObject = try decode(#"{"component":"title","items":[{"title_ref":"tmdb:tv:232766"}]}"#)
        let cards = AgentProcessItem.tool(AgentToolCall(id: "m", name: "show_media_cards_v1", label: "", args: args))
        // 只有卡片绘制调用的处理过程：不出折叠头，卡片组直接常显
        let rows = groupRows(turn("c", [.process([cards]), .text("看看这些")]))
        #expect(rows.map(\.id) == ["c.q", "c.0mm", "c.1b0"])
        #expect(rows.map(\.spacing) == [10, 12, 8])
        // 以错误收尾：红色提示，不出页脚
        var failed = turn("x", [], status: .error)
        failed.error = "模型报错"
        #expect(groupRows(failed).map(\.content) == [
            .question(.init(messageId: "x", input: "问x", images: [])), .error("模型报错"),
        ])
    }

    @Test func defaultsHideProcessKeepCardsAndFooterOnlyOnStop() throws {
        let args: AgentJSONObject = try decode(#"{"component":"title","items":[{"title_ref":"tmdb:tv:232766"}]}"#)
        let bash = AgentProcessItem.tool(AgentToolCall(id: "c", name: "bash", label: "bash"))
        let cards = AgentProcessItem.tool(AgentToolCall(id: "m", name: "show_media_cards_v1", label: "", args: args))
        // 默认不显示处理过程胶囊（思维链 + 工具调用），但工具画出的卡片照常显示
        #expect(!AgentTranscriptLayout.showsProcess)
        let rows = groupRows(turn("h", [.process([.thinking("想"), bash, cards]), .text("看看这些")]))
        #expect(rows.map(\.id) == ["h.q", "h.0mm", "h.1b0"])
        #expect(rows.map(\.spacing) == [10, 12, 8])
        // 进行中只有处理过程：提问下面直接是三点气泡
        let working = groupRows(turn("w", [.process([bash])], status: .running))
        #expect(working.map(\.id) == ["w.q", "w.t"])
        // 停止 / 中断才留一行小字，贴近最后一个气泡
        var stopped = turn("s", [.text("写了一半")])
        stopped.stopped = true
        let stoppedRows = groupRows(stopped)
        #expect(stoppedRows.map(\.id) == ["s.q", "s.0b0", "s.f"])
        #expect(stoppedRows.last?.spacing == 6)
    }

    @Test func transcriptViewportMeasuresTheReadableAreaBetweenBars() {
        // iPhone Air 实测：visibleRect 盖住整屏 912pt，顶栏 122、输入区 127 在它里面
        let insets = EdgeInsets(top: 122, leading: 0, bottom: 127, trailing: 0)
        func viewport(_ minY: CGFloat, content: CGFloat = 1_616) -> AgentTranscriptScroll.Viewport {
            AgentConversationView.viewport(contentHeight: content, visible: CGRect(x: 0, y: minY, width: 420, height: 912), insets: insets)
        }
        // 贴底：内容末尾正好落在输入区上沿
        let resting = viewport(831)
        #expect(resting.atBottom && resting.nearBottom && !resting.offscreen)
        // 内容缩短后停在原处：最后一段上移到屏幕中间、下面一片空白——不是贴底，要校正
        let shrunk = viewport(831, content: 1_300)
        #expect(!shrunk.atBottom && !shrunk.offscreen)
        // 内容整个缩进顶栏背后：看着是空白页，算越界
        #expect(viewport(1_400, content: 1_500).offscreen)
        #expect(viewport(-900).offscreen)
        // 往上翻了一点：离底 150pt，给「回到最新」
        let reading = viewport(681)
        #expect(!reading.atBottom && !reading.nearBottom)
        // 不满一屏的短会话由系统锚点摆放，停在哪都算贴底（实测两种偏移）；内容还没出来不算越界
        for minY: CGFloat in [-122, -244] {
            let short = viewport(minY, content: 157)
            #expect(short.atBottom && short.nearBottom && !short.offscreen)
        }
        #expect(!viewport(-122, content: 0).offscreen)
    }

    @Test func composerBottomGapTucksIntoHomeIndicatorOnlyWithoutKeyboard() {
        // 有 Home 指示条（34）、键盘收起：往里收 10，离底边 24
        #expect(AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 34) == -10)
        // 键盘弹起：贴着键盘留 8；没有指示条的机型：照旧 8
        #expect(AgentComposerBottomGap.padding(keyboardShown: true, windowBottomInset: 34) == 8)
        #expect(AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 0) == 8)
    }

    @Test func groupTimeShowsClockTodayAndDateOtherwise() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 22, minute: 5)))
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
        }
        // 今天：只要时分；跨天：月日 + 时分；跨年再带年份
        #expect(AgentTimeline.groupTime(try at(2026, 10, 12, 8, 3), now: now, calendar: calendar) == "08:03")
        #expect(AgentTimeline.groupTime(try at(2026, 10, 11, 23, 59), now: now, calendar: calendar) == "10月11日 23:59")
        #expect(AgentTimeline.groupTime(try at(2025, 12, 31, 9, 0), now: now, calendar: calendar) == "2025年12月31日 09:00")
        // 会话列表：今天时分、昨天、今年月日、更早年/月/日
        #expect(AgentTimeline.listTime(try at(2026, 10, 12, 8, 3), now: now, calendar: calendar) == "08:03")
        #expect(AgentTimeline.listTime(try at(2026, 10, 11, 23, 59), now: now, calendar: calendar) == "昨天")
        #expect(AgentTimeline.listTime(try at(2026, 10, 10, 9, 0), now: now, calendar: calendar) == "10月10日")
        #expect(AgentTimeline.listTime(try at(2025, 12, 31, 9, 0), now: now, calendar: calendar) == "2025/12/31")
    }

    @Test func rowCacheReusesUnchangedTurnsAndZeroesFirstSpacing() {
        let cache = AgentTranscriptRowCache()
        let done = turn("a", [.text("答")])
        var second = turn("b", [.text("第一段")], status: .running)
        let first = cache.rows(turns: [done, second], handoff: nil)
        #expect(first[0].spacing == 0)
        #expect(Set(first.map(\.id)).count == first.count)
        // 流式追加只改第二轮：第一轮的行原样复用，第二轮的气泡多出一个段落
        second.segments = [.text("第一段\n\n第二段")]
        let next = cache.rows(turns: [done, second], handoff: nil)
        #expect(Array(next.prefix(3)) == Array(first.prefix(3)))
        #expect(next.last?.content == .markdown(
            [.paragraph("第一段"), .paragraph("第二段")],
            bubble: .init(first: true, last: true, hug: false, gap: 0, text: "第一段\n\n第二段"),
            streaming: true
        ))
        // 有续接来源时来源卡片在最前，第一轮（从组时间起）与它相距一个轮间距
        let handed = cache.rows(turns: [second], handoff: (sourceId: "s", sourceTitle: "原会话"))
        #expect(handed.map(\.id).prefix(2) == ["handoff", "b.time"])
        #expect(handed[0].spacing == 0 && handed[1].spacing == 28)
    }
}
