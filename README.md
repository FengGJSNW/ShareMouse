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

Version: v0.1.0-alpha.2.

This is an early alpha preview (internal build 26; MCP protocol 1.3.1). Hardware compatibility and some user workflows still need broader validation.

Alpha.2 adds Windows-to-Mac function-row positions with held-key recovery and user override precedence, per-device remote pointer/scroll settings, and Windows native presentation/toasts aligned with macOS. It also organizes the source and removes avoidable keyboard-repeat and theme-update work. See [contributor guidance](CONTRIBUTING.md) for build and formatting commands.

## macOS: sign and install for local testing

The macOS DMG is not notarized. These steps let you sign a local copy with your own Apple Development identity for local testing. This is not Developer ID signing or Apple notarization. The script does not ask for your Apple Account password, remove Gatekeeper quarantine, or grant macOS privacy permissions.

1. **Download and install Xcode.** Get Xcode from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835?mt=12), or choose a compatible version from [Apple Developer Downloads](https://developer.apple.com/download/). Open Xcode once after installation, accept the license, and install any components it requests.
2. **Create your signing identity.** In Xcode, open **Settings > Accounts**, click **+**, and sign in with your Apple Account. Select an available Team, choose **Manage Certificates**, click **+**, and create an **Apple Development** certificate. Complete any two-factor authentication prompts. Keep the certificate's private key in your own Mac keychain; do not send anyone a .p12 export containing the private key.
3. **Download the release files.** From the [v0.1.0-alpha.2 release](https://github.com/FengGJSNW/ShareMouse/releases/tag/v0.1.0-alpha.2), download both ShareMouse-v0.1.0-alpha.2-macos-universal.dmg and sign-install-macos.zsh. Save them in your Downloads folder and compare the DMG's SHA-256 with the value shown on the release page.
4. **Run the signing installer.** Open Terminal from **Applications > Utilities**, then run:
   ~~~sh
   zsh "$HOME/Downloads/sign-install-macos.zsh" "$HOME/Downloads/ShareMouse-v0.1.0-alpha.2-macos-universal.dmg"
   ~~~
   If macOS asks whether codesign may access your signing key, allow access. The script verifies the app's bundle identifier and signature, installs it to ~/Applications/ShareMouse.app, and tries to launch it. It does not need sudo. If it reports that no valid Apple Development identity was found, return to step 2.
5. **Review any first-launch warning.** Because this app is not notarized, macOS may show a security warning. Only if you verified the release source and accept the alpha risks, open **System Settings > Privacy & Security** and review the app-specific option to **Open Anyway**. Do not disable Gatekeeper globally. If macOS does not offer that option, stop and consult the [signing guide](https://github.com/FengGJSNW/ShareMouse/releases/download/v0.1.0-alpha.2/ShareMouse-macOS-signing-guide.md).
6. **Grant the permissions you need.** In **System Settings > Privacy & Security > Accessibility** and **Input Monitoring**, add and enable ~/Applications/ShareMouse.app, then quit and reopen ShareMouse. Grant Bluetooth access if macOS asks when you use Bluetooth features. Signing does not grant these permissions, and a newly signed copy may need fresh approvals.

You need a valid Apple Development identity for this workflow. The signing script itself uses macOS command-line tools, but creating the identity with the steps above uses Xcode. See Apple's [code-signing instructions](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) and [notarization requirements](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

## Build macOS DMG

Requires macOS 14 or newer and Xcode.

zsh scripts/release-macos.zsh v0.1.0-alpha.2 26

The DMG is written to artifacts/releases/v0.1.0-alpha.2/.

## Build Windows x64 installer

Requires Windows 11 x64, the .NET 10 SDK, and Inno Setup 7 x64.

powershell -NoProfile -File .\scripts\release-windows.ps1 -ReleaseVersion v0.1.0-alpha.2 -BuildNumber 26 -ISCC <path-to-ISCC.exe>

The installer is written to artifacts/releases/v0.1.0-alpha.2/.

## Runtime

Windows requires administrator approval for the input integration. The MCP stdio bridge requires Python 3. Pairing and remote control require explicit approval on the receiving computer.
