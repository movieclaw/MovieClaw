import { common, Want } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';

/**
 * 外部媒体链接（对齐 iOS `ExternalMediaLink.swift`）：
 * 豆瓣词条优先唤起豆瓣 App（`douban://` 深链），未安装或唤起失败时回原网页；
 * 其他站点交给系统处理。
 */
export class ExternalMediaLink {
  /** 豆瓣网页词条 → App 深链；不是可识别的豆瓣词条返回 null。 */
  static doubanAppURL(address: string): string | null {
    let parsed: url.URL;
    try {
      parsed = url.URL.parseURL(address);
    } catch (error) {
      return null;
    }
    const scheme: string = parsed.protocol.replace(':', '').toLowerCase();
    if (scheme !== 'http' && scheme !== 'https') {
      return null;
    }
    const host: string = parsed.hostname.toLowerCase();
    if (host !== 'movie.douban.com' && host !== 'm.douban.com'
      && host !== 'www.douban.com' && host !== 'douban.com') {
      return null;
    }
    const parts: string[] = parsed.pathname.split('/').filter((part: string): boolean => part.length > 0);
    let id = '';
    if (parts.length === 2 && parts[0] === 'subject') {
      id = parts[1];
    } else if (parts.length === 3 && parts[0] === 'movie' && parts[1] === 'subject') {
      id = parts[2];
    }
    if (id.length === 0 || !/^[0-9]+$/.test(id)) {
      return null;
    }
    // 豆瓣的电影、电视剧词条共用 movie 路径
    return `douban://douban.com/movie/${id}`;
  }

  /**
   * 打开外链：豆瓣词条先试 App 深链，失败（未安装等）回原网页；都打不开回调 `onFail`。
   */
  static open(context: common.UIAbilityContext, address: string, onFail: () => void): void {
    const appURL: string | null = ExternalMediaLink.doubanAppURL(address);
    if (appURL === null) {
      ExternalMediaLink.launch(context, address).then((ok: boolean): void => {
        if (!ok) {
          onFail();
        }
      });
      return;
    }
    ExternalMediaLink.launch(context, appURL).then((ok: boolean): void => {
      if (ok) {
        return;
      }
      ExternalMediaLink.launch(context, address).then((fallbackOk: boolean): void => {
        if (!fallbackOk) {
          onFail();
        }
      });
    });
  }

  private static launch(context: common.UIAbilityContext, address: string): Promise<boolean> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: address
    };
    return context.startAbility(want).then((): boolean => true).catch((): boolean => false);
  }
}
