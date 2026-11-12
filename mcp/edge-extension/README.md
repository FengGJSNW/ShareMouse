# Edge DOM bridge

Manifest V3 extension for explicit-tab observations and semantic DOM operations. It connects only to the local native host `com.sharemouse.browser`. The fixed public manifest key gives extension ID **`cdocbfpfceafibeokdomcpmeinlinikf`** on both platforms; the host allowlist must contain `chrome-extension://cdocbfpfceafibeokdomcpmeinlinikf/`. No private key is stored in this directory.

The service worker connects on startup, retries a disconnected host after one second, and uses a one-minute alarm as a worker-suspension fallback. Its action badge shows `ON`/`OFF`; clicking while disconnected reconnects. Register the native host using the parent MCP installation instructions, then load this directory as an unpacked extension in the intended Edge profile. Loading a fixture through `file://` is intentionally unsupported; serve `tests/fixture.html` over local HTTP instead.

## Native protocol

Host request (absolute Unix time in milliseconds):

```json
{"id":"request-1","deadline_ms":1794432005000,"command":{"action":"observe","tab_id":17,"max_nodes":150}}
```

Exactly one response: `{"id":"request-1","result":{...}}` or `{"id":"request-1","error":"error_code"}`. Calls are serialized; the pending queue holds at most 16 commands. Expired commands are rejected before injection and again immediately before DOM mutation. Observe reserves 500 ms of the caller's deadline for returning a `browser_read_timeout`; its injected command uses the same earlier deadline. That read-only error does not imply an interaction occurred. For mutating commands, a deadline cannot undo a DOM operation already started or stop page JavaScript; observe before deciding whether to retry an uncertain action.

| Action | Required command fields | Result/behavior |
|---|---|---|
| `tabs` | none | `tabs`: `tab_id`, `window_id`, `title`, `url`, `active`, `status`, `frozen`, `discarded`, optional `pending_url`; at most 500 |
| `observe` | `tab_id`, optional `max_nodes` | Flat compact tree in `nodes`, with `element_id`, `parent_id`, `role`, normalized `name`, optional `value`/feedback `text`, state, and `actions` |
| `navigate` | `tab_id`, `url` | One HTTP(S) navigation request, then bounded readiness checking; returns `navigation_state` (`complete`, `pending`, `error`) and current `tab` state |
| `click` | `tab_id`, locator | Calls the element's DOM `click()` |
| `fill` | `tab_id`, locator, `text` | Replaces text input/textarea/contenteditable contents and dispatches `input` and `change` |
| `select` | `tab_id`, locator, `value` | Selects one enabled, unique exact option value in a native single select |
| `check` | `tab_id`, locator, boolean `checked` | Native checkbox/radio state; uses DOM click when state differs; radio cannot be unchecked |
| `press` | `tab_id`, locator, `key` | Limited DOM key behavior described below |

Every operation except `tabs` requires a positive, signed 32-bit `tab_id`. No operation implicitly chooses the active tab or activates a tab/window. A locator is either a fresh `element_id` **or** both exact `role` and normalized exact `name`, never both. Role/name matching rejects duplicates, and rejects an incomplete scan rather than choosing a partially observed match. Long displayed names are shortened; use their element IDs. Disabled, readonly, detached, or stale targets reject the corresponding operation.

Every observation produces new element IDs. A new observation, a DOM action attempt that reaches mutation/dispatch, or `pagehide` invalidates previous IDs. IDs cannot cross tabs/documents. Detached/reloaded iframe references reject too. Re-observe after an action; role/name locators scan current DOM independently.

Named status/alert/log and textual nodes also expose their actual bounded `text`, so an ARIA label does not hide feedback. Contenteditable controls expose a bounded `value` that preserves whitespace. Both fields are capped at 512 characters and share the scan's text/visit budgets; password inputs remain redacted. `click` requires native control/link semantics, an interactive ARIA role, contenteditable, or an observable `onclick` handler; `press` requires DOM focusability. The same checks run again at execution, and press fails if focus did not reach the target. Passive headings, paragraphs and landmarks therefore do not advertise click/press solely because they inherit DOM methods. Page event listeners registered only through `addEventListener` cannot be inspected reliably from this isolated adapter; custom interactive elements should expose an appropriate role/focus attribute.

## Loading and suspended tabs

Both injection stages use `injectImmediately: true` to inspect the DOM already present instead of waiting for `document_idle`. This does not wait for page completion and does not wake a suspended renderer. The second stage still targets the exact `documentId` returned by the first, so navigation cannot redirect a command to a replacement document.

`tabs` reports the browser's lifecycle fields. Unsupported `frozen`/`discarded` fields are `null`, and absent status is `unknown`; missing state is never treated as proof that the renderer is awake. A `pending_url`, or loading combined with frozen/discarded, is a navigation transition: DOM commands return `browser_page_loading`, with bounded observation as the next step, not another navigation. Stable discarded/frozen tabs return `browser_tab_discarded`/`browser_tab_frozen` without injecting or activating the tab. An unknown state or a renderer that stops after the check remains protected by `browser_read_timeout` for observe. A UI label saying “sleeping” alone is not proof of a particular Tabs API flag.

Explicit `navigate` remains available for suspended tabs and never sets `active`. It calls `tabs.update` exactly once, then checks for at most 2.5 seconds while reserving 500 ms before the host deadline. Every readiness read and fixed ISOLATED document probe shares this short budget; a frozen probe cannot turn acknowledged navigation into a long action timeout. `complete` means the browser finished loading and the document is accessible, not that an HTTP response or application task succeeded. `pending` includes current tab state and explicitly instructs bounded observation without repeating navigation. A completed browser error page returns `navigation_state: error`, `navigation_error: browser_page_error`; other inspection/state failures have separate diagnostic codes. These are results of an already-attempted navigation, not preflight rejections.

The specific Chrome injection rejection “Frame with ID … is showing error page” is rechecked against current tab state. DOM operations receive `browser_page_loading` while navigation is still in progress, or `browser_page_error` when the browser reports the error page complete. Other errors are not relabelled as network failures. Re-navigating a target can restore a responsive document while retaining the current foreground tab, but reloads its page state; it is not automatic and is not guaranteed to wake every browser-specific sleep mode. The agent must choose recovery explicitly and re-observe afterward. No browser energy-saving setting is changed.

## Scope and limits

- This is a small DOM adapter, **not full Playwright** and not the browser accessibility tree. Role/name heuristics cover native controls, ARIA labels/roles, labels, headings, paragraphs and common landmarks. They do not implement the complete accessible-name specification.
- The extension injects its fixed packaged script on demand into the explicit tab's main document in the **ISOLATED** world, then pins execution to the browser's returned `documentId`. It traverses open shadow roots and accessible same-origin iframes. Cross-origin/sandboxed frames and closed shadow roots are not traversed; inaccessible iframe count is returned. Browser pages, the address bar, PDFs, canvas controls, and other non-DOM interfaces are unsupported.
- There is no arbitrary evaluation command, main-world injection, page-to-bridge messaging, externally connectable entrypoint, web-accessible resource, debugger permission, or real mouse input. The page cannot invoke this bridge via `postMessage` or extension runtime messaging.
- Page events created by the adapter are synthetic (`isTrusted=false`); website handlers may reject them. `click()` does not simulate a pointer path or hit testing. The adapter checks hidden/disabled attributes and CSS display/visibility, but does not provide Playwright actionability, layout stability, scrolling, occlusion, auto-wait, network-idle, popup/dialog management, native keyboard shortcuts, or guaranteed background focus isolation.
- `press` accepts only `Enter`, `Tab`, `Shift+Tab`, `Escape`. It focuses the target in the page and dispatches `keydown`/`keyup`. Unless cancelled, Enter invokes a button/link/summary DOM click or an input's form `requestSubmit`; other Enter targets and Escape receive events only. Tab/Shift+Tab move DOM focus among a bounded current control tree and reject at the page boundary; they never move focus into browser chrome. This is an approximation of page tab order, not native keyboard input. `default_behavior` reports the chosen behavior. Custom editors may need `fill`, their submit button, or an application-specific integration.
- Text writes are at most 32 KiB UTF-8; commands at most 64 KiB. The tree defaults to 150 nodes and allows 1–500, with at most 12,000 visited nodes, depth 80, 200,000 text characters consumed, names 200 characters, values 512 characters, and 50 displayed options per select. Output is strictly below **220 KiB UTF-8 JSON**; excess returns `browser_response_too_large`. Use fewer nodes if a large tree exceeds the byte limit. Password input values are always `[redacted]`; no DOM contents or command text are logged.

## Focused tests

The test dependency is external to the project:

```sh
npm install --prefix /tmp/sharemouse-edge-dom-tests --no-audit --no-fund jsdom@26.1.0
node --test mcp/edge-extension/tests/*.test.mjs
```

Set `SHAREMOUSE_DOM_TEST_DEPS` to another dependency prefix if needed. Tests first failed with missing implementation, then exercised hierarchy, tab/snapshot/document binding, disabled/readonly/ambiguous controls, fill/select/check events, password redaction, open shadows/same-origin frames, key limitations, deadlines, injection document pinning, and payload bounds. Targeted regressions also model the documented `document_idle` gate at each injection stage, frozen/discarded flags, and a renderer that never answers; those tests failed on the prior implementation before the fixes. API mocks and JSDOM tests do not reproduce every real Edge suspension mode or constitute real-Edge acceptance. Use the HTTP fixture for native-host/Edge integration, confirm actual browser events and state, and independently verify that the OS mouse and unrelated tab are unchanged.

API references: [Chrome scripting, injection timing and execution worlds](https://developer.chrome.com/docs/extensions/reference/api/scripting), [Tabs lifecycle fields](https://developer.chrome.com/docs/extensions/reference/api/tabs#type-Tab), [native messaging host protocol](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
