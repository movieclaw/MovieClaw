/**
 * 同步决策逻辑测试：`pnpm --filter extension test`（Node ≥ 22.18 原生去类型执行 .ts，无额外依赖）。
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  PENDING_GRANT_TTL_MS,
  type PendingGrant,
  cookieQuery,
  hasPushed,
  hostsFromOrigins,
  mergeSyncState,
  shouldAutoSync,
  storeMatches,
  syncActionLabel,
} from './sync-logic.ts';

const NOW = 1_800_000_000_000;
const pending = (at: number): PendingGrant => ({
  domain: 'm-team.cc',
  host: 'kp.m-team.cc',
  url: 'https://kp.m-team.cc/',
  at,
});

test('按钮文案只看本扩展是否推送成功过', () => {
  assert.equal(syncActionLabel(undefined), '立即同步');
  assert.equal(syncActionLabel({ ok: false, at: NOW, message: 'x' }), '立即同步');
  assert.equal(syncActionLabel({ ok: true, at: NOW }), '重新同步');
  assert.equal(syncActionLabel({ ok: false, at: NOW, lastSuccessAt: NOW - 1000 }), '重新同步');
});

test('失败不会抹掉上次成功时间', () => {
  const ok = mergeSyncState(undefined, { ok: true, at: 100, siteName: '馒头' });
  assert.equal(ok.lastSuccessAt, 100);
  const failed = mergeSyncState(ok, { ok: false, at: 200, message: 'boom' });
  assert.equal(failed.ok, false);
  assert.equal(failed.lastSuccessAt, 100);
  assert.equal(failed.siteName, '馒头');
  assert.ok(hasPushed(failed));
  // 旧版本数据：只有 ok/at
  assert.equal(mergeSyncState({ ok: true, at: 50 }, { ok: false, at: 60 }).lastSuccessAt, 50);
  assert.equal(mergeSyncState(undefined, { ok: false, at: 60 }).lastSuccessAt, undefined);
});

test('自动同步决策', () => {
  const base = { cookieCount: 3, state: undefined, pending: null, now: NOW };
  // 授权了但从没推过 → 自动推
  assert.equal(shouldAutoSync(base), true);
  // 没读到 Cookie → 不推
  assert.equal(shouldAutoSync({ ...base, cookieCount: 0, pending: pending(NOW) }), false);
  // 推过了 → 不再自动推
  assert.equal(shouldAutoSync({ ...base, state: { ok: true, at: NOW - 10 } }), false);
  // 上次失败 → 不自动重试，交给用户
  assert.equal(shouldAutoSync({ ...base, state: { ok: false, at: NOW - 10 } }), false);
  // 刚授权（弹窗被权限提示关掉）→ 即使有失败记录也推
  assert.equal(shouldAutoSync({ ...base, state: { ok: false, at: NOW - 10 }, pending: pending(NOW - 5000) }), true);
  // 过期的授权意图不算
  assert.equal(
    shouldAutoSync({ ...base, state: { ok: true, at: NOW - 10 }, pending: pending(NOW - PENDING_GRANT_TTL_MS - 1) }),
    false,
  );
});

test('cookie store 选择与过滤', () => {
  assert.deepEqual(cookieQuery('https://a.com/'), { url: 'https://a.com/' });
  assert.deepEqual(cookieQuery('https://a.com/', undefined), { url: 'https://a.com/' });
  assert.deepEqual(cookieQuery('https://a.com/', 'firefox-container-2'), {
    url: 'https://a.com/',
    storeId: 'firefox-container-2',
  });
  assert.equal(storeMatches(undefined, 'firefox-container-2'), true);
  assert.equal(storeMatches('firefox-container-2', undefined), true);
  assert.equal(storeMatches('firefox-container-2', 'firefox-container-2'), true);
  assert.equal(storeMatches('firefox-container-2', 'firefox-default'), false);
});

test('从权限模式提取主机名', () => {
  assert.deepEqual(hostsFromOrigins(['*://m-team.cc/*', '*://*.m-team.cc/*']), ['m-team.cc']);
  assert.deepEqual(hostsFromOrigins(['http://localhost/*']), ['localhost']);
  assert.deepEqual(hostsFromOrigins(['*://*/*', '<all_urls>']), []);
});
