// Execute the production A–Z index query gate without the Harmony device/UI runtime.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.HARMONY_TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = path.resolve(__dirname, '../../entry/src/main/ets/library/LatestRequestGate.ets');
const moduleUnderTest = { exports: {} };
new Function('exports', ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
}).outputText)(moduleUnderTest.exports);
const { LatestRequestGate } = moduleUnderTest.exports;
const pageSource = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/library/LibraryDetailPage.ets'), 'utf8');

function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
const flush = () => new Promise(resolve => setImmediate(resolve));

/**
 * Mirrors LibraryDetailPage: reloadWall takes its identity before any await, awaits the wall
 * (pager.reset), then fetches the index through the gate; reload() (poll) captures current()
 * before its awaits. The production page shape is asserted separately below.
 */
function page() {
  const gate = new LatestRequestGate();
  const state = { index: [], indexRequests: [] };
  return {
    state,
    async reloadWall(filter, wall, index) {
      const query = gate.begin();
      state.index = [];
      await wall;
      if (!index) return;
      try {
        const entries = await gate.run(query, () => { state.indexRequests.push(filter); return index(); });
        if (entries !== undefined) state.index = entries;
      } catch {
        if (gate.isCurrent(query)) state.index = [];
      }
    },
    async poll(filter, refresh, index) {
      const query = gate.current();
      await refresh;
      const entries = await gate.run(query, () => { state.indexRequests.push(filter); return index(); });
      if (entries !== undefined) state.index = entries;
    },
  };
}

test('an old wall that returns late never requests or commits its stale index', async () => {
  const p = page();
  const wallA = deferred();
  const indexB = deferred();
  const a = p.reloadWall('unfinished', wallA.promise, async () => [{ initial: 'W', offset: 0 }]);
  const b = p.reloadWall('all', Promise.resolve(), () => indexB.promise);
  await flush();
  indexB.resolve([{ initial: 'A', offset: 0 }, { initial: 'Q', offset: 12 }]);
  await b;
  // A's wall comes back only after B's index was committed (pager drops A's rows; A must not fetch).
  wallA.resolve();
  await a;
  assert.deepEqual(p.state.indexRequests, ['all']);
  assert.deepEqual(p.state.index.map(e => [e.initial, e.offset]), [['A', 0], ['Q', 12]]);
});

test('an old wall that returns before the new index arrives cannot win either', async () => {
  const p = page();
  const wallA = deferred();
  const wallB = deferred();
  const indexB = deferred();
  const a = p.reloadWall('unfinished', wallA.promise, async () => [{ initial: 'W', offset: 0 }]);
  const b = p.reloadWall('all', wallB.promise, () => indexB.promise);
  wallB.resolve();
  await flush();
  wallA.resolve();
  await a;
  indexB.resolve([{ initial: 'A', offset: 0 }]);
  await b;
  assert.deepEqual(p.state.indexRequests, ['all']);
  assert.deepEqual(p.state.index.map(e => e.initial), ['A']);
});

test('an index already in flight is dropped when the query changes, success or failure', async () => {
  const p = page();
  const indexA = deferred();
  const a = p.reloadWall('unfinished', Promise.resolve(), () => indexA.promise);
  await flush();
  await p.reloadWall('all', Promise.resolve(), async () => [{ initial: 'B', offset: 3 }]);
  indexA.reject(new Error('timeout'));
  await a;
  assert.deepEqual(p.state.index.map(e => e.initial), ['B']);

  const indexC = deferred();
  const c = p.reloadWall('unfinished', Promise.resolve(), () => indexC.promise);
  await flush();
  await p.reloadWall('all-by-added', Promise.resolve(), null); // sort without an index
  indexC.resolve([{ initial: 'W', offset: 0 }]);
  await c;
  assert.deepEqual(p.state.index, []);
});

test('a poll that started before a filter change does not overwrite the new index', async () => {
  const p = page();
  await p.reloadWall('unfinished', Promise.resolve(), async () => [{ initial: 'W', offset: 0 }]);
  const refresh = deferred();
  const poll = p.poll('unfinished', refresh.promise, async () => [{ initial: 'W', offset: 0 }]);
  await p.reloadWall('all', Promise.resolve(), async () => [{ initial: 'A', offset: 0 }]);
  refresh.resolve();
  await poll;
  assert.deepEqual(p.state.index.map(e => e.initial), ['A']);
  assert.deepEqual(p.state.indexRequests, ['unfinished', 'all']);
  // An undisturbed poll still refreshes the index of the current query.
  await p.poll('all', Promise.resolve(), async () => [{ initial: 'A', offset: 0 }, { initial: 'Z', offset: 9 }]);
  assert.deepEqual(p.state.index.map(e => e.initial), ['A', 'Z']);
});

test('the current query still reports its own failure', async () => {
  const gate = new LatestRequestGate();
  const query = gate.begin();
  assert.deepEqual(await gate.run(query, async () => ['ok']), ['ok']);
  await assert.rejects(gate.run(query, async () => { throw new Error('boom'); }), /boom/);
});

function body(name) {
  const start = pageSource.indexOf(`private async ${name}(): Promise<void> {`);
  assert.ok(start >= 0, name);
  const end = pageSource.indexOf('\n  }\n', start);
  return pageSource.slice(start, end);
}

test('LibraryDetailPage takes the query identity before awaiting and checks it on every index commit', () => {
  assert.doesNotMatch(pageSource, /this\.index\s*=\s*await/);
  const reloadWall = body('reloadWall');
  const begin = reloadWall.indexOf('this.indexGate.begin()');
  assert.ok(begin >= 0 && begin < reloadWall.search(/await\s+[A-Za-z(]/), 'begin() must precede every await in reloadWall');
  assert.match(reloadWall, /this\.indexGate\.run\(\s*query,/);
  assert.match(reloadWall, /catch \(error\) \{\s*if \(this\.indexGate\.isCurrent\(query\)\)/);
  const poll = body('reload');
  const current = poll.indexOf('this.indexGate.current()');
  assert.ok(current >= 0 && current < poll.search(/await\s+[A-Za-z(]/), 'poll must capture current() before awaiting');
  assert.match(poll, /this\.indexGate\.run\(\s*query,/);
  assert.equal((pageSource.match(/this\.indexGate\.run\(/g) || []).length, 2);
});
