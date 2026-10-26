
---

### Verification scope / 验证范围

These packages passed Desktop CI: browser E2E, native Rust/HTTP and player checks, install/startup/uninstall smoke and hosted-VM performance checks. Hosted CI does not cover physical GPU/HDR, audio passthrough, multi-monitor DPI, optical-disc playback or Windows/macOS hardware equivalence. The actual signature status is recorded in `release-manifest.json`; unsigned installers ask for confirmation before updating.

安装包通过了 Desktop CI：浏览器端到端测试、Rust/HTTP 与原生播放器检查、安装/启动/卸载冒烟测试和托管虚拟机性能检查。托管 CI 覆盖不到实体显卡/HDR、音频直通、多显示器 DPI、光盘播放与 Windows/macOS 硬件等效。实际签名状态记录在 `release-manifest.json` 中；未签名的安装包在更新前会请你确认。

<!-- desktop-release-policy: ci-verified -->
