import Nuke
import SwiftUI

/// 海报墙右侧索引条的一档（docs/design/tvos-app.md §3.1）
struct TVWallIndexEntry: Hashable, Identifiable {
    /// 档名：首字母（A–Z / #）、年份（2023）、年代（1990s）、评分档（9+ / 更低 / 未评分）
    let key: String
    /// 索引条上写的字（「S」「2023」「90s」「<7」）
    let label: String
    /// 位置提示与预览气泡里的大字（「S」「2023」「1990 年代」「7 分以下」）
    let title: String
    /// 这一档有几部；0 = 空档（压暗、跳不过去）
    let count: Int
    /// 这一档第一部在整份排序里的位置（`/items?offset=`）；空档为 nil
    let offset: Int?

    var id: String { key }
}

/// 服务端跳转索引（`item-index`）→ 电视的索引条
enum TVWallIndex {
    /// 有索引条的排序：按标题（首字母）、按上映（年份）、按评分（分数档）；按添加时间没有有意义的分档
    static func supports(_ sort: String) -> Bool {
        ["title", "release_date", "rating"].contains(sort)
    }

    static func entries(sort: String, reversed: Bool, raw: [API.LibraryIndexEntryView]) -> [TVWallIndexEntry] {
        switch sort {
        case "title": letters(reversed: reversed, raw: raw)
        case "release_date": years(reversed: reversed, raw: raw)
        case "rating": ratings(raw)
        default: []
        }
    }

    /// 整份排序里第 offset 部落在哪一档（档按排序先后排好，取起点不超过 offset 的最后一档）
    static func entry(at offset: Int, in entries: [TVWallIndexEntry]) -> TVWallIndexEntry? {
        entries.filter { ($0.offset ?? .max) <= offset }.max { ($0.offset ?? 0) < ($1.offset ?? 0) }
    }

    /// 按标题：A–Z 加 #（# 在最后，同服务端的排序）全部列出，库里没有的字母压暗——字母表不缺字，按上下找字母不会忽然跳过一截
    private static func letters(reversed: Bool, raw: [API.LibraryIndexEntryView]) -> [TVWallIndexEntry] {
        let found = Dictionary(raw.map { ($0.initial, $0) }, uniquingKeysWith: { first, _ in first })
        var keys = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#".map(String.init)
        if reversed { keys.reverse() }
        return keys.map { key in
            TVWallIndexEntry(key: key, label: key, title: key, count: found[key]?.count ?? 0, offset: found[key]?.offset)
        }
    }

    /// 按上映：每年一档，2000 年以前按年代并成一档（几千部的库按年能有六七十档，遥控器选不过来）；
    /// 从最新一年到最早一年逐年列出，中间没片的年份压暗。服务端回的是按年还是按月（旧服务端）都一样：
    /// 档位在排好的序列上是连续的，同一年的几档挨在一起，并起来时部数相加、起点取最前
    private static func years(reversed: Bool, raw: [API.LibraryIndexEntryView]) -> [TVWallIndexEntry] {
        var groups: [String: (count: Int, offset: Int)] = [:]
        var unknown: (count: Int, offset: Int)?
        for entry in raw {
            guard let year = Int(entry.initial.prefix(4)) else {
                // 「未知」：没有上映日期的，服务端排在最后
                unknown = (count: (unknown?.count ?? 0) + entry.count, offset: min(unknown?.offset ?? entry.offset, entry.offset))
                continue
            }
            let key = year >= 2000 ? String(year) : "\(year / 10 * 10)s"
            let current = groups[key]
            groups[key] = (count: (current?.count ?? 0) + entry.count, offset: min(current?.offset ?? entry.offset, entry.offset))
        }
        let years = groups.keys.compactMap { Int($0) }
        var keys: [String] = []
        if let newest = years.max(), let oldest = years.min() {
            keys = (oldest...newest).reversed().map(String.init)
        }
        keys += groups.keys.filter { $0.hasSuffix("s") }.sorted(by: >)
        if reversed { keys.reverse() }
        var entries = keys.map { key in
            let group = groups[key]
            let decade = key.hasSuffix("s")
            return TVWallIndexEntry(key: key,
                                    label: decade ? String(key.dropFirst(2)) : key,
                                    title: decade ? "\(key.dropLast()) 年代" : key,
                                    count: group?.count ?? 0, offset: group?.offset)
        }
        if let unknown {
            entries.append(TVWallIndexEntry(key: "unknown", label: "?", title: "未知年份", count: unknown.count, offset: unknown.offset))
        }
        return entries
    }

    /// 按评分：服务端给几档就几档（9+ / 8+ / 7+ / 更低 / 未评分）
    private static func ratings(_ raw: [API.LibraryIndexEntryView]) -> [TVWallIndexEntry] {
        raw.map { entry in
            let (label, title): (String, String) = switch entry.initial {
            case "9+": ("9+", "9 分以上")
            case "8+": ("8+", "8 分以上")
            case "7+": ("7+", "7 分以上")
            case "更低": ("<7", "7 分以下")
            case "未评分": ("—", "未评分")
            default: (entry.initial, entry.initial)
            }
            return TVWallIndexEntry(key: entry.initial, label: label, title: title, count: entry.count, offset: entry.offset)
        }
    }
}

/// 海报墙的图片预取。请求与 `RemoteImage` 里的写法一致（同一个 URL、不加处理器），才会命中同一条缓存
@MainActor
enum TVWallPrefetch {
    /// 新到的一页：只下到磁盘缓存——一页 60 张海报都解码进内存太占
    private static let disk = ImagePrefetcher(pipeline: .shared, destination: .diskCache, maxConcurrentRequestCount: 4)
    /// 焦点往下走时接下来三排：解码进内存，滚到屏幕上时当场出图、不闪占位底
    private static let memory = ImagePrefetcher(pipeline: .shared, destination: .memoryCache, maxConcurrentRequestCount: 4)

    static func page(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        disk.startPrefetching(with: urls)
    }

    static func ahead(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        memory.startPrefetching(with: urls)
    }
}
