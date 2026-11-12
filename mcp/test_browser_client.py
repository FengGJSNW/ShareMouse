import io
import json
import struct
import unittest
from computer_client import ComputerClient
from test_computer_client import Backend


class BrowserBackend(Backend):
    def __call__(self, request):
        if request.get('params', {}).get('name') == 'release_input' and self.action_error == 'user_exit':
            self.calls.append(('release_input', request['params']['arguments']))
            return self.reply({'error': 'user_exit', 'error_details': {'code': 'user_exit'}}, True)
        if request.get('params', {}).get('name') == 'browser_command':
            args = request['params']['arguments']
            self.calls.append(('browser_command', args.copy()))
            if self.action_error:
                if isinstance(self.action_error, dict):
                    return self.reply({'error': self.action_error['code'], 'error_details': self.action_error.copy()}, True)
                return self.reply({'error': self.action_error, 'error_details': {'code': self.action_error}}, True)
            browser = {'tabs': [{'tab_id': 7, 'title': 'QA'}]} if args['command']['action'] == 'tabs' else {'tab_id': args['command']['tab_id'], 'controls': []}
            return self.reply({'browser': browser})
        return super().__call__(request)


class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.backend = BrowserBackend()
        self.client = ComputerClient(self.backend, start_timer=False)

    def test_browser_tabs_and_explicit_binding_do_not_inject(self):
        result = self.client.browser_use({'action': 'tabs'})
        self.assertEqual(result['structuredContent']['result']['tabs'][0]['tab_id'], 7)
        self.client.browser_use({'action': 'observe', 'tab_id': 7})
        self.client.browser_use({'action': 'fill', 'element_id': 'node:1', 'text': ''})
        command = self.backend.calls[-1][1]['command']
        self.assertEqual(command, {'action': 'fill', 'tab_id': 7, 'element_id': 'node:1', 'text': ''})
        self.assertFalse(self.backend.actions)
        opened = next(a for n, a in self.backend.calls if n == 'open_computer')
        self.assertTrue(opened['text_only'])
        self.assertFalse(opened['include_controls'])
        self.assertNotIn('private-token', json.dumps(result))

    def test_requires_tab_and_does_not_retry_unknown_or_human_exit(self):
        with self.assertRaises(ValueError):
            self.client.browser_use({'action': 'observe'})
        self.client.browser_use({'action': 'observe', 'tab_id': 7})
        self.backend.action_error = 'remote_timeout_execution_unknown'
        result = self.client.browser_use({'action': 'click', 'element_id': 'node:1'})
        self.assertTrue(result['isError'])
        self.assertTrue(result['structuredContent']['result']['input_result_uncertain'])
        self.backend.action_error = 'user_exit'
        self.client.browser_use({'action': 'observe'})
        count = len(self.backend.calls)
        stopped = self.client.browser_use({'action': 'observe'})
        self.assertEqual(stopped['structuredContent']['result']['status'], 'stopped')
        self.assertEqual(len(self.backend.calls), count)

    def test_native_frames_bound_and_detect_truncation(self):
        from browser_host import read_message, write_message
        stream = io.BytesIO()
        write_message(stream, {'text': '中文'})
        stream.seek(0)
        self.assertEqual(read_message(stream), {'text': '中文'})
        self.assertIsNone(read_message(stream))
        with self.assertRaises(ValueError):
            read_message(io.BytesIO(struct.pack('<I', 1024 * 1024 + 1)))
        with self.assertRaises(ValueError):
            read_message(io.BytesIO(struct.pack('<I', 10) + b'{}'))

    def test_switching_to_browser_does_not_reacquire_after_human_exit(self):
        self.client.use({'action': 'observe'})
        self.backend.action_error = 'user_exit'
        before = len(self.backend.calls)
        result = self.client.browser_use({'action': 'tabs'})
        self.assertEqual(result['structuredContent']['result']['status'], 'stopped')
        self.assertFalse(any(n in ('open_computer', 'browser_command') for n, _ in self.backend.calls[before:]))

    def test_read_timeout_has_one_explicit_retry_and_keeps_failed_binding(self):
        # Compatible with old peers too: an observation cannot have injected input.
        self.backend.action_error = 'browser_timeout_execution_unknown'
        first = self.client.browser_use({'action': 'observe', 'tab_id': 7, 'max_nodes': 20})['structuredContent']['result']
        self.assertEqual(first['error'], 'browser_read_timeout')
        self.assertFalse(first['input_result_uncertain'])
        self.assertEqual(first['error_details']['input_outcome'], 'not_attempted')
        self.assertEqual(first['error_details']['max_retries'], 1)
        self.assertEqual(first['recovery']['next_call']['arguments']['tab_id'], 7)
        self.assertEqual(first['recovery']['next_call']['arguments']['max_nodes'], 20)
        self.assertEqual(sum(n == 'browser_command' for n, _ in self.backend.calls), 1)
        second = self.client.browser_use({'action': 'observe'})['structuredContent']['result']
        self.assertEqual(second['tab_id'], 7)
        self.assertFalse(second['error_details']['retryable'])
        self.assertEqual(second['error_details']['max_retries'], 0)
        self.assertNotIn('next_call', second['recovery'])
        self.assertEqual(sum(n == 'browser_command' for n, _ in self.backend.calls), 2)
        self.assertFalse(self.backend.actions)

    def test_extension_unavailable_suggests_inspection_without_desktop_input(self):
        self.backend.action_error = 'browser_extension_unavailable'
        value = self.client.browser_use({'action': 'tabs'})['structuredContent']['result']
        next_call = value['recovery']['next_call']
        self.assertEqual(next_call['tool'], 'computer_use')
        self.assertEqual(next_call['arguments']['action'], 'windows')
        self.assertFalse(self.backend.actions)
        self.assertEqual(sum(n == 'browser_command' for n, _ in self.backend.calls), 1)

    def test_exhausted_tabs_read_does_not_suggest_a_third_tabs_call(self):
        self.backend.action_error = 'browser_read_timeout'
        self.client.browser_use({'action': 'tabs'})
        value = self.client.browser_use({'action': 'tabs'})['structuredContent']['result']
        self.assertFalse(value['error_details']['retryable'])
        self.assertNotIn('next_call', value['recovery'])
        self.assertNotIn('Inspect tabs', value['recovery']['message'])
        self.assertEqual(sum(n == 'browser_command' for n, _ in self.backend.calls), 2)

    def test_only_boolean_authorization_can_clear_user_stop(self):
        self.client.browser_use({'action': 'tabs'})
        self.client.states['p']['stopped'] = True
        controlled_calls = lambda: sum(n in ('open_computer', 'computer_action', 'browser_command') for n, _ in self.backend.calls)
        before = controlled_calls()
        for entry, action in [(self.client.use, 'observe'), (self.client.browser_use, 'tabs')]:
            for malformed in ['false', 'true', 1]:
                with self.subTest(entry=entry.__name__, value=malformed):
                    result = entry({'action': action, 'resume_authorized': malformed})
                    self.assertEqual(result['structuredContent']['result']['status'], 'stopped')
                    self.assertEqual(controlled_calls(), before)

    def test_frozen_tab_does_not_claim_input_or_automatically_navigate(self):
        self.backend.action_error = {'code': 'browser_tab_frozen: tab 7 is suspended; DOM execution unavailable', 'input_outcome': 'not_attempted', 'retryable': False}
        value = self.client.browser_use({'action': 'click', 'tab_id': 7, 'role': 'link', 'name': 'Topics'})['structuredContent']['result']
        self.assertFalse(value['input_result_uncertain'])
        self.assertTrue(value['recovery']['page_replacement_requires_task_authorization'])
        self.assertFalse(self.backend.actions)
        self.assertEqual(sum(n == 'browser_command' for n, _ in self.backend.calls), 1)

    def test_startup_error_preserves_configured_launcher_name(self):
        self.backend.action_error = {'code': 'browser_extension_unavailable', 'startup': {'preferred_shortcut_name': 'Edge proxy launcher'}}
        value = self.client.browser_use({'action': 'tabs'})['structuredContent']['result']
        self.assertEqual(value['recovery']['preferred_shortcut_name'], 'Edge proxy launcher')
        self.assertIn('Edge proxy launcher', value['recovery']['message'])

    def test_ambiguity_recovery_observes_before_selecting_a_new_reference(self):
        self.backend.action_error = {'code': 'ambiguous_element', 'input_outcome': 'not_attempted'}
        value = self.client.browser_use({'action': 'click', 'tab_id': 7, 'role': 'link', 'name': 'npm'})['structuredContent']['result']
        self.assertFalse(value['input_result_uncertain'])
        self.assertEqual(value['recovery']['next_call']['arguments'], {'computer': 'Windows QA', 'action': 'observe', 'tab_id': 7})
        self.assertFalse(self.backend.actions)

    def test_loading_read_retries_once_without_suggesting_another_navigation(self):
        self.backend.action_error = {'code': 'browser_page_loading', 'read_only': True, 'input_outcome': 'not_attempted'}
        value = self.client.browser_use({'action': 'observe', 'tab_id': 7, 'max_nodes': 20})['structuredContent']['result']
        self.assertFalse(value['input_result_uncertain'])
        self.assertEqual(value['recovery']['next_call']['arguments']['action'], 'observe')
        self.assertEqual(value['recovery']['next_call']['arguments']['max_nodes'], 20)
        self.assertGreater(value['error_details']['retry_after_ms'], 0)
        second = self.client.browser_use({'action': 'observe'})['structuredContent']['result']
        self.assertNotIn('next_call', second['recovery'])

    def test_post_dispatch_failure_keeps_unknown_and_has_no_replay_hint(self):
        self.backend.action_error = {'code': 'fill_not_applied', 'input_outcome': 'unknown'}
        value = self.client.browser_use({'action': 'fill', 'tab_id': 7, 'element_id': 'node:1', 'text': 'value'})['structuredContent']['result']
        self.assertTrue(value['input_result_uncertain'])
        self.assertNotIn('recovery', value)


if __name__ == '__main__':
    unittest.main()
