//! Local release identity and bundled notices. No account or server data is exposed.
use serde::Serialize;

#[derive(Serialize)]
pub struct Component {
    name: &'static str,
    source: &'static str,
    text: &'static str,
}
#[derive(Serialize)]
pub struct AboutInfo {
    version: &'static str,
    revision: &'static str,
    components: Vec<Component>,
}

#[tauri::command]
pub fn get_about_info() -> AboutInfo {
    AboutInfo {
        version: env!("CARGO_PKG_VERSION"),
        revision: env!("MOVIECLAW_BUILD_REVISION"),
        components: vec![
            Component { name: "mpv / FFmpeg — 版权与源码", source: "https://github.com/shinchiro/mpv-winbuild-cmake/tree/b2856ee6deed6957380b32465f359e67f67fafd8", text: include_str!("../../scripts/licenses/MPV-Copyright.txt") },
            Component { name: "mpv — GPL", source: "https://github.com/mpv-player/mpv/tree/b2c255c13e8e37952dbac6c34da56a690560378b", text: include_str!("../../scripts/licenses/MPV-GPL.txt") },
            Component { name: "mpv — LGPL", source: "https://github.com/mpv-player/mpv/tree/b2c255c13e8e37952dbac6c34da56a690560378b", text: include_str!("../../scripts/licenses/MPV-LGPL.txt") },
            Component { name: "Vulkan Loader — Apache 2.0", source: "https://github.com/KhronosGroup/Vulkan-Loader/tree/fa218055ff4948b159f31d43f800c808a13d51df", text: include_str!("../../scripts/licenses/Vulkan-Apache-2.0.txt") },
            Component { name: "hls.js — Apache 2.0", source: "https://github.com/video-dev/hls.js", text: include_str!("../../scripts/licenses/HLS-Notice.txt") },
            Component { name: "JASSUB — JavaScript MIT / 原生依赖许可", source: "https://github.com/ThaUnknown/jassub", text: concat!("JASSUB 的原生依赖许可：LGPL-2.1-or-later AND (FTL OR GPL-2.0-or-later) AND MIT AND MIT-Modern-Variant AND ISC AND NTP AND Zlib AND BSL-1.0。组件源码及构建配置见源码地址。\n\nJavaScript 部分：\n", include_str!("../../scripts/licenses/JASSUB-MIT.txt")) },
            Component { name: "QR Code generator — MIT", source: "https://github.com/nayuki/QR-Code-generator", text: include_str!("../../scripts/licenses/QR-MIT.txt") },
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn about_contains_release_identity_and_readable_bundled_notices() {
        let info = get_about_info();
        assert_eq!(info.version, "1.0.0");
        assert!(info.revision == "unknown" || info.revision.len() == 40);
        assert_eq!(info.components.len(), 7);
        assert!(info.components.iter().all(|component| component.source.starts_with("https://github.com/") && component.text.len() > 500));
        assert!(info.components[1].text.contains("GNU GENERAL PUBLIC LICENSE"));
    }
}
