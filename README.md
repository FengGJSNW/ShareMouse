# ShareMouse

ShareMouse lets one keyboard and mouse work across macOS and Windows computers.

## Included

- Native desktop applications for macOS and Windows.
- Keyboard and mouse sharing, clipboard history, and file transfer.
- Local network and optional Bluetooth connections.
- An optional MCP interface for authorized computer use.

## Development and risk notice

This is vibe-coded software: parts of the project were developed with AI-assisted coding, with assistance from OpenAI Codex. It is an early alpha and may contain defects, security issues, or behavior that has not been fully validated. Release installers are unsigned, and the macOS DMG is not notarized. Review the source and assess the risks before using it, especially in environments where input control, clipboard contents, or file transfer matter.

## Current package

Version: v0.1.0-alpha.1.

This is an early alpha preview. Hardware compatibility and some user workflows still need broader validation.

## Build macOS DMG

Requires macOS 14 or newer and Xcode.

zsh scripts/release-macos.zsh v0.1.0-alpha.1 1

The DMG is written to artifacts/releases/v0.1.0-alpha.1/.

## Build Windows x64 installer

Requires Windows 11 x64, the .NET 10 SDK, and Inno Setup 7 x64.

powershell -NoProfile -File .\scripts\release-windows.ps1 -ReleaseVersion v0.1.0-alpha.1 -BuildNumber 1 -ISCC <path-to-ISCC.exe>

The installer is written to artifacts/releases/v0.1.0-alpha.1/.

## Runtime

Windows requires administrator approval for the input integration. The MCP stdio bridge requires Python 3. Pairing and remote control require explicit approval on the receiving computer.
