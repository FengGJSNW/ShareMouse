/* Loaded only by chrome.scripting in the ISOLATED world of an explicit tab. */
(() => {
  if (globalThis.__shareMouseDOMBridgeV1) return;
  const MAX_VISITS = 12000;
  const MAX_DEPTH = 80;
  const MAX_TEXT = 200000;
  const TEXT_INPUTS = new Set(['text', 'email', 'password', 'search', 'tel', 'url']);
  const CLICK_ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'switch', 'combobox', 'listbox', 'option', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab', 'treeitem', 'slider', 'spinbutton', 'textbox', 'searchbox']);
  const TEXT_ROLES = new Set(['status', 'alert', 'log', 'paragraph', 'heading', 'cell', 'columnheader', 'rowheader', 'listitem', 'note', 'definition', 'term']);
  let snapshot = null;
  let boundTab = null;
  const fail = code => { throw new Error(code); };
  const clip = (text, max = 200) => String(text || '').slice(0, max).replace(/\s+/g, ' ').trim();
  function deadline(command) {
    if (!Number.isFinite(command.deadline_ms) || command.deadline_ms <= 0 || command.deadline_ms > Number.MAX_SAFE_INTEGER || Date.now() >= command.deadline_ms) fail('deadline_exceeded');
  }
  function parent(element) {
    return element.parentElement || element.getRootNode()?.host || element.ownerDocument?.defaultView?.frameElement;
  }
  function hidden(element) {
    if (element.hidden || (element.localName === 'input' && element.type === 'hidden') || element.getAttribute('aria-hidden') === 'true' || element.hasAttribute('inert')) return true;
    const style = element.ownerDocument.defaultView.getComputedStyle(element);
    return style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse';
  }
  function disabled(element) {
    let cursor = element;
    for (let depth = 0; cursor && depth < MAX_DEPTH; depth++, cursor = parent(cursor)) {
      if (cursor.matches(':disabled') || cursor.getAttribute('aria-disabled') === 'true' || cursor.hasAttribute('inert')) return true;
    }
    return false;
  }
  function role(element) {
    const explicit = clip(element.getAttribute('role'), 50).split(' ')[0];
    if (explicit && explicit !== 'none' && explicit !== 'presentation') return explicit;
    const tag = element.localName;
    if (tag === 'input') {
      const type = element.type;
      if (type === 'hidden') return '';
      if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
      if (type === 'checkbox' || type === 'radio') return type;
      if (type === 'range') return 'slider';
      if (type === 'number') return 'spinbutton';
      return 'textbox';
    }
    if (tag === 'select') return element.multiple || element.size > 1 ? 'listbox' : 'combobox';
    if (tag === 'textarea' || editable(element)) return 'textbox';
    if (tag === 'a') return element.hasAttribute('href') ? 'link' : '';
    if (/^h[1-6]$/.test(tag)) return 'heading';
    return ({ button: 'button', summary: 'button', main: 'main', nav: 'navigation', form: 'form', section: 'region', article: 'article', aside: 'complementary', header: 'banner', footer: 'contentinfo', dialog: 'dialog', details: 'group', fieldset: 'group', ul: 'list', ol: 'list', li: 'listitem', table: 'table', tr: 'row', th: 'columnheader', td: 'cell', img: 'img', iframe: 'iframe', p: 'paragraph', output: 'status' })[tag] || (clickable(element) || focusable(element) ? 'generic' : '');
  }
  function editable(element) {
    return element.isContentEditable || ['', 'true', 'plaintext-only'].includes(element.getAttribute('contenteditable'));
  }
  function fillable(element) {
    return element.localName === 'textarea' || (element.localName === 'input' && TEXT_INPUTS.has(element.type)) || editable(element);
  }
  function clickable(element) {
    if (typeof element.click !== 'function' || (element.localName === 'input' && element.type === 'hidden')) return false;
    const tag = element.localName;
    return ['button', 'select', 'textarea', 'summary', 'input'].includes(tag)
      || (['a', 'area'].includes(tag) && element.hasAttribute('href'))
      || (tag === 'label' && element.control && !disabled(element.control))
      || editable(element) || CLICK_ROLES.has(clip(element.getAttribute('role'), 50).split(' ')[0])
      || element.hasAttribute('onclick') || typeof element.onclick === 'function';
  }
  function focusable(element) {
    if (typeof element.focus !== 'function' || (element.localName === 'input' && element.type === 'hidden')) return false;
    return element.tabIndex >= 0 || /^[-+]?\d+$/.test(element.getAttribute('tabindex') || '') || editable(element);
  }
  function tick(state) {
    if (++state.visits > MAX_VISITS) { state.truncated = true; return false; }
    if ((state.visits & 63) === 0) deadline(state.command);
    return true;
  }
  function textOf(element, state, max = 200, normalize = true) {
    let text = '';
    const walker = element.ownerDocument.createTreeWalker(element, 5);
    while (text.length < max && state.text < MAX_TEXT) {
      const node = walker.nextNode();
      if (!node || !tick(state)) break;
      if (node.nodeType !== 3 || node.parentElement?.closest('script,style,textarea,select')) continue;
      const part = (node.nodeValue || '').slice(0, max - text.length);
      text += part;
      state.text += part.length;
    }
    if (state.text >= MAX_TEXT) state.truncated = true;
    if (text.length >= max) state.nameTruncated = true;
    return normalize ? clip(text, max) : text;
  }
  function name(element, state, max = 200) {
    state.nameTruncated = false;
    const normalized = text => {
      if (String(text || '').length > max) state.nameTruncated = true;
      return clip(text, max);
    };
    const labelled = clip(element.getAttribute('aria-labelledby'), 512);
    if (labelled) {
      const root = element.getRootNode();
      if (element.getAttribute('aria-labelledby').length > 512 || labelled.split(/\s+/).length > 16) state.nameTruncated = true;
      const parts = labelled.split(/\s+/).slice(0, 16).map(id => root.getElementById?.(id)).filter(Boolean);
      if (parts.length) return normalized(parts.map(node => textOf(node, state, max)).join(' '));
    }
    const aria = element.getAttribute('aria-label');
    if (aria) return normalized(aria);
    if (element.labels?.length) {
      if (element.labels.length > 8) state.nameTruncated = true;
      return normalized(Array.from(element.labels).slice(0, 8).map(label => textOf(label, state, max)).join(' '));
    }
    if (element.localName === 'img' || (element.localName === 'input' && element.type === 'image')) return normalized(element.getAttribute('alt'));
    if (element.localName === 'iframe') return normalized(element.title) || 'iframe';
    if (element.localName === 'input' && ['submit', 'button', 'reset'].includes(element.type)) return normalized(element.value || element.type);
    if (['input', 'textarea', 'select'].includes(element.localName) || editable(element)) return normalized(element.getAttribute('placeholder') || element.title);
    if (['main', 'nav', 'form', 'section', 'article', 'aside', 'header', 'footer', 'ul', 'ol', 'table', 'tr', 'fieldset'].includes(element.localName)) return normalized(element.title);
    return textOf(element, state, max) || normalized(element.title);
  }
  function actions(element) {
    const result = [];
    if (disabled(element)) return result;
    if (clickable(element)) result.push('click');
    if (fillable(element) && !element.readOnly) result.push('fill');
    if (element.localName === 'select' && !element.multiple) result.push('select');
    if (element.localName === 'input' && ['checkbox', 'radio'].includes(element.type)) result.push('check');
    if (focusable(element)) result.push('press');
    return result;
  }
  function value(element, state) {
    if (element.localName === 'input' && element.type === 'password') return '[redacted]';
    if (['input', 'textarea', 'select'].includes(element.localName)) return String(element.value || '').slice(0, 512);
    if (editable(element)) return textOf(element, state, 512, false);
    return undefined;
  }
  function scan(command, maxNodes = 500, locate = null) {
    const token = crypto.randomUUID();
    const state = { command, visits: 0, text: 0, truncated: false, frameLimitations: 0, nodes: [], refs: new Map(), matches: [] };
    const rootId = `t${command.tab_id}:${token}:0`;
    state.nodes.push({ element_id: rootId, parent_id: null, role: 'document', name: clip(document.title), actions: [] });
    function walk(element, parentId, depth, frames = []) {
      if (!element || state.truncated) return;
      if (depth > MAX_DEPTH || !tick(state)) { state.truncated = true; return; }
      if (hidden(element) || ['script', 'style', 'template', 'noscript'].includes(element.localName)) return;
      const r = role(element);
      let currentId = parentId;
      if (r) {
        const n = name(element, state, locate ? 2048 : 200);
        if (locate && state.nameTruncated) state.truncated = true;
        if (locate && r === locate.role && n === locate.name) state.matches.push(element);
        if (!locate) {
          if (state.nodes.length >= maxNodes) { state.truncated = true; return; }
          currentId = `t${command.tab_id}:${token}:${state.nodes.length}`;
          const node = { element_id: currentId, parent_id: parentId, role: r, name: n, actions: actions(element) };
          if (state.nameTruncated) node.name_truncated = true;
          const v = value(element, state);
          if (v !== undefined) node.value = v;
          if (TEXT_ROLES.has(r)) node.text = textOf(element, state, 512, false);
          if (disabled(element)) node.disabled = true;
          if (element.readOnly) node.readonly = true;
          if (element.localName === 'input' && ['checkbox', 'radio'].includes(element.type)) node.checked = element.checked;
          if (element.hasAttribute('aria-expanded')) node.expanded = element.getAttribute('aria-expanded') === 'true';
          if (element.localName === 'select') {
            node.options = [];
            for (const option of element.options) {
              if (node.options.length >= 50 || !tick(state)) { node.options_truncated = true; break; }
              node.options.push({ value: clip(option.value), name: clip(option.label), disabled: option.disabled || option.parentElement?.disabled === true });
            }
          }
          state.nodes.push(node);
          state.refs.set(currentId, { element, document: element.ownerDocument, frames });
        }
      }
      if (element.shadowRoot) {
        for (const child of element.shadowRoot.children) { walk(child, currentId, depth + 1, frames); if (state.truncated) break; }
      }
      for (const child of element.children) { walk(child, currentId, depth + 1, frames); if (state.truncated) break; }
      if (element.localName === 'iframe') {
        try {
          const frameDoc = element.contentDocument;
          if (frameDoc?.documentElement) walk(frameDoc.documentElement, currentId, depth + 1, [...frames, { element, document: frameDoc }]);
          else state.frameLimitations++;
        } catch { state.frameLimitations++; }
      }
    }
    walk(document.documentElement, rootId, 0);
    deadline(command);
    return state;
  }
  function resolve(command) {
    if (command.element_id) {
      const ref = snapshot?.refs.get(command.element_id);
      if (!ref || !ref.element.isConnected || ref.element.ownerDocument !== ref.document || ref.document.defaultView?.document !== ref.document || ref.frames.some(frame => !frame.element.isConnected || frame.element.contentDocument !== frame.document)) fail('stale_element: observe again');
      return ref.element;
    }
    if (typeof command.role !== 'string' || typeof command.name !== 'string') fail('one_exact_locator_required');
    const state = scan(command, 500, command);
    if (state.matches.length > 1) fail('ambiguous_element');
    if (state.truncated) fail('locator_scan_truncated: use a fresh element_id');
    if (!state.matches.length) fail('element_not_found');
    return state.matches[0];
  }
  function ready(element) {
    if (disabled(element)) fail('disabled_element');
    let cursor = element;
    for (let depth = 0; cursor && depth < MAX_DEPTH; depth++, cursor = parent(cursor)) if (hidden(cursor)) fail('hidden_element');
  }
  function emit(element, type) {
    const EventClass = element.ownerDocument.defaultView.Event;
    element.dispatchEvent(new EventClass(type, { bubbles: true, composed: true }));
  }
  function setValue(element, text) {
    const view = element.ownerDocument.defaultView;
    const prototype = element.localName === 'textarea' ? view.HTMLTextAreaElement.prototype : element.localName === 'select' ? view.HTMLSelectElement.prototype : view.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, text);
  }
  function press(element, command) {
    if (!['Enter', 'Tab', 'Shift+Tab', 'Escape'].includes(command.key)) fail('unsupported_key');
    const key = command.key === 'Shift+Tab' ? 'Tab' : command.key;
    const options = { key, code: key, shiftKey: command.key === 'Shift+Tab', bubbles: true, cancelable: true, composed: true };
    const KeyboardEventClass = element.ownerDocument.defaultView.KeyboardEvent;
    element.focus({ preventScroll: true });
    if (element.getRootNode().activeElement !== element) fail('focus_not_applied');
    const accepted = element.dispatchEvent(new KeyboardEventClass('keydown', options));
    let behavior = 'event_only';
    if (accepted) {
      deadline(command);
      if (key === 'Tab') {
        const state = scan(command, 500);
        if (state.truncated) fail('focus_scan_truncated');
        const candidates = Array.from(state.refs.values()).map(ref => ref.element).filter(node => node.tabIndex >= 0 && !disabled(node));
        candidates.sort((a, b) => (a.tabIndex > 0 ? a.tabIndex : Infinity) - (b.tabIndex > 0 ? b.tabIndex : Infinity));
        const index = candidates.indexOf(element);
        const next = candidates[index + (options.shiftKey ? -1 : 1)];
        if (!next) fail('focus_boundary: browser chrome focus is not supported');
        next.focus({ preventScroll: true });
        behavior = 'dom_focus';
      } else if (key === 'Enter' && ['button', 'a', 'summary'].includes(element.localName) && clickable(element)) {
        element.click(); behavior = 'dom_click';
      } else if (key === 'Enter' && element.localName === 'input' && element.form) {
        element.form.requestSubmit(); behavior = 'form_request_submit';
      }
    }
    element.dispatchEvent(new KeyboardEventClass('keyup', options));
    return { key: command.key, default_behavior: behavior, event_is_trusted: false };
  }
  function execute(command) {
    deadline(command);
    if (!Number.isSafeInteger(command.tab_id) || command.tab_id < 1 || command.tab_id > 2147483647) fail('explicit_tab_id_required');
    if (boundTab !== null && command.tab_id !== boundTab) fail('wrong_tab');
    boundTab = command.tab_id;
    if (command.action === 'observe') {
      const max = command.max_nodes ?? 150;
      if (!Number.isInteger(max) || max < 1 || max > 500) fail('max_nodes_must_be_1_to_500');
      snapshot = null;
      const state = scan(command, max);
      snapshot = state;
      return { tab_id: boundTab, title: clip(document.title), url: location.href.slice(0, 2048), nodes: state.nodes, truncated: state.truncated, visited: state.visits, inaccessible_frames: state.frameLimitations, limitations: ['DOM-derived roles/names; not the browser accessibility tree', 'Cross-origin frames and closed shadow roots are not traversed', 'Page events are synthetic (isTrusted=false)'] };
    }
    if (!['click', 'fill', 'select', 'check', 'press'].includes(command.action)) fail('unsupported_action');
    const element = resolve(command);
    ready(element);
    deadline(command);
    if (command.action === 'fill') {
      if (element.readOnly) fail('readonly_element');
      if (!fillable(element)) fail('element_not_fillable');
      if (typeof command.text !== 'string' || new TextEncoder().encode(command.text).byteLength > 32768) fail('invalid_text');
      snapshot = null;
      if (editable(element)) element.textContent = command.text;
      else setValue(element, command.text);
      emit(element, 'input'); emit(element, 'change');
      if ((editable(element) ? element.textContent : element.value) !== command.text) fail('fill_not_applied');
    } else if (command.action === 'select') {
      if (element.localName !== 'select' || element.multiple) fail('single_select_required');
      if (typeof command.value !== 'string') fail('value_required');
      if (element.options.length > MAX_VISITS) fail('option_scan_truncated');
      const matches = Array.from(element.options).filter(option => option.value === command.value);
      if (matches.length !== 1) fail(matches.length ? 'ambiguous_option' : 'option_not_found');
      if (matches[0].disabled || matches[0].parentElement?.disabled) fail('disabled_option');
      snapshot = null;
      setValue(element, command.value); emit(element, 'input'); emit(element, 'change');
      if (element.value !== command.value) fail('select_not_applied');
    } else if (command.action === 'check') {
      if (element.localName !== 'input' || !['checkbox', 'radio'].includes(element.type) || typeof command.checked !== 'boolean') fail('native_checkable_required');
      if (element.type === 'radio' && !command.checked) fail('radio_cannot_be_unchecked');
      snapshot = null;
      if (element.checked !== command.checked) element.click();
      if (element.checked !== command.checked) fail('check_not_applied');
    } else if (command.action === 'click') {
      if (!clickable(element)) fail('element_not_clickable');
      snapshot = null;
      element.click();
    } else {
      if (!['Enter', 'Tab', 'Shift+Tab', 'Escape'].includes(command.key)) fail('unsupported_key');
      if (!focusable(element)) fail('element_not_focusable');
      snapshot = null;
      return { tab_id: boundTab, action: command.action, ...press(element, command) };
    }
    return { tab_id: boundTab, action: command.action, applied: true, event_is_trusted: false, observe_required: true };
  }
  addEventListener('pagehide', () => { snapshot = null; });
  Object.defineProperty(globalThis, '__shareMouseDOMBridgeV1', { value: Object.freeze({ execute }), configurable: false });
})();
