/// The PCMonitor protocol V1 wire format, shared with `PCMonitorHost`.
///
/// Everything here is a mirror of `PCMonitorProtocol.cs` / `PairingProtocol.cs`.
/// The Android client is a **device**, so the direction of every message is the
/// one an ESP32 would use.
///
/// Envelope:
/// ```json
/// { "v": 1, "type": "<message>", "id": "<optional>", "seq": 7,
///   "timestamp": 1760000000000, "payload": { ... } }
/// ```
/// `seq` and `timestamp` are mandatory on the WebSocket link (the host rejects
/// envelopes without them) and are omitted on the UDP discovery link.
library;

import 'dart:convert';
import 'dart:io';

/// `PCMonitorProtocol`.
class Proto {
  const Proto._();

  static const int version = 1;
  static const String product = 'pcmonitor';
  static const String hostProduct = 'pcmonitor-host';
  static const int port = 8765;
  static const String path = '/ws';
  static const int maxMessageBytes = 262144;
  static const int discoveryPort = 8766;

  /// Largest UDP datagram the host will even look at.
  static const int maxDatagramBytes = 1024;

  // Host -> device.
  static const String snapshot = 'telemetry.snapshot';
  static const String settingsSet = 'device.settings.set';

  // Device -> host.
  static const String deviceStatus = 'device.status';
  static const String settingsAck = 'device.settings.ack';

  // Pairing, over the WebSocket link.
  static const String challenge = 'pairing.challenge';
  static const String authenticate = 'pairing.authenticate';
  static const String authResult = 'pairing.auth.result';
  static const String remove = 'pairing.remove';
  static const String removeAck = 'pairing.remove.ack';

  // Discovery / pairing, over UDP.
  static const String discoveryRequest = 'discovery.request';
  static const String discoveryReply = 'discovery.reply';
  static const String lanProbe = 'discovery.probe';
  static const String lanOffer = 'discovery.offer';
  static const String pairRequest = 'pairing.request';
  static const String pairGrant = 'pairing.grant';

  /// How often the device must report in. The host drops a session that has
  /// been silent for 45 s, so this leaves a wide margin.
  static const Duration statusInterval = Duration(seconds: 10);

  /// The app's advertised firmware version, reported in `device.status`.
  ///
  /// The host records this string verbatim in its device registry, so it names
  /// the client family rather than pretending every client is the same build:
  /// `android-…`, `ios-…`, matching the same vocabulary the ESP32 uses
  /// (`esp32-…`). Only the prefix is platform-dependent - the protocol revision
  /// it fingerprints is unchanged, so nothing on the wire changes shape.
  static String get firmwareVersion => '$_platformTag-2026.10.09.1';

  /// The client family, as reported to the host.
  static String get _platformTag {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'dart';
  }
}

/// A decoded envelope. `payload` keeps the raw map so each message can be
/// validated with its own rules.
class Envelope {
  const Envelope({
    required this.type,
    required this.payload,
    this.id,
    this.seq,
    this.timestamp,
  });

  final String type;
  final Map<String, dynamic> payload;
  final String? id;
  final int? seq;
  final int? timestamp;

  static const int version = Proto.version;

  /// Serialises a device -> host message. [seq]/[timestamp] are required on the
  /// WebSocket link and omitted (`null`) on the UDP discovery link.
  static String encode({
    required String type,
    required Map<String, dynamic> payload,
    String? id,
    int? seq,
    int? timestamp,
  }) {
    final Map<String, dynamic> json = <String, dynamic>{
      'v': version,
      'type': type,
    };
    if (id != null) json['id'] = id;
    if (seq != null) json['seq'] = seq;
    if (timestamp != null) json['timestamp'] = timestamp;
    json['payload'] = payload;
    return jsonEncode(json);
  }

  /// Decodes anything the host sent. Returns `null` for junk rather than
  /// throwing, because discovery runs on a shared broadcast port where other
  /// software's traffic is guaranteed to show up.
  static Envelope? tryDecode(String text) {
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);
    if (json['v'] != version) return null;
    final Object? type = json['type'];
    if (type is! String) return null;
    final Object? payload = json['payload'];
    if (payload is! Map) return null;
    final Object? seq = json['seq'];
    final Object? timestamp = json['timestamp'];
    return Envelope(
      type: type,
      payload: Map<String, dynamic>.from(payload),
      id: json['id'] is String ? json['id'] as String : null,
      seq: seq is num ? seq.toInt() : null,
      timestamp: timestamp is num ? timestamp.toInt() : null,
    );
  }

  // -------------------------------------------------------------------------
  // typed readers
  // -------------------------------------------------------------------------

  String? string(String key) {
    final Object? value = payload[key];
    return value is String ? value : null;
  }

  double? number(String key) {
    final Object? value = payload[key];
    return value is num ? value.toDouble() : null;
  }

  bool? boolean(String key) {
    final Object? value = payload[key];
    return value is bool ? value : null;
  }

  int? integer(String key) {
    final Object? value = payload[key];
    return value is num ? value.toInt() : null;
  }
}

/// The host identity a device talks to, as returned by an offer / reply / grant.
class HostEndpoint {
  const HostEndpoint({
    required this.hostId,
    required this.hostName,
    required this.ip,
    required this.port,
  });

  final String hostId;
  final String hostName;
  final String ip;
  final int port;

  String get webSocketUrl => 'ws://$ip:$port${Proto.path}';

  /// The line the UI shows under a host name.
  String get address => '$ip:$port';

  HostEndpoint copyWith({String? ip, int? port}) => HostEndpoint(
        hostId: hostId,
        hostName: hostName,
        ip: ip ?? this.ip,
        port: port ?? this.port,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hostId': hostId,
        'hostName': hostName,
        'ip': ip,
        'port': port,
      };

  static HostEndpoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final Map<String, dynamic> json = Map<String, dynamic>.from(value);
    final Object? hostId = json['hostId'];
    final Object? ip = json['ip'];
    if (hostId is! String || ip is! String) return null;
    return HostEndpoint(
      hostId: hostId,
      hostName: json['hostName'] is String ? json['hostName'] as String : '',
      ip: ip,
      port: json['port'] is num ? (json['port'] as num).toInt() : Proto.port,
    );
  }
}
