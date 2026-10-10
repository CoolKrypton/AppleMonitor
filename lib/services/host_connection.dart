/// The connection state machine: find a PC, pair with it, stay connected.
///
/// This is the Android counterpart of the firmware's
/// `discovering_host -> connecting_host -> authenticating -> connected` chain in
/// `device_state.c`, with the same rule that matters most in practice: a pairing
/// survives an address change, so the app re-discovers its host instead of
/// asking the user to pair again when the router hands out a new lease.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/device_state.dart';
import '../models/pc_status.dart';
import 'host_discovery_service.dart';
import 'host_link.dart';
import 'pairing_store.dart';
import 'protocol.dart';

/// What the connect screen is currently showing.
enum HostConnectionState {
  /// Nothing has happened yet.
  idle,

  /// Probing the LAN.
  scanning,

  /// A scan finished and at least one host is listed.
  found,

  /// A pair request is on the PC's screen, waiting for the user to click it.
  requesting,

  /// The WebSocket handshake is running.
  connecting,

  /// Streaming telemetry.
  online,

  /// Was online, lost the link, retrying.
  offline,

  /// The last action failed and the user needs to do something.
  failed,
}

class HostConnectionController extends ChangeNotifier {
  HostConnectionController({
    required PairingStore store,
    HostDiscoveryService? discovery,
    this.onSnapshot,
  }) : _store = store,
       _discovery = discovery ?? HostDiscoveryService();

  final PairingStore _store;
  final HostDiscoveryService _discovery;

  /// Where telemetry goes. Replaced whenever the link reconnects.
  void Function(PcStatus status)? onSnapshot;

  // -------------------------------------------------------------------------
  // observable state
  // -------------------------------------------------------------------------

  HostConnectionState _state = HostConnectionState.idle;
  HostConnectionState get state => _state;

  List<DiscoveredHost> _hosts = <DiscoveredHost>[];
  List<DiscoveredHost> get hosts => List<DiscoveredHost>.unmodifiable(_hosts);

  PairedHost? _paired;
  PairedHost? get pairedHost => _paired;

  String _deviceId = '';
  String get deviceId => _deviceId;

  String _deviceName = _platformMonitorName;
  String get deviceName => _deviceName;

  String _message = 'Not connected';
  String get message => _message;

  String? _error;
  String? get error => _error;

  /// The host a pair request is currently pending with.
  HostEndpoint? _pending;
  HostEndpoint? get pendingHost => _pending;

  /// True while a `pairing.request` is waiting for the PC's confirmation.
  bool get awaitingConfirmation => _state == HostConnectionState.requesting;

  double _brightnessPercent = 100;
  double get brightnessPercent => _brightnessPercent;

  /// The dimming the shell applies, mirroring what `device.settings.set`
  /// controls on the firmware's backlight. Capped so the screen never goes
  /// fully black and traps the user.
  double get dimOverlay => (1.0 - _brightnessPercent / 100.0) * 0.7;

  HostLink? _link;
  bool get isOnline => _state == HostConnectionState.online;
  String? get activeHostName => _link?.endpoint?.hostName ?? _paired?.endpoint.hostName;

  bool _disposed = false;
  bool _started = false;
  bool _autoReconnect = true;
  Timer? _scanTimer;
  Timer? _retryTimer;
  Timer? _pairTimeout;
  int _scanTicks = 0;
  int _retryAttempt = 0;
  StreamSubscription<DiscoveredHost>? _hostSubscription;
  StreamSubscription<PairGrant>? _grantSubscription;
  Completer<PairGrant>? _pendingGrant;
  bool _connecting = false;

  // -------------------------------------------------------------------------
  // lifecycle
  // -------------------------------------------------------------------------

  /// Loads identity + credentials and, when a pairing exists, starts chasing it.
  Future<void> start({bool autoReconnect = true}) async {
    if (_started) return;
    _started = true;
    _autoReconnect = autoReconnect;

    _deviceId = await _store.loadOrCreateDeviceId();
    // A stored name wins (the user renamed the device); otherwise the phone's
    // own model name is what the host dialog should show; the synthetic
    // "iOS Monitor xxxx" is only the last-resort fallback.
    _deviceName = await _store.loadDeviceName() ??
        await _platformDeviceName() ??
        _defaultDeviceName();
    _paired = await _store.loadPairedHost();

    try {
      await _discovery.start();
    } catch (_) {
      // A socket that cannot be opened is reported by the scan that follows,
      // not here: start() must still publish the paired-host state.
    }
    _hostSubscription = _discovery.onHost.listen(_onHostSeen);
    _grantSubscription = _discovery.onGrant.listen(_onGrant);

    if (_paired != null) {
      _setState(HostConnectionState.offline, 'Reconnecting to ${_paired!.endpoint.hostName}');
      _scheduleRetry(immediate: true);
    } else {
      _setState(HostConnectionState.idle, 'No PC paired');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
    _retryTimer?.cancel();
    _pairTimeout?.cancel();
    _hostSubscription?.cancel();
    _grantSubscription?.cancel();
    _link?.close();
    _discovery.dispose();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // -------------------------------------------------------------------------
  // scanning
  // -------------------------------------------------------------------------

  /// Runs one discovery window. Safe to call while one is already running.
  Future<void> scan({Duration window = const Duration(seconds: 4)}) async {
    try {
      await _discovery.start();
    } catch (_) {
      // Reported through the failure message below, never thrown at the caller.
    }
    _scanTimer?.cancel();
    _hosts = <DiscoveredHost>[];
    _scanTicks = 0;
    _discovery.resetStats();
    _setState(HostConnectionState.scanning, 'Scanning the local network');

    // Several rounds inside the window: UDP is lossy even on a quiet LAN, a
    // probe is 200 bytes, and every round reshuffles the sweep order.
    final int ticks = (window.inMilliseconds / 800).ceil();
    Future<void> probe() async {
      _scanTicks++;
      try {
        await _discovery.probeOnce(
          deviceId: _deviceId,
          deviceName: _deviceName,
          pairedHostId: _paired?.endpoint.hostId,
          lastKnownHostIp: _paired?.endpoint.ip,
        );
      } catch (_) {
        // A round that cannot send must not end the window: the remaining
        // rounds still get their turn, so one refusal cannot look like a
        // finished scan.
      }
      if (_scanTicks >= ticks) {
        _scanTimer?.cancel();
        _scanTimer = null;
        if (_hosts.isEmpty) {
          _fail(_emptyScanMessage());
        } else {
          _setState(HostConnectionState.found, '${_hosts.length} PC${_hosts.length == 1 ? '' : 's'} found');
        }
      }
    }

    await probe();
    _scanTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => probe(),
    );
    notifyListeners();
  }

  /// Why a scan came back empty, said differently per platform.
  ///
  /// On iOS the transport fails silently, so the counters go in front where a
  /// two-line caption cannot ellipsize them away, followed by the one setting
  /// that is worth checking. On Android the app side is rarely at fault, so the
  /// message points at the host instead.
  String _emptyScanMessage() {
    if (!Platform.isIOS) {
      return 'No PC found. Check that PCMonitorHost is running and that '
          '"LAN pairing" is enabled in its settings.';
    }
    return 'No PC found. ${_discovery.lastReport.compact} | Allow PC Monitor '
        'under Settings > Privacy & Security > Local Network, and enable '
        '"LAN pairing" on the PC.';
  }

  void _onHostSeen(DiscoveredHost host) {
    final int index = _hosts.indexWhere((DiscoveredHost h) => h.key == host.key);
    if (index >= 0) {
      final DiscoveredHost previous = _hosts[index];
      // Keep the address that most recently answered.
      _hosts[index] = host.refreshed(
        pairingOpen: previous.pairingOpen || host.pairingOpen,
        knownPaired: previous.knownPaired || host.knownPaired,
      );
    } else {
      _hosts = <DiscoveredHost>[..._hosts, host];
    }
    if (_state == HostConnectionState.scanning ||
        _state == HostConnectionState.found) {
      _state = HostConnectionState.found;
      _message = '${_hosts.length} PC${_hosts.length == 1 ? '' : 's'} found';
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // pairing
  // -------------------------------------------------------------------------

  /// Pairs with [host] (asks the PC for confirmation) or connects straight away
  /// when the secret is already held.
  Future<void> select(DiscoveredHost host) async {
    _error = null;
    final PairedHost? paired = _paired;
    if (host.knownPaired ||
        (paired != null && paired.endpoint.hostId == host.endpoint.hostId)) {
      await connectTo(host.endpoint, secret: paired?.secretBase64);
      return;
    }
    await requestPairing(host);
  }

  /// Sends a `pairing.request` and waits for the PC's user to approve it.
  Future<void> requestPairing(DiscoveredHost host) async {
    _pending = host.endpoint;
    _setState(
      HostConnectionState.requesting,
      'Waiting for confirmation on ${host.endpoint.hostName}',
    );
    final Completer<PairGrant> completer = Completer<PairGrant>();
    _pendingGrant = completer;
    _discovery.requestPairing(
      host.endpoint,
      deviceId: _deviceId,
      deviceName: _deviceName,
    );

    // The host keeps the request queued until its user answers, so this waits
    // far longer than a scan round: it is a human clicking a dialog.
    _pairTimeout?.cancel();
    _pairTimeout = Timer(const Duration(seconds: 90), () {
      if (!completer.isCompleted) {
        completer.completeError(HostLinkException('timed out'));
      }
    });
    notifyListeners();

    try {
      final PairGrant grant = await completer.future;
      if (grant.approved) {
        await _acceptGrant(grant);
      } else {
        _fail(grant.error == 'refused'
            ? 'The PC refused the pairing request.'
            : 'Pairing was not approved.');
      }
    } on HostLinkException {
      _fail('No confirmation from the PC. Try again.');
    } finally {
      _pairTimeout?.cancel();
      _pairTimeout = null;
      _pendingGrant = null;
      _pending = null;
    }
  }

  void _onGrant(PairGrant grant) {
    final HostEndpoint? pending = _pending;
    // A grant is unicast, but only the host we actually asked may answer.
    if (pending != null && pending.hostId != grant.endpoint.hostId) return;
    final Completer<PairGrant>? completer = _pendingGrant;
    if (completer != null && !completer.isCompleted) {
      completer.complete(grant);
    }
  }

  Future<void> _acceptGrant(PairGrant grant) async {
    final String? secret = grant.secret;
    if (secret == null) {
      _fail('The PC sent an incomplete credential.');
      return;
    }
    final PairedHost paired = PairedHost(
      endpoint: grant.endpoint,
      secretBase64: secret,
    );
    _paired = paired;
    await _store.savePairedHost(paired);
    await connectTo(grant.endpoint, secret: secret);
  }

  // -------------------------------------------------------------------------
  // connecting
  // -------------------------------------------------------------------------

  Future<void> connectTo(HostEndpoint endpoint, {String? secret}) async {
    final String? credential = secret ?? _paired?.secretBase64;
    if (credential == null) {
      _fail('No credential for this PC. Pair with it first.');
      return;
    }
    await _attempt(endpoint, credential, manual: true);
  }

  /// Reconnects to the stored host, without a scan when its address still works.
  Future<void> reconnect() async {
    final PairedHost? paired = _paired;
    if (paired == null) return;
    _retryAttempt = 0;
    await _attempt(paired.endpoint, paired.secretBase64, manual: true);
  }

  Future<void> _attempt(
    HostEndpoint endpoint,
    String secret, {
    required bool manual,
  }) async {
    if (_connecting) return;
    _connecting = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _link?.close();
    _link = null;
    _setState(HostConnectionState.connecting, 'Connecting to ${endpoint.hostName}');

    final HostLink link = HostLink(
      onSnapshot: (PcStatus status) => onSnapshot?.call(status),
      onSettings: _onSettings,
      onRemoved: () {},
      onClosed: _onClosed,
    );
    link.localIp = await _localIp();

    try {
      await link.connect(
        endpoint: endpoint,
        deviceId: _deviceId,
        secretBase64: secret,
      );
    } on HostLinkException catch (e) {
      _connecting = false;
      if (e.authenticationFailed) {
        // The PC no longer knows this secret: it was removed there, or the
        // registry was reset. Drop it rather than retrying forever.
        await _forget(silent: true);
        _fail('${e.message} The stored pairing was discarded.');
        return;
      }
      if (manual) _fail('Could not connect to ${endpoint.hostName}: ${e.message}');
      // Otherwise stay quiet: an automatic retry that fails is expected while
      // the PC is asleep, and flashing an error every 5 s would be noise.
      notifyListeners();
      _scheduleRetry();
      return;
    }

    _connecting = false;
    _link = link;
    _retryAttempt = 0;
    // Refresh the stored address: a DHCP lease change must not cost a re-pair.
    final PairedHost paired = PairedHost(endpoint: endpoint, secretBase64: secret);
    if (_paired == null || _paired!.endpoint.ip != endpoint.ip) {
      _paired = paired;
      await _store.savePairedHost(paired);
    }
    _setState(HostConnectionState.online, 'Connected to ${endpoint.hostName}');
  }

  void _onSettings(double brightnessPercent) {
    _brightnessPercent = brightnessPercent;
    notifyListeners();
  }

  void _onClosed(HostLinkCloseReason reason, String message) {
    _link = null;
    if (reason == HostLinkCloseReason.pairingRemoved) {
      _forget(silent: true).then((_) {
        _fail('The PC removed this pairing.');
      });
      return;
    }
    if (!_autoReconnect) {
      _setState(HostConnectionState.offline, 'Disconnected');
      return;
    }
    _setState(HostConnectionState.offline, 'Link lost - retrying');
    _scheduleRetry(immediate: true);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // retry
  // -------------------------------------------------------------------------

  void _scheduleRetry({bool immediate = false}) {
    if (!_autoReconnect || _disposed) return;
    _retryTimer?.cancel();
    final int seconds = immediate ? 1 : (1 << (_retryAttempt.clamp(0, 3)));
    _retryAttempt++;
    _retryTimer = Timer(Duration(seconds: seconds), _retryTick);
  }

  Future<void> _retryTick() async {
    if (_disposed || !_autoReconnect) return;
    final PairedHost? paired = _paired;
    if (paired == null) return;

    // Every third attempt re-scans: if the PC moved to a new IP, only a reply
    // to `discovery.request` can tell us where it went.
    if (_retryAttempt % 3 == 0) {
      await _discovery.probeOnce(
        deviceId: _deviceId,
        deviceName: _deviceName,
        pairedHostId: paired.endpoint.hostId,
        lastKnownHostIp: paired.endpoint.ip,
      );
      if (_disposed) return;
      final PairedHost current = _paired ?? paired;
      await _attempt(current.endpoint, current.secretBase64, manual: false);
      return;
    }
    await _attempt(paired.endpoint, paired.secretBase64, manual: false);
  }

  // -------------------------------------------------------------------------
  // teardown
  // -------------------------------------------------------------------------

  /// Ends the session but keeps the pairing, so one tap reconnects.
  Future<void> disconnect() async {
    _autoReconnect = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _link?.close();
    _link = null;
    _setState(HostConnectionState.idle, 'Disconnected');
  }

  /// Forgets the pairing entirely - the Android equivalent of the firmware's
  /// `pairing.remove`, done locally because the host may be unreachable.
  Future<void> forget() => _forget(silent: false);

  Future<void> _forget({required bool silent}) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _pendingGrant?.completeError(HostLinkException('forgotten'));
    await _link?.close();
    _link = null;
    _paired = null;
    await _store.clearPairedHost();
    _hosts = <DiscoveredHost>[];
    _setState(HostConnectionState.idle, 'No PC paired');
    if (!silent) notifyListeners();
  }

  /// Resumes automatic retries after [disconnect].
  void resumeAutoReconnect() {
    _autoReconnect = true;
    if (_paired != null && _state != HostConnectionState.online) {
      _scheduleRetry(immediate: true);
    }
  }

  Future<void> setDeviceName(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _deviceName) return;
    _deviceName = trimmed;
    await _store.saveDeviceName(trimmed);
    // Re-announce so the PC's pending dialog shows the new name.
    if (_pending != null) {
      _discovery.requestPairing(
        _pending!,
        deviceId: _deviceId,
        deviceName: _deviceName,
      );
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // helpers
  // -------------------------------------------------------------------------

  /// The phone's own address, sent to the host in `device.status`.
  Future<String?> _localIp() async {
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress address in interface.addresses) {
          return address.address;
        }
      }
    } on SocketException {
      return null;
    }
    return null;
  }

  String _defaultDeviceName() {
    final String suffix = _deviceId.length >= 8
        ? _deviceId.substring(_deviceId.length - 4).toUpperCase()
        : '0000';
    return '$_platformMonitorName $suffix';
  }

  /// Product + platform, the shape `MainActivity`'s fallback uses. It has to be
  /// platform-aware rather than a fixed "Android Monitor": the name is written
  /// into the store and shown in the PC's pairing dialog, so an iPhone must not
  /// introduce itself as an Android one.
  static String get _platformMonitorName {
    if (Platform.isIOS) return 'iOS Monitor';
    if (Platform.isAndroid) return 'Android Monitor';
    return 'PC Monitor';
  }

  /// The phone's own name ("Huawei P10" style, "John's iPhone" style) from the
  /// platform side - `MainActivity.deviceName()` on Android,
  /// `AppDelegate.deviceName()` on iOS. Returns null on any failure - tests,
  /// unsupported platforms, revoked channels - so the caller falls back to the
  /// synthetic name.
  static const MethodChannel _deviceChannel =
      MethodChannel('pcmonitor/device');

  Future<String?> _platformDeviceName() async {
    try {
      final String? name =
          await _deviceChannel.invokeMethod<String>('deviceName');
      final String trimmed = name?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The firmware state the current link maps onto, so the status bar keeps
  /// speaking the same vocabulary it always has.
  DeviceState get deviceState {
    switch (_state) {
      case HostConnectionState.idle:
        return DeviceState.unprovisioned;
      case HostConnectionState.scanning:
        return DeviceState.discoveringHost;
      case HostConnectionState.found:
        return DeviceState.discoveringHost;
      case HostConnectionState.requesting:
        return DeviceState.authenticating;
      case HostConnectionState.connecting:
        return DeviceState.connectingHost;
      case HostConnectionState.online:
        return DeviceState.connected;
      case HostConnectionState.offline:
        return DeviceState.hostOffline;
      case HostConnectionState.failed:
        return DeviceState.error;
    }
  }

  void _setState(HostConnectionState state, String message) {
    _state = state;
    _message = message;
    if (state != HostConnectionState.failed) _error = null;
    notifyListeners();
  }

  void _fail(String message) {
    _state = HostConnectionState.failed;
    _error = message;
    _message = message;
    notifyListeners();
  }
}
