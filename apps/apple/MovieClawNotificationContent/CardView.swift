import SwiftUI

/// 长按剧卡的展开界面：大图、标题正文、集数格子（见 NotificationViewController）。
///
/// 底色是系统的通知材质（跟着系统深浅色），这里只用语义色，不自己铺底。
struct CardView: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.image {
                hero(image)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.body.isEmpty {
                    Text(model.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, model.grid == nil ? 14 : 10)
            if let grid = model.grid, let cells = EpisodeCells(grid) {
                EpisodeGrid(cells: cells)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
    }

    private func hero(_ image: UIImage) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let playing = model.playing {
                    Text(playing)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }
            }
            .accessibilityHidden(true)
    }
}

/// 一季的格子：第 1 集起每集一个状态
struct EpisodeCells: Equatable {
    enum State: Character, CaseIterable {
        case watched = "s", ready = "d", downloading = "w", missing = "m", other = "-"

        var label: String? {
            switch self {
            case .ready: "已入库"
            case .watched: "看过"
            case .downloading: "下载中"
            case .missing: "没找到"
            case .other: nil
            }
        }
    }

    let states: [State]

    /// 明文里的格子；一集都认不出、或多到画不下（日播剧）时返回 nil
    init?(_ grid: PushPlaintext.Grid) {
        let states = grid.cells.map { State(rawValue: $0) ?? .other }
        guard states.count > 1, states.count <= 200 else { return nil }
        self.states = states
    }

    /// 图例：只列格子里出现了的状态，顺序固定
    var legend: [State] {
        [.ready, .watched, .downloading, .missing].filter(states.contains)
    }
}

struct EpisodeGrid: View {
    let cells: EpisodeCells
    private static let columns = 11

    /// 每行 11 集；最后一行不满时用空位补齐，格子宽度一致
    private var rows: [[Int]] {
        stride(from: 0, to: cells.states.count, by: Self.columns).map { start in
            Array(start..<min(start + Self.columns, cells.states.count))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 不用 LazyVGrid：懒加载的网格量不出真实高度，展开界面会被压成一条
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(rows, id: \.first) { row in
                    GridRow {
                        ForEach(row, id: \.self) { index in
                            EpisodeCell(number: index + 1, state: cells.states[index])
                        }
                        ForEach(row.count..<Self.columns, id: \.self) { _ in
                            Color.clear.frame(height: 20)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(cells.legend, id: \.rawValue) { state in
                    HStack(spacing: 4) {
                        EpisodeCell.swatch(state)
                            .frame(width: 9, height: 9)
                        Text(state.label ?? "")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        cells.legend.map { state in
            "\(state.label ?? "")\(cells.states.filter { $0 == state }.count) 集"
        }.joined(separator: "，")
    }
}

struct EpisodeCell: View {
    let number: Int
    let state: EpisodeCells.State
    @State private var dim = false

    var body: some View {
        Self.swatch(state)
            .frame(height: 20)
            .overlay {
                Text("\(number)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(textStyle)
                    .minimumScaleFactor(0.7)
            }
            .opacity(state == .downloading && dim ? 0.55 : 1)
            .onAppear {
                guard state == .downloading else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }

    private var textStyle: AnyShapeStyle {
        switch state {
        case .ready: AnyShapeStyle(Color(uiColor: .systemBackground))
        case .watched: AnyShapeStyle(.primary)
        case .downloading: AnyShapeStyle(.secondary)
        case .missing: AnyShapeStyle(Color.red)
        case .other: AnyShapeStyle(.tertiary)
        }
    }

    @ViewBuilder
    static func swatch(_ state: EpisodeCells.State) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        switch state {
        case .ready: shape.fill(Color.primary.opacity(0.85))
        case .watched: shape.fill(Color.primary.opacity(0.3))
        case .downloading: shape.fill(Color.primary.opacity(0.12))
        case .missing: shape.strokeBorder(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
        case .other: shape.fill(Color.primary.opacity(0.05))
        }
    }
}
