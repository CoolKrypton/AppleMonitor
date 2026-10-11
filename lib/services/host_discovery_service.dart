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
/// **iOS note.** Apple requires a multicast entitlement to send or receive UDP
/// broadcast. This app deliberately does not request that restricted
/// entitlement, so iOS sends probes *only* as plain unicast across local
/// `/24`s. A host answers a unicast probe exactly as it answers a broadcast
/// one. Android keeps its broadcast fast path; the discovery protocol itself
/// is unchanged.
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

/// What the last discovery round actually managed, in numbers.
///
/// iOS fails discovery silently by design: a send the OS refused, a route a VPN
/// swallowed, and a socket that was never bound all look identical from the
/// outside - nothing appears. These counters are what tells them apart, and
/// they are shown on the connect screen when a scan comes back empty.
class DiscoveryReport {
  const DiscoveryReport({
    required this.socketError,
    required this.interfaces,
    required this.locals,
    required this.bound,
    required this.usedFallback,
    required this.sweepTargets,
    required this.broadcastTargets,
    required this.sent,
    required this.refused,
    required this.sendWouldBlock,
    required this.sendExceptions,
    required this.firstSendException,
    required this.received,
    required this.offers,
  });

  /// Why the socket could not be bound, if it could not be.
  final String? socketError;

  /// Every IPv4 `NetworkInterface.list` reported, as `name:address`.
  final List<String> interfaces;

  /// The private ones the sweep and the broadcast guesses were built from.
  final List<String> locals;

  /// The address the socket was bound to. `0.0.0.0` means the system chose the
  /// source address, which is the state this whole report exists to catch.
  final String bound;

  /// True when those addresses had to come from the TCP-connect fallback.
  final bool usedFallback;

  final int sweepTargets;
  final int broadcastTargets;

  /// Datagrams accepted by the OS send queue, and how many could not be queued.
  /// An accepted datagram is not proof that it reached the remote host.
  final int sent;
  final int refused;

  /// Failed destinations split by `send()` returning zero versus throwing.
  final int sendWouldBlock;
  final int sendExceptions;
  final String? firstSendException;

  /// Datagrams read back off the socket, and how many were LAN offers.
  final int received;
  final int offers;

  /// A compact multi-line form, for a caption or a log line.
  String get summary {
    final StringBuffer buffer = StringBuffer()
      ..writeln(socketError == null ? 'socket: bound' : 'socket: $socketError')
      ..writeln('bound: $bound')
      ..writeln(
        'interfaces: ${interfaces.isEmpty ? 'none' : interfaces.join(' ')}',
      )
      ..writeln(
        'subnets: ${locals.isEmpty ? 'none' : locals.join(' ')}'
        '${usedFallback ? ' (via TCP probe)' : ''}',
      )
      ..writeln('targets: sweep=$sweepTargets broadcast=$broadcastTargets')
      ..writeln(
        'sent: $sent   refused: $refused '
        '(zero=$sendWouldBlock exceptions=$sendExceptions'
        '${firstSendException == null ? '' : ' first=$firstSendException'})',
      )
      ..write('received: $received   offers: $offers');
    return buffer.toString();
  }

  /// The same facts on one line, sized for the two-line status caption.
  ///
  /// Ordered by how much each field is worth: the send/receive counters, then
  /// what the socket was bound to and which interfaces exist, then the target
  /// counts. A caption that gets clipped still keeps the part that tells a
  /// refused send from a swallowed one.
  String get compact =>
      'tx=$sent err=$refused z0=$sendWouldBlock ex=$sendExceptions '
      '${firstSendException == null ? '' : 'why=$firstSendException '}'
      'rx=$received offer=$offers '
      '| bind=$bound if=$interfaceNames '
      '| swp=$sweepTargets bc=$broadcastTargets '
      '| loc=${locals.isEmpty ? 'none' : locals.join(',')}';

  /// Interface names only - the part of [interfaces] that identifies a tunnel
  /// or a cellular slot without the addresses.
  String get interfaceNames {
    final Set<String> names = <String>{};
    for (final String entry in interfaces) {
      final int colon = entry.indexOf(':');
      names.add(colon < 0 ? entry : entry.substring(0, colon));
    }
    return names.isEmpty ? 'none' : names.join(' ');
  }
}

class HostDiscoveryService {
  HostDiscoveryService({this.discoveryPort = Proto.discoveryPort});

  /// The UDP port probes are sent to. Overridable so the transport can be
  /// exercised without an installed host.
  final int discoveryPort;

  RawDatagramSocket? _socket;

  /// Where [_socket] was bound. `null` means `anyIPv4`, i.e. the system picked
  /// the source address itself - which is exactly the ambiguity iOS needs to be
  /// kept out of. Reported, because the choice is invisible otherwise.
  InternetAddress? _boundTo;

  StreamSubscription<RawSocketEvent>? _subscription;
  final StreamController<DiscoveredHost> _hosts =
      StreamController<DiscoveredHost>.broadcast();
  final StreamController<PairGrant> _grants =
      StreamController<PairGrant>.broadcast();

  // Why iOS discovery fails is invisible from the outside: a refused send, a
  // route swallowed by a VPN and a socket that was never bound all present as
  // the same silence. These counters are what turns that silence into a cause.
  String? _socketError;
  List<String> _interfaces = const <String>[];
  List<InternetAddress> _locals = const <InternetAddress>[];
  List<InternetAddress> _sweepTargets = const <InternetAddress>[];
  List<InternetAddress> _broadcastTargets = const <InternetAddress>[];
  bool _usedProbeFallback = false;
  int _sent = 0;
  int _refused = 0;
  int _sendWouldBlock = 0;
  int _sendExceptions = 0;
  String? _firstSendException;
  int _rx = 0;
  int _offersSeen = 0;
  int _pairSent = 0;
  int _pairRefused = 0;

  /// Hosts heard from, newest datagram wins.
  Stream<DiscoveredHost> get onHost => _hosts.stream;

  Stream<PairGrant> get onGrant => _grants.stream;

  bool get isRunning => _socket != null;

  /// The local port this service is bound to; `null` before [start].
  int? get port => _socket?.port;

  Future<void> start() async {
    final InternetAddress? preferred = await _preferredBindAddress();
    final InternetAddress target = preferred ?? InternetAddress.anyIPv4;

    // Re-evaluated on every call rather than latched once: the Wi-Fi address
    // changes with the network, and a socket left bound to one that is gone
    // swallows everything it is given without an error.
    if (_socket != null && _boundTo?.address == target.address) return;
    if (_socket != null) await stop();

    try {
      _socket = await _open(target);
      _boundTo = target;
      _socketError = null;
    } catch (error) {
      if (target.address == InternetAddress.anyIPv4.address) {
        _socket = null;
        _boundTo = null;
        _socketError = _describe(error);
      } else {
        // Losing discovery entirely would be worse than whatever the system
        // picks, so fall back to the unbound socket and say so in the report.
        try {
          _socket = await _open(InternetAddress.anyIPv4);
          _boundTo = InternetAddress.anyIPv4;
          _socketError = 'bind ${target.address}: ${_describe(error)}';
        } catch (fallback) {
          _socket = null;
          _boundTo = null;
          _socketError = _describe(fallback);
        }
      }
    }

    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;
    _subscription = socket.listen(
      _onEvent,
      onError: (Object error) {},
      cancelOnError: false,
    );
  }

  /// Binds the socket. Only non-iOS builds enable broadcast: iOS requires an
  /// Apple-granted multicast entitlement even for UDP broadcast, while the
  /// unicast sweep needs neither that entitlement nor this socket option.
  Future<RawDatagramSocket> _open(InternetAddress address) async {
    final RawDatagramSocket socket = await RawDatagramSocket.bind(address, 0);
    if (Platform.isIOS) return socket;
    try {
      socket.broadcastEnabled = true;
    } catch (_) {
      // A socket that cannot broadcast is still worth having. The remembered
      // address (and iOS's unicast sweep) can still discover a host.
    }
    return socket;
  }

  /// The address the discovery socket should send *from*, or `null` to let the
  /// system choose.
  ///
  /// Only iOS answers with anything but `null`. Its interface list mixes Wi-Fi,
  /// a cellular slot and one tunnel per VPN or relay, all of them carrying
  /// private addresses, and a socket on `anyIPv4` gets its source address and
  /// its route picked by the system rather than by us. When that choice lands
  /// on an interface that cannot reach the LAN the datagrams are accepted by
  /// `send()` and then dropped without a trace - the counters show a clean
  /// send, the PC sees nothing, and there is no evidence anywhere to say why.
  /// The interface whose name starts with `en` is the Wi-Fi one; binding to it
  /// takes the decision away from the system.
  ///
  /// Android reports a single `wlan0` and has no equivalent ambiguity, so it
  /// keeps the unbound socket and its traffic profile is untouched.
  Future<InternetAddress?> _preferredBindAddress() async {
    if (!Platform.isIOS) return null;
    try {
      final List<NetworkInterface> list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface interface in list) {
        if (!interface.name.startsWith('en')) continue;
        for (final InternetAddress address in interface.addresses) {
          if (_isPrivateIpv4(address.address)) return address;
        }
      }
    } catch (_) {
      // No interface list: `anyIPv4` is the answer, and the report shows it.
    }
    return null;
  }

  static String _describe(Object error) => error is SocketException
      ? (error.osError?.message ?? error.message)
      : '$error';

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _boundTo = null;
  }

  Future<void> dispose() async {
    await stop();
    await _hosts.close();
    await _grants.close();
  }

  // -------------------------------------------------------------------------
  // sending
  // -------------------------------------------------------------------------

  /// One round of discovery: a sweep/probe for hosts that will pair us, plus a
  /// directed request that finds *our* host even when LAN pairing is off.
  ///
  /// Call it a few times in a row - UDP is lossy and the probe is cheap.
  ///
  /// The round is split into independent phases on purpose. They used to share
  /// one send loop, so a single destination the OS refused ended the loop early
  /// - and on iOS the refused destination is the *first* broadcast, which meant
  /// the unicast sweep behind it never ran at all. Discovery then depended
  /// entirely on a send that cannot succeed there.
  Future<void> probeOnce({
    required String deviceId,
    required String deviceName,
    String? pairedHostId,
    String? lastKnownHostIp,
  }) async {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;

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

    final List<InternetAddress> locals = await _localAddresses();
    _locals = locals;

    // A socket bound to one address can only send from it, so the subnet of any
    // *other* interface is unreachable by definition. Walking it would burn 253
    // datagrams per round, and on iOS it hands the system a chance to send the
    // whole round out an interface the LAN cannot be reached from - which is
    // how a scan ends up reporting thousands of clean sends and zero arrivals.
    final InternetAddress? bound = _boundTo;
    final bool pinned = bound != null && bound.address != '0.0.0.0';
    final List<InternetAddress> reachable =
        pinned ? <InternetAddress>[bound] : locals;
    _sweepTargets = _sweepFrom(reachable);
    // See the iOS-only guard below: keeping this list empty makes the report
    // accurately show that no prohibited broadcast targets were attempted.
    _broadcastTargets = Platform.isIOS
        ? const <InternetAddress>[]
        : _broadcastFrom(reachable);

    // The remembered host goes out early: on a reconnect that direct unicast is
    // both the likeliest to be delivered and the fastest.
    final InternetAddress? remembered = _parseIp(lastKnownHostIp ?? '');

    // iOS only - see [_sweepLocalSubnet]. The sweep carries the probe alone:
    // the directed `discovery.request` is already covered by the remembered
    // address above, and repeating it 254 times would be pure noise. It also
    // goes first, because it is the phase that has to carry discovery there.
    if (_sweepLocalSubnet) {
      await _phase(socket, _sweepTargets, <String>[probe]);
    }
    if (remembered != null) {
      await _phase(socket, <InternetAddress>[remembered], datagrams);
    }
    // iOS must not send any UDP broadcast without Apple's multicast
    // entitlement. `send()` can report success while iOS silently discards
    // those packets, which is precisely the misleading tx>0/rx=0 state this
    // transport is designed to avoid. Its unicast sweep above is the complete
    // first-pairing discovery path instead.
    if (!Platform.isIOS) {
      await _phase(socket, _broadcastTargets, datagrams);
    }
  }

  /// Sends [datagrams] to every address in [targets], tolerating everything.
  ///
  /// Nothing a single destination can do ends the round, and the burst is paced
  /// in small batches: firing 254 datagrams at once is what a mobile stack and
  /// the answering host's receive buffer cope with worst, and a dropped batch
  /// costs nothing because the next round reshuffles the order.
  Future<void> _phase(
    RawDatagramSocket socket,
    List<InternetAddress> targets,
    List<String> datagrams,
  ) async {
    int inBatch = 0;
    for (final InternetAddress target in targets) {
      for (final String datagram in datagrams) {
        final Uint8List bytes = Uint8List.fromList(utf8.encode(datagram));
        if (bytes.length > Proto.maxDatagramBytes) continue;
        bool queued = false;
        bool wouldBlock = false;
        Object? sendException;
        bool shortWrite = false;
        for (int attempt = 0; attempt < _sendAttempts; attempt++) {
          try {
            final int written = socket.send(bytes, target, discoveryPort);
            if (written == bytes.length) {
              queued = true;
              break;
            }
            if (written != 0) {
              shortWrite = true;
              break;
            }
            wouldBlock = true;
            // RawDatagramSocket.send is non-blocking: zero means the packet
            // was not queued, but the same datagram may be retried later.
          } catch (error) {
            sendException = error;
            break;
          }
          if (attempt + 1 < _sendAttempts) {
            await Future<void>.delayed(_sendRetryPause);
          }
        }
        if (queued) {
          _sent++;
        } else {
          // Count zero-return sends as refused too; incrementing tx before
          // checking the return value made a full failed sweep look successful.
          _refused++;
          if (sendException != null) {
            _sendExceptions++;
            _firstSendException ??= _shortError(sendException);
          } else if (shortWrite) {
            _sendExceptions++;
            _firstSendException ??= 'short-send';
          } else if (wouldBlock) {
            _sendWouldBlock++;
          }
        }
      }
      if (++inBatch >= _batchSize) {
        inBatch = 0;
        await Future<void>.delayed(_batchPause);
      }
    }
  }

  /// How many datagrams go out before a phase yields, and for how long.
  ///
  /// Small enough that the socket's send queue and the host's receive queue
  /// both keep up with a full `/24`, large enough that a 254-address sweep
  /// costs tens of milliseconds rather than anything the user could notice.
  static const int _batchSize = 12;
  static const Duration _batchPause = Duration(milliseconds: 4);
  static const int _sendAttempts = 3;
  static const Duration _sendRetryPause = Duration(milliseconds: 2);

  static String _shortError(Object error) {
    final String value = error is SocketException
        ? '${error.osError?.errorCode ?? ''}:${error.osError?.message ?? error.message}'
        : error.toString();
    final String normalized = value.replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
  }

  /// What the last round actually managed, for the connect screen.
  DiscoveryReport get lastReport => DiscoveryReport(
    socketError: _socketError,
    interfaces: _interfaces,
    locals: _locals.map((InternetAddress a) => a.address).toList(growable: false),
    bound: _boundTo?.address ?? InternetAddress.anyIPv4.address,
    usedFallback: _usedProbeFallback,
    sweepTargets: _sweepTargets.length,
    broadcastTargets: _broadcastTargets.length,
    sent: _sent,
    refused: _refused,
    sendWouldBlock: _sendWouldBlock,
    sendExceptions: _sendExceptions,
    firstSendException: _firstSendException,
    received: _rx,
    offers: _offersSeen,
  );

  /// Zeroes the counters so one scan reports only what it did.
  void resetStats() {
    _sent = 0;
    _refused = 0;
    _sendWouldBlock = 0;
    _sendExceptions = 0;
    _firstSendException = null;
    _rx = 0;
    _offersSeen = 0;
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
  /// Rather than make discovery depend on that paperwork, iOS also walks the
  /// local subnet: a host answers a probe addressed straight at it exactly as
  /// it answers a broadcast one, and the PC is always on the same subnet as the
  /// phone. Android and the ESP32 have no such restriction, so the sweep is
  /// skipped there and their traffic profile is untouched.
  bool get _sweepLocalSubnet => Platform.isIOS;

  /// The private IPv4 addresses of this device, one per usable interface.
  ///
  /// iOS hands out several - Wi-Fi, a cellular slot and one `utun` per VPN - and
  /// the sweep is built per subnet, so every private address is kept and
  /// everything else dropped. Which of them the sweep actually walks is decided
  /// in [probeOnce]: only the interface the socket is bound to, because no
  /// other subnet is reachable from that source address anyway.
  ///
  /// The address is read from its dotted string rather than from `rawAddress`:
  /// a platform that reports a widened or mapped representation would make
  /// every `rawAddress.length != 4` check fail, and an empty sweep is
  /// indistinguishable from "no host answered".
  ///
  /// If the interface list yields nothing usable - nothing guarantees it
  /// reports the Wi-Fi interface - the outbound address is learned instead from
  /// a throwaway TCP connect, which the OS resolves through the normal routing
  /// table.
  Future<List<InternetAddress>> _localAddresses() async {
    final List<InternetAddress> found = <InternetAddress>[];
    final Set<String> seen = <String>{};
    final List<String> interfaces = <String>[];

    void record(String label) {
      if (!interfaces.contains(label)) interfaces.add(label);
    }

    void consider(String value) {
      if (!_isPrivateIpv4(value)) return;
      if (!seen.add(value)) return;
      final InternetAddress? parsed = _parseIp(value);
      if (parsed != null) found.add(parsed);
    }

    try {
      final List<NetworkInterface> list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface interface in list) {
        for (final InternetAddress address in interface.addresses) {
          record('${interface.name}:${address.address}');
          consider(address.address);
        }
      }
    } catch (_) {
      // No interface list at all; the probe below is the whole plan.
    }

    if (found.isEmpty) {
      for (final String host in const <String>['223.5.5.5', '1.1.1.1', '8.8.8.8']) {
        try {
          final Socket socket = await Socket.connect(
            host,
            53,
            timeout: const Duration(milliseconds: 900),
          );
          final String address = socket.address.address;
          socket.destroy();
          record('probe->$address');
          consider(address);
          _usedProbeFallback = true;
          if (found.isNotEmpty) break;
        } catch (_) {
          // Offline or blocked; try the next well-known address.
        }
      }
    }

    _interfaces = List<String>.unmodifiable(interfaces);
    return found;
  }

  /// Every usable address of the local `/24`s, for the fallback above.
  ///
  /// One `/24` per interface, never the interface's own address, and only in
  /// RFC 1918 space. Home and office Wi-Fi is overwhelmingly a `/24`, and the
  /// sweep only has to make *first-time* discovery work - a reconnect already
  /// tries the remembered address directly. Restricting the sweep to private
  /// ranges also keeps a cellular interface, whose address is carrier space,
  /// from being walked at all.
  List<InternetAddress> _sweepFrom(List<InternetAddress> locals) {
    final Set<String> own = <String>{
      for (final InternetAddress address in locals) address.address,
    };
    final List<InternetAddress> targets = <InternetAddress>[];
    final Set<String> seen = <String>{};
    for (final InternetAddress local in locals) {
      final List<String> octets = local.address.split('.');
      if (octets.length != 4) continue;
      final String prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
      for (int host = 1; host <= 254; host++) {
        final String candidate = '$prefix.$host';
        if (own.contains(candidate) || !seen.add(candidate)) continue;
        targets.add(InternetAddress(candidate));
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
  static bool _isPrivateIpv4(String value) {
    final List<String> octets = value.split('.');
    if (octets.length != 4) return false;
    final int? first = int.tryParse(octets[0]);
    final int? second = int.tryParse(octets[1]);
    if (first == null || second == null) return false;
    if (first == 10) return true;
    if (first == 192 && second == 168) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    return false;
  }

  /// Asks one host for a credential. The host queues the request for on-screen
  /// confirmation and answers with a `pairing.grant` - possibly minutes later.
  ///
  /// Reports whether the datagram reached the socket, and counts both outcomes.
  /// That evidence is what tells "the request was never sent" from "it was sent
  /// and lost" - which is the whole question when the PC shows no dialog and
  /// the app cannot say why.
  ///
  /// The host keys pending requests by device id, so repeating this costs
  /// nothing on its side; callers are expected to repeat it, because the
  /// datagram itself has no protection against loss.
  bool requestPairing(
    HostEndpoint host, {
    required String deviceId,
    required String deviceName,
  }) {
    final RawDatagramSocket? socket = _socket;
    final InternetAddress? address = _parseIp(host.ip);
    if (socket == null || address == null) {
      _pairRefused++;
      return false;
    }
    final String json = Envelope.encode(
      type: Proto.pairRequest,
      payload: <String, dynamic>{
        'deviceId': deviceId,
        'deviceName': deviceName,
      },
    );
    final Uint8List bytes = Uint8List.fromList(utf8.encode(json));
    if (bytes.length > Proto.maxDatagramBytes) {
      _pairRefused++;
      return false;
    }
    try {
      if (socket.send(bytes, address, discoveryPort) != bytes.length) {
        _pairRefused++;
        return false;
      }
      _pairSent++;
      return true;
    } catch (_) {
      // A send can fail for more reasons than SocketException - a socket the
      // platform has already torn down reports a StateError - and every one of
      // them used to be swallowed here and surface as "the PC did not answer".
      _pairRefused++;
      return false;
    }
  }

  /// How the pairing sends went, sized for the waiting caption.
  String get pairDiagnostics => 'pair tx=$_pairSent err=$_pairRefused';

  /// Zeroes the pairing counters, so one pairing attempt reports only its own.
  void resetPairStats() {
    _pairSent = 0;
    _pairRefused = 0;
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
    _rx++;
    if (datagram.data.length > 4096) return;
    final Envelope? envelope = Envelope.tryDecode(utf8.decode(datagram.data));
    if (envelope == null) return;
    switch (envelope.type) {
      case Proto.lanOffer:
        _offersSeen++;
        _offer(envelope, datagram.address);
      case Proto.discoveryReply:
        _reply(envelope, datagram.address);
      case Proto.pairGrant:
        _grant(envelope, datagram.address);
      default:
        return;
    }
  }

  void _offer(Envelope envelope, InternetAddress source) {
    if (envelope.string('product') != Proto.hostProduct) return;
    final HostEndpoint? endpoint = _endpointOf(envelope, source);
    if (endpoint == null) return;
    _emit(DiscoveredHost(
      endpoint: endpoint,
      pairingOpen: envelope.boolean('pairingOpen') ?? false,
      knownPaired: false,
      seenAt: DateTime.now(),
    ));
  }

  void _reply(Envelope envelope, InternetAddress source) {
    if (envelope.string('product') != Proto.hostProduct) return;
    final HostEndpoint? endpoint = _endpointOf(envelope, source);
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
    final int? port = envelope.integer('webSocketPort');
    final bool approved = envelope.boolean('approved') ?? false;
    final String? secret = envelope.string('pairSecret');
    final String? address = _reachableAddress(envelope, source);

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
          ip: address ?? source.address,
          port: (port != null && port > 0 && port <= 65535) ? port : Proto.port,
        ),
        error: envelope.string('error'),
      ));
      return;
    }
    if (address == null || port == null || port <= 0 || port > 65535) {
      return;
    }
    _emitGrant(PairGrant(
      approved: true,
      endpoint: HostEndpoint(
        hostId: hostId!,
        hostName: envelope.string('hostName') ?? '',
        ip: address,
        port: port,
      ),
      secret: secret,
    ));
  }

  /// Builds an endpoint from a discovery response.
  ///
  /// The UDP peer address is authoritative here. Hosts frequently enumerate
  /// their adapters in a different order from the one that received the probe
  /// (Hyper-V, VPN and Docker adapters make this especially common on Windows).
  /// Their advertised `ip` can consequently be loopback, stale or on an
  /// unreachable interface. Rejecting an offer solely because of that field
  /// makes a perfectly valid response invisible; using it for the next packet
  /// makes pairing fail even after the host has appeared. A unicast response's
  /// source address is the only address proven reachable by this device, so it
  /// wins whenever it is IPv4. The advertised address remains a fallback for
  /// test transports that do not expose an IPv4 source.
  HostEndpoint? _endpointOf(Envelope envelope, InternetAddress source) {
    final String? hostId = envelope.string('hostId');
    final int? port = envelope.integer('webSocketPort');
    final String? address = _reachableAddress(envelope, source);
    if (!validHostId(hostId) || address == null) return null;
    if (port == null || port <= 0 || port > 65535) return null;
    return HostEndpoint(
      hostId: hostId!,
      hostName: envelope.string('hostName') ?? '',
      ip: address,
      port: port,
    );
  }

  /// Returns the response sender when it is an IPv4 address; see
  /// [_endpointOf] for why this deliberately outranks `payload.ip`.
  String? _reachableAddress(Envelope envelope, InternetAddress source) {
    if (source.type == InternetAddressType.IPv4 &&
        _parseIp(source.address) != null) {
      return source.address;
    }
    final String? advertised = envelope.string('ip');
    return advertised != null && _parseIp(advertised) != null
        ? advertised
        : null;
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

  /// The addresses a probe should be broadcast to: the limited broadcast
  /// address plus a `/24` guess for each local IPv4.
  ///
  /// Neither Android nor iOS exposes a netmask through `NetworkInterface`, and
  /// home / office Wi-Fi is overwhelmingly a `/24`, so the directed-broadcast
  /// guess is what makes discovery reliable on networks where
  /// `255.255.255.255` is filtered.
  List<InternetAddress> _broadcastFrom(List<InternetAddress> locals) {
    final List<InternetAddress> targets = <InternetAddress>[];
    try {
      targets.add(InternetAddress('255.255.255.255'));
    } on ArgumentError {
      // Never happens for a literal, kept for clarity.
    }
    for (final InternetAddress local in locals) {
      final List<String> octets = local.address.split('.');
      if (octets.length != 4) continue;
      final String directed = '${octets[0]}.${octets[1]}.${octets[2]}.255';
      if (targets.any((InternetAddress t) => t.address == directed)) continue;
      targets.add(InternetAddress(directed));
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
