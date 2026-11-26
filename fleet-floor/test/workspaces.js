/* fleet-floor/test/workspaces.js — the page over several fleets (#814) and its
 * jobs (#815), driven for real.
 *
 *   node workspaces.js <base-url> <user> <pass> <stub-log> <sleep-file>
 *
 * Run by test/floor/workspaces.sh against ITS collector: a host with the
 * fixture fleet (`default`), `second` (one member, ws-two, not created) and
 * `third` (empty), and a stub CLI that logs every invocation to <stub-log> and
 * sleeps as many seconds as <sleep-file> says. Prints `walk: N ok, M failed`
 * last; the caller holds N to its recorded count.
 */
const { chromium } = require('playwright-core');
const fs = require('fs');

const [, , BASE, USER, PASS, STUB_LOG, SLEEP_FILE] = process.argv;
const CHROME = process.env.PW_CHROME
  || process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome';
let pass = 0; const fails = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fails.push(name); console.log(`  FAIL ${name}${detail ? '  — ' + String(detail).slice(0, 160) : ''}`); }
};
const stubLines = () => (fs.existsSync(STUB_LOG) ? fs.readFileSync(STUB_LOG, 'utf8').split('\n').filter(Boolean) : []);

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME });
  const ctx = await browser.newContext({ httpCredentials: { username: USER, password: PASS }, viewport: { width: 1500, height: 900 } });
  const errors = [];
  const open = async (path) => {
    const p = await ctx.newPage();
    p.requested = [];
    p.on('request', (r) => p.requested.push(r.url()));
    p.on('pageerror', (e) => errors.push(e.message));
    p.on('dialog', (d) => d.accept());
    await p.goto(BASE + path);
    await p.waitForFunction(() => document.getElementById('fleetsel').style.display !== 'none', null, { timeout: 30000 });
    return p;
  };

  // Every fleet's first poll, before any page reads a standing off it.
  for (const f of ['/api/fleet', '/f/second/api/fleet']) {
    for (let i = 0; i < 120; i++) {
      const snap = await (await ctx.request.get(BASE + f)).json();
      if (snap.generated) break;
      await new Promise((r) => setTimeout(r, 500));
    }
  }

  // The switcher, at / and at /f/<id>/.
  const home = await open('/');
  const opts = await home.$$eval('#fleetsel option', (o) => o.map((x) => x.value));
  ok('switcher: lists every fleet on the host, then New fleet', opts.join(' ') === 'default second third +new', opts.join(' '));
  ok('switcher: / is the home fleet', (await home.$eval('#fleetsel', (s) => s.value)) === 'default');

  const a = await open('/f/second/');
  ok('page: /f/second/ is titled for its fleet', (await a.title()) === 'Fleet Floor · second', await a.title());
  ok('switcher: the page selects its own fleet', (await a.$eval('#fleetsel', (s) => s.value)) === 'second');
  const apiCalls = a.requested.filter((u) => /\/api\//.test(u) && !/\/api\/fleets$/.test(u));
  ok('page: its API calls are its fleet\'s', apiCalls.length > 0 && apiCalls.every((u) => u.startsWith(BASE + '/f/second/api/')), apiCalls.join(' '));

  // Switching navigates; a reload keeps the fleet.
  await Promise.all([a.waitForURL(/\/f\/default\/$/), a.selectOption('#fleetsel', 'default')]);
  ok('switcher: switching opens that fleet\'s page', /\/f\/default\/$/.test(a.url()), a.url());
  await a.goto(BASE + '/f/second/');
  await a.reload();
  await a.waitForFunction(() => document.getElementById('fleetsel').style.display !== 'none');
  ok('page: a reload keeps the fleet', (await a.$eval('#fleetsel', (s) => s.value)) === 'second');

  // Two tabs on two fleets share nothing.
  const b = await open('/f/default/');
  await a.click('#g-roster'); await a.waitForSelector('#pagebody .mcard [data-job]', { state: 'visible' });
  await b.click('#g-roster'); await b.waitForSelector('#pagebody .mcard [data-job]', { state: 'visible' });
  ok('pages: Members is its own address (#870)', /#\/members$/.test(a.url()), a.url());
  const boxesA = await a.$$eval('#pagebody .mcard', (i) => i.map((x) => x.dataset.box));
  const boxesB = await b.$$eval('#pagebody .mcard', (i) => i.map((x) => x.dataset.box));
  ok('tabs: the second fleet\'s roster is its own', boxesA.join(' ') === 'ws-two', boxesA.join(' '));
  ok('tabs: the other tab\'s roster is the default fleet\'s', boxesB.length > 1 && boxesB.includes('ff-idle') && !boxesB.includes('ws-two'), boxesB.join(' '));

  // A member's buttons follow its standing.
  const btnA = await a.$$eval('#pagebody .mcard [data-job]', (o) => o.map((x) => `${x.dataset.job}:${x.dataset.box}`));
  ok('roster: a member with no box offers Create', btnA.join(' ') === 'create:ws-two', btnA.join(' '));
  const btnB = await b.$$eval('#pagebody .mcard [data-job]', (o) => o.map((x) => x.dataset.job));
  ok('roster: a hired member offers Upgrade', btnB.includes('upgrade'), btnB.join(' '));
  // A member's own page, and the back button walks back to the list.
  await b.click('#pagebody .mcard[data-box="ff-idle"] .mhead a');
  await b.waitForSelector('#pagebody [data-pg="remove"]', { state: 'visible' });
  ok('pages: a member has its own page', /#\/member\/ff-idle$/.test(b.url()), b.url());
  await b.goBack();
  await b.waitForSelector('#pagebody .mcard', { state: 'visible' });
  ok('pages: the back button returns to Members', /#\/members$/.test(b.url()), b.url());
  await b.click('#page .pgtabs a[data-tab=""]');
  await b.waitForSelector('#page', { state: 'hidden' });

  // Create shows its plan first; nothing but the dry run has run.
  const before = stubLines().length;
  fs.writeFileSync(SLEEP_FILE, '0');
  await a.click('#pagebody .mcard [data-job="create"]');
  await a.waitForSelector('#jobov', { state: 'visible' });
  await a.waitForFunction(() => /finished|FAILED/.test(document.getElementById('jobstate').textContent), null, { timeout: 30000 });
  const ran = stubLines().slice(before);
  ok('plan: Create runs the dry run first, and only it', ran.length === 1 && /^up ws-two --dry-run\|/.test(ran[0]), ran.join(' / '));
  ok('plan: the panel says it is a plan', /PLAN/.test(await a.textContent('#jobttl')));
  ok('plan: the panel shows the plan\'s output', /ws-two: WOULD create/.test(await a.textContent('#jobout')));
  ok('plan: confirming is a button on the plan', /Run crew up ws-two/.test(await a.textContent('#jobacts')));

  // The confirmed run: a spinner and the step while it runs, in every tab.
  fs.writeFileSync(SLEEP_FILE, '4');
  await a.click('[data-jobconfirm]');
  await a.waitForFunction(() => document.querySelector('#jobbar.run .spin'), null, { timeout: 15000 });
  ok('job bar: a running job shows a spinner', true);
  ok('job bar: it names the verb and the fleet', /crew up ws-two/.test(await a.textContent('#jobbar')) && /fleet second/.test(await a.textContent('#jobbar')));
  await b.waitForFunction(() => document.querySelector('#jobbar.run'), null, { timeout: 15000 });
  ok('job bar: another fleet\'s tab shows the host\'s running job', /fleet second/.test(await b.textContent('#jobbar')));
  ok('job bar: every job button there is held', await b.$eval('#g-up', (e) => e.disabled && e.classList.contains('jheld')));
  ok('job panel: a spinner while it runs', !!(await a.$('#jobstate .spin')));
  await a.waitForFunction(() => document.querySelector('#jobbar.ok'), null, { timeout: 30000 });
  ok('job bar: a finished job shows its exit status', /exit 0/.test(await a.textContent('#jobbar')));
  ok('job panel: the output is the run\'s', /stub: crew up ws-two$/m.test(await a.textContent('#jobout')));
  await b.waitForFunction(() => document.querySelector('#jobbar.ok'), null, { timeout: 15000 }).catch(() => {});
  ok('job bar: the held buttons are released', !(await b.$eval('#g-up', (e) => e.disabled)));
  ok('page: no script error on any tab', errors.length === 0, errors.join(' | '));

  await browser.close();
  console.log(`walk: ${pass} ok, ${fails.length} failed`);
  process.exit(fails.length ? 1 : 0);
})().catch((e) => { console.error(e); console.log(`walk: ${pass} ok, ${fails.length + 1} failed`); process.exit(1); });
