import CoreText
import SwiftUI

/// 欢迎页轮播的一句台词：影史经典电影里最经典的原句，外语片附中文字幕，注明片名与年份。
///
/// 选句口径：美国电影学会「百年百大电影台词」里最广为人知的那些，加上华语与世界影史的名句；
/// 只收能确认原话的句子，基调偏温暖与诗意（欢迎页不放太暗黑的台词）。
/// 首页每次出现时打乱顺序，点一下台词换下一句，不点就定时轮换（见 `WelcomeView`）。
///
/// 为什么不用真实海报/剧照：首次打开时还没连上服务器，拿不到用户自己的片库；
/// 把别人的海报打进开源安装包又有版权问题。短句台词注明出处引用即可。
/// 改了台词要重新跑 `scripts/subset-welcome-font.py`，让宋体子集收进新出现的字。
struct WelcomeScene: Identifiable, Equatable, Decodable {
    var id = 0
    /// 中文（华语片为原句，外语片为字幕）
    let line: String
    /// 外语原句（华语片为空）
    let original: String?
    let film: String
    let filmEnglish: String
    let year: Int
    /// 华语片的英文译句（英文界面用；外语片直接用原句）
    let english: String?

    private enum CodingKeys: String, CodingKey { case line, original, film, filmEnglish, english, year }
}

extension WelcomeScene {
    /// 台词表是内容数据，放在 `WelcomeQuotes.json`（中英两套片名与译句并列）
    static let all: [WelcomeScene] = {
        guard let url = Bundle.main.url(forResource: "WelcomeQuotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let quotes = try? JSONDecoder().decode([WelcomeScene].self, from: data) else { return [] }
        return quotes.enumerated().map { index, quote in
            var scene = quote
            scene.id = index
            return scene
        }
    }()

    private static var chinese: Bool { AppLanguage.identifier == "zh-Hans" }

    /// 大字那一行：中文界面是中文台词；英文界面是原句（华语片用英文译句）
    var headline: String { Self.chinese ? line : original ?? english ?? line }

    /// 小字那一行：中文界面是外语原句；英文界面给华语片附上中文原句
    var subline: String? { Self.chinese ? original : (original == nil ? line : nil) }

    /// 出处：「《卡萨布兰卡》1942」/「Casablanca, 1942」
    var source: String { Self.chinese ? "《\(film)》\(year)" : "\(filmEnglish), \(year)" }
}

extension Font {
    /// 欢迎页的宋体：思源宋体（Noto Serif SC）子集，只含欢迎页用到的字，
    /// 生成方法见 `scripts/subset-welcome-font.py`；子集外的字自动回落到系统字体。
    static func welcomeSerif(size: CGFloat) -> Font {
        _ = WelcomeFont.registered
        return .custom(WelcomeFont.postScriptName, size: size)
    }
}

/// 字体不走 Info.plist 的 UIAppFonts：只有欢迎页用，首次取用时再注册进当前进程即可
private enum WelcomeFont {
    static let postScriptName = "MovieClawWelcomeSerif-Regular"
    static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: "WelcomeSerif", withExtension: "otf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}
