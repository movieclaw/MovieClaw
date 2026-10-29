import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';

/**
 * 空间化「沉浸光感」（Spatial UI）材质的统一入口。对应华为最佳实践
 * `best-practices/沉浸光感`（空间化 = 沉浸光感材质 + 悬浮组件）：
 *
 * - **HDS 组件**（`HdsNavigation` 标题栏等）走 `TitleBarStyleOptions.systemMaterialEffect`，
 *   见 `common/AppNavBar`；档位统一 ADAPTIVE，由系统按设备算力选 EXQUISITE/GENTLE/SMOOTH。
 * - **自绘组件**（底部导航胶囊、「接着看」条）走通用属性 `systemMaterial` +
 *   `uiMaterial.ImmersiveMaterial`：通透玻璃、按压弹性形变（interactive）、触点光晕（lightEffect）。
 *
 * **版本兜底**：`ImmersiveMaterial` 是 API 26 的能力，本项目的 compatibleSdkVersion 是
 * 6.1.1(24)，所以这里按运行时 `deviceInfo.sdkApiVersion` 判断；低于 26 直接返回 undefined，
 * 组件退回自己的常规磨砂底（观感一致，只是没有光感）。
 */
export class SpatialMaterial {
  /** 运行时是否支持沉浸光感（ArkUI 沉浸式系统材质） */
  static readonly supported: boolean = deviceInfo.sdkApiVersion >= 26;

  /**
   * 悬浮组件（底栏胶囊 / 接着看条）的材质：
   * REGULAR 厚度 + 按压形变 + 光感反馈；默认颜色由系统给（lightEffect.color = undefined）。
   */
  static floating(): SystemUiMaterial | undefined {
    if (!SpatialMaterial.supported) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true,
      lightEffect: { color: undefined }
    });
  }

  /** HDS 标题栏的材质参数：设备不支持 HDS 系统材质时返回 undefined（保持普通渐变模糊） */
  static hds(): SystemMaterialParams | undefined {
    if (hdsMaterial.getSystemMaterialTypes().length === 0) {
      return undefined;
    }
    return {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    };
  }
}
