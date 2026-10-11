/// Persistent identity and credentials.
///
/// The firmware keeps its pairing in NVS; this is the Android equivalent. Two
/// things are stored:
///
/// * the **device identity** - a UUID generated once per install plus the name
///   the PC shows in its pairing dialog;
/// * the **pairing** - the host's identity, its last known address and the
///   32-byte secret, exactly the material the USB provisioning flow hands an
///   ESP32.
///
/// Storage goes through [KeyValueStore] so the rest of the app never touches a
/// platform plugin directly, which also keeps it testable without a device.
library;

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'pairing_crypto.dart';
import 'protocol.dart';

/// The smallest storage surface this feature needs.
abstract class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

/// Real storage, backed by `SharedPreferences`.
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferences? _preferences;

  Future<SharedPreferences> get _instance async =>
      _preferences ??= await SharedPreferences.getInstance(); // coverage:ignore-line

  @override
  Future<String?> read(String key) async => (await _instance).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await _instance).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await _instance).remove(key);
  }
}

/// In-memory storage, used by tests and by the widget preview harness.
class MemoryStore implements KeyValueStore {
  MemoryStore([Map<String, String>? seed])
      : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}

/// A paired host: who it is, where it last answered, and the shared secret.
class PairedHost {
  const PairedHost({
    required this.endpoint,
    required this.secretBase64,
  });

  final HostEndpoint endpoint;
  final String secretBase64;

  PairedHost withEndpoint(HostEndpoint updated) =>
      PairedHost(endpoint: updated, secretBase64: secretBase64);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'endpoint': endpoint.toJson(),
        'secret': secretBase64,
      };

  static PairedHost? fromJson(Object? value) {
    if (value is! Map) return null;
    final Map<String, dynamic> json = Map<String, dynamic>.from(value);
    final HostEndpoint? endpoint = HostEndpoint.fromJson(json['endpoint']);
    final Object? secret = json['secret'];
    if (endpoint == null || secret is! String || !is32Bytes(secret)) return null;
    return PairedHost(endpoint: endpoint, secretBase64: secret);
  }
}

class PairingStore {
  PairingStore(this._store);

  final KeyValueStore _store;

  static const String _kDeviceId = 'pcmonitor.deviceId';
  static const String _kDeviceName = 'pcmonitor.deviceName';
  static const String _kPairedHost = 'pcmonitor.pairedHost';

  /// The stable per-install device id. Generated on first use, never rotated -
  /// rotating it would invalidate the host's registry entry.
  Future<String> loadOrCreateDeviceId() async {
    final String? existing = await _store.read(_kDeviceId);
    if (existing != null && validDeviceId(existing)) return existing;
    final String created = '${_platformDevicePrefix()}-${newUuidV4()}';
    await _store.write(_kDeviceId, created);
    return created;
  }

  /// The id prefix names the client family to the host, exactly as the ESP32's
  /// `esp32-…` does. The host only validates length and control characters
  /// (`ValidDeviceId`), so the prefix is purely for the pairing registry's
  /// readability - which is precisely why an iOS client should not claim to be
  /// an Android one.
  static String _platformDevicePrefix() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'dart';
  }

  Future<String?> loadDeviceName() async {
    final String? name = await _store.read(_kDeviceName);
    if (name == null || name.trim().isEmpty) return null;
    return clampDeviceName(name.trim());
  }

  Future<void> saveDeviceName(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _store.write(_kDeviceName, clampDeviceName(trimmed));
  }

  Future<PairedHost?> loadPairedHost() async {
    final String? raw = await _store.read(_kPairedHost);
    if (raw == null) return null;
    try {
      return PairedHost.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> savePairedHost(PairedHost host) async {
    await _store.write(_kPairedHost, jsonEncode(host.toJson()));
  }

  Future<void> clearPairedHost() async {
    await _store.remove(_kPairedHost);
  }

  /// The host caps a device friendly name at 64 UTF-8 bytes, and a cut through
  /// the middle of a multi-byte character would be rejected outright, so the
  /// trim happens on rune boundaries.
  static String clampDeviceName(String value) {
    const int limit = 64;
    if (utf8.encode(value).length <= limit) return value;
    final StringBuffer out = StringBuffer();
    int bytes = 0;
    for (final int rune in value.runes) {
      final String character = String.fromCharCode(rune);
      final int cost = utf8.encode(character).length;
      if (bytes + cost > limit) break;
      out.write(character);
      bytes += cost;
    }
    return out.toString();
  }
}
