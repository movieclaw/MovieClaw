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
  let generation = 0;
  const published = [];
  const first = deferred();
  const second = deferred();
  const run = (key, pending) => WallIndexGuard.load(++generation, () => generation, key, () => current, () => pending.promise)
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
  let generation = 0;
  const published = [];
  const first = deferred();
  const second = deferred();
  const run = (key, pending) => WallIndexGuard.load(++generation, () => generation, key, () => current, () => pending.promise)
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
  let generation = 1;
  const index = await WallIndexGuard.load(generation, () => generation, current, () => current, async () => [{ initial: 'A' }]);
  assert.deepEqual(index, [{ initial: 'A' }]);
  generation += 1;
  await assert.rejects(
    WallIndexGuard.load(generation, () => generation, current, () => current, async () => { throw new Error('down'); }),
    /down/,
  );
});

test('an old A response is dropped after the query changes from A to B to A', async () => {
  let current = 'A';
  let generation = 0;
  const published = [];
  const firstA = deferred();
  const middleB = deferred();
  const latestA = deferred();
  const run = (key, pending) => WallIndexGuard.load(++generation, () => generation, key, () => current, () => pending.promise)
    .then((index) => {
      if (index !== null) published.push(index);
    });

  const oldLoad = run('A', firstA);
  current = 'B';
  const middleLoad = run('B', middleB);
  current = 'A';
  const newLoad = run('A', latestA);
  latestA.resolve([{ initial: 'new A' }]);
  await newLoad;
  middleB.resolve([{ initial: 'B' }]);
  await middleLoad;
  firstA.resolve([{ initial: 'old A' }]);
  await oldLoad;

  assert.deepEqual(published, [[{ initial: 'new A' }]]);
});

test('the older of two concurrent requests for the same key is dropped', async () => {
  const current = 'A';
  let generation = 0;
  const first = deferred();
  const second = deferred();
  const oldLoad = WallIndexGuard.load(++generation, () => generation, current, () => current, () => first.promise);
  const newLoad = WallIndexGuard.load(++generation, () => generation, current, () => current, () => second.promise);

  second.resolve([{ initial: 'new A' }]);
  assert.deepEqual(await newLoad, [{ initial: 'new A' }]);
  first.resolve([{ initial: 'old A' }]);
  assert.equal(await oldLoad, null);
});

test('both library detail index writes go through the guard', () => {
  const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/library/LibraryDetailPage.ets'), 'utf8');
  assert.equal(page.includes('this.index = await fetchWallIndex'), false);
  assert.equal(page.split('WallIndexGuard.load').length - 1, 2);
  assert.equal(page.split('++this.wallIndexGeneration').length - 1, 2);
  assert.equal(page.split('(): number => this.wallIndexGeneration').length - 1, 2);
});
