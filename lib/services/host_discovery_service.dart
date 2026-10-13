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
    required this.lanCandidates,
    required this.usedFallback,
    required this.sweepTargets,
    required this.broadcastTargets,
    required this.sent,
    required this.refused,
    required this.phasesCut,
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

  /// The interfaces the bind was allowed to choose from, best first, as
  /// `name:address`.
  ///
  /// This is the field that answers "why that bind". A scan that was pinned to
  /// a Wi-Fi address while the phone was serving a hotspot, or that fell back
  /// to `0.0.0.0` because no LAN interface was recognised at all, looks
  /// identical from the counters alone.
  final List<String> lanCandidates;

  /// True when those addresses had to come from the TCP-connect fallback.
  final bool usedFallback;

  final int sweepTargets;
  final int broadcastTargets;

  /// Datagrams accepted by the OS send queue, and how many could not be queued.
  /// An accepted datagram is not proof that it reached the remote host.
  final int sent;
  final int refused;

  /// How many send phases stopped early because the socket stopped accepting.
  ///
  /// Non-zero is not a failure by itself - it is the sweep declining to keep
  /// pushing datagrams into a queue that is already refusing them, which is
  /// what used to turn one saturated socket into hundreds of dead sends. It is
  /// reported so a sweep that ended far short of [sweepTargets] can be told
  /// from a sweep that was never built.
  final int phasesCut;

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
        'lan: ${lanCandidates.isEmpty ? 'none usable' : lanCandidates.join(' ')}',
      )
      ..writeln(
        'interfaces: ${interfaces.isEmpty ? 'none' : interfaces.join(' ')}',
      )
      ..writeln(
        'subnets: ${locals.isEmpty ? 'none' : locals.join(' ')}'
        '${usedFallback ? ' (via TCP probe)' : ''}',
      )
      ..writeln(
        'targets: sweep=$sweepTargets broadcast=$broadcastTargets '
        'cut=$phasesCut',
      )
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
  /// Ordered by how much each field is worth, because a clipped caption keeps
  /// only its head: the send and receive counters first, then the size of the
  /// sweep they describe, then what the socket was bound to and which
  /// interfaces exist. The sweep size belongs that early - it is the difference
  /// between walking a `/24` that a `/28` link can only refuse and walking the
  /// thirteen addresses that link actually has, and telling those two apart
  /// from the counters alone means knowing both.
  String get compact =>
      'tx=$sent err=$refused z0=$sendWouldBlock ex=$sendExceptions '
      '${firstSendException == null ? '' : 'why=$firstSendException '}'
      'rx=$received offer=$offers '
      'swp=$sweepTargets cut=$phasesCut bc=$broadcastTargets '
      '| bind=$bound '
      'lan=${lanCandidates.isEmpty ? 'none' : lanCandidates.join(',')} '
      '| if=$interfaceNames '
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

/// Every IPv4 address one survey saw, split by whether its interface can carry
/// the LAN.
class _InterfaceSurvey {
  /// All of them, as `name:address`, for the report's interface line.
  final List<String> seen = <String>[];

  /// Private addresses on interfaces that can carry the LAN, best first.
  final List<_LanCandidate> lan = <_LanCandidate>[];

  /// Addresses rejected because their interface is a tunnel, a cellular slot or
  /// a peer-to-peer link. Kept so the outbound-probe fallback cannot hand back
  /// an address already known not to be the LAN.
  final Set<String> nonLan = <String>{};

  void note(String label) {
    if (!seen.contains(label)) seen.add(label);
  }
}

/// A bind candidate: the interface it came from and the address on it.
class _LanCandidate {
  const _LanCandidate(this.interfaceName, this.address);

  final String interfaceName;
  final InternetAddress address;

  String get label => '$interfaceName:${address.address}';
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
  Completer<void>? _writeReady;
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

  /// The LAN candidates the last survey found, best first. Reported, because a
  /// bind that picked the wrong interface and a bind that had nothing to pick
  /// from are otherwise the same silence.
  List<_LanCandidate> _lanSeen = const <_LanCandidate>[];
  List<InternetAddress> _sweepTargets = const <InternetAddress>[];
  List<InternetAddress> _broadcastTargets = const <InternetAddress>[];
  bool _usedProbeFallback = false;
  int _sent = 0;
  int _refused = 0;
  int _phasesCut = 0;
  int _sendWouldBlock = 0;
  int _sendExceptions = 0;
  String? _firstSendException;
  Future<void>? _probeTask;
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
    // We only subscribe for writability after send() says the socket would
    // block. A permanently enabled write subscription is one-shot and can
    // otherwise fire before the discovery sweep needs it.
    socket.writeEventsEnabled = false;
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

  /// Interface names that can never carry the LAN this app talks to.
  ///
  /// This is a **deny**-list on purpose. The bind used to accept `en*` and
  /// nothing else, which quietly excluded the interface a phone uses when it
  /// *serves* the network: an iPhone offering a personal hotspot reaches its
  /// clients over `bridge100` (or `ap1` on newer releases), never over `en0`.
  /// Measured on exactly that hotspot, at `bind=0.0.0.0 if=pdp_ip0 bridge100
  /// swp=506`: the bind had failed, the sweep walked the hotspot's `/24` plus
  /// the carrier's `10.x` `/24`, and 971 of 1012 sends were refused with the
  /// destination queue full. Not one probe reached the PC.
  ///
  /// An allow-list cannot be repaired by adding one name without excluding the
  /// next platform, so the filter now rejects only what is provably not the
  /// LAN:
  ///
  /// * `lo*` - loopback;
  /// * `utun*`, `ipsec*`, `tun*`, `ppp*` - VPN, relay and tethered tunnels;
  /// * `pdp*`, `rmnet*`, `ccmni*`, `clat*` - the cellular slots on iOS, Android
  ///   and Android's 464xlat, whose `10.x` addresses are carrier space that
  ///   [_isPrivateIpv4] cannot tell apart from a home LAN;
  /// * `awdl*`, `llw*`, `anpi*` - Apple's peer-to-peer and accessory links;
  /// * `p2p*` - Wi-Fi Direct;
  /// * `gif*`, `stf*`, `sit*`, `dummy*` - software placeholders.
  ///
  /// Everything else - `en*`, `ap*`, `bridge*`, Android's `wlan*` / `ap*` /
  /// `swlan*` / `rndis*` / `bt-pan` - is a candidate.
  static const List<String> _nonLanInterfacePrefixes = <String>[
    'lo',
    'utun',
    'ipsec',
    'tun',
    'ppp',
    'pdp',
    'rmnet',
    'ccmni',
    'clat',
    'awdl',
    'llw',
    'anpi',
    'p2p',
    'gif',
    'stf',
    'sit',
    'dummy',
  ];

  /// Whether [name] is an interface that can carry the LAN.
  static bool _isLanInterface(String name) {
    for (final String prefix in _nonLanInterfacePrefixes) {
      if (name.startsWith(prefix)) return false;
    }
    return true;
  }

  /// Orders two usable interfaces: Wi-Fi first, then the slot a personal
  /// hotspot is served from, then whatever else survived the filter.
  ///
  /// Wi-Fi keeps rank 0 because it is the interface every build so far was
  /// tested against, and a hotspot must not be allowed to change that. The
  /// hotspot ranks next because an iPhone serving one has no `en*` address at
  /// all - which is the entire case this ordering exists for.
  static int _lanRank(String name) {
    if (name.startsWith('en')) return 0;
    if (name.startsWith('bridge') || name.startsWith('ap')) return 1;
    return 2;
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
  /// Binding to a real LAN interface takes that decision away from the system.
  ///
  /// Which interface that is depends on how the phone is networked: `en0` while
  /// it is a Wi-Fi *client*, `bridge100` / `ap1` while it *serves* a personal
  /// hotspot. Both are accepted; see [_nonLanInterfacePrefixes] for why the
  /// filter rejects by name instead of accepting by name.
  ///
  /// Android reports a single `wlan0` and has no equivalent ambiguity, so it
  /// keeps the unbound socket and its traffic profile is untouched.
  Future<InternetAddress?> _preferredBindAddress() async {
    if (!Platform.isIOS) return null;
    final _InterfaceSurvey survey = await _surveyInterfaces();
    _lanSeen = survey.lan;
    return survey.lan.isEmpty ? null : survey.lan.first.address;
  }

  /// One pass over the platform's IPv4 interfaces, classified.
  ///
  /// Shared by the bind choice and the sweep so the two agree on what "the LAN"
  /// is. They disagreed once already: the socket was not pinned, so the sweep
  /// was built from every private address on the device while only one of them
  /// could carry a packet - and the subnet it could not reach is what filled
  /// the send queue.
  Future<_InterfaceSurvey> _surveyInterfaces() async {
    final _InterfaceSurvey survey = _InterfaceSurvey();
    try {
      final List<NetworkInterface> list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface interface in list) {
        final bool lan = _isLanInterface(interface.name);
        for (final InternetAddress address in interface.addresses) {
          survey.note('${interface.name}:${address.address}');
          if (!_isPrivateIpv4(address.address)) continue;
          if (lan) {
            survey.lan.add(_LanCandidate(interface.name, address));
          } else {
            survey.nonLan.add(address.address);
          }
        }
      }
    } catch (_) {
      // No interface list at all; the outbound probe is the whole plan.
    }
    survey.lan.sort((_LanCandidate a, _LanCandidate b) {
      final int rank =
          _lanRank(a.interfaceName).compareTo(_lanRank(b.interfaceName));
      if (rank != 0) return rank;
      return a.interfaceName.compareTo(b.interfaceName);
    });
    return survey;
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
  }) {
    final Future<void>? active = _probeTask;
    if (active != null) return active;

    // The connect controller schedules probes every 800 ms, but an iOS /24
    // sweep can take longer while the UDP socket is back-pressured. Do not let
    // Timer.periodic start overlapping sweeps on the same raw socket: they
    // compete for its send queue and can turn later sends into EWOULDBLOCK.
    // Callers share the in-flight round and still await its completion.
    late final Future<void> task;
    task = _probeOnce(
      deviceId: deviceId,
      deviceName: deviceName,
      pairedHostId: pairedHostId,
      lastKnownHostIp: lastKnownHostIp,
    ).whenComplete(() {
      if (identical(_probeTask, task)) _probeTask = null;
    });
    _probeTask = task;
    return task;
  }

  Future<void> _probeOnce({
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
    _broadcastTargets =
        Platform.isIOS ? const <InternetAddress>[] : _broadcastFrom(reachable);

    // The remembered host goes out early: on a reconnect that direct unicast is
    // both the likeliest to be delivered and the fastest.
    final InternetAddress? remembered = _parseIp(lastKnownHostIp ?? '');

    // It goes out *first*, before anything else has had a chance to fill the
    // send queue. On the hotspot this came from, that ordering was the whole
    // reason discovery failed: the sweep was 253 datagrams on a link whose
    // clients live in thirteen addresses, most of it was answered with a
    // refusal, and the remembered probe - the last send of the round - was
    // refused along with them. It made it out only on the rounds where its ARP
    // entry happened to be fresh, which is what "it finds the PC now and then"
    // actually was. [_sweepLimit] now shrinks that sweep to the size of the
    // link, but the order still has to hold: a round the platform decides to
    // back-pressure must not be able to spend the queue before the one datagram
    // a reconnect depends on.
    // Discovery without a remembered host is unaffected: the sweep and the
    // broadcast still run, just after this one datagram instead of before it.
    if (remembered != null) {
      await _phase(socket, <InternetAddress>[remembered], datagrams);
    }

    // iOS only - see [_sweepLocalSubnet]. The sweep carries the probe alone:
    // the directed `discovery.request` is already covered by the remembered
    // address above, and repeating it 254 times would be pure noise.
    if (_sweepLocalSubnet) {
      await _phase(socket, _sweepTargets, <String>[probe]);
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
  ///
  /// One thing does end it early: [_maxConsecutiveRefusals] datagrams in a row
  /// that the socket will not take. A refused send is the queue saying it is
  /// full, and a queue that is still full after the writability wait in
  /// [_waitUntilWritable] is not going to accept the remaining 200 either - on
  /// the hotspot this was measured on, 493 of 506 sends were refused that way.
  /// Pushing the rest in costs seconds of the scan window and buries the socket
  /// deeper, and every datagram after the first refusal is one the kernel would
  /// have to materialise an unreachable neighbour for. Stopping is not giving
  /// up on discovery: the destinations after the cut are exactly the ones the
  /// link could not deliver to anyway.
  Future<void> _phase(
    RawDatagramSocket socket,
    List<InternetAddress> targets,
    List<String> datagrams,
  ) async {
    int inBatch = 0;
    int refusedRun = 0;
    for (final InternetAddress target in targets) {
      if (refusedRun >= _maxConsecutiveRefusals) {
        _phasesCut++;
        return;
      }
      for (final String datagram in datagrams) {
        final Uint8List bytes = Uint8List.fromList(utf8.encode(datagram));
        if (bytes.length > Proto.maxDatagramBytes) continue;
        bool queued = false;
        bool wouldBlock = false;
        Object? sendException;
        bool shortWrite = false;
        for (int attempt = 0; attempt < 2; attempt++) {
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
            if (attempt == 0) await _waitUntilWritable(socket);
          } catch (error) {
            sendException = error;
            break;
          }
        }
        if (queued) {
          _sent++;
          refusedRun = 0;
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
            // Only the queue being full counts toward the cut: a destination
            // that throws is one address the link cannot reach, not a socket
            // that has stopped accepting.
            refusedRun++;
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
  static const Duration _writeWaitTimeout = Duration(milliseconds: 12);

  /// How many datagrams in a row the socket may refuse before a phase gives up.
  ///
  /// Reached only when the queue stays full across the writability wait, which
  /// takes [_writeWaitTimeout] per datagram - so the cut lands roughly a third
  /// of a second into a saturated socket. On a link that can take the traffic
  /// the queue drains as fast as the kernel transmits it, and a run this long
  /// never happens; on the hotspot the old code reached 493, and the datagrams
  /// past the cut are ones the link had no address for in the first place.
  static const int _maxConsecutiveRefusals = 32;

  Future<void> _waitUntilWritable(RawDatagramSocket socket) async {
    final Completer<void> ready = Completer<void>();
    _writeReady = ready;
    socket.writeEventsEnabled = true;
    try {
      await ready.future.timeout(_writeWaitTimeout);
    } on TimeoutException {
      // Record the subsequent send result as the definitive outcome.
    } finally {
      if (identical(_writeReady, ready)) _writeReady = null;
      socket.writeEventsEnabled = false;
    }
  }

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
        locals: _locals
            .map((InternetAddress a) => a.address)
            .toList(growable: false),
        bound: _boundTo?.address ?? InternetAddress.anyIPv4.address,
        lanCandidates: _lanSeen
            .map((_LanCandidate candidate) => candidate.label)
            .toList(growable: false),
        usedFallback: _usedProbeFallback,
        sweepTargets: _sweepTargets.length,
        broadcastTargets: _broadcastTargets.length,
        sent: _sent,
        refused: _refused,
        phasesCut: _phasesCut,
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
    _phasesCut = 0;
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

  /// The private IPv4 addresses of the LAN interfaces this device has.
  ///
  /// Only interfaces that can carry the LAN count, and that is decided by name
  /// in [_nonLanInterfacePrefixes], not by the address. iOS hands out several
  /// private addresses at once - Wi-Fi *or* the hotspot's bridge, a cellular
  /// slot, one `utun` per VPN - and the sweep is built per subnet, so every
  /// address kept here becomes 253 datagrams. The cellular slot was the one
  /// that hurt: `10.x` is carrier space, [_isPrivateIpv4] cannot tell it from a
  /// home LAN, and on the hotspot this was measured on it doubled the sweep
  /// (506 targets) and starved the queue until 971 of 1012 sends were refused.
  ///
  /// Which of the kept addresses the sweep actually walks is decided in
  /// [probeOnce]: only the interface the socket is bound to, because no other
  /// subnet is reachable from that source address anyway.
  ///
  /// The address is read from its dotted string rather than from `rawAddress`:
  /// a platform that reports a widened or mapped representation would make
  /// every `rawAddress.length != 4` check fail, and an empty sweep is
  /// indistinguishable from "no host answered".
  ///
  /// If the survey yields nothing - nothing guarantees the interface list
  /// reports the LAN at all - the outbound address is learned instead from a
  /// throwaway TCP connect, which the OS resolves through the normal routing
  /// table. An answer that the survey already rejected by interface name is
  /// discarded: on a phone whose default route is cellular, that probe replies
  /// with the carrier's `10.x`, and sweeping the carrier is worse than
  /// sweeping nothing.
  Future<List<InternetAddress>> _localAddresses() async {
    final _InterfaceSurvey survey = await _surveyInterfaces();
    _lanSeen = survey.lan;

    final List<InternetAddress> found = <InternetAddress>[];
    final Set<String> seen = <String>{};
    for (final _LanCandidate candidate in survey.lan) {
      if (seen.add(candidate.address.address)) found.add(candidate.address);
    }

    if (found.isEmpty) {
      for (final String host in const <String>[
        '223.5.5.5',
        '1.1.1.1',
        '8.8.8.8'
      ]) {
        try {
          final Socket socket = await Socket.connect(
            host,
            53,
            timeout: const Duration(milliseconds: 900),
          );
          final String address = socket.address.address;
          socket.destroy();
          survey.note('probe->$address');
          _usedProbeFallback = true;
          if (survey.nonLan.contains(address)) break;
          if (!_isPrivateIpv4(address) || !seen.add(address)) break;
          final InternetAddress? parsed = _parseIp(address);
          if (parsed != null) found.add(parsed);
          break;
        } catch (_) {
          // Offline or blocked; try the next well-known address.
        }
      }
    }

    _interfaces = List<String>.unmodifiable(survey.seen);
    return found;
  }

  /// The highest host number worth sweeping on [local]'s subnet.
  ///
  /// A sweep costs one datagram and one neighbour lookup per address, and an
  /// address the link has no route for buys nothing back: the send is refused
  /// once the queue fills and the ARP entry behind it can never resolve. An
  /// iPhone hotspot is the case that made this matter - it runs a `/28`, so
  /// clients get `172.20.10.2`-`172.20.10.14` and the other 240 addresses in
  /// its `/24` are not merely empty, they are unreachable. Measured on exactly
  /// that hotspot, `swp=253` produced `tx=13 err=493`: 97% of the sweep was
  /// spent refusing, and the datagram to the PC was queued behind all of it.
  ///
  /// The interface name is the honest signal - `bridge100` and `ap1` are
  /// Apple's hotspot interfaces and nothing else uses them - but the address
  /// identifies the same link on its own, and a `/28` sweep there is correct
  /// whichever way it is recognised. Everything else keeps the `/24`, so every
  /// network this app has ever worked on is swept exactly as before.
  ///
  /// The address test is deliberately the exact hotspot address rather than the
  /// whole `172.20.10.2`-`.14` band. That band is also what a *client* of an
  /// ordinary `172.20.10.0/24` network would be leased, and shrinking the sweep
  /// there would hide every host the router leased beyond `.14`. On the hotspot
  /// the address is `.1` because the bridge itself holds it; on a real network
  /// `.1` is the router, and nothing is ever leased it.
  static int _sweepLimit(InternetAddress local, String? interfaceName) {
    final bool hotspotInterface = interfaceName != null &&
        (interfaceName.startsWith('bridge') || interfaceName.startsWith('ap'));
    final List<String> octets = local.address.split('.');
    final bool hotspotAddress = octets.length == 4 &&
        octets[0] == '172' &&
        octets[1] == '20' &&
        octets[2] == '10' &&
        octets[3] == '1';
    return hotspotInterface || hotspotAddress ? 14 : 254;
  }

  /// The interface [address] came from, as the survey named it.
  ///
  /// The sweep needs it to size the subnet and the report already carries it;
  /// looking it up here keeps [_sweepFrom] a function of the addresses alone.
  String? _interfaceNameOf(InternetAddress address) {
    for (final _LanCandidate candidate in _lanSeen) {
      if (candidate.address.address == address.address) {
        return candidate.interfaceName;
      }
    }
    return null;
  }

  /// Every usable address of the local subnets, for the fallback above.
  ///
  /// One subnet per interface, never the interface's own address, and only in
  /// RFC 1918 space. Home and office Wi-Fi is overwhelmingly a `/24`, and the
  /// sweep only has to make *first-time* discovery work - a reconnect already
  /// tries the remembered address directly. The private-range test keeps a
  /// carrier address out here, and [_nonLanInterfacePrefixes] keeps the
  /// interface itself out of [locals] in the first place.
  ///
  /// The subnet is sized by [_sweepLimit] rather than assumed to be a `/24`:
  /// an iPhone hotspot hands out thirteen addresses and has no others, so
  /// walking 254 of them spends the socket's send budget on neighbours that do
  /// not exist - see [_sweepLimit].
  ///
  /// The result is round-robined across subnets: see [_interleaveBySubnet].
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
      final int lastHost = _sweepLimit(local, _interfaceNameOf(local));
      for (int host = 1; host <= lastHost; host++) {
        final String candidate = '$prefix.$host';
        if (own.contains(candidate) || !seen.add(candidate)) continue;
        targets.add(InternetAddress(candidate));
      }
    }

    // iOS may back-pressure the UDP socket before a whole /24 has been queued.
    // Try addresses closest to this device first; on DHCP home networks the PC
    // is often nearby in the lease range, and this avoids spending the limited
    // send capacity on distant guesses before trying the adjacent host.
    int nearestDistance(InternetAddress target) {
      final List<String> targetOctets = target.address.split('.');
      if (targetOctets.length != 4) return 255;
      final int? host = int.tryParse(targetOctets.last);
      if (host == null) return 255;
      int nearest = 255;
      for (final InternetAddress local in locals) {
        final List<String> localOctets = local.address.split('.');
        if (localOctets.length != 4 ||
            localOctets[0] != targetOctets[0] ||
            localOctets[1] != targetOctets[1] ||
            localOctets[2] != targetOctets[2]) {
          continue;
        }
        final int? localHost = int.tryParse(localOctets.last);
        if (localHost == null) continue;
        final int distance = (host - localHost).abs();
        if (distance < nearest) nearest = distance;
      }
      return nearest;
    }

    targets.sort((InternetAddress a, InternetAddress b) {
      final List<String> aOctets = a.address.split('.');
      final List<String> bOctets = b.address.split('.');
      final int aHost = int.parse(aOctets.last);
      final int bHost = int.parse(bOctets.last);
      final int distanceOrder =
          nearestDistance(a).compareTo(nearestDistance(b));
      if (distanceOrder != 0) return distanceOrder;
      if (aOctets[0] != bOctets[0] ||
          aOctets[1] != bOctets[1] ||
          aOctets[2] != bOctets[2]) {
        return a.address.compareTo(b.address);
      }
      // For equally close addresses, try the higher lease first. This puts
      // 192.168.1.10 immediately before .8 when this device is at .9.
      return bHost.compareTo(aHost);
    });
    return _interleaveBySubnet(targets);
  }

  /// Round-robins [targets] across the `/24`s they belong to, keeping the order
  /// inside each one.
  ///
  /// A sweep is budgeted by the socket, not by the clock: on the hotspot this
  /// was measured on, `send()` accepted 41 datagrams and refused the other 971.
  /// Ordering alone then decides whether the PC is among the 41, and a plain
  /// sort spends the whole budget inside whichever subnet sorts first - which
  /// on that phone was the carrier's, because `10.x` precedes `172.x` as a
  /// string. Interleaving guarantees every candidate subnet gets a share, so
  /// adding one unreachable interface can no longer hide the reachable one. On
  /// the single-subnet case (the common one, and the one the pinned bind
  /// produces) it returns the sorted list untouched.
  static List<InternetAddress> _interleaveBySubnet(
    List<InternetAddress> targets,
  ) {
    final Map<String, List<InternetAddress>> bySubnet =
        <String, List<InternetAddress>>{};
    for (final InternetAddress target in targets) {
      final List<String> octets = target.address.split('.');
      if (octets.length != 4) continue;
      final String subnet = '${octets[0]}.${octets[1]}.${octets[2]}';
      bySubnet.putIfAbsent(subnet, () => <InternetAddress>[]).add(target);
    }
    if (bySubnet.length < 2) return targets;

    // `putIfAbsent` preserved insertion order, and the input was sorted by
    // distance, so the subnet holding the nearest address is walked first.
    final List<List<InternetAddress>> groups =
        bySubnet.values.toList(growable: false);
    final List<InternetAddress> ordered = <InternetAddress>[];
    for (int index = 0;; index++) {
      bool progressed = false;
      for (final List<InternetAddress> group in groups) {
        if (index >= group.length) continue;
        ordered.add(group[index]);
        progressed = true;
      }
      if (!progressed) break;
    }
    return ordered;
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
    if (socket == null) return;
    if (event == RawSocketEvent.write) {
      socket.writeEventsEnabled = false;
      final Completer<void>? ready = _writeReady;
      _writeReady = null;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (event != RawSocketEvent.read) return;
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
    if (approved
        ? !is32Bytes(secret)
        : (envelope.string('error') ?? '').isEmpty) {
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
