import SwiftUI

/// 设置 → IM 推送（原「消息推送」，对应 Web `im-push-section.tsx` 的 `ImPushSection`）。
///
/// 只管接了哪些账号（跨平台统一列表 +「新增通道」菜单，绑定流程收进弹层）和测试推送。
/// 推什么在「设置 → 通知」：IM 只是通知的一个渠道（docs/design/cloud-push.md §5）。
struct PushSettingsView: View {
    var body: some View {
        Form {
            SettingsBPushChannelsSections()
        }
        .settingsBFormStyle()
    }
}
