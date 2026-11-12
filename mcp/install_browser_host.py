#!/usr/bin/env python3
"""Install the Edge Native Messaging host for the current user (no admin/policy edits).

After running, load the printed extension directory at edge://extensions using
Developer mode / Load unpacked. Re-running updates only ShareMouse's own files.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import unicodedata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preferred-shortcut-name', help='User-selected desktop launcher name to report when Edge is unavailable; never executed automatically.')
    options = parser.parse_args()
    preferred = options.preferred_shortcut_name
    if preferred is not None:
        preferred = preferred.strip()
        if not 1 <= len(preferred) <= 256 or any(unicodedata.category(c).startswith('C') or c in '\r\n\u2028\u2029' for c in preferred):
            parser.error('preferred shortcut name must have 1–256 visible characters')
    source = Path(__file__).resolve().parent
    windows = sys.platform == 'win32'
    support = Path(os.environ['LOCALAPPDATA']) / 'ShareMouse' if windows else Path.home() / 'Library/Application Support/ShareMouse'
    root = support / 'browser'
    extension = root / 'edge-extension'
    root.mkdir(parents=True, exist_ok=True)
    if preferred is not None:
        startup = root / 'startup.json'
        startup.write_text(json.dumps({'preferred_shortcut_name': preferred}, ensure_ascii=False) + '\n', encoding='utf-8')
        if not windows:
            startup.chmod(0o600)
    shutil.copytree(source / 'edge-extension', extension, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('tests', 'node_modules', '*.test.*'))
    shutil.copy2(source / 'browser_host.py', root / 'browser_host.py')
    launcher = root / ('browser-host.cmd' if windows else 'browser-host')
    if windows:
        launcher.write_text('@echo off\r\n"' + sys.executable + '" -u "' + str(root / 'browser_host.py') + '" %*\r\n', encoding='utf-8')
        manifest = root / 'com.sharemouse.browser.json'
    else:
        launcher.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -u ' + shlex.quote(str(root / 'browser_host.py')) + ' "$@"\n')
        launcher.chmod(0o700)
        manifest = Path.home() / 'Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.sharemouse.browser.json'
        manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({'name': 'com.sharemouse.browser', 'description': 'ShareMouse browser controls',
        'path': str(launcher), 'type': 'stdio', 'allowed_origins': ['chrome-extension://cdocbfpfceafibeokdomcpmeinlinikf/']}, indent=2), encoding='utf-8')
    if windows:
        import winreg
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Edge\NativeMessagingHosts\com.sharemouse.browser') as key:
            winreg.SetValueEx(key, '', 0, winreg.REG_SZ, str(manifest))
    print(json.dumps({'extension_directory': str(extension), 'host_manifest': str(manifest),
                      'extension_id': 'cdocbfpfceafibeokdomcpmeinlinikf'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
