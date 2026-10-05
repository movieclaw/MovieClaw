import Foundation

/// 发现模块里依赖 iPhone 路由表的部分（数据模型在 Shared/Discover，Apple TV 有自己的路由）
extension CollectionRef {
    /// 「查看完整榜单」的路由
    var route: AppRoute { .discoverCollection(kind: mediaType, provider: provider, collectionId: collectionId) }
}
