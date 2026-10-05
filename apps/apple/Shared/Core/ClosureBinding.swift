import SwiftUI

/// `Binding(get:set:)` 的替身：`Binding(mcGet: { … }, set: { … })`，读写语义完全相同。
///
/// 为什么不直接用 `Binding(get:set:)`：iOS 26 SDK 里它的两个闭包都是 `@isolated(any) @Sendable`，
/// 编译器要为每种 Value 生成一个重抽象 thunk。Xcode 26.x 自带的 Swift 6.3 在 Release（-O、整模块优化）
/// 下生成 `String` 那个 thunk 时 IRGen 直接崩溃（`SyncCallEmission::setArgs` 越界），
/// 发版 CI 因此编不出 IPA（2026-09-29，本机 Xcode 27 不崩）。
///
/// 这里改走 `ObservedObject` 的 keyPath 投影：Binding 读写的是一个引用盒子的计算属性，
/// 盒子再转调闭包——全程不产生 `@isolated(any)` 闭包，绕开编译器缺陷。
/// 新代码一律用本方法，别再写 `Binding(get:set:)`。等 CI 的 Xcode 修好这个问题后可以换回。
extension Binding {
    init(mcGet get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self = ObservedObject(wrappedValue: ClosureBindingBox(get: get, set: set)).projectedValue.value
    }
}

/// 转调读写闭包的引用盒子。只作 keyPath 的落点，不发变更通知——
/// 视图刷新仍由闭包背后的真实状态（@State / @Observable）驱动，与 `Binding(get:set:)` 一致。
private final class ClosureBindingBox<Value>: ObservableObject {
    private let getter: () -> Value
    private let setter: (Value) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get
        setter = set
    }

    var value: Value {
        get { getter() }
        set { setter(newValue) }
    }
}
