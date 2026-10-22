import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/glasses_app.dart';
import '../core/hud_controller.dart';
import '../core/rfcomm/rfcomm_service.dart';

/// iPhone companion screen when the Solos Classic Bluetooth link is unavailable.
/// Keeps real iOS-supported Flutter features accessible instead of trapping
/// users behind a Connect Glasses button that can never complete.
class IOSPreviewHome extends StatefulWidget {
  final List<GlassesApp> apps;

  const IOSPreviewHome({super.key, required this.apps});

  @override
  State<IOSPreviewHome> createState() => _IOSPreviewHomeState();
}

class _IOSPreviewHomeState extends State<IOSPreviewHome> {
  static const _ble = MethodChannel('solos_ios_ble');
  static const _ea = MethodChannel('solos_ios_accessories');
  String? _selectedId;
  List<Map<String, dynamic>> _devices = [];
  String? _scanError;
  bool _scanning = false;
  List<Map<String, dynamic>> _accessories = [];
  bool _checkingAccessories = false;
  bool _connectingAccessory = false;
  String? _accessoryStatus;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAccessories());
  }

  /// Inspect only accessories that iOS exposes to ExternalAccessory.
  /// This does not list arbitrary Bluetooth Settings paired headphones.
  Future<void> _refreshAccessories() async {
    if (_checkingAccessories) return;
    setState(() {
      _checkingAccessories = true;
      _accessoryStatus = null;
    });
    try {
      final raw = await _ea.invokeMethod<List<dynamic>>('list');
      if (!mounted) return;
      setState(() {
        _accessories = (raw ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _accessoryStatus = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _checkingAccessories = false);
    }
  }

  Future<void> _connectAccessory(int id) async {
    if (_connectingAccessory) return;
    final rfcomm = context.read<RfcommService>();
    setState(() {
      _connectingAccessory = true;
      _accessoryStatus = null;
    });
    try {
      await rfcomm.loadPairedDevices();
      PairedDevice? selected;
      for (final device in rfcomm.pairedDevices) {
        if (device.address == 'ea:$id') {
          selected = device;
          break;
        }
      }
      if (selected == null) {
        if (mounted) setState(() => _accessoryStatus = 'Accessory is no longer connected. Refresh and retry.');
        return;
      }
      await rfcomm.connect(selected);
      if (!mounted) return;
      if (rfcomm.isConnected) {
        final hud = context.read<HudController>();
        hud.setActiveApp(_selectedApp);
        if (!hud.running) hud.startLoop();
      } else {
        setState(() => _accessoryStatus =
            'iOS could not open the accessory data protocol. Check the connection log in Settings.');
      }
    } catch (e) {
      if (mounted) setState(() => _accessoryStatus = e.toString());
    } finally {
      if (mounted) setState(() => _connectingAccessory = false);
    }
  }

  GlassesApp? get _selectedApp {
    if (widget.apps.isEmpty) return null;
    for (final app in widget.apps) {
      if (app.id == _selectedId) return app;
    }
    return widget.apps.first;
  }

  Future<void> _scanBle() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanError = null;
      _devices = [];
    });
    try {
      final result = await _ble.invokeMethod<List<dynamic>>('scan');
      if (!mounted) return;
      setState(() {
        _devices = (result ?? [])
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _scanError = e.message ?? e.code);
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanError = 'Unable to scan: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = context.read<HudController>();
    final selected = _selectedApp;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            Text('SOLOS HUD  ·  iOS', style: TextStyle(
              color: scheme.primary, fontWeight: FontWeight.w800,
              fontSize: 12, letterSpacing: 2,
            )),
            const SizedBox(height: 12),
            const Text('iPhone HUD controller', style: TextStyle(
              fontSize: 27, fontWeight: FontWeight.w800,
            )),
            const SizedBox(height: 8),
            const Text(
              'Your glasses can already be paired in iPhone Settings. '
              'For a live 428×240 HUD, iOS must also expose an accessory data '
              'session. Check below; if it is available, this app sends the '
              'existing Solos HUD image packets directly to it.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 20),
            Text('CONNECTED DISPLAY', style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 11,
              fontWeight: FontWeight.bold, letterSpacing: 1.2,
            )),
            const SizedBox(height: 8),
            const Text(
              'Find a Solos/Kopin accessory exposed through Apple ExternalAccessory. '
              'Normal Bluetooth pairing alone does not grant a display data channel.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _checkingAccessories ? null : _refreshAccessories,
              icon: const Icon(Icons.refresh),
              label: Text(_checkingAccessories
                  ? 'Checking connected accessories…'
                  : 'Check connected glasses'),
            ),
            if (_accessoryStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_accessoryStatus!,
                    style: TextStyle(fontSize: 12, color: scheme.error)),
              ),
            if (!_checkingAccessories && _accessories.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'No iOS-accessible MFi accessory found. The glasses may be paired '
                  'for audio but do not expose a usable HUD connection to other apps.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            for (final entry in _accessories)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${entry['name'] ?? 'Accessory'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('Model: ${entry['model'] ?? '?'} · Maker: ${entry['manufacturer'] ?? '?'}',
                          style: const TextStyle(fontSize: 11)),
                      Text(
                        'Protocols: ${(entry['protocols'] as List?)?.join(', ') ?? '(none)'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      const SizedBox(height: 8),
                      if (entry['isSolos'] == true && entry['supportedByApp'] == true)
                        FilledButton.icon(
                          onPressed: _connectingAccessory ? null
                              : () => _connectAccessory(entry['id'] as int),
                          icon: const Icon(Icons.cast),
                          label: Text(_connectingAccessory
                              ? 'Opening HUD stream…' : 'Display HUD'),
                        )
                      else
                        const Text(
                          'Cannot open HUD: accessory not recognized as Solos or '
                          'its approved protocol is not declared in the app.',
                          style: TextStyle(fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Text('PHONE TOOLS', style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 11, letterSpacing: 1.2,
              fontWeight: FontWeight.bold,
            )),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: widget.apps.map((app) => ChoiceChip(
                avatar: Icon(app.icon, size: 16),
                label: Text(app.name),
                selected: selected?.id == app.id,
                onSelected: (_) {
                  // Select phone widgets without starting the RFCOMM HUD loop.
                  setState(() => _selectedId = app.id);
                  hud.setActiveApp(app);
                },
              )).toList(),
            ),
            const SizedBox(height: 18),
            if (selected != null)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: selected.buildPhoneWidget(context),
                ),
              ),
            const SizedBox(height: 22),
            Text('BLUETOOTH DIAGNOSTICS', style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 11,
              fontWeight: FontWeight.bold, letterSpacing: 1.2,
            )),
            const SizedBox(height: 8),
            const Text(
              'Check whether your glasses advertise a Bluetooth Low Energy '
              '(BLE) signal. Finding them here does not mean the Solos HUD '
              'image protocol can be sent over BLE.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _scanning ? null : _scanBle,
              icon: _scanning
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bluetooth_searching),
              label: Text(_scanning ? 'Scanning nearby BLE devices…' : 'Scan Bluetooth LE'),
            ),
            if (_scanError != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_scanError!, style: TextStyle(color: scheme.error)),
              ),
            if (!_scanning && _devices.isEmpty && _scanError == null)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('No scan results yet.', style: TextStyle(fontSize: 12)),
              ),
            for (final device in _devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bluetooth,
                    color: device['isSolos'] == true ? scheme.primary : null),
                title: Text((device['name'] as String?) ?? 'Unknown'),
                subtitle: Text('${device['id'] ?? ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text('${device['rssi'] ?? '?'} dBm'),
              ),
          ],
        ),
      ),
    );
  }
}