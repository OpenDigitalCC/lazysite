/*
 * manager-layout-check.js - what the test tier cannot see.
 *
 * WHY THIS EXISTS. Three manager defects were "fixed" this session by rules
 * that could not take effect, and each looked fixed in the diff:
 *
 *   - an inline style on the cell beat every rule in the sheet;
 *   - flex properties were set on an element the dense form makes a grid;
 *   - a media block sat above the base rule it had to beat, and lost.
 *
 * None of that is visible in source. All of it is obvious in a rendered page,
 * and the difference between the two is why the same report kept coming back.
 * So this asks the browser, at several widths, and reports facts rather than
 * opinions.
 *
 * USAGE
 *   1. a dev server on the manager you want to check:
 *        perl tools/lazysite-server.pl --port 8412 --docroot <docroot> \
 *             --processor lazysite-processor.pl
 *   2. chromium with a debugging port:
 *        chromium --headless=new --remote-debugging-port=9222 \
 *                 --user-data-dir=/tmp/lzs-chrome about:blank &
 *   3. node --experimental-websocket tools/manager-layout-check.js
 *
 *   LZS_AUTH   the lazysite_auth cookie value for a signed-in manager
 *   LZS_BASE   default http://127.0.0.1:8412
 *   LZS_PORT   the CDP port, default 9222
 *   LZS_WIDTHS default 320,420,560,740,900,1200
 *
 * Node 20 needs --experimental-websocket. Exits non-zero if anything failed.
 *
 * WHAT IT CHECKS. Each is a defect that was actually reported, phrased as the
 * outcome rather than as the CSS that ought to produce it:
 *
 *   page-fits        no page is wider than the viewport
 *   control-onscreen no button or link sits outside the viewport with no
 *                    scroll container to reach it (the editor toolbar did)
 *   checkbox-beside  a checkbox shares a row with its own label
 *   table-fits       a data table fits its container at desktop widths
 *   no-clipped-text  no element is cut mid-word by an ancestor's overflow
 */
const http = require('http');

const PORT   = parseInt(process.env.LZS_PORT || '9222', 10);
const BASE   = process.env.LZS_BASE || 'http://127.0.0.1:8412';
const AUTH   = process.env.LZS_AUTH || '';
const WIDTHS = (process.env.LZS_WIDTHS || '320,420,560,740,900,1200')
  .split(',').map(n => parseInt(n, 10));
const PAGES = (process.env.LZS_PAGES || 'data groups config plugin-config plugins stats nav sessions domains edit users files backups audit cache appearance')
  .split(/[\s,]+/).filter(Boolean);

const get = p => new Promise((res, rej) =>
  http.get(`http://127.0.0.1:${PORT}${p}`, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(JSON.parse(b)));
  }).on('error', rej));

// Runs IN the page. Returns one array of findings; an empty array is a pass.
const CHECKS = `(() => {
  const vw = document.documentElement.clientWidth;
  const out = [];
  const clipped = el => {
    for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
      const ox = getComputedStyle(p).overflowX;
      if (ox === 'auto' || ox === 'scroll' || ox === 'hidden') return p;
    }
    return null;
  };
  const shown = el => {
    const cs = getComputedStyle(el);
    return cs.display !== 'none' && cs.visibility !== 'hidden' && !el.closest('[hidden]');
  };

  // page-fits
  if (document.documentElement.scrollWidth > vw + 1)
    out.push('page-fits: document is ' + document.documentElement.scrollWidth + 'px in a ' + vw + 'px viewport');

  // control-onscreen: a control past the right edge that nothing can scroll to
  document.querySelectorAll('button, a.mg-btn, input, select').forEach(el => {
    if (!shown(el)) return;
    const r = el.getBoundingClientRect();
    if (!r.width || r.right <= vw + 1) return;
    const box = clipped(el);
    const scrollable = box && box.scrollWidth > box.clientWidth + 1;
    if (!scrollable)
      out.push('control-onscreen: "' + (el.textContent || el.value || el.name || el.type).trim().slice(0, 22) +
               '" ends at ' + Math.round(r.right) + 'px, past a ' + vw + 'px viewport, with nothing to scroll');
  });

  // checkbox-beside: the box shares a row with its own label
  document.querySelectorAll('input[type=checkbox]').forEach(cb => {
    if (!shown(cb)) return;
    const field = cb.closest('.mg-field');
    if (!field) return;
    const label = [...field.children].find(c => c.tagName === 'LABEL' && !c.contains(cb));
    if (!label) return;
    const a = cb.getBoundingClientRect(), b = label.getBoundingClientRect();
    // BESIDE means their vertical extents overlap, not that their tops match:
    // a label that wraps to two lines starts above a centred box and is still
    // on the same row. Comparing tops reported that as a defect.
    const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    if (overlap <= 0)
      out.push('checkbox-beside: "' + label.textContent.trim().slice(0, 30) +
               '" is on a different row from its checkbox (gap ' +
               Math.round(-overlap) + 'px)');
  });

  // table-fits: only where there is room for one - a phone scrolls a table
  if (vw >= 900) {
    document.querySelectorAll('table').forEach(tb => {
      const wrap = tb.parentElement;
      if (tb.scrollWidth > wrap.clientWidth + 1)
        out.push('table-fits: <table class="' + tb.className + '"> needs ' + tb.scrollWidth +
                 'px in a ' + wrap.clientWidth + 'px container');
    });
  }

  // no-clipped-text: a leaf whose text is cut without an ellipsis to say so
  document.querySelectorAll('td, th, span, div, label, p').forEach(el => {
    if (el.children.length || !el.textContent.trim() || !shown(el)) return;
    const cs = getComputedStyle(el);
    if (cs.textOverflow === 'ellipsis' || cs.overflow === 'visible') return;
    if (el.scrollWidth > el.clientWidth + 1)
      out.push('no-clipped-text: "' + el.textContent.trim().slice(0, 26) + '" is cut at ' +
               el.clientWidth + 'px of ' + el.scrollWidth + 'px, with no ellipsis');
  });

  return JSON.stringify(out);
})()`;

(async () => {
  const v = await get('/json/version');
  const ws = new WebSocket(v.webSocketDebuggerUrl);
  let id = 0; const waiting = new Map();
  const send = (method, params, sessionId) => new Promise(res => {
    const m = ++id; waiting.set(m, res);
    ws.send(JSON.stringify({ id: m, method, params: params || {}, sessionId }));
  });
  await new Promise(r => ws.addEventListener('open', r));
  ws.addEventListener('message', e => {
    const msg = JSON.parse(e.data);
    if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg.result); waiting.delete(msg.id); }
  });

  const t = await send('Target.createTarget', { url: 'about:blank' });
  const a = await send('Target.attachToTarget', { targetId: t.targetId, flatten: true });
  const S = a.sessionId;
  await send('Network.enable', {}, S);
  await send('Page.enable', {}, S);
  await send('Network.setCacheDisabled', { cacheDisabled: true }, S);
  if (AUTH) await send('Network.setCookies', { cookies: [
    { name: 'lazysite_auth', value: AUTH, domain: '127.0.0.1', path: '/', httpOnly: true },
    { name: 'lzs_session', value: '1', domain: '127.0.0.1', path: '/' },
  ] }, S);

  let failures = 0, checked = 0;
  for (const width of WIDTHS) {
    for (const page of PAGES) {
      await send('Emulation.setDeviceMetricsOverride',
        { width, height: 1200, deviceScaleFactor: 1, mobile: false }, S);
      await send('Page.navigate', { url: `${BASE}/manager/${page}` }, S);
      await new Promise(r => setTimeout(r, 3000));   // pages fetch their own data
      const title = await send('Runtime.evaluate',
        { expression: 'document.title', returnByValue: true }, S);
      // A refusal page renders fine and proves nothing: say so rather than pass it.
      if (/not permitted|Sign in/i.test(title.result.value || '')) {
        console.log(`SKIPPED ${page} @${width}: not signed in (${title.result.value})`);
        continue;
      }
      const res = await send('Runtime.evaluate', { expression: CHECKS, returnByValue: true }, S);
      const found = JSON.parse(res.result.value);
      checked++;
      if (found.length) {
        failures += found.length;
        console.log(`FAIL ${page} @${width}px`);
        // One row of a list produces the same finding as its other forty.
        // Reported once with a count: a hundred identical lines is a report
        // nobody reads to the end, and the fortieth adds nothing to the first.
        const seen = new Map();
        for (const f of found) seen.set(f, (seen.get(f) || 0) + 1);
        for (const [f, n] of seen) console.log('     ' + f + (n > 1 ? `  (x${n})` : ''));
      }
    }
  }
  console.log(`\n${checked} page/width combinations checked, ${failures} finding(s)`);
  ws.close();
  process.exit(failures ? 1 : 0);
})();
