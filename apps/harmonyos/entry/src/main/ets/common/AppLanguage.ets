import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { LocaleZhHans } from '../locales/LocaleZhHans';
import { LocaleZhHant } from '../locales/LocaleZhHant';
import { LocaleEn } from '../locales/LocaleEn';

/**
 * 应用内多语言（对应 iOS 的 AppLanguage + LanguageSettings，zh-Hans / zh-Hant / en 三语）。
 *
 * **机制选型：轻量键值表（ets/locales/），不用系统资源限定词目录。**
 * 理由：
 * 1. 系统机制（resources/zh_Hant/、resources/en_US/ + $r('app.string.*')）返回的是 Resource
 *    对象，进不了逻辑层——拼接、比较、replace 占位符都要先 getStringSync 再处理；
 * 2. 应用内即时切换靠 @ObservedV2/@Trace 单例（同 TabBarStyle），切了当场重建，不依赖系统语言；
 * 3. 纯函数 normalize / lookup 不碰 Context，可以直接进 hypium 单测（本地无 DevEco 也能验证）。
 *
 * **后续页面如何接入（三步）：**
 * 1. 在 locales/LocaleZhHans.ets（及 ZhHant / En）加一条 key，三个文件同一集合，
 *    参数用 {0} / {1} 占位；
 * 2. 页面里 import { AppLanguage } from '../common/AppLanguage'，把硬编码文案换成
 *    AppLanguage.shared().t('your.key')（带参数再 .replace('{0}', 值)）；
 *    页面是 @ComponentV2 时 build 里读到 @Trace 的 language，切语言当场重建，无需额外代码。
 * 3. 跑一遍语言设置页确认三语都对；词条补不齐时 zh-Hant / en 自动回退 zh-Hans，不出现空文案。
 */

/** 语言代码（三个支持值，常量集中避免散落的字符串拼错） */
export class LanguageCode {
  static readonly zhHans: string = 'zh-Hans';
  static readonly zhHant: string = 'zh-Hant';
  static readonly en: string = 'en';
}

/**
 * 任意 BCP-47 标签归一到三语之一（纯函数；对齐 iOS AppLanguage.normalize 的意图，
 * 但 iOS 只区分中文/英文，这里把繁体区（TW/HK/MO/Hant）单独分出来）。
 */
export function normalizeLanguage(raw: string): string {
  const lower: string = raw.toLowerCase();
  if (lower.startsWith('zh')) {
    const traditional: boolean = lower.includes('hant') || lower.includes('tw')
      || lower.includes('hk') || lower.includes('mo');
    return traditional ? LanguageCode.zhHant : LanguageCode.zhHans;
  }
  return LanguageCode.en;
}

/** 取词（纯函数）：先按语言查，缺词回退 zh-Hans（简体是词条母本），还缺就返回 key 本身。 */
export function lookupString(language: string, key: string): string {
  const table: Record<string, string> = language === LanguageCode.zhHant ? LocaleZhHant.table
    : language === LanguageCode.en ? LocaleEn.table : LocaleZhHans.table;
  const value: string | undefined = table[key];
  if (value !== undefined && value.length > 0) {
    return value;
  }
  const fallback: string | undefined = LocaleZhHans.table[key];
  return fallback !== undefined && fallback.length > 0 ? fallback : key;
}

/** 语言的自称（autonym 是语言数据，不走词条表；同 iOS AppLanguage.name 的 i18n-ignore） */
export function languageName(language: string): string {
  if (language === LanguageCode.zhHant) {
    return '繁體中文';
  }
  if (language === LanguageCode.en) {
    return 'English';
  }
  return '简体中文';
}

/**
 * 语言单例：@ObservedV2 + @Trace（同 TabBarStyle），设置页切换后所有正在读 t() 的
 * @ComponentV2 页面当场重建。preferences 落盘复用 movieclaw_ui 偏好文件，重启保留。
 */
@ObservedV2
export class AppLanguage {
  private static instance: AppLanguage | null = null;
  private static readonly storeName: string = 'movieclaw_ui';
  private static readonly prefKey: string = 'app_language';
  /** 偏好打开的完成信号（同 TabBarStyle.ready：不等它读到的是默认值） */
  private static ready: Promise<void> | null = null;

  private store: preferences.Preferences | null = null;

  /** 当前语言（默认简体中文）；@Trace 使切换可被 V2 页面观测 */
  @Trace language: string = LanguageCode.zhHans;

  private constructor() {
  }

  static shared(): AppLanguage {
    if (AppLanguage.instance === null) {
      AppLanguage.instance = new AppLanguage();
    }
    return AppLanguage.instance;
  }

  /** EntryAbility.onCreate 里尽早调用（同 TabBarStyle.init）；异步读盘不阻塞首帧 */
  static init(context: Context): void {
    if (AppLanguage.ready === null) {
      AppLanguage.ready = preferences.getPreferences(context, AppLanguage.storeName)
        .then((store: preferences.Preferences): void => {
          const self: AppLanguage = AppLanguage.shared();
          self.store = store;
          const value: preferences.ValueType = store.getSync(AppLanguage.prefKey, LanguageCode.zhHans);
          if (typeof value === 'string' && value.length > 0) {
            self.language = normalizeLanguage(value);
          }
        })
        .catch((): void => {
        });
    }
  }

  /** 切语言：内存先刷（@Trace 触发重建），落盘失败静默——本次会话内仍然生效 */
  setLanguage(language: string): void {
    this.language = normalizeLanguage(language);
    const chosen: string = this.language;
    const save = async (): Promise<void> => {
      const signal: Promise<void> | null = AppLanguage.ready;
      if (signal !== null) {
        await signal;
      }
      const store: preferences.Preferences | null = AppLanguage.shared().store;
      if (store === null) {
        return;
      }
      try {
        await store.put(AppLanguage.prefKey, chosen);
        await store.flush();
      } catch (error) {
      }
    };
    save();
  }

  /** 取词（读 @Trace 的 language，build 里调用即获得切换重建） */
  t(key: string): string {
    return lookupString(this.language, key);
  }

  /** 当前语言的自称（语言设置行右侧的展示值） */
  name(): string {
    return languageName(this.language);
  }
}
