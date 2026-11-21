// Execute the production OfflineDownloadChoices logic from OfflineUi.ets without the Harmony UI runtime.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const tsCandidates = [
  process.env.HARMONY_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript',
  path.resolve(__dirname, '../../../../node_modules/typescript'),
  path.resolve(__dirname, '../../../../apps/web/node_modules/typescript'),
].filter(Boolean);
const tsPath = tsCandidates.find((p) => fs.existsSync(p));
const ts = require(tsPath);

const sourcePath = path.resolve(__dirname, '../../entry/src/main/ets/offline/OfflineUi.ets');
const fullText = fs.readFileSync(sourcePath, 'utf8');
// Extract the pure-logic classes (OfflineDownloadScope, OfflineEpisodeChoice, OfflineDownloadChoices)
// before any ArkUI @ComponentV2 structs.
const start = fullText.indexOf('export class OfflineDownloadScope');
const end = fullText.indexOf('/** 选档的算法');
assert.ok(start >= 0 && end > start, 'Expected OfflineDownloadChoices classes in OfflineUi.ets');
const snippet = fullText.slice(start, end);

const mod = { exports: {} };
new Function('exports', ts.transpileModule(snippet, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
}).outputText)(mod.exports);

const { OfflineEpisodeChoice, OfflineDownloadChoices } = mod.exports;

function episodes(count, season = 1, local = {}, played = []) {
  const playedSet = new Set(played);
  const out = [];
  for (let ep = 1; ep <= count; ep++) {
    out.push(new OfflineEpisodeChoice(season, ep, season * 1000 + ep, playedSet.has(ep), local[ep] ?? null));
  }
  return out;
}

test('single season preserves existing selected/unwatched/all behavior', () => {
  const choices = OfflineDownloadChoices.make(episodes(3, 1, {}, [1]), 1, 2, 1002, false);
  assert.equal(choices.seasonLabel, null);
  assert.equal(choices.note, null);
  assert.deepEqual(choices.scopes.map((s) => s.label), ['第 2 集', '未看 2 集', '全部 3 集']);
  assert.equal(choices.scopes.find((s) => s.preferred).id, 'unwatched');
  assert.equal(choices.scopes[1].detail, '第 2～3 集，共 2 集');
});

test('multi-season scopes stay within current season without cross-season local leakage', () => {
  const list = [
    ...episodes(5, 1, { 1: 'done', 2: 'done' }, [1, 2]),
    ...episodes(4, 2, {}, [1]),
    ...episodes(6, 3),
  ];
  const choices = OfflineDownloadChoices.make(list, 2, 2, 2002, true);
  assert.equal(choices.seasonLabel, '第 2 季');
  assert.equal(choices.hasLocal, false);
  assert.equal(choices.note, null);
  assert.deepEqual(choices.scopes.map((s) => s.label), ['第 2 集', '未看 3 集', '全部 4 集']);
  assert.equal(choices.scopes.find((s) => s.preferred).id, 'unwatched');
  assert.deepEqual(choices.scopes[0].fileIds, [2002]);
  assert.equal(choices.scopes[0].detail, '第 2 季第 2 集');
  assert.deepEqual(choices.scopes[1].fileIds, [2002, 2003, 2004]);
  assert.equal(choices.scopes[1].detail, '第 2 季第 2～4 集，共 3 集');
  assert.deepEqual(choices.scopes[2].fileIds, [2001, 2002, 2003, 2004]);
});

test('next episodes and end-of-season do not spill into next season', () => {
  const list = [...episodes(4, 1, { 2: 'done' }), ...episodes(3, 2)];
  const choices = OfflineDownloadChoices.make(list, 1, 2, null, true);
  assert.equal(choices.note, '第 1 季第 2 集已下载 · 已下载 1 集，不会重复下载');
  assert.deepEqual(choices.scopes.map((s) => s.label), ['接下来 2 集', '剩余 3 集']);
  assert.deepEqual(choices.scopes[0].fileIds, [1003, 1004]);
  assert.equal(choices.scopes[0].detail, '第 1 季第 3～4 集，共 2 集');
  assert.deepEqual(choices.scopes[1].fileIds, [1001, 1003, 1004]);
  assert.equal(choices.scopes[1].detail, '第 1 季第 1 集 起，共 3 集');
});

test('watched and downloaded episode labels remaining all-unwatched scope as 未看 N 集', () => {
  const list = episodes(10, 2, { 1: 'done' }, [1]);
  const choices = OfflineDownloadChoices.make(list, 2, 2, 2002, true);
  assert.equal(choices.seasonLabel, '第 2 季');
  assert.deepEqual(choices.scopes.map((s) => s.label), ['第 2 集', '未看 9 集']);
  assert.equal(choices.scopes.find((s) => s.preferred).label, '未看 9 集');
  assert.equal(choices.scopes[1].detail, '第 2 季第 2～10 集，共 9 集');
  assert.equal(choices.note, '已下载 1 集，不会重复下载');
});

test('specials season uses 特别篇 and distinguishes downloaded vs empty season', () => {
  const specials = OfflineDownloadChoices.make(
    [...episodes(3, 0, {}, [1]), ...episodes(2, 1)],
    0, 2, null, true, 0,
  );
  assert.equal(specials.seasonLabel, '特别篇');
  assert.equal(specials.scopes[0].detail, '特别篇第 2 集');
  assert.equal(specials.scopes[1].detail, '特别篇第 2～3 集，共 2 集');

  const downloaded = OfflineDownloadChoices.make(
    [...episodes(2, 1, { 1: 'done', 2: 'done' }), ...episodes(2, 2)],
    1, 1, null, true, 1,
  );
  assert.deepEqual(downloaded.scopes, []);
  assert.equal(downloaded.hasLocal, true);
  assert.equal(downloaded.seasonLabel, '第 1 季');

  const unowned = OfflineDownloadChoices.make(episodes(2, 1), 1, 1, null, true, 3);
  assert.deepEqual(unowned.scopes, []);
  assert.equal(unowned.hasLocal, false);
  assert.equal(unowned.seasonLabel, '第 3 季');
});
