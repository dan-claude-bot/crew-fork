/* fleet-floor/test/lobby.js — the floor on a host with no fleets (#831),
 * driven for real.
 *
 *   node lobby.js <base-url> <user> <pass>
 *
 * Run by test/floor/workspaces.sh against a collector whose fleet index is
 * empty. The lobby is the page at /, and its one action is New fleet: a bad id
 * is refused where it is typed, a good one makes the fleet and opens its page.
 * Prints `walk: N ok, M failed` last; the caller holds N to its recorded count.
 */
const { chromium } = require('playwright-core');

const [, , BASE, USER, PASS] = process.argv;
const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
let pass = 0; const fails = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fails.push(name); console.log(`  FAIL ${name}${detail ? '  — ' + String(detail).slice(0, 160) : ''}`); }
};

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME });
  const ctx = await browser.newContext({ httpCredentials: { username: USER, password: PASS }, viewport: { width: 1280, height: 800 } });
  const errors = [];
  const p = await ctx.newPage();
  p.on('pageerror', (e) => errors.push(e.message));
  await p.goto(BASE + '/');
  ok('lobby: / says the host has no fleet', (await p.textContent('#lead')) === 'No fleets on this host yet.');
  ok('lobby: titled for it', (await p.title()) === 'Fleet Floor · no fleet yet', await p.title());
  ok('lobby: the id field has focus', await p.evaluate(() => document.activeElement && document.activeElement.id === 'fid'));

  // A bad id never leaves the page: the field's own pattern refuses it.
  await p.fill('#fid', 'Bad Id');
  await p.click('#go');
  await p.waitForTimeout(300);
  ok('lobby: a bad id is refused where it is typed', new URL(p.url()).pathname === '/', p.url());
  ok('lobby: ...and no fleet was asked for', ((await (await ctx.request.get(BASE + '/api/fleets')).json()).fleets || []).length === 0);

  // A good one makes the fleet and opens its page.
  await p.fill('#fid', 'first');
  await Promise.all([p.waitForURL(BASE + '/f/first/', { timeout: 30000 }), p.click('#go')]);
  ok('lobby: New fleet opens the fleet made', new URL(p.url()).pathname === '/f/first/', p.url());
  await p.waitForFunction(() => document.getElementById('fleetsel').style.display !== 'none', null, { timeout: 30000 });
  const opts = await p.$$eval('#fleetsel option', (o) => o.map((x) => x.value));
  ok('first fleet: the switcher lists it, then New fleet', opts.join(' ') === 'first +new', opts.join(' '));
  ok('first fleet: the page is titled for it', (await p.title()) === 'Fleet Floor · first', await p.title());
  ok('walk: no page error', errors.length === 0, errors.join(' | '));

  await browser.close();
  console.log(`walk: ${pass} ok, ${fails.length} failed`);
  process.exit(fails.length ? 1 : 0);
})().catch((e) => { console.log('  FAIL walk crashed — ' + e.message); console.log(`walk: ${pass} ok, ${fails.length + 1} failed`); process.exit(1); });
