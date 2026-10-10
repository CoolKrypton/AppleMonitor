/// LAN discovery and pairing, the app equivalent of the firmware's
/// `discovery_service.c` / `pairing_service.c`.
///
/// The host is the *server*: it never scans. A device has to announce itself,
/// so this service owns one `RawDatagramSocket` on an ephemeral port and uses
/// it for everything:
///
/// ```text
/// device --broadcast discovery.probe--> :8766   (host answers if LAN pairing is open)
/// device <--unicast  discovery.offer--- host     host identity + ws port
/// device --unicast   pairing.request--> host     "please let me pair"
///        (the host shows a confirmation dialog)
/// device <--unicast  pairing.grant----  host     32-byte secret, or a refusal
/// ```
///
/// A device that is *already* paired takes a second route that works even with
/// LAN pairing switched off, because the host can verify it against its own
/// registry:
///
/// ```text
/// device --broadcast discovery.request--> :8766  carries PairedHostId
/// device <--unicast  discovery.reply----  host   only ever answers its own device
/// ```
///
/// **iOS note.** iOS will not let an app *send* to a broadcast address without
/// Apple's `com.apple.developer.networking.multicast` entitlement, so on iOS
/// every probe is additionally repeated as plain unicast across the local
/// `/24`s - a host answers a unicast probe exactly as it answers a broadcast
/// one. See [_sweepLocalSubnet]. The protocol on the wire is unchanged: only
/// the destination addresses differ.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pairing_crypto.dart';
import 'protocol.dart';

/// A host seen on the LAN.
class DiscoveredHost {
  DiscoveredHost({
    required this.endpoint,
    required this.pairingOpen,
    required this.knownPaired,
    required this.seenAt,
  });

  final HostEndpoint endpoint;

  /// The host has LAN pairing switched on, so it will answer a pair request.
  final bool pairingOpen;

  /// The host answered a `discovery.request`, i.e. it already holds our secret.
  final bool knownPaired;

  final DateTime seenAt;

  bool get paired => knownPaired;

  /// Stable list key: a host may be reachable on more than one interface.
  String get key => endpoint.hostId;

  DiscoveredHost refreshed({
    HostEndpoint? endpoint,
    bool? pairingOpen,
    bool? knownPaired,
  }) =>
      DiscoveredHost(
        endpoint: endpoint ?? this.endpoint,
        pairingOpen: pairingOpen ?? this.pairingOpen,
        knownPaired: knownPaired ?? this.knownPaired,
        seenAt: DateTime.now(),
      );
}

/// The credential the host issues after an on-screen confirmation.
class PairGrant {
  const PairGrant({
    required this.approved,
    required this.endpoint,
    this.secret,
    this.error,
  });

  final bool approved;
  final HostEndpoint endpoint;

  /// Base64 of the 32-byte secret. Only ever set when [approved].
  final String? secret;
  final String? error;
}

class HostDiscoveryService {
  HostDiscoveryService({this.discoveryPort = Proto.discoveryPort});

  /// The UDP port probes are sent to. Overridable so the transport can be
  /// exercised without an installed host.
  final int discoveryPort;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  final StreamController<DiscoveredHost> _hosts =
      StreamController<DiscoveredHost>.broadcast();
  final StreamController<PairGrant> _grants =
      StreamController<PairGrant>.broadcast();

  /// Hosts heard from, newest datagram wins.
  Stream<DiscoveredHost> get onHost => _hosts.stream;

  Stream<PairGrant> get onGrant => _grants.stream;

  bool get isRunning => _socket != null;

  /// The local port this service is bound to; `null` before [start].
  int? get port => _socket?.port;

  Future<void> start() async {
    if (_socket != null) return;
    final RawDatagramSocket socket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    // Required before `send(..., 255.255.255.255, ...)` is allowed to leave.
    socket.broadcastEnabled = true;
    _socket = socket;
    _subscription = socket.listen(
      _onEvent,
      onError: (Object error) {},
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _hosts.close();
    await _grants.close();
  }

  // -------------------------------------------------------------------------
  // sending
  // -------------------------------------------------------------------------

  /// One round of discovery: a broadcast probe (finds hosts that will pair us)
  /// plus a directed request (finds *our* host even when LAN pairing is off).
  ///
  /// Call it a few times in a row - UDP is lossy and the probe is cheap.
  Future<void> probeOnce({
    required String deviceId,
    required String deviceName,
    String? pairedHostId,
    String? lastKnownHostIp,
  }) async {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;

    // The remembered host goes out first. On a reconnect that direct unicast is
    // both the likeliest to be delivered and the fastest, and it does not
    // depend on broadcast leaving the interface - a real concern, because a
    // broadcast target that cannot be routed (a VPN or emulator adapter's
    // "broadcast") can make the OS drop the datagrams queued behind it.
    final List<InternetAddress> targets = <InternetAddress>[];
    if (lastKnownHostIp != null && lastKnownHostIp.isNotEmpty) {
      final InternetAddress? remembered = _parseIp(lastKnownHostIp);
      if (remembered != null) targets.add(remembered);
    }
    targets.addAll(await _broadcastTargets());

    final String probe = Envelope.encode(
      type: Proto.lanProbe,
      payload: <String, dynamic>{
        'product': Proto.product,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'protocolVersion': Proto.version,
      },
    );
    final List<String> datagrams = <String>[probe];
    if (pairedHostId != null && validHostId(pairedHostId)) {
      datagrams.add(Envelope.encode(
        type: Proto.discoveryRequest,
        payload: <String, dynamic>{
          'product': Proto.product,
          'deviceId': deviceId,
          'pairedHostId': pairedHostId,
          'protocolVersion': Proto.version,
        },
      ));
    }

    await _sendAll(socket, targets, datagrams);

    // iOS only - see [_sweepLocalSubnet]. The sweep carries the probe alone:
    // the directed `discovery.request` is already covered by the remembered
    // address above, and repeating it 254 times would be pure noise.
    if (_sweepLocalSubnet) {
      await _sendAll(socket, await _sweepTargets(), <String>[probe]);
    }
  }

  /// Sends [datagrams] to every address in [targets], tolerating the ones that
  /// cannot be reached.
  Future<void> _sendAll(
    RawDatagramSocket socket,
    List<InternetAddress> targets,
    List<String> datagrams,
  ) async {
    int sent = 0;
    for (final InternetAddress target in targets) {
      for (final String datagram in datagrams) {
        final Uint8List bytes = Uint8List.fromList(utf8.encode(datagram));
        if (bytes.length > Proto.maxDatagramBytes) continue;
        try {
          socket.send(bytes, target, discoveryPort);
        } on SocketException {
          // A target that cannot be reached (VPN, cellular), or - on iOS - a
          // broadcast the OS refused for want of the multicast entitlement, is
          // not an error worth surfacing here. The unicast sweep is what covers
          // the refused case.
        }
      }
      // A sweep is up to 254 hosts; yielding keeps a discovery round from ever
      // looking like a hang.
      if (++sent % 32 == 0) await Future<void>.delayed(Duration.zero);
    }
  }

  /// Whether a probe should also walk the local subnet with plain unicast.
  ///
  /// iOS refuses to *send* to a broadcast or multicast address unless the app
  /// is signed with Apple's `com.apple.developer.networking.multicast`
  /// entitlement, which Apple grants per app on request:
  ///
  /// > "Your app must have this entitlement to send or receive IP multicast or
  /// > broadcast on iOS."
  ///
  /// Rather than make discovery depend on that paperwork, iOS falls back to
  /// unicast: a host answers a probe addressed straight at it exactly as it
  /// answers a broadcast one, and the PC is always on the same subnet as the
  /// phone. Android and the ESP32 have no such restriction, so the sweep is
  /// skipped there and their traffic profile is untouched.
  ///
  /// If the entitlement *is* granted and wired up (see
  /// `ios/Runner/Runner.entitlements`), the broadcast path simply works and the
  /// sweep becomes a redundant - but harmless - second chance.
  bool get _sweepLocalSubnet => Platform.isIOS;

  /// Every usable address of the local `/24`s, for the fallback above.
  ///
  /// One `/24` per interface, never the interface's own address, and only in
  /// RFC 1918 space. Home and office Wi-Fi is overwhelmingly a `/24`, and the
  /// sweep only has to make *first-time* discovery work - a reconnect already
  /// tries the remembered address directly. Restricting the sweep to private
  /// ranges also keeps a cellular interface, whose address is carrier space,
  /// from being walked at all.
  Future<List<InternetAddress>> _sweepTargets() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
    } on SocketException {
      return const <InternetAddress>[];
    }

    final Set<String> localAddresses = <String>{};
    for (final NetworkInterface interface in interfaces) {
      for (final InternetAddress address in interface.addresses) {
        localAddresses.add(address.address);
      }
    }

    final List<InternetAddress> targets = <InternetAddress>[];
    final Set<String> seen = <String>{};
    for (final NetworkInterface interface in interfaces) {
      for (final InternetAddress address in interface.addresses) {
        final Uint8List octets = address.rawAddress;
        if (octets.length != 4 || !_isPrivateIpv4(octets)) continue;
        final String prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
        for (int host = 1; host <= 254; host++) {
          final String candidate = '$prefix.$host';
          if (seen.contains(candidate) || localAddresses.contains(candidate)) {
            continue;
          }
          seen.add(candidate);
          targets.add(InternetAddress(candidate));
        }
      }
    }

    // The answering side caps how many probes it will reply to per second, and
    // a burst walks this list in order - so a fixed order would keep testing
    // the same handful of addresses on every round while the rest of the /24
    // went unanswered. Shuffling makes each round cover a different slice.
    targets.shuffle();
    return targets;
  }

  /// `10/8`, `172.16/12`, `192.168/16` - the ranges a home router hands out.
  static bool _isPrivateIpv4(Uint8List octets) {
    if (octets.length != 4) return false;
    if (octets[0] == 10) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    return false;
  }

  /// Asks one host for a credential. The host queues the request for on-screen
  /// confirmation and answers with a `pairing.grant` - possibly minutes later.
  void requestPairing(
    HostEndpoint host, {
    required String deviceId,
    required String deviceName,
  }) {
    final RawDatagramSocket? socket = _socket;
    final InternetAddress? address = _parseIp(host.ip);
    if (socket == null || address == null) return;
    final String json = Envelope.encode(
      type: Proto.pairRequest,
      payload: <String, dynamic>{
        'deviceId': deviceId,
        'deviceName': deviceName,
      },
    );
    final Uint8List bytes = Uint8List.fromList(utf8.encode(json));
    if (bytes.length > Proto.maxDatagramBytes) return;
    try {
      socket.send(bytes, address, discoveryPort);
    } on SocketException {
      // Surfaced to the user as "no answer"; nothing else to do here.
    }
  }

  // -------------------------------------------------------------------------
  // receiving
  // -------------------------------------------------------------------------

  void _onEvent(RawSocketEvent event) {
    final RawDatagramSocket? socket = _socket;
    if (socket == null || event != RawSocketEvent.read) return;
    Datagram? datagram = socket.receive();
    while (datagram != null) {
      _handle(datagram);
      datagram = socket.receive();
    }
  }

  void _handle(Datagram datagram) {
    if (datagram.data.length > 4096) return;
    final Envelope? envelope = Envelope.tryDecode(utf8.decode(datagram.data));
    if (envelope == null) return;
    switch (envelope.type) {
      case Proto.lanOffer:
        _offer(envelope);
      case Proto.discoveryReply:
        _reply(envelope);
      case Proto.pairGrant:
        _grant(envelope, datagram.address);
      default:
        return;
    }
  }

  void _offer(Envelope envelope) {
    if (envelope.string('product') != Proto.hostProduct) return;
    final HostEndpoint? endpoint = _endpointOf(envelope);
    if (endpoint == null) return;
    _emit(DiscoveredHost(
      endpoint: endpoint,
      pairingOpen: envelope.boolean('pairingOpen') ?? false,
      knownPaired: false,
      seenAt: DateTime.now(),
    ));
  }

  void _reply(Envelope envelope) {
    if (envelope.string('product') != Proto.hostProduct) return;
    final HostEndpoint? endpoint = _endpointOf(envelope);
    if (endpoint == null) return;
    _emit(DiscoveredHost(
      endpoint: endpoint,
      // A reply means the host already holds our secret, so pairing is moot.
      pairingOpen: true,
      knownPaired: true,
      seenAt: DateTime.now(),
    ));
  }

  void _grant(Envelope envelope, InternetAddress source) {
    final String? hostId = envelope.string('hostId');
    if (!validHostId(hostId)) return;
    final String? ip = envelope.string('ip');
    final int? port = envelope.integer('webSocketPort');
    final bool approved = envelope.boolean('approved') ?? false;
    final String? secret = envelope.string('pairSecret');

    // Same rule the host applies to itself: a refusal never carries a secret,
    // and an approval must carry exactly 32 bytes of it.
    if (approved ? !is32Bytes(secret) : (envelope.string('error') ?? '').isEmpty) {
      return;
    }
    if (!approved) {
      _emitGrant(PairGrant(
        approved: false,
        endpoint: HostEndpoint(
          hostId: hostId!,
          hostName: envelope.string('hostName') ?? '',
          ip: (ip != null && _parseIp(ip) != null) ? ip : source.address,
          port: (port != null && port > 0 && port <= 65535) ? port : Proto.port,
        ),
        error: envelope.string('error'),
      ));
      return;
    }
    if (ip == null ||
        _parseIp(ip) == null ||
        port == null ||
        port <= 0 ||
        port > 65535) {
      return;
    }
    _emitGrant(PairGrant(
      approved: true,
      endpoint: HostEndpoint(
        hostId: hostId!,
        hostName: envelope.string('hostName') ?? '',
        ip: ip,
        port: port,
      ),
      secret: secret,
    ));
  }

  HostEndpoint? _endpointOf(Envelope envelope) {
    final String? hostId = envelope.string('hostId');
    final String? ip = envelope.string('ip');
    final int? port = envelope.integer('webSocketPort');
    if (!validHostId(hostId) || ip == null || _parseIp(ip) == null) return null;
    if (port == null || port <= 0 || port > 65535) return null;
    return HostEndpoint(
      hostId: hostId!,
      hostName: envelope.string('hostName') ?? '',
      ip: ip,
      port: port,
    );
  }

  void _emit(DiscoveredHost host) {
    if (_hosts.isClosed) return;
    _hosts.add(host);
  }

  void _emitGrant(PairGrant grant) {
    if (_grants.isClosed) return;
    _grants.add(grant);
  }

  // -------------------------------------------------------------------------
  // addresses
  // -------------------------------------------------------------------------

  /// Everything a probe should be sent to: the limited broadcast address plus a
  /// `/24` guess for each local IPv4. Neither Android nor iOS exposes a netmask
  /// through `NetworkInterface`, and home / office Wi-Fi is overwhelmingly a
  /// `/24`, so the directed-broadcast guess is what makes discovery reliable on
  /// networks where `255.255.255.255` is filtered.
  Future<List<InternetAddress>> _broadcastTargets() async {
    final List<InternetAddress> targets = <InternetAddress>[];
    try {
      targets.add(InternetAddress('255.255.255.255'));
    } on ArgumentError {
      // Never happens for a literal, kept for clarity.
    }
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress address in interface.addresses) {
          final Uint8List octets = address.rawAddress;
          if (octets.length != 4) continue;
          final String directed = '${octets[0]}.${octets[1]}.${octets[2]}.255';
          final InternetAddress broadcast = InternetAddress(directed);
          if (!targets.any((InternetAddress t) => t.address == directed)) {
            targets.add(broadcast);
          }
        }
      }
    } on SocketException {
      // No usable interface: the limited broadcast above is all we have.
    }
    return targets;
  }

  static InternetAddress? _parseIp(String value) {
    try {
      final InternetAddress address = InternetAddress(value);
      if (address.type != InternetAddressType.IPv4) return null;
      return address;
    } on ArgumentError {
      return null;
    }
  }
}
