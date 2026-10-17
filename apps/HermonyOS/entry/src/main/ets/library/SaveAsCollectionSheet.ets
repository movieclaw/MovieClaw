import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { CollectionPayload, CollectionView } from '../api/Models';
import { JsonValue } from '../api/JsonValue';
import { LibraryFilter } from './LibraryWall';

/**
 * 「筛完存为合集」（对应 iOS `SaveAsCollectionSheet` / Web `save-as-collection-dialog`）。
 *
 * 设计要点（iOS 原话）：**合集不是一个新概念，是「存好的筛选」**——所以这里只做两件事：
 * 起个名字，以及问清楚一件用户真正会在意的事：
 *
 * - **自动收录**：「以后符合这组条件的片都算」（规则驱动）
 * - **固定这批**：「就现在这些，别再变了」（名单驱动）
 *
 * 两者的差别**在几个月后才显形**（多了/少了片），事后无从追查，所以必须在创建这一刻问，
 * 而且**用后果的语言问**，不写成「smart / manual」让用户自己猜。
 * 「固定这批」由服务端定格（`payload.snapshot`）：客户端只表达意图，
 * 不必把上千个 id 拉下来再传回去。
 */
@ComponentV2
export struct SaveAsCollectionSheet {
  @Require @Param libraryId: number;
  /** 要存下来的那组条件（即此刻墙上生效的筛选） */
  @Require @Param filter: LibraryFilter;
  @Require @Param onSaved: (view: CollectionView) => void;
  @Require @Param onClose: () => void;

  @Local private name: string = '';
  /** true = 固定这批（名单驱动），false = 自动收录（规则驱动） */
  @Local private snapshot: boolean = false;
  @Local private busy: boolean = false;
  @Local private errorMessage: string = '';

  aboutToAppear(): void {
    this.name = this.suggestedName();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 条件一句话概括，当默认名（用户多半直接用它） */
  private suggestedName(): string {
    const parts: string[] = [];
    if (this.filter.genres.length > 0) {
      parts.push(`${this.filter.genres.length} 个类型`);
    }
    if (this.filter.countries.length > 0) {
      parts.push(this.filter.countries.join('/'));
    }
    if (this.filter.decades.length > 0) {
      parts.push(this.filter.decades.join('/'));
    }
    if (this.filter.hdr === true) {
      parts.push('HDR');
    }
    if (this.filter.resolutions.length > 0) {
      parts.push(this.filter.resolutions.join('/'));
    }
    return parts.length === 0 ? '我的合集' : parts.join(' · ');
  }

  /** 条件条数（给用户一个「存的是什么」的量） */
  private conditionCount(): number {
    const rules: JsonValue[] = this.filter.rules();
    return rules.length;
  }

  private async save(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.busy) {
      return;
    }
    const trimmed: string = this.name.trim();
    if (trimmed.length === 0) {
      this.toast('给合集起个名字');
      return;
    }
    this.busy = true;
    this.errorMessage = '';
    try {
      const payload: CollectionPayload = {
        name: trimmed,
        library_id: this.libraryId,
        rules: this.filter.rules(),
        // 「固定这批」由服务端把此刻的命中集定格成名单（客户端不必回传上千个 id）
        snapshot: this.snapshot
      };
      const saved: CollectionView = await api.collectionCreate(payload);
      this.toast(`已存为合集「${saved.name}」`);
      this.onSaved(saved);
      this.onClose();
    } catch (error) {
      this.errorMessage = this.messageOf(error);
    } finally {
      this.busy = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `保存失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '保存失败';
  }

  // MARK: 视图

  build() {
    Column() {
      this.SheetBar()
      Scroll() {
        Column({ space: 14 }) {
          this.NameField()
          this.ModeChoice()
          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(13)
              .fontColor(Theme.danger)
              .width('100%')
          }
          this.SaveButton()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  SheetBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(18)
        .fontColor([Theme.textMuted])
        .width(40)
        .height(40)
        .onClick(() => {
          this.onClose();
        })
      Blank()
      Text('存为合集')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Blank()
      Row().width(40).height(40)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
  }

  @Builder
  NameField() {
    Column({ space: 6 }) {
      Text('合集名')
        .fontSize(13)
        .fontColor(Theme.textFaint)
      TextInput({ text: this.name, placeholder: '给这个合集起个名' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(Theme.text)
        .backgroundColor(Theme.surfaceRaised)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .onChange((value: string): void => {
          this.name = value;
        })
      Text(`会存下当前这 ${this.conditionCount()} 个筛选条件`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 6 })
  }

  /**
   * 关键的一问：**用后果的语言**问「以后新的算不算」。
   * 两个选项的差别几个月后才显形，所以副标题写的是后果，不是机制名。
   */
  @Builder
  ModeChoice() {
    Column({ space: 10 }) {
      Text('以后新出的片算不算？')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
      this.ModeCard(false, '自动收录', '以后符合这组条件的片都算进来，随着入库自己长大。')
      this.ModeCard(true, '固定这批', '就现在墙上这些，以后新入库的不会再进来。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ModeCard(snapshot: boolean, title: string, blurb: string) {
    Row({ space: 12 }) {
      SymbolGlyph(this.snapshot === snapshot
        ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
        .fontSize(20)
        .fontColor([this.snapshot === snapshot ? Theme.accent : Theme.textFaint])
      Column({ space: 3 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text(blurb)
          .fontSize(13)
          .fontColor(Theme.textMuted)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(14)
    .backgroundColor(this.snapshot === snapshot ? Theme.surfaceRaised : Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: this.snapshot === snapshot ? Theme.accent : Theme.line })
    .onClick(() => {
      this.snapshot = snapshot;
    })
  }

  @Builder
  SaveButton() {
    Text(this.busy ? '保存中…' : '存为合集')
      .fontSize(16)
      .fontWeight(600)
      .fontColor(this.busy ? Theme.textFaint : '#0b0d12')
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .backgroundColor(this.busy ? Theme.glassFill : Theme.accent)
      .borderRadius(Theme.cardRadius)
      .margin({ top: 6 })
      .onClick(() => {
        if (!this.busy) {
          this.save();
        }
      })
  }
}
