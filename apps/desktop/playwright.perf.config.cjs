const base = require('./playwright.config.cjs');
module.exports = { ...base, testDir: './tests/perf', timeout: 240000, retries: 0,
  reporter: [['list']], outputDir: 'dist/browser-performance',
  use: { ...base.use, trace: 'off', screenshot: 'only-on-failure' } };
