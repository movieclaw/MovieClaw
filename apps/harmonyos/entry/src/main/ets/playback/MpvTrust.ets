import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * mpv 内核的 TLS 信任库（`OfflineDisk.init` 同款：EntryAbility.onCreate 装载）。
 *
 * libmpv 的 ffmpeg 走 mbedtls，在鸿蒙上没有系统信任路径：外网 https 域名（如 Let's
 * Encrypt 签发的服务器证书）一律 BADCERT_NOT_TRUSTED，转码 HLS 连 manifest 都拉不到、
 * 秒退 -13——avplayer 用系统网络栈不受影响，于是「部分影片」（决策必须走 mpv 的那些：
 * Dolby Vision 转码档、特殊音轨、PGS 字幕等）在外网全灭，且服务端降档文案南辕北辙。
 *
 * 这里把内置的 Mozilla CA 包（`resources/rawfile/cacert.pem`，MPL-2.0）落到沙箱，
 * 由引擎工厂当 `tls-ca-file` 交给 mpv。每次启动重写一遍（约 200KB，app 升级后 CA
 * 包也随之更新）；安装失败不拦启动——mpv 回到无信任库的旧行为，局域网 http 不受影响。
 */
export class MpvTrust {
  private static caPath: string = '';

  /** EntryAbility.onCreate 时调一次 */
  static init(context: common.Context): void {
    if (MpvTrust.caPath.length > 0) { return; }
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync('cacert.pem');
      const target: string = `${context.filesDir}/mpv-cacert.pem`;
      const file = fileIo.openSync(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(file);
      }
      MpvTrust.caPath = target;
      hilog.info(0x0000, 'MovieClaw', '%{public}s', `mpv CA 包就绪: ${bytes.length} 字节`);
    } catch (error) {
      hilog.warn(0x0000, 'MovieClaw', 'mpv CA 包安装失败，外网 https 转码流将无法播放: %{public}s', `${error}`);
    }
  }

  /** 引擎工厂要的 `tls-ca-file` 路径；未初始化或安装失败为 ''（不设该选项，维持旧行为） */
  static caBundlePath(): string {
    return MpvTrust.caPath;
  }
}
