import { JsonValue, jsonStringValue } from '../api/JsonValue';
import { SkillView } from '../api/Models';

/**
 * 技能显式调用的文本规则（对应 iOS `Features/Agent/AgentSkills.swift` 与 Web `lib/agent-skills.ts`，
 * 两个正则都是后端 `movieclaw_agent/skills.py` 的镜像）。
 *
 * - 输入框里的 `/skill:名字` 占位符：行首或空白后出现，发送时由服务端展开成 `<skill>` 块；
 * - 轨迹回放时 user 消息已是展开后的形态，先还原成 token 形态（`toTokenForm`），
 *   气泡再拆成 chip + 用户原文（`parseTokens`）。
 */

/** 拆出来的技能调用：chip 用的名字 + 去掉 token 后的原文 */
export class AgentSkillText {
  /** 已知技能名（小写） */
  static readonly tokenPattern: RegExp = /(^|(?<=\s))\/skill:([A-Za-z0-9._-]+)/g;
  static readonly blockPattern: RegExp = /^<skill name="([^"]*)" location="[^"]*">\n[\s\S]*?\n<\/skill>\n*/;

  /** 组装一个插入输入框的占位符（尾随空格便于继续输入） */
  static token(name: string): string {
    return `/skill:${name} `;
  }

  /**
   * 从文本中拆出技能名（首现序去重）与剩余原文。
   * `allow`：已知技能名（小写）集合；空数组 = 名单未就绪（不过滤）。服务端只展开已知技能，
   * 拼错的 token 原样留给模型解释，气泡不能把它画成「已调用」的 chip。
   */
  static parseTokens(text: string, allow: string[]): AgentSkillNames {
    const names: string[] = [];
    const seen: string[] = [];
    const lines: string[] = text.split('\n');
    const kept: string[] = [];
    for (const line of lines) {
      let out: string = '';
      let cursor: number = 0;
      let touched: boolean = false;
      AgentSkillText.tokenPattern.lastIndex = 0;
      let match: RegExpExecArray | null = AgentSkillText.tokenPattern.exec(line);
      while (match !== null) {
        const name: string = match[2];
        const key: string = name.toLowerCase();
        let allowed: boolean = allow.length === 0;
        for (const known of allow) {
          if (known === key) {
            allowed = true;
            break;
          }
        }
        if (allowed) {
          touched = true;
          let isNew: boolean = true;
          for (const prev of seen) {
            if (prev === key) {
              isNew = false;
              break;
            }
          }
          if (isNew) {
            seen.push(key);
            names.push(name);
          }
          const tokenStart: number = match.index + match[0].length - match[2].length - '/skill:'.length;
          out += line.substring(cursor, tokenStart);
          cursor = match.index + match[0].length;
        }
        match = AgentSkillText.tokenPattern.exec(line);
      }
      if (!touched) {
        kept.push(line);
        continue;
      }
      out += line.substring(cursor);
      kept.push(out.replace(/[ \t]+/g, ' ').trim());
    }
    const trimmed: string[] = [];
    for (let i = 0; i < kept.length; i++) {
      if (kept[i].length > 0 || (i > 0 && i < kept.length - 1)) {
        trimmed.push(kept[i]);
      }
    }
    return new AgentSkillNames(names, trimmed.join('\n'));
  }

  /** 服务端已展开的 user 消息 → token 形态 `/skill:a /skill:b 用户原文`；非展开消息原样返回 */
  static toTokenForm(text: string): string {
    const names: string[] = [];
    let rest: string = text;
    while (true) {
      const match: RegExpExecArray | null = AgentSkillText.blockPattern.exec(rest);
      if (match === null) {
        break;
      }
      names.push(match[1]);
      rest = rest.substring(match[0].length);
    }
    if (names.length === 0) {
      return text;
    }
    let prefix: string = '';
    for (const name of names) {
      prefix += AgentSkillText.token(name);
    }
    return prefix + rest;
  }

  /**
   * 输入框末尾的「/查询」触发技能快选：行首或空白后敲「/」即开菜单，后续字符收窄匹配。
   * 返回查询串（不含 `/`）与待替换范围（`/` 的位置）；`skill:` 前缀视为手敲完整占位符，按名字部分过滤。
   */
  static slashQuery(text: string): AgentSlashQuery | null {
    const match: RegExpExecArray | null = /(^|\s)\/[A-Za-z0-9._:-]{0,64}$/.exec(text);
    if (match === null) {
      return null;
    }
    const start: number = match.index + (match[1].length > 0 ? 1 : 0);
    let query: string = text.substring(start + 1).toLowerCase();
    if (query.startsWith('skill:')) {
      query = query.substring(6);
    }
    if (query.indexOf(':') >= 0) {
      return null;
    }
    return new AgentSlashQuery(query, start, text.length);
  }

  /** 快选候选（最多 8 项，同 iOS `slashMatches`） */
  static slashMatches(query: string, skills: SkillView[]): SkillView[] {
    const out: SkillView[] = [];
    for (const skill of skills) {
      const name: string = skill.name.toLowerCase();
      const description: string = skill.description.toLowerCase();
      if (query.length === 0 || name.indexOf(query) >= 0 || description.indexOf(query) >= 0) {
        out.push(skill);
      }
      if (out.length >= 8) {
        break;
      }
    }
    return out;
  }

  /** 技能清单（`GET /ns`）→ 小写名字列表 */
  static namesOf(list: JsonValue[]): string[] {
    const names: string[] = [];
    for (const entry of list) {
      const map = entry as Record<string, JsonValue> | null;
      if (map === null) {
        continue;
      }
      const name: string | null = jsonStringValue(map['name']);
      if (name !== null && name.length > 0) {
        names.push(name.toLowerCase());
      }
    }
    return names;
  }
}

/** 「/」快选：查询串 + 待替换范围（`start` = `/` 的下标，`end` = 查询串末尾） */
export class AgentSlashQuery {
  readonly query: string;
  readonly start: number;
  readonly end: number;

  constructor(query: string, start: number, end: number) {
    this.query = query;
    this.start = start;
    this.end = end;
  }
}

/** 技能 token 的拆分结果 */
export class AgentSkillNames {
  readonly names: string[];
  readonly text: string;

  constructor(names: string[], text: string) {
    this.names = names;
    this.text = text;
  }
}
