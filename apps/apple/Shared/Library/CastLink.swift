import Foundation

/// 详情页演职员卡按下去去哪（iPhone / iPad、Apple TV、Mac 共用这一条判断，同网页 `cast-row.tsx`）。
///
/// - 有 TMDB 影人 id：影人页（原有行为不变）；
/// - 没有影人 id 的**演员**（本地/NFO 库只有姓名）：同库按演员名筛的海报墙，看「他在这个库里的其他作品」；
/// - 没有影人 id 的导演：不跳——后端按演员表筛，导演点进去会是空墙。
nonisolated enum CastLink: Hashable, Sendable {
    case person(tmdbId: Int)
    case libraryActor(libraryId: Int, actor: String)

    /// nil = 静态卡（按下不跳转）。演员名去首尾空白，空白名同样不跳
    static func resolve(personId: Int?, name: String, isActor: Bool, libraryId: Int) -> CastLink? {
        if let personId { return .person(tmdbId: personId) }
        guard isActor, let actor = LibraryFilter.normalizedActor(name) else { return nil }
        return .libraryActor(libraryId: libraryId, actor: actor)
    }

    /// 落到同库按演员筛的墙（无障碍说明「在本库查看 X 的作品」用）
    var opensLibrary: Bool {
        switch self {
        case .person: false
        case .libraryActor: true
        }
    }
}
