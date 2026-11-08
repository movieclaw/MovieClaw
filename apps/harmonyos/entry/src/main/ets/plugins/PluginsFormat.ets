import { BlockedBy, HealthView, PluginView } from '../api/Models';
import { Formatters } from '../common/Formatters';
import { Theme } from '../theme/AppTheme';
import { PluginInstalledPackage, PluginPathGrant } from './PluginsApi';

/**
 * 插件页的展示口径（对应 Web `lib/plugins-display.ts`）：状态 → 文案与颜色、
 * 「为什么没起来」的一句话、官方 / 系统模块分层、插件包行内说明。
 * 这里的措辞直接上屏。
 */

/** 内置插件分组（系统模块清单内部） */
export class PluginGroup {
  readonly label: string;
  readonly plugins: PluginView[];

  constructor(label: string, plugins: PluginView[]) {
    this.label = label;
    this.plugins = plugins;
  }
}

export class PluginDisplay {
  static stateLabel(state: string): string {
    if (state === 'active') {
      return '运行中';
    }
    if (state === 'failed') {
      return '失败';
    }
    if (state === 'pending') {
      return '等待依赖';
    }
    if (state === 'disabled') {
      return '已关闭';
    }
    if (state === 'incompatible') {
      return '不兼容';
    }
    if (state === 'loading') {
      return '加载中';
    }
    if (state === 'unloading') {
      return '卸载中';
    }
    if (state === 'disposed') {
      return '已释放';
    }
    return state;
  }

  static stateTone(state: string): string {
    if (state === 'active') {
      return Theme.ok;
    }
    if (state === 'failed' || state === 'incompatible') {
      return Theme.danger;
    }
    if (state === 'pending') {
      return Theme.warn;
    }
    if (state === 'loading' || state === 'unloading') {
      return Theme.info;
    }
    return Theme.textMuted;
  }

  /** 插件自己报告的降级（令牌过期、外部系统连不上……） */
  static degradedHealth(plugin: PluginView): string[] {
    const out: string[] = [];
    const health: HealthView[] = plugin.health ?? [];
    for (const item of health) {
      if (!item.ok && item.message.length > 0) {
        out.push(item.message);
      }
    }
    return out;
  }

  /** 等依赖、但依赖是被有意关掉的：跟着关闭，不是故障 */
  static offWithDependency(plugin: PluginView): boolean {
    const blocked: BlockedBy[] = plugin.blocked_by ?? [];
    if (plugin.state !== 'pending' || blocked.length === 0) {
      return false;
    }
    for (const item of blocked) {
      if (item.provider_state !== 'disabled') {
        return false;
      }
    }
    return true;
  }

  static displayState(plugin: PluginView): string {
    return PluginDisplay.offWithDependency(plugin) ? 'disabled' : plugin.state;
  }

  /** 需要管理员留意：失败、不兼容、等依赖、运行中降级 */
  static needsAttention(plugin: PluginView): boolean {
    if (plugin.state === 'failed' || plugin.state === 'incompatible') {
      return true;
    }
    if (plugin.state === 'pending' && !PluginDisplay.offWithDependency(plugin)) {
      return true;
    }
    return plugin.state === 'active' && PluginDisplay.degradedHealth(plugin).length > 0;
  }

  private static disabledByText(source: string | null | undefined): string {
    const raw: string = source ?? '';
    if (raw.length === 0) {
      return '已关闭';
    }
    if (raw === 'switch') {
      return '管理员停用';
    }
    if (raw.startsWith('feature:')) {
      return '所属功能已停用';
    }
    if (raw === 'patch') {
      return '在 data/plugins.yaml 里关掉了';
    }
    if (raw.startsWith('env:')) {
      return `被环境变量 ${raw.substring(4)} 关掉了`;
    }
    return '已关闭';
  }

  /** 行内说明：没起来的写原因，起来的写启动耗时 */
  static detailText(plugin: PluginView): string {
    if (plugin.state === 'failed') {
      const error: string = plugin.error ?? '';
      return error.length > 0 ? error : '启动失败，原因未知';
    }
    if (plugin.state === 'incompatible') {
      const reason: string = plugin.incompatible ?? '';
      return reason.length > 0 ? reason : '版本不匹配';
    }
    if (plugin.state === 'pending') {
      const blocked: BlockedBy[] = plugin.blocked_by ?? [];
      if (PluginDisplay.offWithDependency(plugin)) {
        const names: string[] = [];
        for (const item of blocked) {
          names.push(item.provider ?? item.key);
        }
        return `依赖已关闭：${names.join('、')}`;
      }
      if (blocked.length === 0) {
        return '正在等待依赖';
      }
      const parts: string[] = [];
      for (const item of blocked) {
        parts.push(`缺少 ${item.key}（${item.reason}）`);
      }
      return parts.join('；');
    }
    if (plugin.state === 'disabled') {
      return PluginDisplay.disabledByText(plugin.disabled_by);
    }
    if (plugin.state === 'active') {
      const degraded: string[] = PluginDisplay.degradedHealth(plugin);
      if (degraded.length > 0) {
        return `运行中降级：${degraded.join('；')}`;
      }
      const parts: string[] = [];
      if (plugin.apply_ms !== null && plugin.apply_ms !== undefined) {
        parts.push(`启动 ${PluginDisplay.duration(plugin.apply_ms)}`);
      }
      if (plugin.stats.tasks > 0) {
        parts.push(`${plugin.stats.tasks} 个后台任务`);
      }
      const progressErrors: number = plugin.stats.failures + plugin.stats.timeouts;
      if (progressErrors > 0) {
        parts.push(`${progressErrors} 次运行错误`);
      }
      return parts.join(' · ');
    }
    return PluginDisplay.stateLabel(plugin.state);
  }

  /** 启动耗时文案 */
  static duration(ms: number): string {
    if (ms >= 1000) {
      return `${(ms / 1000).toFixed(ms >= 10000 ? 0 : 1)} 秒`;
    }
    return `${Math.max(0, Math.round(ms))} 毫秒`;
  }

  /** 列表顺序：需要留意的在前，其余保持服务器给的启动顺序 */
  static sortPlugins(plugins: PluginView[]): PluginView[] {
    const attention: PluginView[] = [];
    const rest: PluginView[] = [];
    for (const item of plugins) {
      if (PluginDisplay.needsAttention(item)) {
        attention.push(item);
      } else {
        rest.push(item);
      }
    }
    return attention.concat(rest);
  }

  static isBuiltin(plugin: PluginView): boolean {
    return plugin.source === 'builtin';
  }

  /** 插件页分层；旧服务端没有分层时内置插件一律当系统模块 */
  static tierOf(plugin: PluginView): string {
    const tier: string = plugin.tier ?? '';
    if (tier.length > 0) {
      return tier;
    }
    return PluginDisplay.isBuiltin(plugin) ? 'system' : '';
  }

  /** 系统模块：应用运行所需，平时不展示 */
  static systemModules(plugins: PluginView[]): PluginView[] {
    const out: PluginView[] = [];
    for (const item of plugins) {
      if (PluginDisplay.tierOf(item) === 'system') {
        out.push(item);
      }
    }
    return out;
  }

  /** 官方插件：随应用提供、可用插件包替换的（含替换它们的插件包） */
  static officialPlugins(plugins: PluginView[]): PluginView[] {
    const out: PluginView[] = [];
    for (const item of plugins) {
      if (PluginDisplay.tierOf(item) === 'official'
        && (item.provides.length === 0 || PluginDisplay.needsAttention(item))) {
        out.push(item);
      }
    }
    return out;
  }

  static officialSourceText(plugin: PluginView): string {
    return PluginDisplay.isBuiltin(plugin) ? '随应用提供' : '由插件包替换';
  }

  /** 内置插件按功能分组：组序与归属由服务器给，没归属的收进末尾「其他」 */
  static groupBuiltins(plugins: PluginView[], groups: string[]): PluginGroup[] {
    const builtins: PluginView[] = [];
    for (const item of plugins) {
      if (PluginDisplay.isBuiltin(item)) {
        builtins.push(item);
      }
    }
    const known: string[] = groups;
    const result: PluginGroup[] = [];
    for (const label of groups) {
      const members: PluginView[] = [];
      for (const item of builtins) {
        if ((item.group ?? '') === label) {
          members.push(item);
        }
      }
      if (members.length > 0) {
        result.push(new PluginGroup(label, PluginDisplay.sortPlugins(members)));
      }
    }
    const other: PluginView[] = [];
    for (const item of builtins) {
      const group: string = item.group ?? '';
      if (group.length === 0 || known.indexOf(group) < 0) {
        other.push(item);
      }
    }
    if (other.length > 0) {
      result.push(new PluginGroup('其他', PluginDisplay.sortPlugins(other)));
    }
    return result;
  }

  /** 系统模块概况：一共几个、几个在运行、几个出问题、几个已关闭 */
  static summary(plugins: PluginView[]): string {
    let active: number = 0;
    let problems: number = 0;
    let disabled: number = 0;
    for (const item of plugins) {
      if (item.state === 'active') {
        active += 1;
      }
      if (PluginDisplay.needsAttention(item)) {
        problems += 1;
      }
      if (item.state === 'disabled') {
        disabled += 1;
      }
    }
    const parts: string[] = [`共 ${plugins.length} 个`, `运行 ${active} 个`];
    if (problems > 0) {
      parts.push(`异常 ${problems} 个`);
    }
    if (disabled > 0) {
      parts.push(`已关闭 ${disabled} 个`);
    }
    return parts.join(' · ');
  }

  static runtimeLabel(runtime: string | undefined | null): string {
    return runtime === 'inline' ? '主进程内运行' : '独立进程运行';
  }

  /** 路径授权 → 给人看的说明 */
  static pathGrantLabel(grant: PluginPathGrant): string {
    const mode: string = grant.mode === 'rw' ? '读写' : '只读';
    const path: string = grant.path;
    let where: string = path;
    if (path === 'library') {
      where = '全部媒体库';
    } else if (path.startsWith('library:')) {
      where = `媒体库 #${path.substring('library:'.length)}`;
    } else if (path === 'staging') {
      where = '下载暂存目录';
    } else if (path === 'plugin') {
      where = '插件自己的目录';
    }
    return `${where}（${mode}）`;
  }

  /** 已安装插件包的行内说明：版本、运行方式、权限规模、坏版本、宽限期 */
  static packageDetail(item: PluginInstalledPackage): string {
    const parts: string[] = [`v${item.version}`, PluginDisplay.runtimeLabel(item.runtime)];
    if (item.replaces_builtin) {
      parts.push('替换随带版本');
    }
    if (item.operations.length > 0) {
      parts.push(`${item.operations.length} 项权限`);
    }
    if (item.paths.length > 0) {
      parts.push(`${item.paths.length} 个目录`);
    }
    if (item.dependencies !== undefined && item.dependencies !== null) {
      parts.push(`${item.dependencies.packages.length} 个依赖`);
    }
    if (item.watching) {
      parts.push('安装观察期');
    }
    if (item.bad_versions.length > 0) {
      parts.push(`坏版本 ${item.bad_versions.join('、')}`);
    }
    return parts.join(' · ');
  }

  /** 插件类型（详情页头部） */
  static kindLabel(kind: string): string {
    if (kind === 'official') {
      return '官方插件';
    }
    if (kind === 'package') {
      return '插件包';
    }
    if (kind === 'local') {
      return '本地插件';
    }
    if (kind === 'system') {
      return '系统模块';
    }
    return kind;
  }

  /** 数据量：行数与磁盘占用 */
  static storageLine(rows: number, bytes: number): string {
    return `${rows} 行数据 · ${Formatters.bytes(bytes)}`;
  }
}
