import { LoginDeviceView } from '../api/Models';
import { Formatters } from './Formatters';

/**
 * 设备类型 / 权限文案（对应 iOS `DevicesSettingsView.swift` 里的 `enum DeviceText`，
 * 文案口径同 Web `lib/devices-display.ts`）。
 *
 * 这一块**必须写明「将获得什么」**：批准等于把那台机器的程序当成自己
 * （超管批的是完全权限，成员批的是他自己那一份），所以每一步都要说清后果，
 * 而不是只写「批准 / 拒绝」。
 */
export class GrantText {
  readonly title: string;
  readonly body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }
}

export class DeviceText {
  /** 设备类型的中文叫法 */
  static clientType(type: string): string {
    if (type === 'worker') {
      return '转码器';
    }
    if (type === 'cli') {
      return '命令行 / Agent';
    }
    if (type === 'tvos') {
      return 'Apple TV';
    }
    if (type === 'macos') {
      return 'Mac';
    }
    if (type === 'manual') {
      return '手工令牌';
    }
    return '未知类型';
  }

  /** 设备类型的图标（`sys.symbol`；本地符号库里没有 terminal/tv，就近取语义相近的） */
  static symbol(type: string): Resource {
    if (type === 'tvos') {
      return $r('sys.symbol.media_center');
    }
    if (type === 'macos') {
      return $r('sys.symbol.desktop');
    }
    if (type === 'cli') {
      return $r('sys.symbol.computer');
    }
    if (type === 'worker') {
      return $r('sys.symbol.gearshape');
    }
    return $r('sys.symbol.questionmark_circle');
  }

  /**
   * 「将获得」：令牌就是批准者本人的权限——超管批的是完全权限，成员批的是他自己的那份。
   */
  static grant(type: string, isAdmin: boolean): GrantText {
    if (type === 'worker') {
      return new GrantText('将获得：仅限转码', '这台机器不能查看或修改你的订阅、媒体库和设置。');
    }
    if (type === 'tvos') {
      return new GrantText(
        isAdmin ? '将获得：这台 Apple TV 以你的超级管理员身份登录' : '将获得：这台 Apple TV 以你的身份登录',
        '等同你在这台电视上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。'
          + '只批准你面前这台电视上显示的配对码。');
    }
    if (type === 'macos') {
      return new GrantText(
        isAdmin ? '将获得：这台 Mac 以你的超级管理员身份登录' : '将获得：这台 Mac 以你的身份登录',
        '等同你在这台 Mac 上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。'
          + '只批准你面前这台 Mac 上显示的配对码。');
    }
    if (isAdmin) {
      return new GrantText('将获得：与你相同的完全权限',
        '这台机器上的程序将能做你在网页上能做的一切，包括删除媒体文件。'
          + '只在你清楚这台机器上正在运行什么程序时才批准。');
    }
    return new GrantText('将获得：与你相同的权限',
      '这台机器上的程序将以你的身份操作，能做你在网页上能做的一切。'
        + '只在你清楚这台机器上正在运行什么程序时才批准。');
  }

  /**
   * 行首图标：**与 iOS 逐项对齐**，用鸿蒙原生符号库里语义最接近的字形
   * （iOS：worker/仅转码=cpu、ios/android=iphone、tvos=appletv、macos=laptopcomputer、
   *  web=globe、jellyfin=play.rectangle、其余=terminal；本地库没有 cpu/globe/terminal 的同名字形，
   *  取芯片、web、代码等价物）。
   */
  static symbolOf(kind: string, scope: string): Resource {
    if (kind === 'worker' || scope === 'transcode') {
      return $r('sys.symbol.memory_module');
    }
    if (kind === 'ios' || kind === 'android') {
      return $r('sys.symbol.pad_and_iphone');
    }
    if (kind === 'tvos') {
      return $r('sys.symbol.TV_tv');
    }
    if (kind === 'macos') {
      return $r('sys.symbol.computer');
    }
    if (kind === 'web') {
      return $r('sys.symbol.website');
    }
    if (kind === 'jellyfin') {
      return $r('sys.symbol.video');
    }
    return $r('sys.symbol.code');
  }

  /** 此刻是否「在线」：只有转码器有长连接（其余设备在不在用看最近活跃时间） */
  static isLive(device: LoginDeviceView): boolean {
    return device.connected;
  }

  /** 最近活跃文案（对应 iOS `activity`）：正在使用 / 刚刚 / N 分钟前 … */
  static activityText(device: LoginDeviceView): string {
    if (device.current) {
      return '正在使用';
    }
    const raw: string | null | undefined = device.last_seen_at;
    if (raw === null || raw === undefined || raw.length === 0) {
      return '从未使用';
    }
    return Formatters.relative(raw);
  }

  /** 超过 90 天没动过（对应 iOS `isDormant`） */
  static isDormant(device: LoginDeviceView): boolean {
    if (device.current || device.connected) {
      return false;
    }
    const raw: string | null | undefined = device.last_seen_at;
    if (raw === null || raw === undefined || raw.length === 0) {
      return true;
    }
    const at: number | null = Formatters.date(raw);
    if (at === null) {
      return false;
    }
    return Date.now() - at > 90 * 24 * 60 * 60 * 1000;
  }

  /** 第一行说明：系统、型号、版本（全部成员视图前面带上主人） */
  static identityParts(device: LoginDeviceView, showOwner: boolean): string[] {
    const parts: string[] = [];
    if (showOwner && device.owner_nickname.length > 0) {
      parts.push(device.owner_nickname);
    }
    const platformText: string = device.platform ?? '';
    const platform: string[] = [];
    for (const piece of platformText.split(' · ')) {
      const trimmed: string = piece.trim();
      if (trimmed.length > 0) {
        platform.push(trimmed);
      }
    }
    const isApp: boolean = device.kind === 'ios' || device.kind === 'tvos'
      || device.kind === 'macos' || device.kind === 'android';
    // 浏览器、带系统信息的 App 由图标说明形态，不再写类型名；命令行、令牌、播放器照写
    if (device.kind !== 'web' && !(isApp && platform.length > 0)) {
      parts.push(device.kind_label);
    }
    if (device.scope === 'transcode' && device.kind !== 'worker') {
      parts.push('仅转码');
    }
    for (const piece of platform) {
      parts.push(piece);
    }
    const version: string = device.client_version ?? '';
    if (version.length > 0) {
      parts.push(`版本 ${version}`);
    }
    return parts;
  }

  /** 第二行说明：正在使用 / 最近活跃、来源 IP */
  static activityParts(device: LoginDeviceView): string[] {
    const parts: string[] = [DeviceText.activityText(device)];
    const ip: string = device.last_seen_ip ?? '';
    if (ip.length > 0) {
      parts.push(ip);
    }
    return parts;
  }

  /**
   * 把几段说明拼成一行：段内用不断行空格（U+00A0）连住、段间用「· 」（点后面不换行），
   * 窄屏只会在「· 」之后换行——不会把「2026/10/05」拆开，也不会出现以点开头的行（同 iOS `metaLine`）。
   */
  static metaLine(parts: string[]): string {
    const joined: string[] = [];
    for (const part of parts) {
      joined.push(part.replace(/ /g, '\u00A0'));
    }
    return joined.join('\u00A0· ');
  }

  /** 手工令牌（完全权限）的「将获得」说明 */
  static get manualGrant(): GrantText {
    return new GrantText('将获得：与你相同的完全权限',
      '持有这枚令牌的程序将能做你在网页上能做的一切，包括删除媒体文件。'
        + '令牌不会自动过期，只能在这里注销——只把它放进你自己掌握的机器。');
  }

  /** 手工令牌（仅限转码）的「将获得」说明 */
  static get transcodeManualGrant(): GrantText {
    return new GrantText('将获得：仅限转码',
      '给命令行模式（Headless）的转码器用：只能连转码链路，不能查看或修改你的订阅、媒体库和设置。'
        + '令牌不会自动过期，只能在这里注销。');
  }
}
