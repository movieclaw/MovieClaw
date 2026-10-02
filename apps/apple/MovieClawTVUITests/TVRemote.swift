import XCTest

/// Apple TV 的 UI 自动化只能用遥控器：没有点击，只有方向键、确认键、返回键、播放暂停键。
/// 这里把「把焦点挪到某个元素上再按确认」这类动作包成工具，用例读起来接近人的操作。
@MainActor
enum TVRemote {
    static let remote = XCUIRemote.shared

    static func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0 ..< times {
            remote.press(button)
        }
    }

    /// 沿给定方向一下一下按，直到目标拿到焦点（最多 `limit` 下）
    @discardableResult
    static func focus(_ target: XCUIElement, by direction: XCUIRemote.Button, limit: Int = 12,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = target.waitForExistence(timeout: 15)
        for _ in 0 ..< limit {
            if target.hasFocus { return true }
            remote.press(direction)
        }
        if target.hasFocus { return true }
        XCTFail("按了 \(limit) 下 \(direction) 还没把焦点挪到「\(target.identifier)」上", file: file, line: line)
        return false
    }

    /// 先试一个方向，不行再试另一个（目标在当前焦点的左上 / 右下这类情况）
    @discardableResult
    static func focus(_ target: XCUIElement, trying directions: [XCUIRemote.Button], limit: Int = 12,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = target.waitForExistence(timeout: 15)
        for direction in directions {
            for _ in 0 ..< limit {
                if target.hasFocus { return true }
                remote.press(direction)
            }
        }
        if target.hasFocus { return true }
        XCTFail("没能把焦点挪到「\(target.identifier)」上", file: file, line: line)
        return false
    }

    /// 焦点挪上去再按确认
    static func select(_ target: XCUIElement, by direction: XCUIRemote.Button, limit: Int = 12,
                       file: StaticString = #filePath, line: UInt = #line) {
        if focus(target, by: direction, limit: limit, file: file, line: line) {
            remote.press(.select)
        }
    }

    /// 焦点挪上去再按确认（依次试几个方向）
    static func select(_ target: XCUIElement, trying directions: [XCUIRemote.Button], limit: Int = 12,
                       file: StaticString = #filePath, line: UInt = #line) {
        if focus(target, trying: directions, limit: limit, file: file, line: line) {
            remote.press(.select)
        }
    }

    /// 文本框：焦点挪上去、按确认唤出键盘、输入、确认收起键盘
    static func type(_ text: String, into field: XCUIElement, app: XCUIApplication, by direction: XCUIRemote.Button,
                     file: StaticString = #filePath, line: UInt = #line) {
        guard focus(field, by: direction, file: file, line: line) else { return }
        remote.press(.select)
        // 全屏键盘出现后直接输入（tvOS 的 typeText 发给当前的键盘）
        let keyboard = app.keyboards.firstMatch
        _ = keyboard.waitForExistence(timeout: 5)
        app.typeText(text)
        // 返回键收起键盘、回到表单；等键盘真的退场再往下按，否则方向键会被正在淡出的键盘吃掉
        remote.press(.menu)
        _ = keyboard.waitForNonExistence(timeout: 5)
    }
}

extension XCUIApplication {
    /// 按无障碍标识找任意类型的元素
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}
