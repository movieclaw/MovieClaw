import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NotifyCenter } from './NotifyCenter';

const DOMAIN = 0x0000;

/**
 * 通知延迟任务的回调入口（`module.json5` 里 `type: 'workScheduler'` 对应的 Extension）。
 *
 * 系统按分组的活跃度拉起（活跃分组最快也要 2 小时一次），回调**跑在独立的扩展进程**，
 * 和主进程不共享任何内存——所以登录态、偏好都要在这里重新初始化
 * （见 `NotifyCenter.pollFromExtension`，Extension 进程自己 init + restore）。
 *
 * 回调窗口最长 2 分钟：一轮差分轮询拉五个接口 + 弹通知绰绰有余；
 * 就算中断也无妨——差分是幂等的，基线没落盘下一轮重算，不会重复弹。
 */
export default class WorkNotifyExtensionAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, 'MovieClaw', '通知延迟任务触发 workId=%{public}d', work.workId);
    NotifyCenter.shared().pollFromExtension(this.context)
      .catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, 'MovieClaw', '通知轮询失败：%{public}s', `${error}`);
      });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    // 2 分钟窗口到点或 stopWork 时回调：没有要收尾的资源
  }
}
