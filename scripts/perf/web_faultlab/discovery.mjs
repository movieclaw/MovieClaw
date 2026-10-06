// 发现页桌面/手机交互回归。复用本目录的 playwright-core 与本机 Chrome。
// npm install --no-package-lock --prefix scripts/perf/web_faultlab
// pnpm --filter web dev --port 3047
// node scripts/perf/web_faultlab/discovery.mjs http://127.0.0.1:3047
// 截图默认写到 .tmp-uidev/discovery；API 使用固定数据，验证真实页面、路由和请求。
// agent-browser 人工验收可先运行 --serve-fixtures，并设置
// MOVIECLAW_API_PROXY_TARGET=http://127.0.0.1:8047 启动上述 dev server。
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { chromium } from 'playwright-core';

const envelope = (data) => ({ success: true, code: 'OK', message: '', data });
const typeLabel = (type) => type === 'tv' ? '剧集' : '电影';
const sourceLabel = (source) => source === 'douban' ? '豆瓣' : 'TMDB';
const viewLabel = (type, source) => `${sourceLabel(source)} · ${typeLabel(type)}`;

function fixture(url, theme = 'silver') {
  const path = url.pathname.replace(/^\/api\/v1/, '');
  if (path === '/auth/bootstrap') return { initialized: true };
  if (path === '/auth/me') return {
    username: 'discovery-test', nickname: '发现验收', avatar_url: null, role: 'admin',
    capabilities: { allow_subscribe: true, allow_search: true, allow_direct_download: true },
  };
  if (path === '/ui/preferences') return {
    theme, nav: { order: [] },
  };
  if (path === '/subscriptions') return [];
  if (path === '/subscriptions/automation-readiness') return {
    status: 'ok', error_count: 0, warn_count: 0, issues: [], libraries: [],
    site_check: { key: 'sites', status: 'ok', title: '资源搜索', detail: '' },
    downloader_ok: true, sites_configured: true, downloaders_configured: true,
  };
  if (path === '/appearance') return { active_id: null, active_url: null, backdrops: [] };
  if (path === '/search/presets') return { presets: [] };
  if (path === '/jobs') return { items: [] };
  if (path === '/downloaders/tasks') return { items: [], sources: [] };
  if (path === '/playback/up-next') return { items: [] };
  if (path === '/playback/favorites') return { items: [], total: 0 };
  if (path === '/playback/activity') return {
    sessions: [], downloads: [], hidden_session_count: 0, hidden_download_count: 0,
  };
  if (path === '/app/update/status') return { pending: null, last_exit: null };
  if (path === '/app/update/pending') return { pending: null };
  if (path === '/discover/region') return { region: 'CN', can_edit: true };
  if (path === '/discover/filters') return {
    media_type: url.searchParams.get('media_type'), genres: [{ id: 18, name: '剧情' }],
  };
  if (path.startsWith('/ui/discovery/')) {
    const type = path.split('/').at(-1);
    const source = url.searchParams.get('provider');
    const sections = [{
      collection_ref: `${source}:${type}:popular`, title: viewLabel(type, source),
      presentation: 'poster-row', preview_limit: 10, supports_full_listing: false,
    }];
    if (source === 'tmdb') sections.unshift({
      collection_ref: `${source}:${type}:hero`, title: '精选',
      presentation: 'hero', preview_limit: 1, supports_full_listing: false,
    });
    return { provider: source, media_type: type, sections };
  }
  const collection = /^\/discover\/collections\/([^/]+)\/titles$/.exec(path);
  if (collection || path === '/discover/titles') {
    const ref = collection ? decodeURIComponent(collection[1]) : 'tmdb:movie:filtered';
    const [source, type] = collection ? ref.split(':') : ['tmdb', url.searchParams.get('media_type')];
    const titles = Array.from({ length: ref.endsWith('hero') ? 1 : 6 }, (_, index) => ({
      title_ref: `${source}:${type}:${index + 1}`, provider: source, external_id: String(index + 1),
      media_type: type, title: `${viewLabel(type, source)} ${index + 1}`, original_title: '',
      release_year: 2024, provider_rating: 8.5, genres: ['剧情'], extent_label: '2024',
      overview: '用于验证发现页数据源与类型切换的固定片单。',
      poster_url: '/backdrop-neutral.jpg', backdrop_url: '/backdrop-neutral.jpg',
    }));
    return {
      collection: { collection_ref: ref, provider: source, media_type: type,
        name: viewLabel(type, source), is_ranked: false, supports_full_listing: false },
      titles, returned_count: titles.length, truncated: false,
      page: 1, total_pages: 1, total_results: titles.length, has_more: false,
    };
  }
  return [];
}

if (process.argv.includes('--serve-fixtures')) {
  createServer((req, res) => {
    if (req.url.includes('/jobs/stream')) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write(': connected\n\n');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(envelope(fixture(new URL(req.url, 'http://localhost')))));
  }).listen(8047, '127.0.0.1', () => console.log('Discovery fixtures: http://127.0.0.1:8047'));
} else {
  const base = process.argv[2] || 'http://127.0.0.1:3047';
  const out = '.tmp-uidev/discovery';
  await mkdir(out, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const iconShapes = new Map();
  const settingsLabels = ['概览', '个人信息', '设备', '通知', '外观', '成员', '订阅规则',
    '资源站点', '下载器', '自动入库', '刮削与整理', '播放', 'App 推送', 'IM 推送',
    'Webhook', '模型接入', 'MCP 服务', 'AI 设定', 'MovieClaw Cloud', '更新与维护', '网络', '系统日志'];
  const checkIcon = async (locator, key) => {
    const svg = locator.locator('svg').first();
    const actual = await svg.evaluate((el) => {
      const bounds = el.getBBox();
      return { shape: el.innerHTML, hidden: el.getAttribute('aria-hidden'),
        width: el.getBoundingClientRect().width,
        bounds: { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height } };
    });
    assert.equal(actual.hidden, 'true', '装饰图标不覆盖菜单的读屏名称');
    assert.ok(actual.width >= 16 && actual.width <= 28);
    assert.ok(actual.bounds.width > 0 && actual.bounds.height > 0, `${key} 有可见图形`);
    assert.ok(actual.bounds.x >= 0 && actual.bounds.y >= 0 &&
      actual.bounds.x + actual.bounds.width <= 24.1 && actual.bounds.y + actual.bounds.height <= 24.1,
      `${key} 图形未超出 viewBox`);
    if (iconShapes.has(key)) assert.equal(actual.shape, iconShapes.get(key), `${key} 跨主题/尺寸图形一致`);
    else iconShapes.set(key, actual.shape);
  };
  try {
    for (const [theme, width] of [
      ['silver', 1440], ['silver', 900], ['netflix', 1440], ['netflix', 900],
      ['silver', 390], ['silver', 375], ['netflix', 390], ['netflix', 375],
    ]) {
      const context = await browser.newContext({ viewport: { width, height: 900 } });
      const page = await context.newPage();
      const errors = [];
      const requests = [];
      page.on('pageerror', (error) => errors.push(error.message));
      page.on('console', (message) => {
        if (message.type() === 'error') errors.push(message.text());
      });
      await context.addInitScript((theme) => {
        localStorage.setItem('movieclaw.ui-prefs', JSON.stringify({ theme }));
      }, theme);
      await page.route('**/api/v1/**', async (route) => {
        const url = new URL(route.request().url());
        requests.push(url.pathname + url.search);
        if (url.pathname.endsWith('/jobs/stream')) {
          return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' });
        }
        await route.fulfill({ json: envelope(fixture(url, theme)) });
      });
      const trigger = () => page.getByRole('button', { name: /切换类型或数据源/ });
      const filter = () => page.getByRole('button', { name: /^筛选/ });
      const waitView = async (type, source, filtered = false) => {
        await page.getByRole('button', {
          name: `正在看${typeLabel(type)}，数据源${sourceLabel(source)}；切换类型或数据源`,
        }).waitFor();
        if (!filtered) await page.getByRole('heading', { name: viewLabel(type, source), exact: true }).waitFor();
        assert.equal(await trigger().count(), 1);
        assert.equal(await page.locator('body').evaluate((el) => el.scrollWidth > window.innerWidth), false);
        assert.equal(await page.locator('[data-nextjs-dialog]').count(), 0);
      };
      const choose = async (label, type, source) => {
        await trigger().click();
        const menu = page.getByRole('menu');
        await menu.waitFor();
        assert.equal(await menu.getByRole('menuitemradio').count(), 4);
        assert.equal(await menu.locator('[role=menuitemradio][aria-checked=true]').count(), 2);
        const box = await menu.boundingBox();
        assert.ok(box.x >= 0 && box.x + box.width <= width && box.y >= 0 && box.y + box.height <= 900);
        await menu.getByRole('menuitemradio', { name: label, exact: true }).click();
        await page.waitForURL(`${base}/discover/${type}?source=${source}`);
        await waitView(type, source);
        assert.equal(await menu.count(), 0);
      };
      await page.goto(`${base}/discover/movie`);
      // 默认导航顺序在桌面与手机均为媒体库 → 订阅 → 发现，并验证交换后的实际跳转。
      const narrowNetflix = theme === 'netflix' && width >= 768 && width < 1100;
      const openBrowse = async () => {
        if (narrowNetflix) await page.getByRole('button', { name: /^(发现|媒体库)$/ }).click();
      };
      const navItem = (label) => page.getByRole(
        theme === 'silver' && width >= 768 ? 'button' : 'link',
        { name: label, exact: true },
      );
      await openBrowse();
      await navItem('媒体库').waitFor();
      assert.equal(await navItem('媒体库').evaluate(
        (node, next) => Boolean(node.compareDocumentPosition(next) & Node.DOCUMENT_POSITION_FOLLOWING),
        await navItem('发现').elementHandle(),
      ), true, '媒体库排在发现之前');
      const subscriptionLabel = width >= 768 ? '我的订阅' : '订阅';
      for (const [before, after] of [['媒体库', subscriptionLabel], [subscriptionLabel, '发现']]) {
        assert.equal(await navItem(before).evaluate(
          (node, next) => Boolean(node.compareDocumentPosition(next) & Node.DOCUMENT_POSITION_FOLLOWING),
          await navItem(after).elementHandle(),
        ), true, `${before} 排在 ${after} 之前`);
      }
      await navItem(subscriptionLabel).click();
      await page.waitForURL(`${base}/subscriptions`);
      await page.getByRole('heading', { name: '从一部想看的作品开始', exact: true }).waitFor();
      if (width < 768) assert.equal(await navItem(subscriptionLabel).getAttribute('aria-current'), 'page');
      if (narrowNetflix) await page.getByRole('button', { name: '我的订阅', exact: true }).click();
      await navItem('发现').click();
      await page.waitForURL(`${base}/discover/movie`);
      await openBrowse();
      if (theme === 'silver' || width < 768) {
        for (const label of ['媒体库', '发现', theme === 'silver' && width >= 768 ? '我的订阅' : '订阅']) {
          await checkIcon(navItem(label), `main/${label === '我的订阅' ? '订阅' : label}`);
        }
      }
      await page.screenshot({ path: `${out}/${theme}-${width}-nav-icons.png`, animations: 'disabled' });
      // 桌面设置侧栏、手机设置目录逐项比对；每个入口仍能进入原来的分区。
      await page.goto(`${base}${width < 768 ? '/settings' : '/settings/appearance'}`);
      await page.getByRole('button', { name: '设备', exact: true }).waitFor();
      for (const label of settingsLabels) {
        if (theme === 'silver' && width < 768 && label === '个人信息') continue;
        await checkIcon(page.getByRole('button', { name: label, exact: true }), `settings/${label}`);
      }
      await page.screenshot({ path: `${out}/${theme}-${width}-settings-icons.png`, animations: 'disabled' });
      await page.getByRole('button', { name: '外观', exact: true }).click();
      await page.waitForURL(`${base}/settings/appearance`);
      console.log(`PASS ${theme} ${width}px: 主导航/设置菜单图标一致、尺寸无裁切、装饰语义、分区跳转`);
      await page.goto(`${base}/discover/movie`);
      await openBrowse();
      await navItem('媒体库').click();
      await page.waitForURL(`${base}/library`);
      await page.getByText('为收藏准备一个家', { exact: true }).waitFor();
      if (width < 768) {
        assert.equal(await navItem('媒体库').getAttribute('aria-current'), 'page');
        await page.goto(base);
        await page.waitForURL(`${base}/library`);
        await page.getByText('为收藏准备一个家', { exact: true }).waitFor();
      }
      await openBrowse();
      await navItem('发现').click();
      await page.waitForURL(`${base}/discover/movie`);
      if (width < 768) assert.equal(await navItem('发现').getAttribute('aria-current'), 'page');
      if (theme === 'netflix' && width < 768) {
        await page.getByRole('heading', { name: viewLabel('movie', 'tmdb'), exact: true }).waitFor();
        await page.screenshot({ path: `${out}/${theme}-${width}-home.png`, animations: 'disabled' });
        assert.deepEqual(errors, [], '页面无运行时或 console 错误');
        console.log(`PASS ${theme} ${width}px: 媒体库优先、首页落点、双向导航与页签高亮`);
        await context.close();
        continue;
      }
      await waitView('movie', 'tmdb');
      if (width >= 768) {
        if (theme === 'silver') {
          assert.equal(await page.getByRole('button', { name: '发现', exact: true }).count(), 1);
          assert.equal(await page.getByRole('button', { name: /发现电影|发现剧集/ }).count(), 0);
        } else {
          // 宽桌面展开导航；窄桌面收敛进浏览菜单。
          if (width < 1100) await page.getByRole('button', { name: '发现', exact: true }).click();
          const link = page.getByRole('link', { name: '发现', exact: true });
          assert.equal(await link.count(), 1);
          assert.match(await link.getAttribute('class'), /font-bold/);
          if (width < 1100) await page.getByRole('button', { name: '发现', exact: true }).click();
        }
      }
      await trigger().click();
      await page.getByRole('menu').waitFor();
      await page.screenshot({ path: `${out}/${theme}-${width}-menu.png`, animations: 'disabled' });
      await page.keyboard.press('Escape');
      await choose('豆瓣', 'movie', 'douban');
      if (theme === 'silver') assert.equal(await filter().count(), 0);
      else assert.equal(await filter().isDisabled(), true);
      await choose('剧集', 'tv', 'douban');
      await choose('TMDB', 'tv', 'tmdb');
      assert.equal(await filter().isEnabled(), true);
      const beforeReturn = requests.filter((url) => url.startsWith('/api/v1/ui/discovery/')).length;
      await choose('电影', 'movie', 'tmdb');
      const homeRequests = requests.filter((url) => url.startsWith('/api/v1/ui/discovery/'));
      assert.equal(new Set(homeRequests).size, 4);
      assert.equal(homeRequests.length, beforeReturn, '返回已访问视角复用缓存');
      await page.goto(`${base}/discover/tv?source=tmdb&year=2024&genre_ids=18`);
      await waitView('tv', 'tmdb', true);
      // 点当前类型/来源是 no-op，不能误清筛选。
      await trigger().click();
      await page.getByRole('menuitemradio', { name: '剧集', exact: true }).click();
      assert.equal(new URL(page.url()).searchParams.get('year'), '2024');
      await trigger().click();
      await page.getByRole('menuitemradio', { name: 'TMDB', exact: true }).click();
      assert.equal(new URL(page.url()).searchParams.get('genre_ids'), '18');
      await choose('豆瓣', 'tv', 'douban');
      await page.goBack();
      await waitView('tv', 'tmdb', true);
      assert.equal(new URL(page.url()).searchParams.get('year'), '2024');
      await page.goForward();
      await waitView('tv', 'douban');
      await page.reload();
      await waitView('tv', 'douban');
      await page.goto(`${base}/discover/tv?source=tmdb&year=2024&genre_ids=18`);
      await waitView('tv', 'tmdb', true);
      // 键盘操作菜单，切类型也会清空筛选。
      await trigger().focus();
      await page.keyboard.press('Enter');
      await page.getByRole('menuitemradio', { name: '电影', exact: true }).focus();
      await page.keyboard.press('Enter');
      await page.waitForURL(`${base}/discover/movie?source=tmdb`);
      await waitView('movie', 'tmdb');
      await page.screenshot({ path: `${out}/${theme}-${width}-home.png`, animations: 'disabled' });
      if (theme === 'silver') {
        // 从真实筛选入口选年份，再切类型，验证筛选与标题菜单一起工作。
        await filter().click();
        await page.getByRole('menuitem', { name: /^上映年份/ }).click();
        await page.getByRole('menuitemradio', { name: '2024 年', exact: true }).click();
        await page.waitForURL((url) => url.searchParams.get('year') === '2024');
        await waitView('movie', 'tmdb', true);
        await choose('剧集', 'tv', 'tmdb');
        if (width === 900) {
          await page.setViewportSize({ width: 390, height: 900 });
          await waitView('tv', 'tmdb');
          assert.ok((await trigger().boundingBox()).x < 100);
          await page.setViewportSize({ width, height: 900 });
          await waitView('tv', 'tmdb');
          assert.ok((await trigger().boundingBox()).x > 300);
        }
      }
      assert.deepEqual(errors, [], '页面无运行时或 console 错误');
      console.log(`PASS ${theme} ${width}px: 媒体库优先、双向导航、四种视角、筛选重置、缓存、前进后退、刷新、键盘与菜单边界`);
      await context.close();
    }
  } finally {
    await browser.close();
  }
}
