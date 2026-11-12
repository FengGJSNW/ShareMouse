import test from 'node:test';
import assert from 'node:assert/strict';

test('service worker module registers, handles fractional deadlines and reconnects a lost native port', async () => {
  const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
  const ports = [];
  const alarms = [];
  const badges = [];
  const timers = new Map();
  const saved = { chrome: globalThis.chrome, setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
  globalThis.setTimeout = (callback, ms) => { const id = {}; timers.set(id, { callback, ms }); return id; };
  globalThis.clearTimeout = id => timers.delete(id);
  globalThis.chrome = {
    action: { onClicked: event(), setBadgeText: value => badges.push(value.text), setBadgeBackgroundColor() {}, setTitle() {} },
    runtime: {
      onStartup: event(), onInstalled: event(),
      connectNative(name) {
        assert.equal(name, 'com.sharemouse.browser');
        const port = { onMessage: event(), onDisconnect: event(), replies: [], postMessage(reply) { this.replies.push(reply); } };
        ports.push(port); return port;
      },
    },
    alarms: { onAlarm: event(), create(name, options) { alarms.push({ name, options }); } },
    tabs: { query: async () => [] },
  };
  try {
    await import('../background.mjs');
    assert.equal(ports.length, 1);
    assert.deepEqual(alarms, [{ name: 'sharemouse-reconnect', options: { periodInMinutes: 1 } }]);
    assert.equal(globalThis.chrome.runtime.onStartup.listeners.length, 1);
    assert.equal(globalThis.chrome.action.onClicked.listeners.length, 1);
    ports[0].onMessage.listeners[0]({ id: 'swift-time', deadline_ms: Date.now() + 5000.25, command: { action: 'tabs' } });
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(ports[0].replies, [{ id: 'swift-time', result: { tabs: [], truncated: false } }]);
    ports[0].onDisconnect.listeners[0]();
    assert.equal(badges.at(-1), 'OFF');
    const retry = Array.from(timers.values()).find(item => item.ms === 1000);
    assert.ok(retry);
    retry.callback();
    assert.equal(ports.length, 2);
    assert.equal(badges.at(-1), 'ON');
  } finally {
    globalThis.chrome = saved.chrome;
    globalThis.setTimeout = saved.setTimeout;
    globalThis.clearTimeout = saved.clearTimeout;
  }
});

test('an unresponsive observe reports a read-only timeout before the host deadline and releases its queue', async () => {
  const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
  const timers = new Map();
  const port = { onMessage: event(), onDisconnect: event(), replies: [], postMessage(reply) { this.replies.push(reply); } };
  const saved = { chrome: globalThis.chrome, setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout };
  globalThis.setTimeout = (callback, ms) => { const id = {}; timers.set(id, { callback, ms }); return id; };
  globalThis.clearTimeout = id => timers.delete(id);
  globalThis.chrome = {
    action: { onClicked: event(), setBadgeText() {}, setBadgeBackgroundColor() {}, setTitle() {} },
    runtime: { onStartup: event(), onInstalled: event(), connectNative: () => port },
    alarms: { onAlarm: event(), create() {} },
    tabs: { query: async () => [], get: async () => ({ id: 7, url: 'https://fixture.test/' }) },
    scripting: { executeScript: () => new Promise(() => {}) },
  };
  try {
    await import('../background.mjs?observe-timeout');
    port.onMessage.listeners[0]({ id: 'sleeping-observe', deadline_ms: Date.now() + 5000, command: { action: 'observe', tab_id: 7 } });
    await new Promise(resolve => setImmediate(resolve));
    const timer = Array.from(timers.values())[0];
    assert.ok(timer.ms <= 4500, 'reserve time to return the read-only timeout before the native host expires');
    timer.callback();
    await new Promise(resolve => setImmediate(resolve));
    assert.match(port.replies[0].error, /^browser_read_timeout/);
    assert.doesNotMatch(port.replies[0].error, /already-started DOM action|execution_unknown/);
    port.onMessage.listeners[0]({ id: 'next-tabs', deadline_ms: Date.now() + 5000, command: { action: 'tabs' } });
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(port.replies[1], { id: 'next-tabs', result: { tabs: [], truncated: false } });
  } finally {
    globalThis.chrome = saved.chrome;
    globalThis.setTimeout = saved.setTimeout;
    globalThis.clearTimeout = saved.clearTimeout;
  }
});
