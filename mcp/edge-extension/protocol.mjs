const ACTIONS = new Set(['tabs', 'observe', 'navigate', 'click', 'fill', 'select', 'check', 'press']);
const FIELDS = new Set(['action', 'tab_id', 'element_id', 'text', 'value', 'checked', 'key', 'max_nodes', 'role', 'name', 'url']);
const encoder = new TextEncoder();
export const MAX_REPLY_BYTES = 220 * 1024;
export function checkDeadline(deadline) {
  if (!Number.isFinite(deadline) || deadline <= 0 || deadline > Number.MAX_SAFE_INTEGER || deadline <= Date.now()) throw new Error('deadline_exceeded');
}
function httpURL(value) {
  if (typeof value !== 'string' || value.length > 8192) throw new Error('http_url_required');
  let url;
  try { url = new URL(value); } catch { throw new Error('http_url_required'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error('http_url_required');
  return url.href;
}
export function validateRequest(request) {
  if (!request || typeof request !== 'object' || typeof request.id !== 'string' || !request.id || request.id.length > 128) throw new Error('invalid_request_id');
  checkDeadline(request.deadline_ms);
  const command = { ...request.command };
  if (!ACTIONS.has(command.action)) throw new Error('unsupported_action');
  for (const field of Object.keys(command)) if (!FIELDS.has(field)) throw new Error('unsupported_command_field');
  if (command.action !== 'tabs' && (!Number.isSafeInteger(command.tab_id) || command.tab_id < 1 || command.tab_id > 2147483647)) throw new Error('explicit_tab_id_required');
  for (const field of ['element_id', 'text', 'value', 'key', 'role', 'name']) {
    if (command[field] !== undefined && (typeof command[field] !== 'string' || command[field].length > (field === 'text' ? 65536 : 2048))) throw new Error(`invalid_${field}`);
  }
  if (typeof command.text === 'string' && encoder.encode(command.text).byteLength > 32768) throw new Error('text_too_large');
  if (encoder.encode(JSON.stringify(command)).byteLength > 65536) throw new Error('command_too_large');
  if (command.max_nodes !== undefined && (!Number.isInteger(command.max_nodes) || command.max_nodes < 1 || command.max_nodes > 500)) throw new Error('max_nodes_must_be_1_to_500');
  if (command.action === 'observe') command.max_nodes ??= 150;
  if (command.action === 'navigate') command.url = httpURL(command.url);
  if (!['tabs', 'observe', 'navigate'].includes(command.action)) {
    const byId = typeof command.element_id === 'string' && command.element_id.length > 0;
    const byName = typeof command.role === 'string' && command.role.length > 0 && typeof command.name === 'string';
    if (byId === byName || (byId && (command.role !== undefined || command.name !== undefined))) throw new Error('one_exact_locator_required');
    if (command.action === 'fill' && typeof command.text !== 'string') throw new Error('text_required');
    if (command.action === 'select' && typeof command.value !== 'string') throw new Error('value_required');
    if (command.action === 'check' && typeof command.checked !== 'boolean') throw new Error('checked_boolean_required');
    if (command.action === 'press' && !['Enter', 'Tab', 'Shift+Tab', 'Escape'].includes(command.key)) throw new Error('unsupported_key');
  }
  return { id: request.id, deadline_ms: request.deadline_ms, command };
}
export function boundedReply(id, result, error) {
  const reply = error ? { id, error: String(error).slice(0, 300) } : { id, result };
  if (encoder.encode(JSON.stringify(reply)).byteLength >= MAX_REPLY_BYTES) return { id, error: 'browser_response_too_large' };
  return reply;
}
function tabSummary(tab) {
  return {
    tab_id: tab.id, window_id: tab.windowId, title: (tab.title || '').slice(0, 256), url: (tab.url || '').slice(0, 2048), active: Boolean(tab.active),
    status: typeof tab.status === 'string' ? tab.status.slice(0, 32) : 'unknown',
    frozen: typeof tab.frozen === 'boolean' ? tab.frozen : null,
    discarded: typeof tab.discarded === 'boolean' ? tab.discarded : null,
    ...(tab.pendingUrl ? { pending_url: tab.pendingUrl.slice(0, 2048) } : {}),
  };
}
const isErrorPage = error => /^Frame with ID \d+ is showing error page\.?$/i.test(String(error?.message || '').trim());
const WAIT_EXPIRED = Symbol('navigation_wait_expired');
async function withinNavigationBudget(promise, stopAt) {
  let timer;
  try {
    return await Promise.race([promise, new Promise(resolve => { timer = setTimeout(() => resolve(WAIT_EXPIRED), Math.max(0, stopAt - Date.now())); })]);
  } finally { clearTimeout(timer); }
}
async function navigationResult(api, command, before, updated, deadline) {
  const stopAt = Math.min(Date.now() + 2500, deadline - 500);
  let current = updated || before;
  let progressed = current.status === 'loading' || Boolean(current.url && current.url !== before.url);
  const result = (state, error) => ({
    tab_id: command.tab_id, navigation_started: true, navigation_state: state, tab: tabSummary(current),
    next_step: state === 'pending' ? 'observe_loading_page_with_bounded_retry' : state === 'error' ? 'report_browser_page_unavailable' : 'observe',
    guidance: state === 'pending' ? 'Navigation is still pending. Wait and observe with bounded read retries; do not navigate again to poll its progress.' :
      state === 'error' ? 'Navigation was attempted, but the browser page or its DOM inspection is unavailable. Report the error; do not repeat navigation automatically.' : 'Navigation completed and the document is accessible. Observe before choosing a control.',
    ...(error ? { navigation_error: error } : {}),
  });
  while (Date.now() < stopAt) {
    try {
      const next = await withinNavigationBudget(api.tabs.get(command.tab_id), stopAt);
      if (next === WAIT_EXPIRED) break;
      current = next;
      progressed ||= current.status === 'loading' || Boolean(current.url && current.url !== before.url);
      if (progressed && current.status === 'complete' && !current.pendingUrl && !current.frozen && !current.discarded) {
        try {
          const probe = await withinNavigationBudget(api.scripting.executeScript({
            target: { tabId: command.tab_id, frameIds: [0] }, world: 'ISOLATED', injectImmediately: true,
            func: () => ({ url: location.href, ready_state: document.readyState }),
          }), stopAt);
          if (probe === WAIT_EXPIRED) break;
          const page = probe.find(item => item.frameId === 0)?.result;
          if (page?.ready_state === 'complete' && page.url === current.url) return result('complete');
        } catch (error) {
          if (!isErrorPage(error)) return result('error', 'browser_navigation_inspection_unavailable');
          const latest = await withinNavigationBudget(api.tabs.get(command.tab_id), stopAt);
          if (latest === WAIT_EXPIRED) break;
          current = latest;
          if (current.status === 'complete' && !current.pendingUrl) return result('error', 'browser_page_error');
        }
      }
    } catch { return result('error', 'browser_navigation_state_unavailable'); }
    await new Promise(resolve => setTimeout(resolve, Math.max(0, Math.min(100, stopAt - Date.now()))));
  }
  return result('pending');
}
async function injectDOM(api, options, tabId) {
  try { return await api.scripting.executeScript(options); }
  catch (error) {
    // This exact Chrome API rejection happens before the requested script executes.
    if (!isErrorPage(error)) throw error;
    const current = await api.tabs.get(tabId);
    if (current.status === 'loading' || current.pendingUrl) throw new Error(`browser_page_loading: tab ${tabId} is navigating; wait and observe, do not navigate again`);
    if (current.status === 'complete') throw new Error(`browser_page_error: tab ${tabId} is a browser error page; DOM execution unavailable`);
    throw error;
  }
}
export async function dispatchCommand(api, command, deadline) {
  checkDeadline(deadline);
  if (command.action === 'tabs') {
    const all = await api.tabs.query({});
    checkDeadline(deadline);
    return { tabs: all.slice(0, 500).map(tabSummary), truncated: all.length > 500 };
  }
  const tab = await api.tabs.get(command.tab_id);
  checkDeadline(deadline);
  if (command.action === 'navigate') {
    const updated = await api.tabs.update(command.tab_id, { url: httpURL(command.url) });
    return navigationResult(api, command, tab, updated, deadline);
  }
  if (!/^https?:\/\//i.test(tab.url || '')) throw new Error('unsupported_page: only http/https DOM pages');
  if (tab.pendingUrl || (tab.status === 'loading' && (tab.frozen === true || tab.discarded === true))) throw new Error(`browser_page_loading: tab ${command.tab_id} is navigating; wait and observe, do not navigate again`);
  if (tab.discarded === true) throw new Error(`browser_tab_discarded: tab ${command.tab_id} content is unloaded; DOM execution unavailable`);
  if (tab.frozen === true) throw new Error(`browser_tab_frozen: tab ${command.tab_id} is suspended; DOM execution unavailable`);
  const injected = await injectDOM(api, { target: { tabId: command.tab_id, frameIds: [0] }, world: 'ISOLATED', injectImmediately: true, files: ['dom.js'] }, command.tab_id);
  checkDeadline(deadline);
  const documentId = injected.find(item => item.frameId === 0)?.documentId;
  if (!documentId) throw new Error('document_unavailable');
  const results = await injectDOM(api, {
    target: { tabId: command.tab_id, documentIds: [documentId] }, world: 'ISOLATED', injectImmediately: true,
    func: (payload) => {
      try { return { result: globalThis.__shareMouseDOMBridgeV1.execute(payload) }; }
      catch (error) { return { error: String(error?.message || 'dom_operation_failed').slice(0, 300) }; }
    }, args: [{ ...command, deadline_ms: deadline }],
  }, command.tab_id);
  const response = results.find(item => item.frameId === 0)?.result;
  if (!response) throw new Error('document_unavailable');
  if (response.error) throw new Error(response.error);
  return response.result;
}
