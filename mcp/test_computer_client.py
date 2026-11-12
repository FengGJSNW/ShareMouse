import copy
import json
import unittest
from computer_client import ComputerClient


class Backend:
    def __init__(self):
        self.calls = []
        self.frame = 0
        self.control_mode = "user_mouse"
        self.active = False
        self.action_error = None
        self.actions = []
        self.window = {'window_id': 'win:qa', 'title': 'QA', 'process_name': 'QA', 'left': 0, 'top': 0, 'right': 100, 'bottom': 100}

    def reply(self, value, error=False, image=False):
        return {'jsonrpc': '2.0', 'result': {'isError': error, 'structuredContent': {'result': value}, 'content': [{'type': 'image', 'mimeType': 'image/png', 'data': 'image-bytes'}] if image else []}}

    def observe(self):
        self.frame += 1
        return self.reply({'peer_id': 'p', 'control_session_id': 'private-token', 'observation_id': str(self.frame),
                           'control_mode': self.control_mode, 'screenshot': {'width': 100, 'height': 100}, 'coordinate_transform': {'desktop_units_per_screenshot_pixel': {'x': 2.56, 'y': 1.6}}, 'input_state': {'foreground_window': copy.deepcopy(self.window), 'control_target_window': copy.deepcopy(self.window) if self.control_mode == 'independent' else None},
                           'analysis': {'controls': {'items': [{'name': 'Continue', 'role': 'ControlType.Button', 'enabled': True, 'bounds': {'x': 10, 'y': 20, 'width': 30, 'height': 20}}, {'name': 'Continue', 'role': 'ControlType.Text', 'bounds': {'x': 15, 'y': 25, 'width': 20, 'height': 10}}]}}}, image=True)

    def __call__(self, request):
        name = request.get('params', {}).get('name')
        args = request.get('params', {}).get('arguments', {})
        self.calls.append((name, copy.deepcopy(args)))
        if request['method'] == 'tools/list':
            return {'result': {'tools': [{'name': 'open_computer'}, {'name': 'list_computers'}, {'name': 'send_files'}]}}
        if name == 'list_computers':
            return self.reply([{'peer_id': 'p', 'name': 'Windows QA', 'platform': 'windows', 'local': True}])
        if name == 'get_computer_info':
            if args.get('read_screen'):
                return self.reply({'observation': {'read_only': True, 'screenshot': {'width': 100, 'height': 100, 'image_omitted': True, 'pixels_captured': False}, 'analysis': {'controls': {'status': 'available', 'tree': [{'role': 'Button', 'name': 'Continue', 'depth': 0}]}}}})
            return self.reply({'input_state': {'foreground_window': copy.deepcopy(self.window), 'control_target_window': copy.deepcopy(self.window) if self.control_mode == 'independent' else None}, 'control_state': {'active': self.active}})
        if name in ('open_computer', 'observe_computer'):
            self.active = True
            if name == 'open_computer':
                self.control_mode = args.get('control_mode', 'user_mouse')
            return self.observe()
        if name == 'release_input':
            self.active = False
            return self.reply({'closed': True})
        if name == 'computer_action':
            if self.action_error:
                code = self.action_error
                self.action_error = None
                return self.reply({'error': code, 'error_details': {'code': code, 'expected_observation_id': 'internal-frame'}}, True)
            self.actions += args['actions']
            result = self.observe()
            result['result']['structuredContent']['result'] = {'execution_status': 'injected', 'executed_actions': len(args['actions']), 'observation': result['result']['structuredContent']['result']}
            return result
        return {'result': {}}


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.now = 0
        self.client = ComputerClient(self.backend, clock=lambda: self.now, start_timer=False)

    def test_windows_inventory_does_not_acquire_control(self):
        self.client.use({'action': 'windows'})
        self.assertFalse(self.backend.active)
        self.assertEqual(self.backend.calls[-1], ('get_computer_info', {'peer_id': 'p', 'list_windows': True}))

    def test_explicit_window_binding_is_forwarded_and_retained(self):
        self.client.use({'control_mode': 'independent', 'window_id': 'win:qa'})
        opened = next(a for n, a in self.backend.calls if n == 'open_computer')
        self.assertEqual(opened['window_id'], 'win:qa')
        self.client.use({'action': 'observe'})
        self.assertEqual(self.client.states['p']['window_id'], 'win:qa')

    def test_repeating_same_window_binding_does_not_reopen_or_block_click(self):
        binding = {'computer': 'local', 'window_id': 'win:qa', 'control_mode': 'independent'}
        self.client.use({**binding, 'action': 'observe', 'text_only': True})
        self.assertEqual(self.client.states['p']['application'], 'QA')
        self.client.states['p']['observation']['analysis']['controls']['items'][0]['element_id'] = 'element:qa'
        self.client.use({**binding, 'action': 'click', 'element_id': 'element:qa'})
        self.assertEqual(self.backend.actions, [{'type': 'ax_click', 'element_id': 'element:qa'}])
        self.assertEqual(sum(n == 'open_computer' for n, _ in self.backend.calls), 1)
        self.assertEqual(sum(n == 'release_input' for n, _ in self.backend.calls), 0)

    def test_changing_explicit_window_still_rebinds_and_drops_old_inferred_app(self):
        self.client.use({'window_id': 'win:qa', 'control_mode': 'independent', 'text_only': True})
        self.client.use({'window_id': 'win:other', 'control_mode': 'independent', 'text_only': True})
        opens = [a for n, a in self.backend.calls if n == 'open_computer']
        self.assertEqual(len(opens), 2)
        self.assertEqual(opens[-1]['window_id'], 'win:other')
        self.assertNotIn('application', opens[-1])

    def test_unsupported_semantic_action_is_rejected_before_open_or_review(self):
        with self.assertRaisesRegex(ValueError, 'element_id_requires_independent_click_or_set_value'):
            self.client.use({'window_id': 'win:qa', 'control_mode': 'independent', 'action': 'double_click', 'element_id': 'element:qa'})
        self.assertFalse(any(n == 'open_computer' for n, _ in self.backend.calls))

    def test_element_action_never_falls_back_to_coordinates(self):
        self.client.use({'control_mode': 'independent', 'application': 'QA'})
        self.client.states['p']['observation']['analysis']['controls']['items'][0]['element_id'] = 'element:qa'
        self.client.use({'action': 'click', 'element_id': 'element:qa'})
        operation = self.backend.actions[-1]
        self.assertEqual(operation, {'type': 'ax_click', 'element_id': 'element:qa'})

    def test_bound_text_only_capture_is_retained_for_semantic_action(self):
        self.client.use({'control_mode': 'independent', 'application': 'QA', 'text_only': True})
        self.client.states['p']['observation']['analysis']['controls']['items'][0]['element_id'] = 'element:qa'
        self.client.use({'action': 'click', 'element_id': 'element:qa'})
        args = next(a for n, a in reversed(self.backend.calls) if n == 'computer_action')
        self.assertTrue(args['text_only'])

    def test_reopened_text_only_session_requests_controls_review_not_missing_image(self):
        observe = self.backend.observe
        def with_element_ids():
            result = observe()
            result['result']['structuredContent']['result']['analysis']['controls']['items'][0]['element_id'] = 'fresh:control'
            return result
        self.backend.observe = with_element_ids
        self.client.use({'control_mode': 'independent', 'application': 'QA', 'text_only': True})
        self.client._release(self.client.states['p'])
        result = self.client.use({'action': 'click', 'element_id': 'old-reference'})['structuredContent']['result']
        self.assertEqual(result['status'], 'review_new_controls')
        self.assertTrue(result['needs_review'])
        self.assertFalse(result['input_attempted'])
        self.assertTrue(result['controls'])
        self.assertEqual(result['next_step'], 'inspect_returned_controls_then_use_fresh_element_id')
        self.assertFalse(self.backend.actions)

    def test_missing_controls_never_request_nonexistent_element_id(self):
        state = {'name': 'QA', 'control_mode': 'independent', 'text_only': True, 'report_analysis': True}
        native = {'structuredContent': {'result': {'screenshot': {'image_omitted': True}, 'analysis': {'controls': {'items': []}}}}}
        result = self.client._public(state, native, 'review_new_image', True)['structuredContent']['result']
        self.assertEqual(result['status'], 'review_new_state')
        self.assertNotEqual(result['next_step'], 'inspect_returned_controls_then_use_fresh_element_id')

    def test_stale_element_is_not_replaced_by_another_control(self):
        self.client.use({'control_mode': 'independent', 'application': 'QA'})
        r = self.client.use({'action': 'click', 'element_id': 'element:old'})
        self.assertEqual(r['structuredContent']['result']['status'], 'element_not_in_latest_observation')
        self.assertFalse(self.backend.actions)

    def test_set_value_requires_a_semantic_target_and_allows_empty_value(self):
        self.client.use({'control_mode': 'independent', 'application': 'QA'})
        self.client.states['p']['observation']['analysis']['controls']['items'][0]['element_id'] = 'element:qa'
        self.client.use({'action': 'set_value', 'element_id': 'element:qa', 'text': ''})
        self.assertEqual(self.backend.actions[-1], {'type': 'set_value', 'element_id': 'element:qa', 'text': ''})

    def test_read_only_text_does_not_open_or_mutate_frame(self):
        result = self.client.use({'text_only': True})
        value = result['structuredContent']['result']
        self.assertEqual(value['text'], 'Button Continue')
        self.assertTrue(value['read_only'])
        self.assertFalse(value['pixels_captured'])
        self.assertFalse(self.backend.active)
        self.assertFalse(any(n == 'open_computer' for n, a in self.backend.calls))
        self.assertFalse(any(p['type'] == 'image' for p in result['content']))
        self.client.use({})
        frame = self.client.states['p']['observation_id']
        self.client.use({'text_only': True})
        self.assertEqual(self.client.states['p']['observation_id'], frame)

    def test_native_default_and_explicit_resolution_reset(self):
        self.client.use({})
        self.assertNotIn('max_dimension', self.backend.calls[-1][1])
        self.client.use({'max_dimension': 3840})
        self.assertEqual(self.backend.calls[-1][1]['max_dimension'], 3840)
        self.client.use({'action': 'move', 'x': 10, 'y': 10})
        self.assertEqual(self.backend.calls[-1][1]['max_dimension'], 3840)
        self.client.use({'max_dimension': 0})
        self.assertEqual(self.backend.calls[-1][1]['max_dimension'], 0)

    def test_region_converts_without_guessing_and_public_transform(self):
        result = self.client.use({})
        self.assertEqual(result['structuredContent']['result']['coordinate_transform']['desktop_units_per_screenshot_pixel']['x'], 2.56)
        self.client.use({'region': {'x': 25, 'y': 20, 'width': 50, 'height': 40}})
        native = self.backend.calls[-1][1]
        self.assertEqual(native['capture_region'], {'x': .25, 'y': .2, 'width': .5, 'height': .4})
        self.client.use({'action': 'click', 'x': 10, 'y': 10})
        self.assertEqual(self.backend.calls[-1][1]['capture_region'], native['capture_region'])
        with self.assertRaises(ValueError):
            self.client.use({'region': {'x': 0, 'y': 0, 'width': 101, 'height': 10}})
        self.client.use({})
        self.assertNotIn('capture_region', self.backend.calls[-1][1])

    def test_bound_window_move_and_closed_window_never_use_old_coordinates(self):
        self.client.use({'application': 'QA'})
        self.backend.window['left'] = 200
        response = self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertTrue(response['structuredContent']['result']['needs_review'])
        self.assertFalse(self.backend.actions)
        self.backend.window['window_id'] = None
        response = self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertEqual(response['structuredContent']['result']['status'], 'application_window_unavailable')
        self.assertFalse(self.backend.actions)

    def test_independent_mode_is_native_bound_without_focus_and_mode_switch_releases_own(self):
        response = self.client.use({'application': 'QA', 'control_mode': 'independent'})
        self.assertEqual(response['structuredContent']['result']['control_mode'], 'independent')
        self.client.use({'action': 'click', 'target': 'Continue'})
        action = self.backend.actions[-1]
        self.assertEqual(action['type'], 'click')
        self.assertFalse(any(a['type'] == 'focus_application' for a in self.backend.actions))
        self.assertEqual(self.backend.calls[-1][1]['expected_window_id'], 'win:qa')
        response = self.client.use({'control_mode': 'user_mouse'})
        self.assertEqual(response['structuredContent']['result']['control_mode'], 'user_mouse')
        self.assertNotIn('application', response['structuredContent']['result'])
        self.assertNotIn('bound_window', self.client.states['p'])
        self.assertTrue(any(n == 'release_input' for n, a in self.backend.calls))

    def test_explicit_user_mouse_clears_old_binding_after_focus_failure(self):
        self.client.use({'application': 'QA', 'control_mode': 'user_mouse'})
        self.backend.window = {'window_id': 'win:edge', 'process_name': 'Edge', 'left': 0, 'top': 0, 'right': 100, 'bottom': 100}
        self.backend.action_error = 'application_focus_denied'
        failed = self.client.use({'action': 'observe'})
        self.assertEqual(failed['structuredContent']['result']['error'], 'application_focus_denied')
        start = len(self.backend.calls)
        observed = self.client.use({'action': 'observe', 'computer': 'local', 'control_mode': 'user_mouse'})
        self.assertFalse(observed['isError'])
        self.assertNotIn('application', observed['structuredContent']['result'])
        self.assertEqual(observed['structuredContent']['result']['window']['window_id'], 'win:edge')
        self.assertFalse(any(n == 'computer_action' for n, a in self.backend.calls[start:]))
        opened = next(a for n, a in self.backend.calls[start:] if n == 'open_computer')
        self.assertNotIn('application', opened)
        self.assertNotIn('bound_window', self.client.states['p'])
        self.client.use({'action': 'click', 'control_mode': 'user_mouse', 'x': 20, 'y': 30})
        native = self.backend.calls[-1][1]
        self.assertNotIn('expected_window_id', native)
        self.assertNotIn('require_same_window', native)
        self.assertEqual(self.backend.actions, [{'type': 'click', 'x': 20, 'y': 30}])
        # The same desktop mode continues without repeatedly replacing its lease.
        self.assertEqual(sum(n == 'open_computer' for n, a in self.backend.calls[start:]), 1)

    def test_empty_application_unbinds_without_disabling_explicit_binding(self):
        self.client.use({'application': 'QA', 'control_mode': 'user_mouse'})
        self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertEqual(self.backend.calls[-1][1]['expected_window_id'], 'win:qa')
        result = self.client.use({'action': 'observe', 'application': ''})
        self.assertNotIn('application', result['structuredContent']['result'])
        self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertNotIn('expected_window_id', self.backend.calls[-1][1])
        self.client.use({'application': 'QA', 'control_mode': 'independent'})
        with self.assertRaisesRegex(ValueError, 'application_unbind_requires_user_mouse'):
            self.client.use({'application': ''})
        self.assertEqual(self.client.states['p']['application'], 'QA')

    def test_wire_result_discriminator_for_facade_success_and_error(self):
        for arguments in ({"action":"status"},{"computer":"missing"}):
            reply=self.client.dispatch({"jsonrpc":"2.0","id":"wire","method":"tools/call","params":{"name":"computer_use","arguments":arguments}})
            self.assertEqual(reply["result"]["resultType"],"complete")

    def test_simple_state_and_image_separation(self):
        first = self.client.use({'computer': 'windows'})
        self.assertEqual(first['content'][0]['type'], 'image')
        second = self.client.use({'action': 'click', 'x': 20, 'y': 30})
        native = next(args for name, args in self.backend.calls if name == 'computer_action')
        self.assertEqual(native['control_session_id'], 'private-token')
        self.assertEqual(native['observation_id'], '1')
        public = json.dumps(second['structuredContent'])
        self.assertNotIn('private-token', public)
        self.assertNotIn('observation_id', public)
        self.assertNotIn('image-bytes', public)
        self.assertEqual(second['structuredContent']['result']['status'], 'completed')

    def test_idle_release_and_fresh_frame_before_reconnect_click(self):
        self.client.use({})
        self.now = 31
        self.client.expire_idle()
        self.assertFalse(self.backend.active)
        response = self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertTrue(response['structuredContent']['result']['needs_review'])
        self.assertFalse(self.backend.actions)
        self.client.close()
        self.assertFalse(self.backend.active)

    def test_stale_recovery_never_replays_input(self):
        self.client.use({})
        self.backend.action_error = 'observation_id_mismatch'
        response = self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertTrue(response['structuredContent']['result']['needs_review'])
        self.assertFalse(self.backend.actions)
        self.assertNotIn('expected_observation_id', json.dumps(response['structuredContent']))
        self.client.use({'action': 'click', 'x': 25, 'y': 35})
        self.assertEqual(len(self.backend.actions), 1)

    def test_exit_and_uncertain_input_do_not_reopen_or_retry(self):
        self.client.use({})
        self.backend.action_error = 'remote_timeout_execution_unknown'
        result = self.client.use({'action': 'click', 'x': 1, 'y': 2})
        self.assertTrue(result['structuredContent']['result']['input_result_uncertain'])
        self.assertEqual(sum(name == 'computer_action' for name, _ in self.backend.calls), 1)
        self.backend.action_error = 'user_exit'
        self.client.use({'action': 'click', 'x': 1, 'y': 2})
        count = len(self.backend.calls)
        result = self.client.use({'action': 'observe'})
        self.assertTrue(result['structuredContent']['result']['requires_user_authorization'])
        # Discovery can read device state; no new open or input is sent.
        self.assertFalse(any(name in ('open_computer', 'computer_action') for name, _ in self.backend.calls[count:]))

    def test_target_name_resolves_from_a_fresh_observation(self):
        result = self.client.use({'computer': 'windows', 'action': 'click', 'target': 'Continue'})
        self.assertEqual(self.backend.actions, [{'type': 'click', 'x': 25, 'y': 30}])
        self.assertEqual(result['structuredContent']['result']['status'], 'completed')

    def test_catalog_and_window_binding(self):
        listed = self.client.dispatch({'id': 1, 'method': 'tools/list', 'params': {}})
        self.assertEqual([t['name'] for t in listed['result']['tools']], ['computer_use', 'browser_use', 'list_computers', 'send_files'])
        self.client.use({'application': 'QA'})
        self.backend.window = {'window_id': 'win:other', 'left': 0, 'top': 0, 'right': 100, 'bottom': 100}
        result = self.client.use({'action': 'click', 'x': 20, 'y': 30})
        self.assertTrue(result['structuredContent']['result']['needs_review'])
        self.assertTrue(any(a.get('type') == 'focus_application' for a in self.backend.actions))
        self.assertFalse(any(a.get('type') == 'click' for a in self.backend.actions))


if __name__ == '__main__':
    unittest.main()
