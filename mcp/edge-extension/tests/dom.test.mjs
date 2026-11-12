import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(`${process.env.SHAREMOUSE_DOM_TEST_DEPS || '/tmp/sharemouse-edge-dom-tests'}/package.json`);
const { JSDOM } = require('jsdom');
const source = readFileSync(new URL('../dom.js', import.meta.url), 'utf8');
function fixture(html) {
  const dom = new JSDOM(html, { url: 'https://fixture.test/', runScripts: 'outside-only' });
  dom.window.TextEncoder = TextEncoder;
  dom.window.eval(source);
  const run = (command) => dom.window.__shareMouseDOMBridgeV1.execute({ tab_id: 17, deadline_ms: Date.now() + 5000, ...command });
  return { dom, doc: dom.window.document, run };
}
const find = (tree, role, name) => tree.nodes.find(n => n.role === role && n.name === name);

test('fractional Unix millisecond deadlines reach the DOM executor', () => {
  const { run } = fixture('<button>Go</button>');
  assert.ok(find(run({ action: 'observe', deadline_ms: Date.now() + 5000.25 }), 'button', 'Go'));
  for (const invalid of [NaN, Infinity, -Infinity, 0, -1, Number.MAX_SAFE_INTEGER + 1, String(Date.now() + 5000), Date.now() - 0.25]) {
    assert.throws(() => run({ action: 'observe', deadline_ms: invalid }), /deadline_exceeded/);
  }
});

test('compact tree has hierarchy, actions and fresh, tab-bound references', () => {
  const { run } = fixture('<main><button>Save</button></main>');
  const first = run({ action: 'observe' });
  const button = find(first, 'button', 'Save');
  assert.ok(button.element_id && button.parent_id);
  assert.ok(button.actions.includes('click'));
  assert.throws(() => run({ action: 'click', tab_id: 18, element_id: button.element_id }), /wrong_tab/);
  const next = run({ action: 'observe' });
  assert.notEqual(button.element_id, find(next, 'button', 'Save').element_id);
  assert.throws(() => run({ action: 'click', element_id: button.element_id }), /stale_element/);
});

test('fill/select/check dispatch DOM events and redact password output', () => {
  const { run, doc } = fixture('<label>Name<input id="name"></label><label>Secret<input type="password" value="never-echo"></label><label>Choice<select><option value="a">A</option><option value="b">B</option></select></label><label>Ready<input type="checkbox"></label>');
  const events = [];
  doc.getElementById('name').addEventListener('input', e => events.push(e.isTrusted));
  assert.equal(JSON.stringify(run({ action: 'observe' })).includes('never-echo'), false);
  run({ action: 'fill', role: 'textbox', name: 'Name', text: 'hello' });
  assert.equal(doc.getElementById('name').value, 'hello');
  assert.deepEqual(events, [false]);
  run({ action: 'select', role: 'combobox', name: 'Choice', value: 'b' });
  assert.equal(doc.querySelector('select').value, 'b');
  run({ action: 'check', role: 'checkbox', name: 'Ready', checked: true });
  assert.equal(doc.querySelector('[type=checkbox]').checked, true);
});

test('named feedback text and contenteditable values remain readable and bounded', () => {
  const { run, doc } = fixture('<output aria-label="Event log">input name isTrusted=false</output><div role="alert" aria-label="Alert">Saved successfully</div><p aria-label="Summary">Actual paragraph</p><div contenteditable="true" aria-label="Editor">line one\nline two</div><input type="password" aria-label="Secret" value="never-echo">');
  let tree = run({ action: 'observe' });
  assert.equal(find(tree, 'status', 'Event log').text, 'input name isTrusted=false');
  assert.equal(find(tree, 'alert', 'Alert').text, 'Saved successfully');
  assert.equal(find(tree, 'paragraph', 'Summary').text, 'Actual paragraph');
  assert.equal(find(tree, 'textbox', 'Editor').value, 'line one\nline two');
  run({ action: 'fill', role: 'textbox', name: 'Editor', text: 'written\nfeedback' });
  tree = run({ action: 'observe' });
  assert.equal(find(tree, 'textbox', 'Editor').value, 'written\nfeedback');
  assert.equal(JSON.stringify(tree).includes('never-echo'), false);
  doc.querySelector('output').textContent = 'x'.repeat(1000);
  doc.querySelector('[contenteditable]').textContent = 'y'.repeat(1000);
  tree = run({ action: 'observe' });
  assert.equal(find(tree, 'status', 'Event log').text.length, 512);
  assert.equal(find(tree, 'textbox', 'Editor').value.length, 512);
});

test('click and press capabilities require interaction evidence and execution rechecks them', () => {
  const { run, doc } = fixture('<main aria-label="Main"><h1>Heading</h1><p>Paragraph</p><div role="button" aria-label="Custom">Custom</div><div aria-label="Inline" onclick="void 0">Inline</div><div tabindex="-1" aria-label="Focus only">Focus</div><input aria-label="Input"><div contenteditable="true" aria-label="Editor">Text</div></main>');
  let tree = run({ action: 'observe' });
  for (const [role, name] of [['main', 'Main'], ['heading', 'Heading'], ['paragraph', 'Paragraph']]) {
    const node = find(tree, role, name);
    assert.deepEqual(Array.from(node.actions), []);
    assert.throws(() => run({ action: 'click', element_id: node.element_id }), /element_not_clickable/);
    assert.throws(() => run({ action: 'press', element_id: node.element_id, key: 'Escape' }), /element_not_focusable/);
  }
  assert.deepEqual(Array.from(find(tree, 'button', 'Custom').actions), ['click']);
  assert.deepEqual(Array.from(find(tree, 'generic', 'Inline').actions), ['click']);
  assert.deepEqual(Array.from(find(tree, 'generic', 'Focus only').actions), ['press']);
  assert.ok(find(tree, 'textbox', 'Input').actions.includes('press'));
  assert.ok(find(tree, 'textbox', 'Editor').actions.includes('press'));
  const inline = find(tree, 'generic', 'Inline');
  doc.querySelector('[onclick]').removeAttribute('onclick');
  assert.throws(() => run({ action: 'click', element_id: inline.element_id }), /element_not_clickable/);
  const focus = find(tree, 'generic', 'Focus only');
  doc.querySelector('[tabindex]').removeAttribute('tabindex');
  assert.throws(() => run({ action: 'press', element_id: focus.element_id, key: 'Escape' }), /element_not_focusable/);
});

test('ambiguous, disabled, hidden, detached and readonly targets reject without action', () => {
  const { run, doc } = fixture('<button>Same</button><button>Same</button><fieldset disabled><button>Off</button></fieldset><input aria-label="Read" readonly><button hidden>Hidden</button><button id="gone">Gone</button>');
  assert.throws(() => run({ action: 'click', role: 'button', name: 'Same' }), /ambiguous_element/);
  assert.throws(() => run({ action: 'click', role: 'button', name: 'Off' }), /disabled_element/);
  assert.throws(() => run({ action: 'fill', role: 'textbox', name: 'Read', text: 'x' }), /readonly_element/);
  assert.throws(() => run({ action: 'click', role: 'button', name: 'Hidden' }), /element_not_found/);
  const node = find(run({ action: 'observe' }), 'button', 'Gone');
  doc.getElementById('gone').remove();
  assert.throws(() => run({ action: 'click', element_id: node.element_id }), /stale_element/);
});

test('open shadow DOM and same-origin frame controls preserve parent tree', () => {
  const { run, doc } = fixture('<main><div id="shadow"></div><iframe title="Embedded"></iframe></main>');
  doc.getElementById('shadow').attachShadow({ mode: 'open' }).innerHTML = '<button>Shadow</button>';
  doc.querySelector('iframe').contentDocument.body.innerHTML = '<input aria-label="Frame">';
  const tree = run({ action: 'observe' });
  assert.ok(find(tree, 'button', 'Shadow'));
  assert.ok(find(tree, 'textbox', 'Frame'));
  run({ action: 'fill', role: 'textbox', name: 'Frame', text: 'inside' });
  assert.equal(doc.querySelector('iframe').contentDocument.querySelector('input').value, 'inside');
  const frameNode = find(run({ action: 'observe' }), 'textbox', 'Frame');
  doc.querySelector('iframe').remove();
  assert.throws(() => run({ action: 'fill', element_id: frameNode.element_id, text: 'stale' }), /stale_element/);
});

test('limited press uses DOM focus and synthetic events, and long names are not prefix locators', () => {
  const { run, doc } = fixture('<input aria-label="First"><input aria-label="Next"><button>Go</button>');
  const seen = [];
  doc.querySelector('input').addEventListener('keydown', event => seen.push([event.key, event.isTrusted]));
  const result = run({ action: 'press', role: 'textbox', name: 'First', key: 'Tab' });
  assert.equal(result.default_behavior, 'dom_focus');
  assert.equal(doc.activeElement.getAttribute('aria-label'), 'Next');
  assert.deepEqual(seen, [['Tab', false]]);
  const longer = fixture(`<button>${'A'.repeat(250)}</button>`);
  assert.throws(() => longer.run({ action: 'click', role: 'button', name: 'A'.repeat(200) }), /element_not_found/);
  const spaced = fixture(`<button aria-label="Go${' '.repeat(2050)}elsewhere">button</button>`);
  assert.throws(() => spaced.run({ action: 'click', role: 'button', name: 'Go' }), /locator_scan_truncated/);
});

test('bounds, expired commands, unsupported keys and action-consumed snapshots', () => {
  const { run } = fixture('<button>Go</button>'.repeat(550));
  const tree = run({ action: 'observe', max_nodes: 500 });
  assert.equal(tree.nodes.length, 500);
  assert.equal(tree.truncated, true);
  assert.throws(() => run({ action: 'click', role: 'button', name: 'Go' }), /ambiguous_element/);
  assert.throws(() => run({ action: 'observe', deadline_ms: Date.now() - 1 }), /deadline_exceeded/);
  assert.throws(() => run({ action: 'press', element_id: tree.nodes[1].element_id, key: 'Control+L' }), /unsupported_key/);
  const other = fixture('<button>Only</button>');
  const id = find(other.run({ action: 'observe' }), 'button', 'Only').element_id;
  other.run({ action: 'click', element_id: id });
  assert.throws(() => other.run({ action: 'click', element_id: id }), /stale_element/);
});
