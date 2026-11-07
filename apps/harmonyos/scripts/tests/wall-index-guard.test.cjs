// 旧 A–Z 索引晚到时不能盖住新查询。直接跑生产里的 WallIndexGuard。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../..');
const compilerPath = process.env.HARMONY_TYPESCRIPT_PATH || path.join(
  process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const ts = require(fs.existsSync(compilerPath) ? compilerPath : 'typescript');

function load(file) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const moduleUnderTest = { exports: {} };
  new Function('exports', output)(moduleUnderTest.exports);
  return moduleUnderTest.exports;
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}

const { WallIndexGuard } = load('entry/src/main/ets/library/WallIndexGuard.ets');

test('a late index from the previous query is dropped', async () => {
  let current = 'title||wunfinished';
  const published = [];
  const first = deferred();
  const second = deferred();
  const run = (key, pending) => WallIndexGuard.load(key, () => current, () => pending.promise)
    .then((index) => {
      if (index !== null) published.push(index);
    });
  const oldLoad = run('title||wunfinished', first);
  current = 'title||';
  const newLoad = run('title||', second);
  second.resolve([{ initial: 'A' }]);
  await newLoad;
  first.resolve([{ initial: 'U' }]);
  await oldLoad;
  assert.deepEqual(published, [[{ initial: 'A' }]]);
});

test('a late index failure does not clear the index of the newer query', async () => {
  let current = 'title||wunfinished';
  const published = [];
  const first = deferred();
  const second = deferred();
  const run = (key, pending) => WallIndexGuard.load(key, () => current, () => pending.promise)
    .then((index) => {
      if (index !== null) published.push(index);
      return 'kept';
    })
    .catch(() => 'cleared');
  const oldLoad = run('title||wunfinished', first);
  current = 'title||';
  const newLoad = run('title||', second);
  second.resolve([{ initial: 'A' }]);
  assert.equal(await newLoad, 'kept');
  first.reject(new Error('old index failed'));
  assert.equal(await oldLoad, 'kept');
  assert.deepEqual(published, [[{ initial: 'A' }]]);
});

test('the current query still publishes its index and still reports its own failure', async () => {
  let current = 'title||';
  const index = await WallIndexGuard.load(current, () => current, async () => [{ initial: 'A' }]);
  assert.deepEqual(index, [{ initial: 'A' }]);
  await assert.rejects(
    WallIndexGuard.load(current, () => current, async () => { throw new Error('down'); }),
    /down/,
  );
});

test('both library detail index writes go through the guard', () => {
  const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/library/LibraryDetailPage.ets'), 'utf8');
  assert.equal(page.includes('this.index = await fetchWallIndex'), false);
  assert.equal(page.split('WallIndexGuard.load').length - 1, 2);
});
