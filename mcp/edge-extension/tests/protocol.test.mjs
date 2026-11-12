import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRequest, boundedReply, dispatchCommand } from '../protocol.mjs';

test('fractional Unix millisecond deadlines from Swift are accepted without rounding', async () => {
  const deadline = Date.now() + 5000.25;
  const request = { id: 'swift-time', deadline_ms: deadline, command: { action: 'tabs' } };
  assert.equal(validateRequest(request).deadline_ms, deadline);
  assert.deepEqual(await dispatchCommand({ tabs: { query: async () => [] } }, request.command, deadline), { tabs: [], truncated: false });
  for (const invalid of [NaN, Infinity, -Infinity, 0, -1, Number.MAX_SAFE_INTEGER + 1, String(deadline), Date.now() - 0.25]) {
    assert.throws(() => validateRequest({ ...request, deadline_ms: invalid }), /deadline_exceeded/);
  }
});

test('explicit tab binding, closed command allowlist and absolute deadlines', () => {
  const req = command => ({ id: 'test', deadline_ms: Date.now() + 5000, command });
  assert.throws(() => validateRequest(req({ action: 'click', role: 'button', name: 'Go' })), /tab_id/);
  assert.throws(() => validateRequest(req({ action: 'eval', tab_id: 7, script: 'alert(1)' })), /unsupported_action/);
  assert.throws(() => validateRequest({ ...req({ action: 'tabs' }), deadline_ms: Date.now() - 1 }), /deadline_exceeded/);
  assert.throws(() => validateRequest(req({ action: 'navigate', tab_id: 7, url: 'javascript:alert(1)' })), /http/);
  assert.equal(validateRequest(req({ action: 'observe', tab_id: 7 })).command.max_nodes, 150);
  assert.throws(() => validateRequest(req({ action: 'fill', tab_id: 7, element_id: 'some-id', text: '界'.repeat(11000) })), /text_too_large/);
  assert.ok(Buffer.byteLength(JSON.stringify(boundedReply('x', { x: '界'.repeat(500000) }))) < 220 * 1024);
});

test('tabs reports exact IDs; DOM operations never select an active tab', async () => {
  const calls = [];
  const api = {
    tabs: { query: async q => { calls.push(['query', q]); return [{ id: 7, windowId: 2, title: 'Fixture', url: 'https://fixture.test/', active: false }]; }, get: async id => ({ id, url: 'https://fixture.test/' }) },
    scripting: { executeScript: async options => { calls.push(['execute', options]); return [{ frameId: 0, documentId: 'doc-1', result: { result: { ok: true } } }]; } },
  };
  const tabs = await dispatchCommand(api, { action: 'tabs' }, Date.now() + 5000);
  assert.deepEqual(tabs.tabs[0], { tab_id: 7, window_id: 2, title: 'Fixture', url: 'https://fixture.test/', active: false, status: 'unknown', frozen: null, discarded: null });
  assert.deepEqual(await dispatchCommand(api, { action: 'observe', tab_id: 7 }, Date.now() + 5000), { ok: true });
  assert.equal(calls.filter(c => c[0] === 'query').length, 1);
  assert.equal(calls[1][1].world, 'ISOLATED');
  assert.deepEqual(calls[1][1].target, { tabId: 7, frameIds: [0] });
  assert.deepEqual(calls[2][1].target, { tabId: 7, documentIds: ['doc-1'] });
});

test('frozen and discarded tabs reject DOM work immediately and expose their state', async () => {
  for (const state of [{ frozen: true, discarded: false }, { frozen: false, discarded: true }]) {
    let injected = false;
    const updates = [];
    const tab = { id: 7, windowId: 2, title: 'Sleeping', url: 'https://fixture.test/', active: false, status: 'complete', ...state };
    const api = {
      tabs: { query: async () => [tab], get: async () => tab, update: async (...args) => { updates.push(args); Object.assign(tab, { frozen: false, discarded: false }); return { ...tab, status: 'loading' }; } },
      scripting: { executeScript: async options => { if (options.files) { injected = true; throw new Error('renderer_cannot_run'); } return [{ frameId: 0, result: { url: tab.url, ready_state: 'complete' } }]; } },
    };
    await assert.rejects(dispatchCommand(api, { action: 'observe', tab_id: 7 }, Date.now() + 5000), state.frozen ? /browser_tab_frozen/ : /browser_tab_discarded/);
    assert.equal(injected, false);
    assert.deepEqual(updates, []);
    const listed = (await dispatchCommand(api, { action: 'tabs' }, Date.now() + 5000)).tabs[0];
    assert.equal(listed.status, 'complete');
    assert.equal(listed.frozen, state.frozen);
    assert.equal(listed.discarded, state.discarded);
    await dispatchCommand(api, { action: 'navigate', tab_id: 7, url: tab.url }, Date.now() + 5000);
    assert.deepEqual(updates, [[7, { url: tab.url }]]);
  }
});

test('both injection stages run on an existing loading document without waiting for document_idle', async t => {
  for (const blockedStage of ['bootstrap', 'command']) await t.test(blockedStage, async () => {
    let pageIdle = false;
    let releaseIdle;
    const idle = new Promise(resolve => { releaseIdle = () => { pageIdle = true; resolve(); }; });
    const calls = [];
    const api = {
      tabs: { get: async () => ({ id: 7, url: 'https://fixture.test/', status: 'loading', frozen: false, discarded: false }) },
      scripting: { executeScript: async options => {
        calls.push(options);
        const stage = options.files ? 'bootstrap' : 'command';
        if (!pageIdle && stage === blockedStage && !options.injectImmediately) await idle;
        return [{ frameId: 0, documentId: 'loading-doc', result: { result: { nodes: [{ role: 'button', name: 'Already parsed' }] } } }];
      } },
    };
    let result;
    let error;
    const observed = dispatchCommand(api, { action: 'observe', tab_id: 7 }, Date.now() + 5000).then(value => { result = value; }, value => { error = value; });
    try {
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(error, undefined);
      assert.ok(result, `${blockedStage} waited for document_idle despite an available document`);
      assert.equal(result.nodes[0].name, 'Already parsed');
      assert.equal(calls.length, 2);
      assert.deepEqual(calls[1].target, { tabId: 7, documentIds: ['loading-doc'] });
    } finally {
      releaseIdle();
      await observed;
    }
  });
});

test('navigate updates once and waits through the old frozen loading document before reporting completion', async () => {
  const oldTab = { id: 7, windowId: 2, url: 'https://fixture.test/old', status: 'complete', frozen: true, discarded: false, active: false };
  const target = 'https://fixture.test/new';
  const states = [oldTab, { ...oldTab, status: 'loading', pendingUrl: target }, { ...oldTab, url: target, status: 'loading', frozen: false }, { ...oldTab, url: target, status: 'complete', frozen: false }];
  const updates = [];
  const probes = [];
  const api = {
    tabs: { get: async () => states.shift() || { ...oldTab, url: target, frozen: false }, update: async (...args) => { updates.push(args); return { ...oldTab, status: 'loading', pendingUrl: target }; } },
    scripting: { executeScript: async options => { probes.push(options); return [{ frameId: 0, result: { url: target, ready_state: 'complete' } }]; } },
  };
  const result = await dispatchCommand(api, { action: 'navigate', tab_id: 7, url: target }, Date.now() + 5000);
  assert.equal(result.navigation_state, 'complete');
  assert.equal(result.tab.url, target);
  assert.equal(result.tab.status, 'complete');
  assert.equal(result.tab.active, false);
  assert.deepEqual(updates, [[7, { url: target }]]);
  assert.equal(probes.length, 1);
  assert.equal(probes[0].world, 'ISOLATED');
});

test('a hung navigation probe returns pending with read-only recovery within the remaining budget', async () => {
  const target = 'https://fixture.test/new';
  let updated = false;
  const api = {
    tabs: { get: async () => ({ id: 7, url: updated ? target : 'https://fixture.test/old', status: 'complete', active: false }), update: async () => { updated = true; return { id: 7, url: target, status: 'loading' }; } },
    scripting: { executeScript: () => new Promise(() => {}) },
  };
  const start = Date.now();
  const result = await dispatchCommand(api, { action: 'navigate', tab_id: 7, url: target }, start + 650);
  assert.equal(result.navigation_started, true);
  assert.equal(result.navigation_state, 'pending');
  assert.equal(result.next_step, 'observe_loading_page_with_bounded_retry');
  assert.match(result.guidance, /do not navigate again/i);
  assert.ok(Date.now() - start < 500);
});

test('loading plus frozen is a transition, while browser error pages are classified using current tab state', async () => {
  for (const state of [{ status: 'loading', frozen: true }, { status: 'complete', frozen: false, pendingUrl: 'https://fixture.test/new' }]) {
    let injected = false;
    const pending = { tabs: { get: async () => ({ id: 7, url: 'https://fixture.test/', ...state }) }, scripting: { executeScript: async () => { injected = true; return []; } } };
    await assert.rejects(dispatchCommand(pending, { action: 'observe', tab_id: 7 }, Date.now() + 5000), /browser_page_loading/);
    assert.equal(injected, false);
  }
  for (const status of ['loading', 'complete']) {
    const api = {
      tabs: { get: async () => ({ id: 7, url: 'https://fixture.test/', status, frozen: false }) },
      scripting: { executeScript: async () => { throw new Error('Frame with ID 0 is showing error page'); } },
    };
    await assert.rejects(dispatchCommand(api, { action: 'observe', tab_id: 7 }, Date.now() + 5000), status === 'loading' ? /browser_page_loading/ : /browser_page_error/);
  }
});

test('an attempted navigation ending on a completed error page reports error state rather than success or preflight rejection', async () => {
  const target = 'https://fixture.test/unreachable';
  let updated = false;
  const api = {
    tabs: { get: async () => ({ id: 7, url: updated ? target : 'https://fixture.test/old', status: 'complete', active: false }), update: async () => { updated = true; return { id: 7, status: 'loading' }; } },
    scripting: { executeScript: async () => { throw new Error('Frame with ID 0 is showing error page'); } },
  };
  const result = await dispatchCommand(api, { action: 'navigate', tab_id: 7, url: target }, Date.now() + 5000);
  assert.equal(result.navigation_started, true);
  assert.equal(result.navigation_state, 'error');
  assert.equal(result.navigation_error, 'browser_page_error');
  assert.equal(result.next_step, 'report_browser_page_unavailable');
});
