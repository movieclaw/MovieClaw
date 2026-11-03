import {
  BlurStrategy,
  DynamicHideParams,
  HdsNavigationTitleBarOptions,
  HideMode,
  ScrollEffectType,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { Theme } from '../theme/AppTheme';
import { SpatialMaterial } from './SpatialMaterial';
import { WindowInsets } from './WindowInsets';

/**
 * 各页签根页的标题栏：**全 App 唯一实现**（此前五个 NavHost 各抄了一份配置）。
 *
 * 统一口径（见 docs 里的 HdsNavigation「动态模糊样式」/ 沉浸光感最佳实践）：
 * - MINI 标题栏 + 内容行定高 56（`HEIGHT`）：标题 20vp Medium、左 16、右 12；
 * - `IMMERSIVE_GRADIENT_BLUR` + `BlurStrategy.ENABLE` + `systemMaterialEffect`：
 *   静止时标题栏透明、滚动后渐显磨砂光感（沉浸光感 / 空间化）；
 * - `dynamicHideTitleBar`：上滑收起标题栏与状态栏图标，下滑恢复；
 * - 标题栏**不是**组件级安全区（`enableComponentSafeArea: false`）：页面内容从 y=0 铺起、
 *   从标题栏下面穿过去，顶栏区域才不会是「一条黑边」。非头图页的滚动内容因此要在
 *   最上面空出 `contentTop`（状态栏 + 56）——这段留白在滚动区里，会跟着内容滚走。
 *
 * 二级页不用这套：它们统一用 `common/PageTopBar`（返回 + 标题的自绘毛玻璃条）。
 */
export class AppNavBar {
  /** 标题栏内容行高度（官方 MINI 标题栏的标准高度） */
  static readonly HEIGHT: number = 56;

  /** 沉浸：内容铺进顶部系统安全区（Hero 从屏幕最顶端钻到状态栏底下） */
  static readonly SAFE_AREA_TYPES: LayoutSafeAreaType[] = [LayoutSafeAreaType.SYSTEM];
  static readonly SAFE_AREA_EDGES: LayoutSafeAreaEdge[] = [LayoutSafeAreaEdge.TOP];

  /** 非头图页滚动内容要让开的高度 = 状态栏 + 标题行（内容从 y=0 起时的顶部留白） */
  static get contentTop(): number {
    return WindowInsets.shared().top + AppNavBar.HEIGHT;
  }

  /**
   * 二级页（`HdsNavDestination`）的标题栏：**与根页签同一套样式**——沉浸光感渐变模糊
   * （`IMMERSIVE_GRADIENT_BLUR` + `systemMaterialEffect`），标题与返回键交给官方渲染。
   *
   * - `contentUnderBar = true`（默认）：页面内容从 y=0 铺到标题栏下面，滚动时才有文档里那种
   *   「透明 → 磨砂」的渐变；此时页面自己的滚动内容要用 `contentTop` 让开首屏。
   * - `contentUnderBar = false`：内容由系统排在标题栏下方（适合同一页里还有固定头部、
   *   或由子组件各自滚动的页面），标题栏样式仍与根页签一致。
   */
  static subPageTitleBar(title: string, contentUnderBar: boolean = true): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: !contentUnderBar,
      content: {
        title: { mainTitle: title }
      },
      style: AppNavBar.style()
    };
  }

  /** 标题栏样式：所有根页签共用这一份，改这里就是全局改 */
  static style(): TitleBarStyleOptions {
    return {
      /*
       * 沉浸光感（空间化）：官方「沉浸式渐变模糊」——静止时完全透明、滚动后渐显磨砂，
       * 模糊区域比 GRADIENT_BLUR 更大；配合 systemMaterialEffect 才是完整的空间化标题栏。
       * 设备不支持 HDS 材质时 systemMaterialEffect 为 undefined，退回普通渐变模糊。
       */
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
      },
      blurStrategy: BlurStrategy.ENABLE,
      systemMaterialEffect: SpatialMaterial.hds()
    };
  }

  /**
   * 标题栏 + 状态栏的滑动显隐（文档「标题栏和状态栏适配滑动显隐」）：
   * 上滑到固定位置收起标题栏与状态栏图标，下滑回来。
   * 与内容区滚动器的联动来自 `bindToScrollable([scroller])`，这里只给显隐策略。
   */
  static dynamicHide(): DynamicHideParams {
    return {
      hideTitleArea: true,
      hideStatusBar: true,
      mode: HideMode.SCROLL_UP_TO
    };
  }
}

/**
 * 统一的标题行（`titleBar.content.stackBuilder` 的内容）：标题 + 右侧动作。
 * 右上是各页签自己的胶囊/菜单，但字号、边距、行高都从这里来，五个页签一致。
 */
@ComponentV2
export struct AppNavTitleBar {
  @Param title: string = '';
  /** 右侧动作（可空）：胶囊、图标按钮都放这里 */
  @BuilderParam actions: () => void = this.NoActions;

  @Builder
  NoActions() {
  }

  build() {
    Row() {
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .margin({ left: 16 })
      Blank()
      this.actions()
    }
    .width('100%')
    .height(AppNavBar.HEIGHT)
    .alignItems(VerticalAlign.Center)
    .margin({ right: 12 })
  }
}
