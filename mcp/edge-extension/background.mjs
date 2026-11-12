import { validateRequest, boundedReply, dispatchCommand } from './protocol.mjs';

const HOST = 'com.sharemouse.browser';
const READ_TIMEOUT = 'browser_read_timeout: target renderer did not finish the DOM observation; it may be suspended or busy. No page interaction was requested.';
let port = null;
let reconnectTimer = null;
let queue = Promise.resolve();
let queued = 0;
function status(connected) {
  void chrome.action.setBadgeText({ text: connected ? 'ON' : 'OFF' });
  void chrome.action.setBadgeBackgroundColor({ color: connected ? '#277148' : '#805235' });
  void chrome.action.setTitle({ title: connected ? 'ShareMouse browser bridge connected' : 'ShareMouse browser bridge disconnected; click to reconnect' });
}
function reconnect() {
  if (port) return;
  clearTimeout(reconnectTimer);
  try {
    const connection = chrome.runtime.connectNative(HOST);
    port = connection;
    status(true);
    connection.onMessage.addListener(request => {
      const id = typeof request?.id === 'string' ? request.id.slice(0, 128) : '';
      if (queued >= 16) { connection.postMessage(boundedReply(id, null, 'bridge_busy')); return; }
      queued++;
      queue = queue.then(async () => {
        if (port !== connection) return;
        let reply;
        let deadlineTimer;
        const observing = request?.command?.action === 'observe';
        try {
          const valid = validateRequest(request);
          // Leave time for the read-only error to reach the native host before its deadline.
          // The injected command shares this earlier deadline, so a delayed injection cannot run later.
          const executionDeadline = valid.deadline_ms - (observing ? 500 : 0);
          const result = await Promise.race([
            dispatchCommand(chrome, valid.command, executionDeadline),
            new Promise((_, reject) => { deadlineTimer = setTimeout(() => reject(new Error(observing ? READ_TIMEOUT : 'deadline_exceeded: an already-started DOM action cannot be rolled back')), Math.max(0, Math.min(2147483647, executionDeadline - Date.now()))); }),
          ]);
          reply = boundedReply(valid.id, result);
        } catch (error) { reply = boundedReply(id, null, observing && error?.message?.startsWith('deadline_exceeded') ? READ_TIMEOUT : error?.message || 'bridge_error'); }
        finally { clearTimeout(deadlineTimer); }
        if (port === connection) connection.postMessage(reply);
      }).catch(() => { /* Disconnection discards its responses. No page contents are logged. */ }).finally(() => { queued--; });
    });
    connection.onDisconnect.addListener(() => {
      void chrome.runtime.lastError;
      if (port === connection) port = null;
      status(false);
      reconnectTimer = setTimeout(reconnect, 1000);
    });
  } catch {
    port = null;
    status(false);
    reconnectTimer = setTimeout(reconnect, 1000);
  }
}
chrome.action.onClicked.addListener(() => { if (!port) reconnect(); else status(true); });
chrome.runtime.onStartup.addListener(reconnect);
chrome.runtime.onInstalled.addListener(reconnect);
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'sharemouse-reconnect') reconnect(); });
void chrome.alarms.create('sharemouse-reconnect', { periodInMinutes: 1 });
reconnect();
