#!/usr/bin/env python3
"""ShareMouse MCP stdio bridge with a small, stateful computer-use facade."""
import argparse
import base64
import json
import os
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
from computer_client import ComputerClient


def main():
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--token-file', type=Path)
    parser.add_argument('--advanced-tools', action='store_true', help='Also expose the original token-based tools.')
    options = parser.parse_args()
    directory = Path(os.environ.get('LOCALAPPDATA', '')) / 'ShareMouse' if sys.platform == 'win32' else Path.home() / 'Library/Application Support/ShareMouse'
    token_file = options.token_file or directory / 'mcp-token'
    client = build_opener(ProxyHandler({}))

    def rpc(request):
        token = token_file.read_text(encoding='utf-8').strip()
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'Authorization': 'Bearer ' + token}
        version = request.get('params', {}).get('_meta', {}).get('io.modelcontextprotocol/protocolVersion')
        if version:
            headers['MCP-Protocol-Version'] = version
            headers['Mcp-Method'] = request['method']
            if request['method'] == 'tools/call':
                name = request['params']['name']
                headers['Mcp-Name'] = name if name.isascii() and name.strip() == name else '=?base64?' + base64.b64encode(name.encode()).decode() + '?='
        call = Request('http://127.0.0.1:49170/mcp', data=json.dumps(request, ensure_ascii=False).encode('utf-8'), headers=headers)
        timeout = 6 if request.get('params', {}).get('name') == 'release_input' else 75
        try:
            with client.open(call, timeout=timeout) as response:
                payload = response.read(24 * 1024 * 1024)
                return json.loads(payload) if payload else {}
        except HTTPError as error:
            payload = error.read(1024 * 1024)
            try:
                reply = json.loads(payload)
                if 'error' in reply:
                    return reply
            except (ValueError, TypeError):
                pass
            raise OSError('ShareMouse rejected the MCP request; check app permissions and token path') from None

    facade = ComputerClient(rpc)
    try:
        for line in sys.stdin:
            request = None
            try:
                request = json.loads(line)
                response = facade.dispatch(request, options.advanced_tools)
                if response:
                    print(json.dumps(response, ensure_ascii=False), flush=True)
            except (OSError, ValueError, TypeError, KeyError) as error:
                if isinstance(request, dict) and 'id' in request:
                    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32603, 'message': str(error)}}, ensure_ascii=False), flush=True)
    finally:
        facade.close()


if __name__ == '__main__':
    main()
