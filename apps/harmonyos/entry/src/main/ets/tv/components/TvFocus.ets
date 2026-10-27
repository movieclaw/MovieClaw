/**
 * TV 焦点请求的安全封装。
 *
 * `FocusController.requestFocus(key)` 在「目标未挂树 / 祖先暂时不可获焦」时会抛异常
 * （150002/150003）。TV 端的请求基本都在 setTimeout 里做「等节点挂载稳了再定位」——
 * 定时器回调抛出的异常没人接，直接把进程打崩（实测：打开播放器必闪退）。
 *
 * 焦点没落上只是走焦不理想，不该让应用退出：统一在这里接住并留一行日志。
 */
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class TvFocus {
  static request(ui: UIContext, key: string): void {
    try {
      ui.getFocusController().requestFocus(key);
    } catch (error) {
      hilog.warn(0x0000, 'TvFocus', 'requestFocus(%{public}s) 失败：%{public}s', key, `${error}`);
    }
  }
}
