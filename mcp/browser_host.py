#!/usr/bin/env python3
"""Edge Native Messaging pipe. Only the installed extension can launch this host.

No listening socket and no page-to-host bridge. Commands come from the existing
authenticated ShareMouse MCP endpoint; the MCP credential never enters Edge.
"""
import json
import os
from pathlib import Path
import queue
import struct
import sys
import threading
import time
import uuid
from urllib.request import Request, build_opener, ProxyHandler

ORIGIN = 'chrome-extension://cdocbfpfceafibeokdomcpmeinlinikf/'
MAX_FRAME = 1024 * 1024


def read_message(stream):
    header = stream.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise ValueError('truncated_native_header')
    size = struct.unpack('<I', header)[0]
    if not 0 < size <= MAX_FRAME:
        raise ValueError('native_frame_too_large')
    body = bytearray()
    while len(body) < size:
        part = stream.read(size - len(body))
        if not part:
            raise ValueError('truncated_native_frame')
        body.extend(part)
    value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError('invalid_native_message')
    return value


def write_message(stream, message):
    body = json.dumps(message, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    if not 0 < len(body) <= MAX_FRAME:
        raise ValueError('native_frame_too_large')
    stream.write(struct.pack('<I', len(body)) + body)
    stream.flush()


def main():
    if len(sys.argv) < 2 or sys.argv[1] != ORIGIN:
        return 1
    if sys.platform == 'win32':
        import msvcrt
        msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
        msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
    directory = Path(os.environ['LOCALAPPDATA']) / 'ShareMouse' if sys.platform == 'win32' else Path.home() / 'Library/Application Support/ShareMouse'
    instance = str(uuid.uuid4())
    responses = queue.Queue(maxsize=8)
    stopped = threading.Event()
    opener = build_opener(ProxyHandler({}))

    def receive():
        try:
            while not stopped.is_set():
                value = read_message(sys.stdin.buffer)
                if value is None:
                    break
                responses.put_nowait(value)
        except (OSError, ValueError, queue.Full):
            pass
        finally:
            stopped.set()

    threading.Thread(target=receive, daemon=True).start()
    response, inflight = None, None
    while not stopped.is_set():
        try:
            while True:
                try:
                    candidate = responses.get_nowait()
                except queue.Empty:
                    break
                if inflight and candidate.get('id') == inflight['id']:
                    response, inflight = candidate, None
            if inflight and inflight['deadline_ms'] <= time.time() * 1000:
                response = {'id': inflight['id'], 'error': 'browser_timeout_execution_unknown'}
                inflight = None
            if response is not None and len(json.dumps(response, ensure_ascii=False, separators=(',', ':')).encode('utf-8')) > 230000:
                response = {'id': response['id'], 'error': 'browser_response_too_large'}
            params = {'instance_id': instance}
            if response is not None:
                params['response'] = response
            token = (directory / 'mcp-token').read_text(encoding='utf-8').strip()
            request = Request('http://127.0.0.1:49170/mcp',
                data=json.dumps({'jsonrpc': '2.0', 'id': str(uuid.uuid4()), 'method': 'browser/exchange', 'params': params}, ensure_ascii=False, separators=(',', ':')).encode('utf-8'),
                headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
            with opener.open(request, timeout=3) as reply:
                result = json.loads(reply.read(MAX_FRAME))
            if result.get('error'):
                if response is not None and result['error'].get('message') in ('browser_response_too_large', 'invalid_browser_response'):
                    response = {'id': response['id'], 'error': 'browser_response_rejected'}
                stopped.wait(1)
                continue
            response = None
            command = result.get('result', {}).get('command')
            if command:
                if command.get('deadline_ms', 0) <= time.time() * 1000:
                    response = {'id': command['id'], 'error': 'browser_command_expired'}
                elif inflight:
                    response = {'id': command['id'], 'error': 'browser_host_busy'}
                else:
                    inflight = command
                    write_message(sys.stdout.buffer, command)
            # Poll while awaiting a reply too: keep the instance heartbeat alive.
            stopped.wait(0.25)
        except (OSError, ValueError, KeyError):
            # Retaining a response is safe: broker correlates UUIDs, never reinjects.
            stopped.wait(1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
