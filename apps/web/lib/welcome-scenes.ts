/**
 * 欢迎页（登录 / 初始化）轮播的影史经典台词，与原生 App 同一份内容数据
 * （apps/apple/Shared/Welcome/WelcomeQuotes.json 的副本，单测守着两份一致，改动两边同步）。
 *
 * 选句口径：美国电影学会「百年百大电影台词」里最广为人知的那些，加上华语与世界影史的名句；
 * 只收能确认原话的句子，基调偏温暖与诗意。外语片附中文字幕，注明片名与年份。
 * 不用真实海报 / 剧照：登录前拿不到用户自己的片库，把别人的海报放进开源项目也有版权问题。
 * 台词用思源宋体子集显示（app/fonts/WelcomeSerif.otf，与 App 同一份，子集外的字回落系统衬线体）。
 */
import QUOTES from "./welcome-quotes.json" with { type: "json" };

export interface WelcomeScene {
  /** 中文（华语片为原句，外语片为字幕）；\n 断在语气停顿处 */
  line: string;
  /** 外语原句（华语片为 null） */
  original: string | null;
  film: string;
  filmEnglish: string;
  year: number;
  /** 华语片的英文译句（英文界面用；外语片直接用原句） */
  english?: string | null;
}

export const WELCOME_SCENES: WelcomeScene[] = QUOTES;

/** 打乱一份台词顺序（每次打开首页、一轮放完时各打乱一次） */
export function shuffledScenes(): WelcomeScene[] {
  const list = [...WELCOME_SCENES];
  for (let i = list.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [list[i], list[j]] = [list[j], list[i]];
  }
  return list;
}

/**
 * 按界面语言取三行（与 App 的 WelcomeScene 同一口径）：
 * 中文界面大字是中文台词、小字是外语原句、出处「《卡萨布兰卡》1942」；
 * 英文界面大字是原句（华语片用英文译句）、华语片小字附中文原句、出处「Casablanca, 1942」。
 */
export function sceneText(scene: WelcomeScene, locale: string) {
  if (locale === "zh-Hans") {
    return { headline: scene.line, subline: scene.original, film: scene.film, source: `《${scene.film}》${scene.year}` };
  }
  return {
    headline: scene.original ?? scene.english ?? scene.line,
    subline: scene.original === null ? scene.line : null,
    film: scene.filmEnglish,
    source: `${scene.filmEnglish}, ${scene.year}`,
  };
}
