// Isolated synthetic E2E and unit verification for PR #1352 fixes.
// Runs production HarmonyOS .ets modules via DevEco Studio's bundled TypeScript transpiler
// against real local synthetic HTTP servers and isolated temporary directories.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const ts = require(
  process.env.HARMONY_TYPESCRIPT_PATH
    || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'
);

const ETS_ROOT = path.resolve(__dirname, '../../entry/src/main/ets');

function transpileEts(relPath, preprocess) {
  const fullPath = path.resolve(ETS_ROOT, relPath);
  let source = fs.readFileSync(fullPath, 'utf8');
  if (preprocess) {
    source = preprocess(source);
  }
  return ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2021,
      experimentalDecorators: true,
    },
  }).outputText;
}

function loadEts(relPath, mocks = {}, preprocess) {
  const code = transpileEts(relPath, preprocess);
  const mod = { exports: {} };
  const customRequire = (id) => {
    if (Object.prototype.hasOwnProperty.call(mocks, id)) {
      return mocks[id];
    }
    throw new Error(`Unexpected import "${id}" while loading ${relPath}`);
  };
  new Function('exports', 'require', 'module', code)(mod.exports, customRequire, mod);
  return mod.exports;
}

/** Real Node.js HTTP adapter matching @kit.NetworkKit's http.createHttp() contract. */
function createNodeHttpKit() {
  return {
    http: {
      RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE', HEAD: 'HEAD' },
      HttpDataType: { STRING: 0, OBJECT: 1, ARRAY_BUFFER: 2 },
      createHttp() {
        let activeReq = null;
        let destroyed = false;
        return {
          request(url, options) {
            return new Promise((resolve, reject) => {
              if (destroyed) {
                reject({ code: 2300042, message: 'aborted' });
                return;
              }
              const parsed = new URL(url);
              const req = http.request(
                {
                  hostname: parsed.hostname,
                  port: parsed.port,
                  path: parsed.pathname + parsed.search,
                  method: options.method || 'GET',
                  headers: options.header || {},
                  timeout: options.readTimeout || 15000,
                },
                (res) => {
                  const chunks = [];
                  res.on('data', (chunk) => chunks.push(chunk));
                  res.on('end', () => {
                    const buf = Buffer.concat(chunks);
                    const result =
                      options.expectDataType === 2
                        ? buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)
                        : buf.toString('utf8');
                    resolve({
                      responseCode: res.statusCode,
                      header: res.headers,
                      result,
                    });
                  });
                }
              );
              activeReq = req;
              req.on('error', (err) => reject({ code: 2300007, message: err.message }));
              req.on('timeout', () => {
                req.destroy();
                reject({ code: 2300028, message: 'timeout' });
              });
              if (options.extraData !== undefined && options.extraData !== null) {
                req.write(options.extraData);
              }
              req.end();
            });
          },
          destroy() {
            destroyed = true;
            if (activeReq) {
              activeReq.destroy();
              activeReq = null;
            }
          },
        };
      },
    },
  };
}

/** Real Node.js filesystem adapter matching @kit.CoreFileKit's fileIo contract. */
function createNodeFileIoKit() {
  const OpenMode = {
    READ_ONLY: 0x1,
    WRITE_ONLY: 0x2,
    READ_WRITE: 0x4,
    CREATE: 0x8,
    TRUNC: 0x10,
  };
  return {
    fileIo: {
      OpenMode,
      accessSync(p) {
        return fs.existsSync(p);
      },
      mkdirSync(p, recursive) {
        fs.mkdirSync(p, { recursive: Boolean(recursive) });
      },
      statSync(p) {
        const s = fs.statSync(p);
        return { size: s.size };
      },
      openSync(p, mode) {
        let flags = 'r';
        if (mode & OpenMode.TRUNC) {
          flags = 'w+';
        } else if (mode & OpenMode.CREATE) {
          flags = 'a+';
        } else if (mode & OpenMode.READ_WRITE) {
          flags = 'r+';
        }
        return { fd: fs.openSync(p, flags) };
      },
      readSync(fd, buffer, opts = {}) {
        const view = new Uint8Array(buffer, opts.offset || 0, opts.length ?? buffer.byteLength);
        return fs.readSync(fd, view, 0, view.byteLength, null);
      },
      writeSync(fd, data) {
        if (typeof data === 'string') {
          return fs.writeSync(fd, data, undefined, 'utf8');
        }
        const view = new Uint8Array(data);
        return fs.writeSync(fd, view, 0, view.byteLength);
      },
      closeSync(file) {
        fs.closeSync(file.fd);
      },
      renameSync(from, to) {
        fs.renameSync(from, to);
      },
      unlinkSync(p) {
        fs.unlinkSync(p);
      },
      readTextSync(p) {
        return fs.readFileSync(p, 'utf8');
      },
      listFileSync(dir) {
        return fs.readdirSync(dir);
      },
    },
  };
}

function startServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      resolve({ server, origin: `http://127.0.0.1:${addr.port}` });
    });
  });
}

function closeServer(server) {
  return new Promise((resolve) => server.close(() => resolve()));
}

function loadApiClient() {
  const lruMod = loadEts('common/ImageLruPolicy.ets');
  return loadEts('api/ApiClient.ets', {
    '@kit.NetworkKit': createNodeHttpKit(),
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    '@kit.BasicServicesKit': {
      BusinessError: Error,
      deviceInfo: { productModel: 'TestDevice', osFullName: 'HarmonyOS-Test' },
    },
    '../common/ImageLruPolicy': lruMod,
  });
}

function loadImageDiskCache() {
  const lruMod = loadEts('common/ImageLruPolicy.ets');
  return loadEts('common/ImageDiskCache.ets', {
    '@kit.CoreFileKit': createNodeFileIoKit(),
    '@kit.AbilityKit': {},
    './ImageLruPolicy': lruMod,
  });
}

test('ApiClient conditional GET semantics, isolation across servers/accounts/cookies/routes, and write race', async () => {
  const { ApiClient } = loadApiClient();
  ApiClient.clearSessionCaches(true);

  const callsA = [];
  let versionA = 1;
  let etagMode = 'v1';
  let slowGetGate = null;
  let slowGetVersion = 1;
  let slowPostGate = null;

  const srvA = await startServer((req, res) => {
    callsA.push({
      method: req.method,
      url: req.url,
      auth: req.headers['authorization'] || '',
      inm: req.headers['if-none-match'] || '',
      cookie: req.headers['cookie'] || '',
      route: req.headers['x-movieclaw-route'] || '',
    });

    if (req.url === '/api/v1/health') {
      res.writeHead(200, { 'Content-Type': 'application/json', ETag: '"health-1"' });
      res.end(JSON.stringify({ status: 'ok', version: versionA }));
      return;
    }
    if (req.url === '/api/v1/auth/bootstrap') {
      res.writeHead(200, { 'Content-Type': 'application/json', ETag: '"boot-A"' });
      res.end(JSON.stringify({ success: true, data: { server: 'A', initialized: true } }));
      return;
    }
    if (req.url === '/api/v1/no-store') {
      res.writeHead(200, {
        'Content-Type': 'application/json',
        ETag: '"secret-1"',
        'Cache-Control': 'private, no-store',
      });
      res.end(JSON.stringify({ success: true, data: { secret: versionA } }));
      return;
    }
    if (req.url === '/api/v1/share/demo') {
      const unlocked = (req.headers['cookie'] || '').includes('movieclaw_share=ok');
      const etag = unlocked ? '"share-unlocked"' : '"share-locked"';
      if (req.headers['if-none-match'] === etag) {
        res.writeHead(304, { ETag: etag });
        res.end();
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json', ETag: etag });
      res.end(JSON.stringify({ success: true, data: { unlocked } }));
      return;
    }
    if (req.url === '/api/v1/share/demo/unlock' && req.method === 'POST') {
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Set-Cookie': 'movieclaw_share=ok; Path=/api/v1/share/demo',
      });
      res.end(JSON.stringify({ success: true, data: { ok: true } }));
      return;
    }
    if (req.url === '/api/v1/libraries' && req.method === 'GET') {
      const user = req.headers['authorization'] === 'Bearer tok-alice' ? 'alice' : 'bob';
      const route = req.headers['x-movieclaw-route'] || 'login';
      if (etagMode === 'no-etag') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, data: { user, route, version: versionA } }));
        return;
      }
      if (etagMode === '304-retag' && req.headers['if-none-match'] === `"${user}-${route}-v1"`) {
        res.writeHead(304, { ETag: `"${user}-${route}-v1-updated"` });
        res.end();
        return;
      }
      if (etagMode === '304-nostore' && req.headers['if-none-match'] === `"${user}-${route}-v1-updated"`) {
        res.writeHead(304, { 'Cache-Control': 'no-store' });
        res.end();
        return;
      }
      const etag = `"${user}-${route}-v${versionA}"`;
      if (req.headers['if-none-match'] === etag) {
        res.writeHead(304, { ETag: etag });
        res.end();
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json', ETag: etag });
      res.end(JSON.stringify({ success: true, data: { user, route, version: versionA } }));
      return;
    }
    if (req.url === '/api/v1/race' && req.method === 'GET') {
      const snapVersion = versionA;
      const respond = () => {
        res.writeHead(200, { 'Content-Type': 'application/json', ETag: `"race-v${snapVersion}"` });
        res.end(JSON.stringify({ success: true, data: { version: snapVersion } }));
      };
      if (slowGetGate && snapVersion === slowGetVersion) {
        slowGetGate.then(respond);
      } else {
        respond();
      }
      return;
    }
    if (req.url === '/api/v1/bump' && req.method === 'POST') {
      const finishPost = () => {
        versionA += 1;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, data: { version: versionA } }));
      };
      if (slowPostGate) {
        const gate = slowPostGate;
        slowPostGate = null;
        gate.then(finishPost);
      } else {
        finishPost();
      }
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const callsB = [];
  const srvB = await startServer((req, res) => {
    callsB.push({ url: req.url, inm: req.headers['if-none-match'] || '' });
    // Even if Server B returns 304 on a colliding If-None-Match, it must NEVER receive Server A's ETag!
    if (req.headers['if-none-match'] === '"boot-A"') {
      res.writeHead(304);
      res.end();
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json', ETag: '"boot-B"' });
    res.end(JSON.stringify({ success: true, data: { server: 'B', initialized: false } }));
  });

  try {
    // 1. Cross-server unauthenticated isolation (token = null)
    const anonA = new ApiClient(srvA.origin, null);
    const anonB = new ApiClient(srvB.origin, null);
    assert.deepEqual(await anonA.get('/auth/bootstrap'), { server: 'A', initialized: true });
    assert.deepEqual(await anonB.get('/auth/bootstrap'), { server: 'B', initialized: false });
    assert.equal(callsB[0].inm, '', 'Server B must never receive Server A ETag');

    // 2. Account + routeKind isolation + 304 ETag update + 304 no-store eviction + 200 without ETag eviction
    const alice = new ApiClient(srvA.origin, 'tok-alice');
    alice.routeKind = 'lan';
    const bob = new ApiClient(srvA.origin, 'tok-bob');
    bob.routeKind = 'lan';
    assert.deepEqual(await alice.get('/libraries'), { user: 'alice', route: 'lan', version: 1 });
    assert.deepEqual(await bob.get('/libraries'), { user: 'bob', route: 'lan', version: 1 });
    assert.equal(callsA[callsA.length - 1].inm, '', 'Bob must not send Alice ETag');

    // Route change isolates cache key
    const aliceWan = new ApiClient(srvA.origin, 'tok-alice');
    aliceWan.routeKind = 'wan';
    assert.deepEqual(await aliceWan.get('/libraries'), { user: 'alice', route: 'wan', version: 1 });
    assert.equal(callsA[callsA.length - 1].inm, '', 'WAN route must not collide with LAN cache');

    // 304 with updated ETag refreshes stored ETag for subsequent request
    etagMode = '304-retag';
    assert.deepEqual(await alice.get('/libraries'), { user: 'alice', route: 'lan', version: 1 });
    assert.equal(callsA[callsA.length - 1].inm, '"alice-lan-v1"');
    etagMode = '304-nostore';
    assert.deepEqual(await alice.get('/libraries'), { user: 'alice', route: 'lan', version: 1 });
    assert.equal(callsA[callsA.length - 1].inm, '"alice-lan-v1-updated"');
    // Previous 304 had Cache-Control: no-store -> cache entry must be evicted!
    etagMode = 'v1';
    assert.deepEqual(await alice.get('/libraries'), { user: 'alice', route: 'lan', version: 1 });
    assert.equal(callsA[callsA.length - 1].inm, '', '304 with no-store must evict cached ETag');

    // 200 without ETag removes previously cached ETag
    etagMode = 'no-etag';
    assert.deepEqual(await alice.get('/libraries'), { user: 'alice', route: 'lan', version: 1 });
    etagMode = 'v1';
    assert.deepEqual(await alice.get('/libraries'), { user: 'alice', route: 'lan', version: 1 });
    assert.equal(callsA[callsA.length - 1].inm, '', '200 without ETag must drop stale cached ETag');

    // 3. Cache-Control: no-store on 200 is never cached
    await alice.get('/no-store');
    await alice.get('/no-store');
    assert.equal(callsA[callsA.length - 1].inm, '', 'no-store response must never be cached');

    // 4. rawGet (/health) never sends If-None-Match or caches ETag
    await alice.rawGet('/health');
    await alice.rawGet('/health');
    assert.equal(callsA[callsA.length - 1].inm, '', 'rawGet probes must bypass ETag cache');

    // 5. Share cookie isolation + clearSessionCaches(true) wipes ETag and cookies
    assert.deepEqual(await anonA.get('/share/demo'), { unlocked: false });
    await anonA.post('/share/demo/unlock', '{}');
    assert.deepEqual(await anonA.get('/share/demo'), { unlocked: true });
    ApiClient.clearSessionCaches(true);
    assert.deepEqual(await anonA.get('/share/demo'), { unlocked: false });
    assert.equal(callsA[callsA.length - 1].inm, '');
    assert.equal(callsA[callsA.length - 1].cookie, '');

    // 6. Concurrent GET coalescing returns independent parsed copies
    const [r1, r2] = await Promise.all([alice.get('/libraries'), alice.get('/libraries')]);
    r1.mutated = true;
    assert.equal(r2.mutated, undefined, 'coalesced callers must receive independent parsed objects');

    // 7a. Write-vs-inflight GET race (GET starts BEFORE POST): post-write GET must NOT coalesce onto pre-write GET,
    //     and late pre-write GET must NOT write stale ETag back into cache!
    let releaseSlow;
    slowGetVersion = 1;
    slowGetGate = new Promise((r) => { releaseSlow = r; });
    const preWriteGet = alice.get('/race');
    await new Promise((r) => setTimeout(r, 20));
    await alice.post('/bump', '{}'); // versionA is now 2; clears inflightGets & bumps etagEpoch
    const postWriteGet = await alice.get('/race');
    assert.equal(postWriteGet.version, 2, 'post-write GET must not join stale pre-write inflight GET');
    releaseSlow();
    const lateOldResult = await preWriteGet;
    assert.equal(lateOldResult.version, 1);
    // Next GET must carry race-v2, NOT stale race-v1 overwritten by late pre-write GET!
    await alice.get('/race');
    assert.equal(callsA[callsA.length - 1].inm, '"race-v2"', 'late pre-write GET must not overwrite post-write ETag');

    // 7b. Write-vs-inflight GET race (GET starts WHILE POST is in-flight before server commits):
    //     post-write refresh on same client MUST NOT reuse the in-flight GET started during the write!
    let releaseDuringWriteGet;
    let releaseSlowPost;
    slowGetVersion = 2;
    slowGetGate = new Promise((r) => { releaseDuringWriteGet = r; });
    slowPostGate = new Promise((r) => { releaseSlowPost = r; });
    const pendingPost = alice.post('/bump', '{}'); // starts at v2, will bump to v3 on releaseSlowPost
    await new Promise((r) => setTimeout(r, 20));
    const duringWriteGet = alice.get('/race'); // hits server while versionA is still 2
    await new Promise((r) => setTimeout(r, 20));
    releaseSlowPost();
    await pendingPost; // versionA is now 3; finally invalidates inflightGets & bumps etagEpoch
    const postCommitRefresh = await alice.get('/race'); // MUST NOT join duringWriteGet!
    assert.equal(postCommitRefresh.version, 3, 'post-write refresh must not reuse GET started during write');
    releaseDuringWriteGet();
    assert.equal((await duringWriteGet).version, 2);
    await alice.get('/race');
    assert.equal(callsA[callsA.length - 1].inm, '"race-v3"', 'late during-write GET must not overwrite v3 ETag');

    // 7c. Cross-instance write invalidation: write on another ApiClient instance must prevent
    //     the first instance's post-write GET from coalescing onto its own pre-write inflight GET!
    const aliceSecondClient = new ApiClient(srvA.origin, 'tok-alice');
    aliceSecondClient.routeKind = 'lan';
    let releaseCrossGet;
    slowGetVersion = 3;
    slowGetGate = new Promise((r) => { releaseCrossGet = r; });
    const crossPreGet = alice.get('/race');
    await new Promise((r) => setTimeout(r, 20));
    await aliceSecondClient.post('/bump', '{}'); // bumps global etagEpoch; versionA is now 4
    const crossPostGet = await alice.get('/race');
    assert.equal(crossPostGet.version, 4, 'cross-instance write must break inflight coalescing on first client');
    releaseCrossGet();
    assert.equal((await crossPreGet).version, 3);
    slowGetGate = null;

    // 8. Logout / setToken clears ETag cache & inflight
    alice.setToken('tok-alice-2');
    await alice.get('/race');
    assert.equal(callsA[callsA.length - 1].inm, '', 'setToken must invalidate ETag cache');
  } finally {
    await closeServer(srvA.server);
    await closeServer(srvB.server);
  }
});

test('ImageDiskCache enforces per-owner isolation, orphan cleanup, and real 256MB LRU eviction', () => {
  const { ImageDiskCache } = loadImageDiskCache();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-img-cache-'));
  try {
    // 1. Default 256MB budget constant & real 256MB boundary eviction on disk
    assert.equal(ImageDiskCache.DEFAULT_BUDGET_BYTES, 256 * 1024 * 1024);
    ImageDiskCache.init({ cacheDir: tmpDir });
    assert.equal(ImageDiskCache.statsBudgetBytes(), 256 * 1024 * 1024);

    const chunk64MB = new ArrayBuffer(64 * 1024 * 1024);
    new Uint8Array(chunk64MB)[0] = 0xAA;
    for (let i = 1; i <= 4; i++) {
      ImageDiskCache.putBytes('http://srvA|alice', `https://img/big-${i}`, chunk64MB);
    }
    assert.equal(ImageDiskCache.statsEntries(), 4);
    assert.equal(ImageDiskCache.statsBytes(), 256 * 1024 * 1024);

    // Touch big-1 so big-2 becomes the LRU victim when big-5 arrives
    assert.notEqual(ImageDiskCache.getBytes('http://srvA|alice', 'https://img/big-1'), null);
    ImageDiskCache.putBytes('http://srvA|alice', 'https://img/big-5', chunk64MB);
    assert.equal(ImageDiskCache.statsEntries(), 4);
    assert.equal(ImageDiskCache.statsBytes(), 256 * 1024 * 1024);
    assert.equal(ImageDiskCache.contains('http://srvA|alice', 'https://img/big-1'), true);
    assert.equal(ImageDiskCache.contains('http://srvA|alice', 'https://img/big-2'), false);
    assert.equal(ImageDiskCache.contains('http://srvA|alice', 'https://img/big-5'), true);

    // Verify real disk bytes of .img files <= 256MB
    const cacheDir = path.join(tmpDir, 'img_cache_v1');
    const diskBytes = fs
      .readdirSync(cacheDir)
      .filter((f) => f.endsWith('.img'))
      .reduce((sum, f) => sum + fs.statSync(path.join(cacheDir, f)).size, 0);
    assert.equal(diskBytes, 256 * 1024 * 1024);

    // Cleanup 256MB test files before smaller tests
    ImageDiskCache.clearAll();
    assert.equal(ImageDiskCache.statsEntries(), 0);
    assert.equal(ImageDiskCache.statsBytes(), 0);

    // 2. Account / server isolation + clearOwner + orphan/v1 cleanup + restart eviction
    ImageDiskCache.init({ cacheDir: tmpDir }, 100);
    const bufA = new Uint8Array([1, 2, 3, 4]).buffer;
    const bufB = new Uint8Array([9, 8, 7, 6, 5]).buffer;
    const sharedUrl = 'http://srvA/api/v1/libraries/1/cover';
    ImageDiskCache.putBytes('http://srvA|alice', sharedUrl, bufA);
    ImageDiskCache.putBytes('http://srvA|bob', sharedUrl, bufB);
    ImageDiskCache.putBytes('http://srvB|alice', sharedUrl, new Uint8Array([7, 7]).buffer);

    assert.deepEqual(
      Array.from(new Uint8Array(ImageDiskCache.getBytes('http://srvA|alice', sharedUrl))),
      [1, 2, 3, 4]
    );
    assert.deepEqual(
      Array.from(new Uint8Array(ImageDiskCache.getBytes('http://srvA|bob', sharedUrl))),
      [9, 8, 7, 6, 5]
    );
    assert.deepEqual(
      Array.from(new Uint8Array(ImageDiskCache.getBytes('http://srvB|alice', sharedUrl))),
      [7, 7]
    );

    // clearOwner removes ONLY Alice on srvA, preserving Bob on srvA and Alice on srvB
    ImageDiskCache.clearOwner('http://srvA|alice');
    assert.equal(ImageDiskCache.contains('http://srvA|alice', sharedUrl), false);
    assert.equal(ImageDiskCache.contains('http://srvA|bob', sharedUrl), true);
    assert.equal(ImageDiskCache.contains('http://srvB|alice', sharedUrl), true);

    // Oversized file (> budget) does not wipe existing entries
    ImageDiskCache.putBytes('http://srvA|bob', 'https://img/huge', new ArrayBuffer(101));
    assert.equal(ImageDiskCache.contains('http://srvA|bob', sharedUrl), true);

    // Orphan .img and .tmp files + shrunk budget on restart init()
    fs.writeFileSync(path.join(cacheDir, 'deadbeefdeadbeef.img'), Buffer.alloc(40));
    fs.writeFileSync(path.join(cacheDir, 'stale.tmp'), Buffer.alloc(10));
    ImageDiskCache.init({ cacheDir: tmpDir }, 5);
    assert.equal(fs.existsSync(path.join(cacheDir, 'deadbeefdeadbeef.img')), false, 'orphan .img must be swept');
    assert.equal(fs.existsSync(path.join(cacheDir, 'stale.tmp')), false, 'leftover .tmp must be swept');
    assert.ok(ImageDiskCache.statsBytes() <= 5, 'startup init must enforce shrunk budget');

    // Legacy v1 index (without owner) is purged on upgrade
    fs.writeFileSync(path.join(cacheDir, 'legacy.img'), Buffer.alloc(3));
    fs.writeFileSync(
      path.join(cacheDir, 'index.json'),
      JSON.stringify({ version: 1, order: ['legacy'], entries: { legacy: { name: 'legacy.img', size: 3 } } })
    );
    ImageDiskCache.init({ cacheDir: tmpDir }, 100);
    assert.equal(ImageDiskCache.statsEntries(), 0);
    assert.equal(fs.existsSync(path.join(cacheDir, 'legacy.img')), false, 'unscoped v1 cache files must be purged');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('RemoteImage cache pipeline isolates accounts/servers/logout and reports accurate 3-tier hit metrics', async () => {
  const { ImageLruPolicy } = loadEts('common/ImageLruPolicy.ets');
  const { ImageDiskCache } = loadImageDiskCache();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-rimg-'));

  const mockAppModel = {
    shared: {
      server: { origin: 'http://srv-a' },
      session: { username: 'alice' },
      client: { getToken: () => 'tok-alice' },
    },
  };
  let cookieValue = '';
  const mockApiClient = {
    ApiClient: {
      cookieHeaderFor: () => cookieValue,
    },
  };

  let decodeMode = 'ok';
  const imgRequests = [];
  const srv = await startServer((req, res) => {
    imgRequests.push({ url: req.url, auth: req.headers['authorization'] || '', cookie: req.headers['cookie'] || '' });
    if (req.url === '/missing.jpg') {
      res.writeHead(404);
      res.end();
      return;
    }
    const payload = req.headers['authorization'] === 'Bearer tok-alice' ? 'ALICE_IMG' : 'BOB_IMG';
    res.writeHead(200, { 'Content-Type': 'image/jpeg' });
    res.end(payload);
  });

  try {
    ImageDiskCache.init({ cacheDir: tmpDir }, 1024 * 1024);

    // Load pure non-UI RemoteImageCache.ets directly (no UI slicing needed)
    const remoteMod = loadEts('common/RemoteImageCache.ets', {
      '@kit.NetworkKit': createNodeHttpKit(),
      '@kit.ImageKit': {},
      '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 1080, height: 2400, densityPixels: 3 }) } },
      '@kit.ArkTS': {
        taskpool: {
          async execute(fn, buf, edge) {
            if (decodeMode === 'null') {
              decodeMode = 'ok';
              return null;
            }
            if (decodeMode === 'throw') {
              decodeMode = 'ok';
              throw new Error('taskpool native decode crash');
            }
            return { label: Buffer.from(buf).toString('utf8'), edge };
          },
        },
      },
      './AppModel': { AppModel: mockAppModel },
      '../api/ApiClient': mockApiClient,
      './ImageDiskCache': { ImageDiskCache },
      './ImageLruPolicy': { ImageLruPolicy },
      './ImageDecodeTask': { decodeImageBytes: () => null },
    });

    const { RemoteImageCache, remoteImageStats, clearImageCaches } = remoteMod;
    const cache = RemoteImageCache.shared;
    const posterUrl = `${srv.origin}/poster/1.jpg`;

    // 1. Alice cold fetch -> networkFetches=1, diskHits=0, memoryHits=0, decodes=1
    const h1 = cache.acquire(posterUrl, 360);
    const img1 = await h1.task;
    assert.equal(img1.label, 'ALICE_IMG');
    assert.deepEqual(remoteImageStats(), {
      memoryHits: 0,
      diskHits: 0,
      networkFetches: 1,
      decodes: 1,
      memoryEntries: 1,
    });

    // 2. Second acquire (simulating onAreaChange after L1 already populated) -> MUST hit L1 memory, NOT L2 disk!
    const h2 = cache.acquire(posterUrl, 360);
    assert.equal(h2.inflight, false);
    assert.equal((await h2.task).label, 'ALICE_IMG');
    assert.deepEqual(remoteImageStats(), {
      memoryHits: 1,
      diskHits: 0,
      networkFetches: 1,
      decodes: 1,
      memoryEntries: 1,
    });

    // 3. Failed 404 download must NOT increment networkFetches or decodes
    const h404 = cache.acquire(`${srv.origin}/missing.jpg`, 360);
    assert.equal(await h404.task, null);
    assert.equal(remoteImageStats().networkFetches, 1, '404 must not count as network hit');
    assert.equal(remoteImageStats().decodes, 1);

    // 4. Switch to Bob -> clearImageCaches(null, false) clears L1 & inflight; Bob MUST NOT hit Alice's L2 disk!
    clearImageCaches(null, false);
    mockAppModel.shared.session = { username: 'bob' };
    mockAppModel.shared.client = { getToken: () => 'tok-bob' };
    const bobImg = await cache.acquire(posterUrl, 360).task;
    assert.equal(bobImg.label, 'BOB_IMG', 'Bob must not see Alice disk-cached image');
    assert.equal(remoteImageStats().diskHits, 0);
    assert.equal(remoteImageStats().networkFetches, 2);

    // 5. Switch back to Alice -> L1 cleared on switch, hits Alice's L2 disk cache!
    clearImageCaches(null, false);
    mockAppModel.shared.session = { username: 'alice' };
    mockAppModel.shared.client = { getToken: () => 'tok-alice' };
    const aliceFromDisk = await cache.acquire(posterUrl, 360).task;
    assert.equal(aliceFromDisk.label, 'ALICE_IMG');
    assert.equal(remoteImageStats().diskHits, 1, 'Alice should hit her own L2 disk cache');
    assert.equal(remoteImageStats().networkFetches, 2, 'No extra network fetch on L2 hit');

    // 6a. Corrupt disk decode returning null self-heals: diskHits not incremented & disk entry removed
    clearImageCaches(null, false);
    decodeMode = 'null';
    assert.equal(await cache.acquire(posterUrl, 360).task, null);
    assert.equal(remoteImageStats().diskHits, 1, 'corrupt disk decode must not increment diskHits');
    assert.equal(ImageDiskCache.contains('http://srv-a|alice', posterUrl), false);

    // 6b. taskpool.execute throwing on network fetch resolves safely to null, cleans inflight, and recovers on retry
    const throwUrl = `${srv.origin}/poster/throw-net.jpg`;
    decodeMode = 'throw';
    assert.equal(await cache.acquire(throwUrl, 360).task, null, 'decode throw must resolve to null, not reject');
    const recoveredNet = await cache.acquire(throwUrl, 360).task;
    assert.equal(recoveredNet.label, 'ALICE_IMG', 'inflight slot must be cleaned so retry succeeds');

    // 6c. taskpool.execute throwing on disk L2 hit resolves safely to null, does not count diskHit,
    //     removes corrupt disk entry, and recovers from network on retry
    clearImageCaches(null, false);
    assert.equal(ImageDiskCache.contains('http://srv-a|alice', throwUrl), true);
    const diskHitsBeforeThrow = remoteImageStats().diskHits;
    const netFetchesBeforeThrow = remoteImageStats().networkFetches;
    decodeMode = 'throw';
    assert.equal(await cache.acquire(throwUrl, 360).task, null, 'disk decode throw must resolve to null, not reject');
    assert.equal(remoteImageStats().diskHits, diskHitsBeforeThrow, 'disk decode throw must not increment diskHits');
    assert.equal(ImageDiskCache.contains('http://srv-a|alice', throwUrl), false, 'corrupt disk entry must be removed on decode throw');
    const recoveredDisk = await cache.acquire(throwUrl, 360).task;
    assert.equal(recoveredDisk.label, 'ALICE_IMG');
    assert.equal(remoteImageStats().networkFetches, netFetchesBeforeThrow + 1, 'retry after corrupt disk eviction should re-fetch from network');

    // 7. Share-cookie protected image is never persisted to disk cache
    cookieValue = 'movieclaw_share=secret';
    const shareUrl = `${srv.origin}/share/1.jpg`;
    assert.notEqual(await cache.acquire(shareUrl, 360).task, null);
    assert.equal(ImageDiskCache.contains('http://srv-a|alice', shareUrl), false);
    cookieValue = '';

    // 8. Logout Alice evicts Alice disk entries; Bob remains untouched
    await cache.acquire(posterUrl, 360).task; // repopulate Alice disk
    assert.equal(ImageDiskCache.contains('http://srv-a|alice', posterUrl), true);
    clearImageCaches('http://srv-a|alice', false);
    assert.equal(ImageDiskCache.contains('http://srv-a|alice', posterUrl), false);
    assert.equal(ImageDiskCache.contains('http://srv-a|bob', posterUrl), true);
  } finally {
    await closeServer(srv.server);
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('DiscoverPrefetchGuard prevents error re-entry, empty-list trigger, and leading-item offset errors', () => {
  const { shouldPrefetchOnScrollIndex, shouldPaginateOnReachEnd } = loadEts(
    'discover/DiscoverPrefetchGuard.ets'
  );

  // Simulate DiscoverFilteredGrid (2 leading items: AppNavBar spacer + Header)
  let fetchCount = 0;
  const grid = {
    totalRows: 10,
    hasMore: true,
    loading: false,
    error: '',
    debouncePending: false,
    loadPage(shouldFail) {
      fetchCount++;
      this.loading = true;
      this.error = '';
      if (shouldFail) {
        this.error = 'network failed';
      } else {
        this.totalRows += 10;
      }
      this.loading = false;
    },
    onScrollIndex(last) {
      if (shouldPrefetchOnScrollIndex(this.totalRows, last, 2, 3, this.hasMore, this.loading, this.error.length > 0, this.debouncePending)) {
        this.loadPage(true);
      }
    },
    onReachEnd() {
      if (shouldPaginateOnReachEnd(this.totalRows, this.hasMore, this.loading, this.error.length > 0, this.debouncePending)) {
        this.loadPage(true);
      }
    },
  };

  // Row 6 (List index 8 with 2 leading items) is 4 from bottom -> must NOT trigger
  grid.onScrollIndex(8);
  assert.equal(fetchCount, 0);
  // Row 7 (List index 9) is 3 from bottom -> triggers and fails
  grid.onScrollIndex(9);
  assert.equal(fetchCount, 1);
  assert.equal(grid.error, 'network failed');
  // Error banner mounts / bounce triggers repeated onScrollIndex and onReachEnd -> MUST NOT re-enter!
  grid.onScrollIndex(9);
  grid.onScrollIndex(11);
  grid.onReachEnd();
  assert.equal(fetchCount, 1, 'must not re-enter pagination loop after error');
  // Explicit user retry clears error and loads next page
  grid.loadPage(false);
  assert.equal(fetchCount, 2);
  assert.equal(grid.totalRows, 20);
  assert.equal(grid.error, '');

  // Empty list (e.g. first page failed or loading): never triggers even for last=0/1/2
  assert.equal(shouldPrefetchOnScrollIndex(0, 0, 1, 3, true, false, false, false), false);
  assert.equal(shouldPrefetchOnScrollIndex(0, 2, 2, 3, true, false, false, false), false);
  assert.equal(shouldPaginateOnReachEnd(0, true, false, false, false), false);

  // Debounce / filtering active blocks auto-prefetch
  assert.equal(shouldPrefetchOnScrollIndex(10, 11, 2, 3, true, false, false, true), false);
  assert.equal(shouldPaginateOnReachEnd(10, true, false, false, true), false);

  // Verify production pages actually wire both guards
  for (const rel of ['discover/DiscoverCollectionPage.ets', 'discover/DiscoverFilteredGrid.ets']) {
    const src = fs.readFileSync(path.resolve(ETS_ROOT, rel), 'utf8');
    assert.match(src, /shouldPrefetchOnScrollIndex\(/, `${rel} must guard onScrollIndex`);
    assert.match(src, /shouldPaginateOnReachEnd\(/, `${rel} must guard onReachEnd`);
  }
});

test('PerfTelemetry uses monotonic clock, supports cancel(), and never reports fake/negative metrics', () => {
  let uptimeMs = 10_000;
  const events = [];
  const { PerfTelemetry } = loadEts('common/PerfTelemetry.ets', {
    '@kit.PerformanceAnalysisKit': {
      hiAppEvent: {
        EventType: { BEHAVIOR: 4 },
        write(evt) {
          events.push(evt);
          return Promise.resolve();
        },
      },
      hilog: { info() {}, warn() {}, error() {} },
    },
    '@kit.BasicServicesKit': {
      BusinessError: Error,
      systemDateTime: {
        TimeType: { STARTUP: 0, ACTIVE: 1 },
        getUptime() {
          return uptimeMs;
        },
      },
    },
  });

  // Normal begin -> end reports exact monotonic delta once
  PerfTelemetry.begin('cold_start');
  uptimeMs += 185;
  assert.equal(PerfTelemetry.end('cold_start', 'pages/Index'), 185);
  assert.equal(PerfTelemetry.end('cold_start', 'pages/Index'), -1, 'second end must be noop');
  assert.equal(PerfTelemetry.lastValueOf('cold_start'), 185);

  // cancel() discards unfinished mark (e.g. reconnect failed / player closed before playing)
  PerfTelemetry.begin('session_ready');
  uptimeMs += 500;
  PerfTelemetry.cancel('session_ready');
  assert.equal(PerfTelemetry.end('session_ready', 'reconnect'), -1);
  assert.equal(PerfTelemetry.lastValueOf('session_ready'), -1, 'cancelled mark must not report');

  // Backward clock anomaly is clamped to 0, never negative
  PerfTelemetry.begin('playback_open');
  uptimeMs -= 200;
  assert.equal(PerfTelemetry.end('playback_open'), 0);
  assert.equal(PerfTelemetry.lastValueOf('playback_open'), 0);

  assert.equal(events.length, 2);
  assert.equal(events[0].name, 'cold_start');
  assert.equal(events[0].params.value, 185);
  assert.equal(events[1].name, 'playback_open');
  assert.equal(events[1].params.value, 0);

  // Verify production callers gate session_ready / playback_open / cold_start properly
  const appModelSrc = fs.readFileSync(path.resolve(ETS_ROOT, 'common/AppModel.ets'), 'utf8');
  assert.match(appModelSrc, /this\.phase === AppPhase\.ready[\s\S]*?PerfTelemetry\.end\('session_ready', 'reconnect'\)/);
  assert.match(appModelSrc, /PerfTelemetry\.cancel\('session_ready'\)/);
  const playerSrc = fs.readFileSync(path.resolve(ETS_ROOT, 'player/PlayerPage.ets'), 'utf8');
  assert.match(playerSrc, /aboutToDisappear[\s\S]*?PerfTelemetry\.cancel\('playback_open'\)/);
  const abilitySrc = fs.readFileSync(path.resolve(ETS_ROOT, 'entryability/EntryAbility.ets'), 'utf8');
  assert.match(abilitySrc, /if \(err\.code\)[\s\S]*?PerfTelemetry\.cancel\('cold_start'\)/);
});

test('Reusable list cells and PosterRowView update all fields and reset defaults on reuse/prop change', () => {
  // 1. Verify PosterRowView reacts to prop updates & uses content-aware LazyForEach key
  const homeSrc = fs.readFileSync(path.resolve(ETS_ROOT, 'library/LibraryHomeView.ets'), 'utf8');
  const posterRowBlock = homeSrc.slice(homeSrc.indexOf('struct PosterRowView'), homeSrc.indexOf('struct UpNextCard'));
  assert.match(posterRowBlock, /@Prop title:/);
  assert.match(posterRowBlock, /@Prop moreTitle:/);
  assert.match(posterRowBlock, /@Prop @Watch\('onItemsChanged'\) items:/);
  assert.match(posterRowBlock, /onItemsChanged\(\): void\s*\{\s*this\.source\.setItems\(this\.items\);/);
  assert.match(posterRowBlock, /item\.renderKey\(\)/);

  // 2. Verify LibrarySectionHeader updates via @Prop
  const sharedSrc = fs.readFileSync(path.resolve(ETS_ROOT, 'library/LibraryShared.ets'), 'utf8');
  const headerBlock = sharedSrc.slice(sharedSrc.indexOf('export struct LibrarySectionHeader'), sharedSrc.indexOf('export struct LibraryArtwork'));
  assert.match(headerBlock, /@Prop title:/);
  assert.match(headerBlock, /@Prop trailingText:/);

  // 3. Execute real aboutToReuse methods extracted from LibraryArtwork, LibraryPosterCell, LibraryInventoryCell
  function extractAboutToReuse(src, structName) {
    const start = src.indexOf(`export struct ${structName}`);
    const reuseStart = src.indexOf('aboutToReuse(', start);
    assert.ok(reuseStart > start, `${structName} must implement aboutToReuse`);
    let depth = 0;
    let bodyStart = src.indexOf('{', reuseStart);
    let i = bodyStart;
    for (; i < src.length; i++) {
      if (src[i] === '{') depth++;
      else if (src[i] === '}') {
        depth--;
        if (depth === 0) break;
      }
    }
    const methodText = `class C { ${src.slice(reuseStart, i + 1)} }`;
    const js = ts.transpileModule(methodText, {
      compilerOptions: { target: ts.ScriptTarget.ES2021 },
    }).outputText;
    const Theme = { posterAspect: 0.66 };
    const $r = (id) => ({ resource: id });
    const EMPTY_ITEM = { media_item_id: 0, title: '' };
    const C = new Function('Theme', '$r', 'EMPTY_ITEM', `${js}; return C;`)(Theme, $r, EMPTY_ITEM);
    return C.prototype.aboutToReuse;
  }

  // LibraryArtwork reuse resets optional fields when omitted
  const artworkReuse = extractAboutToReuse(sharedSrc, 'LibraryArtwork');
  const art = { url: 'old.jpg', imageAspect: 1.77, frameAspect: 1.5, placeholderSymbol: { resource: 'tv' }, fallbackText: 'S01E01' };
  artworkReuse.call(art, { url: 'new.jpg' });
  assert.deepEqual(art, {
    url: 'new.jpg',
    imageAspect: null,
    frameAspect: 0.66,
    placeholderSymbol: { resource: 'sys.symbol.film' },
    fallbackText: null,
  });

  // LibraryPosterCell reuse updates all fields and resets stale badges/flags
  const posterReuse = extractAboutToReuse(sharedSrc, 'LibraryPosterCell');
  const cell = {
    title: 'Old',
    year: 2020,
    extent: '★ 8.5',
    url: 'old.jpg',
    imageAspect: 1.77,
    frameAspect: 1.77,
    favorite: true,
    played: true,
    dead: true,
    abnormal: '2 个文件缺失',
    working: '扫描中',
    cornerLabel: '第 1 季',
    artworkOpacity: 0.4,
    placeholderSymbol: { resource: 'sys.symbol.tv' },
  };
  posterReuse.call(cell, { title: 'New Movie', year: 2025, url: 'new.jpg' });
  assert.deepEqual(cell, {
    title: 'New Movie',
    year: 2025,
    extent: null,
    url: 'new.jpg',
    imageAspect: null,
    frameAspect: 0.66,
    favorite: false,
    played: false,
    dead: false,
    abnormal: null,
    working: null,
    cornerLabel: null,
    artworkOpacity: 1,
    placeholderSymbol: { resource: 'sys.symbol.film' },
  });

  // LibraryInventoryCell reuse updates item, working (reset to null), and onOpen handler
  const wallSrc = fs.readFileSync(path.resolve(ETS_ROOT, 'library/LibraryWall.ets'), 'utf8');
  const invReuse = extractAboutToReuse(wallSrc, 'LibraryInventoryCell');
  const opened = [];
  const inv = {
    item: { media_item_id: 1, title: 'Old' },
    libraryId: 10,
    frameAspect: 1.77,
    showRating: true,
    working: '刮削中',
    onOpen: () => opened.push('stale'),
  };
  invReuse.call(inv, {
    item: { media_item_id: 2, title: 'Fresh' },
    libraryId: 20,
    onOpen: (item) => opened.push(item.title),
  });
  assert.equal(inv.item.media_item_id, 2);
  assert.equal(inv.libraryId, 20);
  assert.equal(inv.frameAspect, 0.66);
  assert.equal(inv.showRating, false);
  assert.equal(inv.working, null, 'omitted working param must reset to null');
  inv.onOpen(inv.item);
  assert.deepEqual(opened, ['Fresh']);
});
