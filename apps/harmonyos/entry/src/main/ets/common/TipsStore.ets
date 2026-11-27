import { AppModel } from './AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { InvalidateTipRequest, TipRecordView, TipStateView } from '../api/Models';

/**
 * 使用提示的鸿蒙端引擎（docs/design/tips.md，同 iOS `TipsStore` / Android `core/tips/TipsStore.kt`）。
 *
 * 状态在服务端、每个账号一份；规则与文案写在用到提示的页面里。判定只做目前用得上的一条：
 * 快照拉回来之前不出任何提示；已作废的永不出现。上屏记展示、用过/关掉记作废，
 * 上报先改本地再以服务端返回的那一行为准，网络失败静默（提示不是关键功能）。
 *
 * 单例跨账号存活，所以快照记着属于谁（服务器地址 + 用户名，同媒体库首页快照）：换了账号就重新拉。
 */
export class TipsStore {
  static readonly shared: TipsStore = new TipsStore();

  private records: Map<string, TipRecordView> = new Map<string, TipRecordView>();
  private owner: string = '';
  private loaded: boolean = false;
  private loading: boolean = false;

  private currentOwner(): string {
    const session = AppModel.shared.session;
    return `${AppModel.origin()}|${session !== null ? session.username : ''}`;
  }

  /** 以当前账号拉一次快照（已经拉到、或正在拉就什么都不做；失败下次用到时再拉） */
  async ensureLoaded(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const owner: string = this.currentOwner();
    if (this.owner === owner && (this.loaded || this.loading)) {
      return;
    }
    if (this.owner !== owner) {
      this.owner = owner;
      this.records = new Map<string, TipRecordView>();
      this.loaded = false;
    }
    this.loading = true;
    try {
      const state: TipStateView = await api.tipsStateShow();
      if (this.currentOwner() !== owner) {
        return;
      }
      const next: Map<string, TipRecordView> = new Map<string, TipRecordView>();
      for (const row of state.tips) {
        next.set(row.tip_id, row);
      }
      this.records = next;
      this.loaded = true;
    } catch (_error) {
      // 旧服务器没有接口 / 断网：保持未加载，下次用到再试
    } finally {
      if (this.owner === owner) {
        this.loading = false;
      }
    }
  }

  /** 这条提示现在能不能出现（页面自己的规则另外判） */
  eligible(tip: string): boolean {
    if (!this.loaded || this.owner !== this.currentOwner()) {
      return false;
    }
    const row: TipRecordView | undefined = this.records.get(tip);
    return row === undefined || row.invalidated_at === null || row.invalidated_at === undefined;
  }

  /** 提示上屏一次 */
  recordDisplay(tip: string): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const owner: string = this.currentOwner();
    const row: TipRecordView | undefined = this.records.get(tip);
    const local: TipRecordView = {
      tip_id: tip,
      display_count: (row !== undefined ? row.display_count : 0) + 1,
      first_displayed_at: row !== undefined ? row.first_displayed_at : new Date().toISOString(),
      last_displayed_at: new Date().toISOString(),
      invalidated_at: row !== undefined ? row.invalidated_at : null,
      invalidated_reason: row !== undefined ? row.invalidated_reason : null
    };
    this.records.set(tip, local);
    api.tipsDisplaysRecord(tip).then((saved: TipRecordView): void => {
      if (this.currentOwner() === owner) {
        this.records.set(tip, saved);
      }
    }).catch((): void => {
    });
  }

  /** 作废：`action_performed` 用过了提示说的功能，`closed` 用户关掉 */
  invalidate(tip: string, reason: string): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const owner: string = this.currentOwner();
    const row: TipRecordView | undefined = this.records.get(tip);
    if (row !== undefined && row.invalidated_at !== null && row.invalidated_at !== undefined) {
      return;
    }
    const local: TipRecordView = {
      tip_id: tip,
      display_count: row !== undefined ? row.display_count : 0,
      first_displayed_at: row !== undefined ? row.first_displayed_at : null,
      last_displayed_at: row !== undefined ? row.last_displayed_at : null,
      invalidated_at: new Date().toISOString(),
      invalidated_reason: reason
    };
    this.records.set(tip, local);
    const body: InvalidateTipRequest = { reason: reason };
    api.tipsInvalidate(tip, body).then((saved: TipRecordView): void => {
      if (this.currentOwner() === owner) {
        this.records.set(tip, saved);
      }
    }).catch((): void => {
    });
  }
}
