import { Theme } from '../theme/AppTheme';
import { DialogButtonRow } from '../common/NativeDialog';
import { AppModel } from '../common/AppModel';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { RenameDeviceRequest } from '../api/Models';

/**
 * 设备改名的**弹窗内容**（与 `DeviceApprovalDialog` 同一套样式与呈现方式）。
 *
 * 由宿主调 `NativeDialog.options` 拉起居中的系统式弹窗
 * （`UIContext.getPromptAction().openCustomDialog`）：系统负责遮罩、进出场动效、
 * 点遮罩关闭，以及**输入法避让**。本组件只画标题/说明/输入区和底部按钮行。
 *
 * **本组件是 V1 `@Component`**（宿主是 V2，V1 子组件可嵌入；内部只用 `@State`，
 * 只往外回 `onClose` / `onRenamed`）——与批准弹窗保持一致。
 */
@Component
export struct DeviceRenameDialog {
  /** 要改名的设备 id */
  @Prop deviceId: string = '';
  /** 当前设备名（输入框初值） */
  @Prop deviceName: string = '';
  /** 取消 / 保存完成：宿主关弹窗 */
  onClose: () => void = (): void => {
  };
  /** 真的改成功了：宿主重拉设备列表 */
  onRenamed: () => void = (): void => {
  };

  @State private name: string = '';
  @State private busy: boolean = false;
  @State private error: string = '';

  aboutToAppear(): void {
    this.name = this.deviceName;
  }

  private canSave(): boolean {
    const trimmed: string = this.name.trim();
    return !this.busy && trimmed.length > 0 && trimmed !== this.deviceName;
  }

  /** 改名：成功回调宿主（列表重拉），失败把话说明白 */
  private async save(): Promise<void> {
    if (!this.canSave()) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.busy = true;
    this.error = '';
    try {
      const body: RenameDeviceRequest = { name: this.name.trim() };
      await api.authDevicesRename(this.deviceId, body);
      this.onRenamed();
      this.onClose();
    } catch (err) {
      this.error = err instanceof ApiError && err.message.length > 0
        ? err.message : '改名失败，请稍后再试';
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      Column({ space: 20 }) {
        Column({ space: 6 }) {
          Text('给设备改名')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.text)
          Text('名字会显示在「正在播放」和「最近播放」里，帮你自己认出是哪台设备。')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)

        Column({ space: 8 }) {
          TextInput({ text: this.name, placeholder: '设备名' })
            .width('100%')
            .height(52)
            .fontSize(17)
            .fontColor(Theme.text)
            .backgroundColor(Theme.surface)
            .borderRadius(12)
            .border({ width: 1, color: Theme.line })
            .maxLength(64)
            .enterKeyType(EnterKeyType.Done)
            .onChange((value: string): void => {
              this.name = value;
              this.error = '';
            })
            .onSubmit((): void => {
              this.save();
            })
          if (this.error.length > 0) {
            Text(this.error)
              .fontSize(12)
              .fontColor(Theme.danger)
              .width('100%')
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 24, right: 24, top: 24, bottom: 16 })

      DialogButtonRow({
        leftLabel: '取消',
        rightLabel: this.busy ? '保存中…' : '保存',
        rightColor: this.canSave() ? Theme.accentStrong : Theme.textFaint,
        onLeft: (): void => {
          this.onClose();
        },
        onRight: (): void => {
          this.save();
        }
      })
    }
    .width('100%')
  }
}
