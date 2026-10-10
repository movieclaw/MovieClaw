import { LlmModelOptionView } from '../api/Models';
import { MovieClawApi } from '../api/Endpoints';

/**
 * 模型清单与思维链档位的纯逻辑（对应 iOS `Features/Agent/AgentSkills.swift` 里的
 * `AgentCatalog` / `AgentThinking`，以及 Web `lib/thinking-level-control.ts`）。
 *
 * 服务端只下发一个字符串菜单（`thinking_levels`），前端按菜单形状决定控件长相：
 * 空 → 不渲染；一档 → 两格分段（默认 / 该档）；两档及以上 → 档位 chips（更快 ↔ 更聪明）。
 * 「默认」= 不发参数、用模型自身行为，不是强度轴上的一点：不占刻度，靠「默认」这一项回去。
 */
export class AgentThinking {
  static readonly order: string[] = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
  private static readonly labels: string[] = ['关', '最少', '低', '中', '高', '超高', '最高'];

  /** 按词汇表排序的刻度（词汇表外的值丢弃） */
  static stops(levels: string[]): string[] {
    const out: string[] = [];
    for (const level of AgentThinking.order) {
      if (levels.indexOf(level) >= 0) {
        out.push(level);
      }
    }
    return out;
  }

  /** 'hidden' | 'toggle' | 'chips' */
  static shape(stops: string[]): string {
    if (stops.length === 0) {
      return 'hidden';
    }
    return stops.length === 1 ? 'toggle' : 'chips';
  }

  /** 档位展示名；'' = 默认 */
  static label(value: string): string {
    if (value.length === 0) {
      return '默认';
    }
    const at: number = AgentThinking.order.indexOf(value);
    return at >= 0 ? AgentThinking.labels[at] : value;
  }
}

/** 模型清单（一分钟内不重复请求，同 iOS `AgentCatalog`） */
export class AgentCatalog {
  private static models: LlmModelOptionView[] | null = null;
  private static modelsAt: number = 0;

  /** 对话框可选的模型清单；加载失败返回空（隐藏模型胶囊） */
  static async modelOptions(api: MovieClawApi): Promise<LlmModelOptionView[]> {
    const now: number = Date.now();
    const cached: LlmModelOptionView[] | null = AgentCatalog.models;
    if (cached !== null && now - AgentCatalog.modelsAt < 60000) {
      return cached;
    }
    try {
      const list: LlmModelOptionView[] = await api.llmModels();
      AgentCatalog.models = list;
      AgentCatalog.modelsAt = now;
      return list;
    } catch (error) {
      return [];
    }
  }

  /** 设置里改了模型供应商后作废缓存（下次打开立即拿到新清单） */
  static invalidate(): void {
    AgentCatalog.models = null;
    AgentCatalog.modelsAt = 0;
  }

  /** 选择器当前生效的选项：显式引用命中的项，否则全局默认项 */
  static resolve(options: LlmModelOptionView[], ref: string): LlmModelOptionView | null {
    if (ref.length > 0) {
      for (const option of options) {
        if (option.ref === ref) {
          return option;
        }
      }
    }
    for (const option of options) {
      if (option.is_default) {
        return option;
      }
    }
    return options.length > 0 ? options[0] : null;
  }

  /** 胶囊上的文案：显式选过就显示该模型，否则「默认模型」 */
  static displayLabel(options: LlmModelOptionView[], ref: string): string {
    if (ref.length > 0) {
      if (ref === 'default') {
        return '默认模型';
      }
      for (const option of options) {
        if (option.ref === ref) {
          return option.label;
        }
      }
      return ref;
    }
    const hit: LlmModelOptionView | null = AgentCatalog.resolve(options, '');
    return hit !== null && hit.is_default ? `默认（${hit.label}）` : '默认模型';
  }
}
