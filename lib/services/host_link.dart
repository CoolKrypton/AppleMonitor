/// The device half of the PCMonitorHost WebSocket session.
///
/// This is the Dart equivalent of the firmware's `host_client.c`: it dials the
/// host, proves it holds the pairing secret, then keeps the link alive and
/// streams telemetry into the UI.
///
/// Handshake, in the order `DeviceSessionManager.ServeAsync` enforces it:
///
/// ```text
/// host -> device  pairing.challenge     { hostId, nonce }
/// device -> host  pairing.authenticate  { deviceId, hostId, proof, clientNonce }
/// host -> device  pairing.auth.result   { success, hostProof }
/// device -> host  device.status         (seq must exceed the authenticate seq)
/// host -> device  telemetry.snapshot    ... then once per telemetry interval
/// ```
///
/// The host verifies our proof; we verify its `hostProof` right back, which is
/// what tells us we are talking to a machine that really knows the secret and
/// not to something that merely answered on port 8765.
library;

import 'dart:async';
import 'dart:io';

import '../models/pc_status.dart';
import 'pairing_crypto.dart';
import 'protocol.dart';
import 'ws_client.dart';

/// Thrown when the link cannot be established or the handshake fails.
class HostLinkException implements Exception {
  HostLinkException(this.message, {this.authenticationFailed = false});

  final String message;

  /// True when the host rejected our credential - re-pairing is required.
  final bool authenticationFailed;

  @override
  String toString() => message;
}

/// Why a live session ended.
enum HostLinkCloseReason {
  /// We closed it.
  local,

  /// The host closed it, or the network dropped.
  remote,

  /// The host asked us to remove the pairing.
  pairingRemoved,
}

class HostLink {
  HostLink({
    required this.onSnapshot,
    required this.onSettings,
    required this.onRemoved,
    required this.onClosed,
  });

  /// A fresh telemetry snapshot.
  ///
  /// [hostTimeMs] is the envelope's own `timestamp` - the moment the PC built
  /// the frame, in epoch milliseconds. The provider positions its history by
  /// it, so a frame the network delayed still lands where it was sampled.
  final void Function(PcStatus status, int? hostTimeMs) onSnapshot;

  /// The host pushed a new display brightness (`device.settings.set`).
  final void Function(double brightnessPercent) onSettings;

  /// The host removed the pairing; the stored secret must be discarded.
  final void Function() onRemoved;

  /// The session ended for good. [reason] explains why.
  final void Function(HostLinkCloseReason reason, String message) onClosed;

  /// Set before [connect]. Identifies this device on the wire.
  late String deviceId;

  /// The negotiated host.
  HostEndpoint? _endpoint;

  /// Our own LAN address, reported back to the host in `device.status`.
  String? localIp;
  String? wifiSsid;
  int? wifiRssi;

  WsClient? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _statusTimer;
  int _seq = 0;
  bool _closed = false;
  bool _removed = false;

  /// Until the handshake has succeeded once, [connect] is the only thing that
  /// reports failure - [onClosed] stays silent so the caller never sees the
  /// same failure twice.
  bool _everOnline = false;
  _Phase _phase = _Phase.challenge;
  Completer<void>? _ready;

  // Handshake state.
  String? _expectedHostProof;
  List<int>? _secret;

  /// Display brightness the host last asked for, mirrored into `device.status`.
  double _brightnessPercent = 100;

  double get brightnessPercent => _brightnessPercent;
  HostEndpoint? get endpoint => _endpoint;
  bool get isOnline => _phase == _Phase.online && _closed == false;
  bool get isClosed => _closed;

  /// Dials [endpoint] and runs the handshake. Throws [HostLinkException] when
  /// the host is unreachable, slow, or rejects the credential.
  Future<void> connect({
    required HostEndpoint endpoint,
    required String deviceId,
    required String secretBase64,
  }) async {
    final List<int>? secret = decodeBase64(secretBase64);
    if (secret == null || secret.length != kSecretBytes) {
      throw HostLinkException('Stored pairing secret is invalid');
    }
    this.deviceId = deviceId;
    _secret = secret;
    _endpoint = endpoint;
    _closed = false;
    _removed = false;
    _phase = _Phase.challenge;
    _seq = 0;
    _ready = Completer<void>();

    try {
      _socket = await WsClient.connect(
        Uri.parse(endpoint.webSocketUrl),
        timeout: const Duration(seconds: 8),
      );
    } on TimeoutException {
      throw HostLinkException('No answer from ${endpoint.address}');
    } on SocketException catch (error) {
      throw HostLinkException(
        'Cannot reach ${endpoint.address} '
        '(${error.osError?.message ?? 'socket error'})',
      );
    } on WebSocketHandshakeException catch (error) {
      throw HostLinkException(
        'The PC refused the connection: ${error.message}',
      );
    } on FormatException catch (error) {
      throw HostLinkException(
        'Bad host address ${endpoint.webSocketUrl} (${error.message})',
      );
    }

    final WsClient socket = _socket!;
    _subscription = socket.messages.listen(
      _onFrame,
      onError: (Object error) =>
          _close(HostLinkCloseReason.remote, _describe(error)),
      onDone: () {
        final String? reason = socket.closeReason;
        _close(
          HostLinkCloseReason.remote,
          (reason != null && reason.isNotEmpty)
              ? reason
              : 'Host closed the connection',
        );
      },
      cancelOnError: true,
    );

    try {
      await _ready!.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      await close();
      throw HostLinkException('Handshake timed out');
    } on HostLinkException {
      await close();
      rethrow;
    }
  }

  /// Sends a `device.status`. The host drops a session that has been silent for
  /// 45 s, so this doubles as the heartbeat.
  Future<void> sendDeviceStatus({double? brightnessPercent}) async {
    if (_closed || _phase != _Phase.online) return;
    final double brightness = brightnessPercent ?? _brightnessPercent;
    _brightnessPercent = brightness;
    _send(Proto.deviceStatus, <String, dynamic>{
      'deviceId': deviceId,
      'firmwareVersion': Proto.firmwareVersion,
      'wifi': <String, dynamic>{
        'ssid': wifiSsid,
        'ip': localIp,
        'rssi': wifiRssi,
      },
      'display': <String, dynamic>{
        'brightnessPercent': brightness.clamp(0.0, 100.0),
      },
    });
  }

  /// Closes the session. Safe to call more than once.
  Future<void> close() async {
    if (_closed) {
      await _subscription?.cancel();
      return;
    }
    _closed = true;
    _statusTimer?.cancel();
    _statusTimer = null;
    final Completer<void>? ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(HostLinkException('Connection closed'));
    }
    await _subscription?.cancel();
    _subscription = null;
    final WsClient? socket = _socket;
    _socket = null;
    try {
      await socket?.close(1000, 'normal');
    } on Object {
      // The peer may already be gone; nothing useful to report.
    }
  }

  // -------------------------------------------------------------------------
  // frames
  // -------------------------------------------------------------------------

  void _onFrame(String frame) {
    final Envelope? envelope = Envelope.tryDecode(frame);
    if (envelope == null) {
      _close(HostLinkCloseReason.remote, 'Malformed envelope from host');
      return;
    }

    switch (_phase) {
      case _Phase.challenge:
        _handleChallenge(envelope);
      case _Phase.authenticating:
        _handleAuthResult(envelope);
      case _Phase.online:
        _handleOnline(envelope);
    }
  }

  void _handleChallenge(Envelope envelope) {
    if (envelope.type != Proto.challenge) {
      _fail('Expected the pairing challenge, got ${envelope.type}',
          authenticationFailed: true);
      return;
    }
    final String? hostId = envelope.string('hostId');
    final String? nonce = envelope.string('nonce');
    final String? expectedHostId = _endpoint?.hostId;
    if (!validHostId(hostId) || !is32Bytes(nonce)) {
      _fail('Host sent malformed pairing material');
      return;
    }
    if (expectedHostId != null && expectedHostId != hostId) {
      // The IP we dialled now belongs to a different host.
      _fail('A different host answered on this address');
      return;
    }

    final String clientNonce = newNonce();
    final String proof;
    try {
      proof = deviceProof(
        secret: _secret!,
        nonce: nonce!,
        hostId: hostId!,
        deviceId: deviceId,
      );
      _expectedHostProof = hostProof(
        secret: _secret!,
        nonce: nonce,
        clientNonce: clientNonce,
        hostId: hostId,
        deviceId: deviceId,
      );
    } on ArgumentError {
      _fail('Stored pairing secret cannot be used');
      return;
    }

    _send(Proto.authenticate, <String, dynamic>{
      'deviceId': deviceId,
      'hostId': hostId,
      'proof': proof,
      'clientNonce': clientNonce,
    });
    _phase = _Phase.authenticating;
  }

  void _handleAuthResult(Envelope envelope) {
    if (envelope.type != Proto.authResult) {
      _fail('Expected the authentication result, got ${envelope.type}');
      return;
    }
    if (envelope.boolean('success') != true) {
      _fail('The PC rejected this device. Pair it again.', authenticationFailed: true);
      return;
    }
    final String? hostProof = envelope.string('hostProof');
    if (!verifyProof(_expectedHostProof ?? '', hostProof)) {
      _fail('The PC failed proof-of-secret verification', authenticationFailed: true);
      return;
    }
    _phase = _Phase.online;
    _everOnline = true;

    // The host tracks the sequence and requires this first status to be newer
    // than the authenticate frame that preceded it.
    sendDeviceStatus();

    final Completer<void>? ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete();

    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(Proto.statusInterval, (_) {
      sendDeviceStatus();
    });
  }

  void _handleOnline(Envelope envelope) {
    switch (envelope.type) {
      case Proto.snapshot:
        onSnapshot(
          PcStatus.fromTelemetry(envelope.payload),
          envelope.timestamp,
        );
      case Proto.settingsSet:
        final double? brightness = envelope.number('brightnessPercent');
        if (brightness == null) return;
        _brightnessPercent = brightness.clamp(0.0, 100.0);
        onSettings(_brightnessPercent);
        // Every command is acknowledged, including the host's 75 ms preview
        // frames while the slider is being dragged.
        _send(Proto.settingsAck, <String, dynamic>{
          'brightnessPercent': _brightnessPercent,
          'persisted': envelope.boolean('persist') ?? false,
          'success': true,
          'error': null,
          if (envelope.id != null) 'requestId': envelope.id,
        });
      case Proto.remove:
        _removed = true;
        if (envelope.id != null) {
          _send(Proto.removeAck, <String, dynamic>{
            'deviceId': deviceId,
            'success': true,
            'error': null,
            'requestId': envelope.id,
          });
        }
        _close(HostLinkCloseReason.pairingRemoved, 'Pairing removed by the PC');
      default:
        // Unknown authenticated messages are ignored, matching the host's own
        // forward-compatibility rule for devices.
        return;
    }
  }

  // -------------------------------------------------------------------------
  // plumbing
  // -------------------------------------------------------------------------

  void _send(String type, Map<String, dynamic> payload) {
    final WsClient? socket = _socket;
    if (socket == null || _closed) return;
    _seq++;
    final String json = Envelope.encode(
      type: type,
      payload: payload,
      seq: _seq,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      socket.sendText(json);
    } on StateError {
      _close(HostLinkCloseReason.remote, 'The connection was already closed');
    }
  }

  void _fail(String message, {bool authenticationFailed = false}) {
    final Completer<void>? ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        HostLinkException(message, authenticationFailed: authenticationFailed),
      );
    }
    _close(HostLinkCloseReason.remote, message);
  }

  void _close(HostLinkCloseReason reason, String message) {
    if (_closed) return;
    _closed = true;
    _statusTimer?.cancel();
    _statusTimer = null;
    final Completer<void>? ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(HostLinkException(message));
    }
    _subscription?.cancel();
    _subscription = null;
    final WsClient? socket = _socket;
    _socket = null;
    // Fire and forget: the closing handshake is best effort, and the caller
    // must not be blocked on it (this runs from stream callbacks).
    unawaited(socket?.close(1001, 'going away') ?? Future<void>.value());
    if (_everOnline) {
      onClosed(
        _removed ? HostLinkCloseReason.pairingRemoved : reason,
        message,
      );
    }
  }

  static String _describe(Object error) {
    if (error is SocketException) {
      return error.osError?.message ?? 'Network error';
    }
    if (error is WebSocketHandshakeException) return error.message;
    return error.toString();
  }
}

enum _Phase { challenge, authenticating, online }
