#!/usr/bin/env python3
"""Apply the Solos HUD iOS companion patch to a local checkout.

Usage:
    python apply_ios_patch.py /path/to/solos-hud

It accepts either the repository root or the inner solos_hud Flutter folder.
Every modified original is backed up as .ios-original.bak once.
"""
from pathlib import Path
import argparse
import shutil
import sys


def update_once(path: Path, old: str, new: str) -> None:
    data = path.read_text(encoding='utf-8')
    if new in data:
        print('Already updated:', path)
        return
    if old not in data:
        raise RuntimeError(f'Expected source pattern was not found in {path}: {old[:90]!r}')
    backup = path.with_name(path.name + '.ios-original.bak')
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(data.replace(old, new, 1), encoding='utf-8')
    print('Updated:', path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repo', nargs='?', default='.', help='path to cloned Solos HUD repository')
    args = parser.parse_args()
    directory = Path(args.repo).expanduser().resolve()
    flutter = directory / 'solos_hud' if (directory / 'solos_hud' / 'ios').is_dir() else directory
    if not (flutter / 'ios' / 'Runner' / 'AppDelegate.swift').exists():
        raise SystemExit('Could not find solos_hud/ios/Runner/AppDelegate.swift. Clone the repository first.')

    here = Path(__file__).resolve().parent
    replacement_app_delegate = here / 'solos_hud' / 'ios' / 'Runner' / 'AppDelegate.swift'
    replacement_preview = here / 'solos_hud' / 'lib' / 'screens' / 'ios_preview_home.dart'
    if not replacement_app_delegate.is_file() or not replacement_preview.is_file():
        raise SystemExit('Patch bundle incomplete: keep this script next to the solos_hud folder in the ZIP.')

    for relative in ('ios/Runner/AppDelegate.swift', 'lib/screens/ios_preview_home.dart'):
        destination = flutter / relative
        replacement = here / 'solos_hud' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_file() and destination.read_bytes() == replacement.read_bytes():
            print('Already installed:', relative)
            continue
        if destination.exists():
            backup = destination.with_name(destination.name + '.ios-original.bak')
            if not backup.exists():
                shutil.copy2(destination, backup)
        shutil.copyfile(replacement, destination)
        print('Installed:', relative)

    home = flutter / 'lib' / 'screens' / 'home_screen.dart'
    update_once(home,
        "import 'package:flutter/material.dart';",
        "import 'dart:io' show Platform;\nimport 'package:flutter/material.dart';")
    update_once(home,
        "import 'scan_sheet.dart';",
        "import 'scan_sheet.dart';\nimport 'ios_preview_home.dart';")
    update_once(home,
        "    final isConnecting = rfcomm.state == RfcommState.connecting;\n\n    if (!isConnected && !isConnecting) {",
        "    final isConnecting = rfcomm.state == RfcommState.connecting;\n\n"
        "    // iOS can only send HUD data through an authorized accessory data stream.\n"
        "    // Show the accessory connection screen while no session is open.\n"
        "    if (Platform.isIOS && !isConnected) {\n"
        "      return IOSPreviewHome(apps: apps);\n"
        "    }\n\n"
        "    if (!isConnected && !isConnecting) {")

    app = flutter / 'lib' / 'app.dart'
    update_once(app,
        "import 'dart:async';",
        "import 'dart:async';\nimport 'dart:io' show Platform;")
    update_once(app,
        "      if (_settings.autoConnect) {\n        _rfcomm.autoConnectSolos(lastAddress: _settings.lastDeviceAddress);",
        "      if (_settings.autoConnect && !Platform.isIOS) {\n"
        "        _rfcomm.autoConnectSolos(lastAddress: _settings.lastDeviceAddress);")
    update_once(app,
        "  void _onDisconnected() {\n    _hud.stopLoop();",
        "  void _onDisconnected() {\n    _hud.stopLoop();\n"
        "    // iOS reconnects through an explicitly authorized accessory session.\n"
        "    if (Platform.isIOS) return;")

    settings = flutter / 'lib' / 'screens' / 'settings_screen.dart'
    update_once(settings,
        "              _ConnectionSection(rfcomm: rfcomm, settings: settings),",
        "              if (Platform.isIOS)\n"
        "                const ListTile(\n"
        "                  title: Text('iPhone display connection'),\n"
        "                  subtitle: Text('The paired glasses must expose an approved '\n"
        "                      'ExternalAccessory data protocol to send HUD frames. '\n"
        "                      'Check connected glasses on the Home screen.'),\n"
        "                )\n"
        "              else\n"
        "                _ConnectionSection(rfcomm: rfcomm, settings: settings),")
    update_once(settings,
        "            children: [\n              SwitchListTile.adaptive(\n                dense: true,\n                contentPadding: const EdgeInsets.symmetric(horizontal: 14),\n                title: const Text('Enable Notifications'),",
        "            children: [\n"
        "              if (Platform.isIOS)\n"
        "                const ListTile(\n"
        "                  title: Text('iOS notification limitations'),\n"
        "                  subtitle: Text('iOS does not let third-party apps read '\n"
        "                      'notifications belonging to other apps.'),\n"
        "                ),\n"
        "              SwitchListTile.adaptive(\n                dense: true,\n                contentPadding: const EdgeInsets.symmetric(horizontal: 14),\n                title: const Text('Enable Notifications'),")

    controller = flutter / 'lib' / 'core' / 'hud_controller.dart'
    update_once(controller,
        '      packet = SolosProtocol.buildImagePacket(imageData: customRle);',
        '      packet = SolosProtocol.buildImagePacket(\n'
        '        imageData: customRle, codec: _activeApp!.preferredCodec);')

    info = flutter / 'ios' / 'Runner' / 'Info.plist'
    data = info.read_text(encoding='utf-8')
    if '<key>NSMicrophoneUsageDescription</key>' not in data:
        update_once(info, '\n</dict>\n</plist>',
            '\n\t<!-- Voice assistant -->\n'
            '\t<key>NSMicrophoneUsageDescription</key>\n'
            '\t<string>Solos HUD uses your microphone for voice commands.</string>\n'
            '\t<key>NSSpeechRecognitionUsageDescription</key>\n'
            '\t<string>Solos HUD uses speech recognition to understand voice commands.</string>\n'
            '</dict>\n</plist>')

    # iOS allows ExternalAccessory only for approved, explicitly declared
    # protocols. Never invent the manufacturer's reverse-DNS identifier.
    # The workflow can fill this array when the real protocol is known.
    data = info.read_text(encoding='utf-8')
    if '<key>UISupportedExternalAccessoryProtocols</key>' not in data:
        update_once(info, '\n</dict>\n</plist>',
            '\n\t<key>UISupportedExternalAccessoryProtocols</key>\n'
            '\t<array/>\n'
            '</dict>\n</plist>')

    podfile = flutter / 'ios' / 'Podfile'
    update_once(podfile, "# platform :ios, '13.0'", "\nplatform :ios, '13.0'")

    workflow = here / '.github' / 'workflows' / 'ios-display-bridge.yml'
    repo_root = flutter.parent if flutter.name == 'solos_hud' else directory
    workflow_dest = repo_root / '.github' / 'workflows' / 'ios-display-bridge.yml'
    if workflow.is_file():
        workflow_dest.parent.mkdir(parents=True, exist_ok=True)
        if not workflow_dest.exists():
            shutil.copyfile(workflow, workflow_dest)
            print('Installed build workflow:', workflow_dest)
        else:
            print('Existing workflow unchanged:', workflow_dest)

    print('\nFinished. Review changes with git diff, then commit to your own fork.')
    print('iOS transmits only over an approved ExternalAccessory data session. Ordinary Bluetooth audio pairing is insufficient.')

if __name__ == '__main__':
    main()