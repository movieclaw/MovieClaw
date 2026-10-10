import { hapTasks, OhosHapContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { hvigor, getNode } from '@ohos/hvigor';
import * as fs from 'fs';
import * as path from 'path';

function parseDotEnv(raw: string): Map<string, string> {
  const map = new Map<string, string>();
  const lines: string[] = raw.split(/\r?\n/);
  for (const line of lines) {
    const trimmed: string = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith('#')) {
      continue;
    }
    const eq: number = trimmed.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key: string = trimmed.slice(0, eq).trim();
    let value: string = trimmed.slice(eq + 1).trim();
    if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))) {
      value = value.slice(1, value.length - 1);
    }
    map.set(key, value);
  }
  return map;
}

function esc(source: string): string {
  return source
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\r?\n/g, '\\n');
}

function stubContent(): string {
  return [
    '/**',
    ' * 本文件由 hvigorfile.ts 自动生成，勿手改。',
    ' * release 构建：恒为空桩，开发快捷登录与凭据不会进入正式包。',
    ' */',
    'export class DevConfig {',
    '  static readonly isDev: boolean = false;',
    '  static readonly lanServer: string = \'\';',
    '  static readonly lanUsername: string = \'\';',
    '  static readonly lanPassword: string = \'\';',
    '  static readonly wanServer: string = \'\';',
    '  static readonly wanUsername: string = \'\';',
    '  static readonly wanPassword: string = \'\';',
    '}',
    ''
  ].join('\n');
}

function devContent(env: Map<string, string>): string {
  const get = (key: string): string => esc(env.get(key) ?? '');
  return [
    '/**',
    ' * 本文件由 hvigorfile.ts 自动生成，勿手改。',
    ' * debug 构建：内容来自项目根目录 .env，仅供开发期快捷登录使用。',
    ' */',
    'export class DevConfig {',
    '  static readonly isDev: boolean = true;',
    `  static readonly lanServer: string = '${get('LAN_SERVER')}';`,
    `  static readonly lanUsername: string = '${get('LAN_USERNAME')}';`,
    `  static readonly lanPassword: string = '${get('LAN_PASSWORD')}';`,
    `  static readonly wanServer: string = '${get('WAN_SERVER')}';`,
    `  static readonly wanUsername: string = '${get('WAN_USERNAME')}';`,
    `  static readonly wanPassword: string = '${get('WAN_PASSWORD')}';`,
    '}',
    ''
  ].join('\n');
}

/**
 * debug 构建时把根目录 .env 注入 DevConfig.ets；
 * release 构建时生成空桩，凭据不进包。
 */
hvigor.nodesEvaluated(() => {
  const node = getNode(__filename);
  if (node === undefined || node === null) {
    return;
  }
  const ctx = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
  if (ctx === undefined || ctx === null) {
    return;
  }
  const isDebug: boolean = ctx.getBuildMode() === 'debug';
  const moduleDir: string = path.dirname(__filename);
  const envPath: string = path.resolve(moduleDir, '..', '.env');
  let env: Map<string, string> = new Map<string, string>();
  if (fs.existsSync(envPath)) {
    env = parseDotEnv(fs.readFileSync(envPath, 'utf-8'));
  }
  const content: string = isDebug ? devContent(env) : stubContent();
  const target: string = path.join(moduleDir, 'src', 'main', 'ets', 'common', 'DevConfig.ets');
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf-8') !== content) {
    fs.writeFileSync(target, content, 'utf-8');
  }
});

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []       /* Custom plugin to extend the functionality of Hvigor. */
}
