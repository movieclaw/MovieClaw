import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { AppModel } from '../common/AppModel';
import { MovieClawApi } from '../api/Endpoints';
import { JsonValue, jsonStringValue } from '../api/JsonValue';
import {
  DeleteFollowUpView,
  DeleteOptionView,
  DeletePreviewLineView,
  ItemDeleteResultView,
  JobView,
  LibraryItemDetailView
} from '../api/Models';

/**
 * 「删除影片」后果单（iOS DeleteItemSheets.swift 的 DeleteItemSheet，Web DeleteDialog）。
 *
 * 全站唯一真删磁盘的操作，所以把后果一次性讲透：列出将被清掉的目录、文件数与体积，
 * 勾选「我已明白」后才放开红色按钮；完成后展示实际删除的路径清单，让用户对
 * 「删了什么」有完整凭据。条目详情（目录、文件数、体积）由弹层自己拉，调用方只给 id。
 */
@Component
export struct DeleteItemSheet {
  @Prop libraryId: number = 0;
  @Prop mediaItemId: number = 0;
  @Prop title: string = '';
  onClose: () => void = (): void => {
  };
  /** 删除完成（结果页关闭）时回调：调用方离开条目页并刷新库存 */
  onDeleted: () => void = (): void => {
  };

  @State private detail: LibraryItemDetailView | null = null;
  @State private loadFailed: boolean = false;
  @State private confirmed: boolean = false;
  @State private busy: boolean = false;
  @State private result: ItemDeleteResultView | null = null;
  @State private error: string = '';
  /** 附加选项（别的模块登记的删除参与方，如下载模块）；预览取失败不挡删除 */
  @State private previewLoading: boolean = true;
  @State private previewFailed: boolean = false;
  @State private linkedBytes: number = 0;
  @State private options: DeleteOptionView[] = [];
  @State private selectedKeys: string[] = [];

  aboutToAppear(): void {
    this.load();
    this.loadPreview();
  }

  /** 结果页不可漏发回调：下滑关掉弹层也算「完成」 */
  aboutToDisappear(): void {
    if (this.result !== null && !this.finished) {
      this.finished = true;
      this.onDeleted();
    }
  }

  private finished: boolean = false;

  private load(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.libraryItemsGet(this.libraryId, this.mediaItemId).then((detail: LibraryItemDetailView): void => {
      this.detail = detail;
      this.loadFailed = false;
    }).catch((): void => {
      this.loadFailed = this.detail === null;
    });
  }

  private loadPreview(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.libraryItemsDeletePreview(this.libraryId, this.mediaItemId).then((preview): void => {
      this.linkedBytes = preview.linked_bytes;
      this.options = preview.options;
      this.previewLoading = false;
    }).catch((): void => {
      this.previewFailed = true;
      this.previewLoading = false;
    });
  }

  /** 勾选的键排序拼接，传给删除接口；没勾传 undefined（旧服务端不认识也不受影响） */
  private optionsQuery(): string | undefined {
    if (this.selectedKeys.length === 0) {
      return undefined;
    }
    return this.selectedKeys.slice().sort().join(',');
  }

  private toggleOption(key: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (const existing of this.selectedKeys) {
      if (existing === key) {
        found = true;
      } else {
        next.push(existing);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.selectedKeys = next.sort();
  }

  private run(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    api.libraryItemsDelete(this.libraryId, this.mediaItemId, undefined, this.optionsQuery())
      .then((result: ItemDeleteResultView): void => {
        this.result = result;
        this.busy = false;
      }).catch((error: Error): void => {
        this.error = error.message.length > 0 ? error.message : '删除失败，请稍后重试';
        this.busy = false;
      });
  }

  /** 结果页的「回到库存页」：关弹层 + 通知调用方离开条目页 */
  private finish(): void {
    if (!this.finished) {
      this.finished = true;
      this.onDeleted();
    }
    this.onClose();
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('删除影片')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Text(this.result !== null ? '关闭' : '取消')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            if (this.result !== null) {
              this.finish();
            } else {
              this.onClose();
            }
          })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16, bottom: 8 })

      if (this.result !== null) {
        this.ResultContent()
      } else if (this.detail === null) {
        this.LoadingContent()
      } else {
        this.ConfirmContent(this.detail as LibraryItemDetailView)
      }

      // 底栏：结果页给「回到库存页」，确认页给红色删除键
      Row() {
        Blank()
        if (this.result !== null) {
          Button('回到库存页')
            .height(44)
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
            .backgroundColor(Theme.accent)
            .borderRadius(14)
            .padding({ left: 24, right: 24 })
            .onClick(() => {
              this.finish();
            })
        } else {
          DangerDeleteButton({
            busy: this.busy,
            allowTap: this.confirmed && this.detail !== null,
            onTap: (): void => {
              this.run();
            }
          })
        }
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  LoadingContent() {
    Column({ space: 12 }) {
      if (this.loadFailed) {
        Text('条目信息加载失败')
          .fontSize(14)
          .fontColor(Theme.textMuted)
        Text('重试')
          .fontSize(14)
          .fontColor(Theme.accentStrong)
          .onClick(() => {
            this.loadFailed = false;
            this.load();
          })
      } else {
        LoadingProgress().width(22).height(22).color(Theme.textMuted)
        Text('正在读取条目信息…')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ConfirmContent(detail: LibraryItemDetailView) {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(17)
            .fontColor([Theme.danger])
          Text(`删除「${this.title}」`)
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
        }

        Text() {
          Span('这不是「从列表移除」——将把下列目录从磁盘')
          Span('彻底删除')
            .fontWeight(700)
            .fontColor(Theme.danger)
          Span('，包括视频文件、NFO、海报、字幕等全部刮削产物，共 ')
          Span(`${detail.file_count}`)
            .fontWeight(700)
          Span(' 个媒体文件、')
          Span(Formatters.bytes(detail.total_size_bytes))
            .fontWeight(700)
          Span('。此操作不可恢复。')
        }
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.8)')
        .width('100%')
        .lineHeight(22)

        PathListBox({
          paths: detail.entry_dirs.length > 0 ? detail.entry_dirs : this.filePaths(detail),
          folderIcon: true
        })

        this.OptionsSection()
        this.AcknowledgeRow('我已明白：以上目录及其中全部文件将被永久删除，无法恢复。')

        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 12 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.TopStart)
  }

  /** 附加选项（iOS DeleteOptionsSection）：来自别的模块登记的删除参与方，默认一律不勾 */
  @Builder
  OptionsSection() {
    Column({ space: 10 }) {
      if (this.previewFailed) {
        Text('附加选项暂时加载不出来，这次只删除媒体库文件。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      } else if (this.previewLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(14).height(14).color(Theme.textFaint)
          Text('正在检查关联的下载任务…')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
      } else {
        if (this.linkedBytes > 0) {
          Text() {
            Span('其中 ')
            Span(Formatters.bytes(this.linkedBytes))
              .fontWeight(700)
            Span(' 与别处的文件是同一份数据（硬链接）：只删媒体库文件不会释放这部分空间。')
          }
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.7)')
          .width('100%')
        }
        ForEach(this.options, (option: DeleteOptionView) => {
          this.OptionRow(option)
        }, (option: DeleteOptionView) => option.key)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  OptionRow(option: DeleteOptionView) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Checkbox()
          .select(this.selectedKeys.indexOf(option.key) >= 0)
          .selectedColor(Theme.danger)
          .width(20)
          .height(20)
          .onChange((checked: boolean) => {
            this.toggleOption(option.key);
          })
        Column({ space: 2 }) {
          Text(option.label)
            .fontSize(14)
            .fontWeight(500)
            .fontColor(Theme.text)
          if (option.help.length > 0) {
            Text(option.help)
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .opacity(option.available ? 1 : 0.5)
      .onClick(() => {
        if (option.available) {
          this.toggleOption(option.key);
        }
      })

      Column({ space: 2 }) {
        if (option.available) {
          ForEach(option.lines, (line: DeletePreviewLineView) => {
            Text(line.text)
              .fontSize(12)
              .fontColor(this.lineTone(line.tone))
          }, (line: DeletePreviewLineView) => line.text)
        } else {
          Text(`这次不能勾选：${option.reason ?? '不可用'}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 30 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  @Builder
  AcknowledgeRow(text: string) {
    Row({ space: 10 }) {
      Checkbox()
        .select(this.confirmed)
        .selectedColor(Theme.danger)
        .width(20)
        .height(20)
        .onChange((checked: boolean) => {
          this.confirmed = checked;
        })
      Text(text)
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.8)')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .onClick(() => {
      this.confirmed = !this.confirmed;
    })
  }

  @Builder
  ResultContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.result !== null && (this.result as ItemDeleteResultView).errors.length === 0
          ? '已从磁盘彻底删除' : '部分删除完成')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        if ((this.result as ItemDeleteResultView).removed_paths.length === 0) {
          Text('没有删除任何磁盘路径')
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .padding(14)
            .width('100%')
            .backgroundColor('rgba(255,255,255,0.03)')
            .borderRadius(12)
            .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
        } else {
          PathListBox({
            paths: (this.result as ItemDeleteResultView).removed_paths,
            folderIcon: false
          })
        }
        ForEach((this.result as ItemDeleteResultView).errors, (line: string) => {
          Text(line)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
        }, (line: string) => line)
        Text(`已清理 ${(this.result as ItemDeleteResultView).rows_deleted} 条台账，`
          + `释放 ${Formatters.bytes((this.result as ItemDeleteResultView).freed_bytes)}。`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        ForEach((this.result as ItemDeleteResultView).follow_ups ?? [], (followUp: DeleteFollowUpView) => {
          FollowUpJobRow({ label: followUp.label, jobId: followUp.job_id })
        }, (followUp: DeleteFollowUpView) => followUp.job_id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 12 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.TopStart)
  }

  private filePaths(detail: LibraryItemDetailView): string[] {
    const out: string[] = [];
    for (const file of detail.files) {
      out.push(file.file_path);
    }
    return out;
  }

  private lineTone(tone: string): ResourceColor {
    if (tone === 'warn') {
      return Theme.warning;
    }
    if (tone === 'danger') {
      return Theme.danger;
    }
    return 'rgba(255,255,255,0.7)';
  }
}

/**
 * 「删除此文件」后果单（iOS DeleteFileSheet）：条目删除的文件级姊妹
 * （多版本洗掉一个 / 删某集重下）。同一套三段式：讲透后果 → 勾选确认 → 红色按钮 → 结果清单。
 * 两条必须讲清的规则：
 * 1. 条目在本库只剩这一行台账时，后端会**升级为整条目删除**（不留只剩 NFO/海报的空目录）；
 * 2. 该单元有订阅盯着时，删掉最后一份拷贝订阅会自动重新下载补齐。
 */
@Component
export struct DeleteFileSheet {
  @Prop libraryId: number = 0;
  @Prop mediaItemId: number = 0;
  @Prop fileId: number = 0;
  @Prop fileName: string = '';
  @Prop filePath: string = '';
  @Prop sizeBytes: number = 0;
  @Prop missing: boolean = false;
  @Prop seasonNumber: number = 0;
  @Prop episodeNumber: number = 0;
  onClose: () => void = (): void => {
  };
  /** 只删掉了这个文件、条目仍在：调用方重拉详情 */
  onDeleted: () => void = (): void => {
  };
  /** 删的是最后一个文件、整条目随之删除：调用方应离开条目页 */
  onItemDeleted: () => void = (): void => {
  };

  @State private detail: LibraryItemDetailView | null = null;
  @State private loadFailed: boolean = false;
  @State private confirmed: boolean = false;
  @State private busy: boolean = false;
  @State private result: ItemDeleteResultView | null = null;
  @State private error: string = '';
  @State private previewLoading: boolean = true;
  @State private previewFailed: boolean = false;
  @State private linkedBytes: number = 0;
  @State private options: DeleteOptionView[] = [];
  @State private selectedKeys: string[] = [];
  private finished: boolean = false;

  aboutToAppear(): void {
    this.load();
    this.loadPreview();
  }

  aboutToDisappear(): void {
    if (this.result !== null && !this.finished) {
      this.finished = true;
      this.fireCompletion();
    }
  }

  /** 同 Web：最后一个文件且无错误 = 整条目已删，调用方应离开条目页；否则只重拉详情 */
  private fireCompletion(): void {
    const isLast: boolean = this.detail !== null && (this.detail as LibraryItemDetailView).files.length === 1;
    const clean: boolean = this.result !== null && (this.result as ItemDeleteResultView).errors.length === 0;
    if (isLast && clean) {
      this.onItemDeleted();
    } else {
      this.onDeleted();
    }
  }

  private load(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.libraryItemsGet(this.libraryId, this.mediaItemId).then((detail: LibraryItemDetailView): void => {
      this.detail = detail;
      this.loadFailed = false;
    }).catch((): void => {
      this.loadFailed = this.detail === null;
    });
  }

  private loadPreview(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.missing) {
      this.previewLoading = false;
      return;
    }
    api.libraryItemsDeletePreview(this.libraryId, this.mediaItemId, this.fileId).then((preview): void => {
      this.linkedBytes = preview.linked_bytes;
      this.options = preview.options;
      this.previewLoading = false;
    }).catch((): void => {
      this.previewFailed = true;
      this.previewLoading = false;
    });
  }

  private optionsQuery(): string | undefined {
    if (this.selectedKeys.length === 0) {
      return undefined;
    }
    return this.selectedKeys.slice().sort().join(',');
  }

  private toggleOption(key: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (const existing of this.selectedKeys) {
      if (existing === key) {
        found = true;
      } else {
        next.push(existing);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.selectedKeys = next.sort();
  }

  private run(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    api.libraryItemsDeleteFile(this.libraryId, this.mediaItemId, this.fileId, undefined, this.optionsQuery())
      .then((result: ItemDeleteResultView): void => {
        this.result = result;
        this.busy = false;
      }).catch((error: Error): void => {
        this.error = error.message.length > 0 ? error.message : '删除失败，请稍后重试';
        this.busy = false;
      });
  }

  private finish(): void {
    if (!this.finished) {
      this.finished = true;
      this.fireCompletion();
    }
    this.onClose();
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('删除文件')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Text(this.result !== null ? '关闭' : '取消')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            if (this.result !== null) {
              this.finish();
            } else {
              this.onClose();
            }
          })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16, bottom: 8 })

      if (this.result !== null) {
        this.ResultContent()
      } else if (this.detail === null) {
        this.LoadingContent()
      } else {
        this.ConfirmContent(this.detail as LibraryItemDetailView)
      }

      Row() {
        Blank()
        if (this.result !== null) {
          Button('完成')
            .height(44)
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
            .backgroundColor(Theme.accent)
            .borderRadius(14)
            .padding({ left: 24, right: 24 })
            .onClick(() => {
              this.finish();
            })
        } else {
          DangerDeleteButton({
            busy: this.busy,
            allowTap: this.confirmed,
            onTap: (): void => {
              this.run();
            }
          })
        }
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 10, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  LoadingContent() {
    Column({ space: 12 }) {
      if (this.loadFailed) {
        Text('条目信息加载失败')
          .fontSize(14)
          .fontColor(Theme.textMuted)
        Text('重试')
          .fontSize(14)
          .fontColor(Theme.accentStrong)
          .onClick(() => {
            this.loadFailed = false;
            this.load();
          })
      } else {
        LoadingProgress().width(22).height(22).color(Theme.textMuted)
        Text('正在读取条目信息…')
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ConfirmContent(detail: LibraryItemDetailView) {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(17)
            .fontColor([Theme.danger])
          Text('删除文件')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
        }

        if (this.missing) {
          Text('该文件在磁盘上已缺失，删除只会清掉这条台账记录。')
            .fontSize(14)
            .fontColor('rgba(255,255,255,0.8)')
            .width('100%')
            .lineHeight(22)
        } else {
          Text() {
            Span('将把下列文件从磁盘')
            Span('彻底删除')
              .fontWeight(700)
              .fontColor(Theme.danger)
            Span('，同名的 NFO/字幕/图片附属文件一并清除。此操作不可恢复。')
          }
          .fontSize(14)
          .fontColor('rgba(255,255,255,0.8)')
          .width('100%')
          .lineHeight(22)
        }

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            if (this.episodeLabel(detail).length > 0) {
              Text(this.episodeLabel(detail))
                .fontSize(13)
                .fontWeight(600)
                .fontColor(Theme.accent)
            }
            Text(this.fileName)
              .fontSize(14)
              .fontColor(Theme.text)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(Formatters.bytes(this.sizeBytes))
              .fontSize(12)
              .fontColor(Theme.textMuted)
          }
          .width('100%')
          Text(this.filePath)
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.5)')
            .fontFamily('monospace')
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .backgroundColor('rgba(255,255,255,0.03)')
        .borderRadius(12)
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })

        if (detail.files.length === 1) {
          Text(`这是「${detail.title}」在本库的最后一个文件——删除将升级为整条目删除，`
            + '整个刮削目录（含 NFO/海报）一并清除，条目将从库存消失。')
            .fontSize(13)
            .fontColor(Theme.warning)
            .width('100%')
            .lineHeight(20)
            .padding(14)
            .backgroundColor('rgba(251,191,36,0.06)')
            .borderRadius(12)
            .border({ width: 1, color: 'rgba(251,191,36,0.3)' })
        }

        Text('若该作品有订阅且删除后此单元不再有其他拷贝，订阅会将其视为缺失并自动重新下载。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .width('100%')
          .lineHeight(18)

        if (!this.missing) {
          this.OptionsSection()
        }
        this.AcknowledgeRow(detail.files.length === 1
          ? '我已明白：整个条目目录及其中全部文件将被永久删除，无法恢复。'
          : '我已明白：该文件及其同名附属文件将被永久删除，无法恢复。')

        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 12 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.TopStart)
  }

  @Builder
  OptionsSection() {
    Column({ space: 10 }) {
      if (this.previewFailed) {
        Text('附加选项暂时加载不出来，这次只删除媒体库文件。')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      } else if (this.previewLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(14).height(14).color(Theme.textFaint)
          Text('正在检查关联的下载任务…')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
      } else {
        if (this.linkedBytes > 0) {
          Text() {
            Span('其中 ')
            Span(Formatters.bytes(this.linkedBytes))
              .fontWeight(700)
            Span(' 与别处的文件是同一份数据（硬链接）：只删媒体库文件不会释放这部分空间。')
          }
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.7)')
          .width('100%')
        }
        ForEach(this.options, (option: DeleteOptionView) => {
          this.OptionRow(option)
        }, (option: DeleteOptionView) => option.key)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  OptionRow(option: DeleteOptionView) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Checkbox()
          .select(this.selectedKeys.indexOf(option.key) >= 0)
          .selectedColor(Theme.danger)
          .width(20)
          .height(20)
          .onChange((checked: boolean) => {
            this.toggleOption(option.key);
          })
        Column({ space: 2 }) {
          Text(option.label)
            .fontSize(14)
            .fontWeight(500)
            .fontColor(Theme.text)
          if (option.help.length > 0) {
            Text(option.help)
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .opacity(option.available ? 1 : 0.5)
      .onClick(() => {
        if (option.available) {
          this.toggleOption(option.key);
        }
      })

      Column({ space: 2 }) {
        if (option.available) {
          ForEach(option.lines, (line: DeletePreviewLineView) => {
            Text(line.text)
              .fontSize(12)
              .fontColor(this.lineTone(line.tone))
          }, (line: DeletePreviewLineView) => line.text)
        } else {
          Text(`这次不能勾选：${option.reason ?? '不可用'}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 30 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }

  @Builder
  AcknowledgeRow(text: string) {
    Row({ space: 10 }) {
      Checkbox()
        .select(this.confirmed)
        .selectedColor(Theme.danger)
        .width(20)
        .height(20)
        .onChange((checked: boolean) => {
          this.confirmed = checked;
        })
      Text(text)
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.8)')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .onClick(() => {
      this.confirmed = !this.confirmed;
    })
  }

  @Builder
  ResultContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.result !== null && (this.result as ItemDeleteResultView).errors.length === 0
          ? '已从磁盘删除' : '删除失败')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        if ((this.result as ItemDeleteResultView).removed_paths.length === 0) {
          Text('没有删除任何磁盘路径'
            + (this.missing ? '（文件本就缺失，仅清除了台账记录）' : ''))
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .padding(14)
            .width('100%')
            .backgroundColor('rgba(255,255,255,0.03)')
            .borderRadius(12)
            .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
        } else {
          PathListBox({
            paths: (this.result as ItemDeleteResultView).removed_paths,
            folderIcon: false
          })
        }
        ForEach((this.result as ItemDeleteResultView).errors, (line: string) => {
          Text(line)
            .fontSize(13)
            .fontColor(Theme.danger)
            .width('100%')
        }, (line: string) => line)
        Text(`已清理 ${(this.result as ItemDeleteResultView).rows_deleted} 条台账，`
          + `释放 ${Formatters.bytes((this.result as ItemDeleteResultView).freed_bytes)}。`)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
        ForEach((this.result as ItemDeleteResultView).follow_ups ?? [], (followUp: DeleteFollowUpView) => {
          FollowUpJobRow({ label: followUp.label, jobId: followUp.job_id })
        }, (followUp: DeleteFollowUpView) => followUp.job_id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 12 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.TopStart)
  }

  /** 剧集文件前的「S01E02」标签（电影返回空串） */
  private episodeLabel(detail: LibraryItemDetailView): string {
    if (detail.kind === 'movie') {
      return '';
    }
    if (this.episodeNumber <= 0 && this.seasonNumber <= 0) {
      return '';
    }
    return `S${Formatters.pad2(this.seasonNumber)}E${Formatters.pad2(this.episodeNumber)}`;
  }

  private lineTone(tone: string): ResourceColor {
    if (tone === 'warn') {
      return Theme.warning;
    }
    if (tone === 'danger') {
      return Theme.danger;
    }
    return 'rgba(255,255,255,0.7)';
  }
}

/** 红色「彻底删除 / 正在删除…」按钮（iOS DangerButton） */
@Component
struct DangerDeleteButton {
  @Prop busy: boolean = false;
  /** 可点（勾了「我已明白」才亮；不叫 enabled：会和组件的 enabled 属性撞名） */
  @Prop allowTap: boolean = false;
  onTap: () => void = (): void => {
  };

  build() {
    Button({ stateEffect: this.allowTap }) {
      Row({ space: 6 }) {
        if (this.busy) {
          LoadingProgress().width(16).height(16).color(Color.White)
        }
        Text(this.busy ? '正在删除…' : '彻底删除')
          .fontSize(15)
          .fontWeight(600)
      }
    }
    .height(44)
    .padding({ left: 28, right: 28 })
    .fontColor(Color.White)
    .backgroundColor(this.allowTap ? Theme.danger : 'rgba(255,107,107,0.35)')
    .borderRadius(14)
    .enabled(this.allowTap)
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 等宽路径清单框（iOS PathListBox） */
@Component
struct PathListBox {
  @Prop paths: string[] = [];
  @Prop folderIcon: boolean = false;

  build() {
    Column({ space: 4 }) {
      ForEach(this.paths, (path: string) => {
        Row({ space: 6 }) {
          if (this.folderIcon) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(13)
              .fontColor(['rgba(255,255,255,0.4)'])
          }
          Text(path)
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.7)')
            .fontFamily('monospace')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }, (path: string) => path)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }
}

/**
 * 结果页的后续任务行（iOS FollowUpRow）：勾选的删除选项在后台跑，
 * 当场轮询到结束（失败了去「活动 → 任务」重试）。
 */
@Component
struct FollowUpJobRow {
  @Prop label: string = '';
  @Prop jobId: string = '';
  @State private message: string = '正在处理…';
  @State private failed: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.poll();
    this.timer = setInterval((): void => {
      this.poll();
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private stopPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private poll(): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.jobsShow(this.jobId).then((job: JobView): void => {
      if (job.status === 'succeeded') {
        const record: Record<string, JsonValue> | null | undefined = job.result;
        const msg: string | null = record !== null && record !== undefined
          ? jsonStringValue(record['message']) : null;
        this.message = msg !== null && msg.length > 0 ? msg : '已完成';
        this.stopPolling();
        return;
      }
      if (job.status === 'failed') {
        const record: Record<string, JsonValue> | null | undefined = job.error;
        const msg: string | null = record !== null && record !== undefined
          ? jsonStringValue(record['message']) : null;
        this.message = `没能完成：${msg !== null && msg.length > 0 ? msg : '未知原因'}。可在「活动 → 任务」里重试`;
        this.failed = true;
        this.stopPolling();
        return;
      }
      if (job.status === 'cancelled') {
        this.message = '已取消';
        this.stopPolling();
      }
    }).catch((): void => {
      // 拉不到就等下一轮
    });
  }

  build() {
    Column({ space: 4 }) {
      Text(this.label)
        .fontSize(14)
        .fontWeight(500)
        .fontColor(Theme.text)
      Text(this.message)
        .fontSize(12)
        .fontColor(this.failed ? Theme.danger : Theme.textMuted)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('rgba(255,255,255,0.03)')
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
  }
}
