// Execute the production home merge without the Harmony device/UI runtime.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.HARMONY_TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = path.resolve(__dirname, '../../entry/src/main/ets/library/HomeRows.ets');
const moduleUnderTest = { exports: {} };
new Function('exports', ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
}).outputText)(moduleUnderTest.exports);
const { HomeRows } = moduleUnderTest.exports;
const libraries = [{ id: 1, name: 'Movies', kind: 'movie', viewer_access: true, exclude_from_home: false }];
function row(pref) { return HomeRows.build([{ id: 'lib:1', ...pref }], libraries, []).find(row => row.id === 'lib:1').kind; }
test('unfinished survives saved preferences and takes precedence over legacy unwatched', () => {
  const actual = row({ unfinished: true, unwatched: true, sort: 'title', order: 'desc' });
  assert.equal(actual.unfinished, true);
  assert.equal(actual.unwatched, false);
  assert.equal(actual.reversed, true);
});
test('legacy unwatched still has its distinct meaning', () => {
  assert.equal(row({ unwatched: true }).unwatched, true);
  assert.equal(row({ unwatched: true }).unfinished, false);
});
test('recently watched clears incompatible unfinished and unwatched preferences', () => {
  const actual = row({ unfinished: true, unwatched: true, sort: 'last_played' });
  assert.equal(actual.unfinished, false);
  assert.equal(actual.unwatched, false);
});
