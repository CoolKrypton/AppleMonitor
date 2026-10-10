/// The single source of truth for the UI.
///
/// Mirrors the timing model of `ui_service.c`, minus the firmware's own
/// smoothing pass - on the app the bars ease themselves with Flutter's
/// animation pipeline (`TweenAnimationBuilder`), so no 50 ms display tick is
/// needed:
///
/// * a 1 Hz tick refreshes the clock, drives the simulator and the connection
///   status text;
/// * **a stale link freezes the displayed values** - it never decays toward
///   zero, and resumes from the exact point it stopped at;
/// * the target snapshot triggers a refresh as soon as it actually changed.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/device_state.dart';
import '../models/pc_status.dart';
import 'gpu_selection_service.dart';
import 'mock_data_source.dart';

/// Number of history points behind the 60 s sparkline (`UI_DASHBOARD_HISTORY_POINTS`).
const int kDashboardHistoryPoints = 60;

/// Telemetry older than this marks the link stale (`telemetry_stale()`).
const Duration kStaleAfter = Duration(seconds: 5);

/// Where the snapshots come from.
enum TelemetrySourceKind {
  /// The built-in simulator - the app runs with no PC on the network.
  simulated,

  /// A live PCMonitorHost session over WebSocket.
  live,
}

class MonitorProvider extends ChangeNotifier {
  MonitorProvider({
    MockProfile profile = MockProfile.workstation,
    bool simulate = true,
    bool persistSelection = true,
  })  : _dataSource = MockDataSource(profile: profile),
        _kind = simulate ? TelemetrySourceKind.simulated : TelemetrySourceKind.live {
    _gpuSelection = GpuSelectionService(persist: persistSelection);
  }

  final MockDataSource _dataSource;
  TelemetrySourceKind _kind;
  late final GpuSelectionService _gpuSelection;

  /// Newest snapshot, straight off the wire (or the simulator). There is no
  /// second "display" copy any more - bars ease in the widget layer.
  PcStatus? _lastStatus;

  Timer? _slowTimer;

  DateTime? _mockLastSample;
  DateTime? _receivedAt;

  /// Status line and badge published by the host link, so the status bar keeps
  /// reading from one place regardless of where the data is coming from.
  String? _linkStatusText;
  ConnectionKind _linkKind = ConnectionKind.waiting;

  /// The 60 s rolling window feeding the dashboard sparklines. `null` entries
  /// are invalid points and are rendered as gaps, matching `LV_CHART_POINT_NONE`.
  final List<double?> _cpuHistory = <double?>[];
  final List<double?> _gpuHistory = <double?>[];

  /// Per-adapter 60 s windows keyed by `protocol_id`, feeding the curves on the
  /// GPU device list. Unlike [_gpuHistory] these are never cleared by an
  /// adapter switch - every card owns its own continuous series.
  final Map<String, List<double?>> _gpuHistories = <String, List<double?>>{};

  /// protocol id currently feeding the GPU sparkline. A change clears history.
  String _historyGpuId = '';

  // Target-side (unsmoothed) cached values used by the text layer.
  int _cpuUsageTarget = 0;
  bool _cpuUsageTargetValid = false;
  int _gpuUsageTarget = 0;
  bool _gpuUsageTargetValid = false;

  /// Whether the last user-triggered navigation left a GPU detail page open.
  String _openGpuId = '';

  DeviceState _deviceState = DeviceState.connected;

  bool _disposed = false;

  // -------------------------------------------------------------------------
  // accessors
  // -------------------------------------------------------------------------

  /// Newest snapshot straight off the wire. Text layers read this.
  PcStatus get target => _lastStatus ?? _dataSource.status;

  /// The snapshot the UI renders. Bars now ease themselves with
  /// [TweenAnimationBuilder], so there is no algorithmically smoothed copy
  /// any more - this is simply the newest snapshot. Kept as an alias so the
  /// screens do not need a mechanical rename.
  PcStatus get display => target;

  bool get hasData => target.received;

  bool get isSimulated => _kind == TelemetrySourceKind.simulated;

  /// True when the link is live but no sample arrived within [kStaleAfter].
  bool get isStale {
    final DateTime? at = _receivedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > kStaleAfter;
  }

  List<double?> get cpuHistory => List<double?>.unmodifiable(_cpuHistory);
  List<double?> get gpuHistory => List<double?>.unmodifiable(_gpuHistory);

  /// The 60 s window belonging to one adapter (empty when it has never been
  /// sampled). Used by the GPU device list.
  List<double?> gpuHistoryFor(String protocolId) => List<double?>.unmodifiable(
        _gpuHistories[protocolId] ?? const <double?>[],
      );

  GpuSelectionService get gpuSelection => _gpuSelection;

  /// The adapter the dashboard renders. Decoupled from the open detail page.
  GpuStatus? get selectedGpu => _gpuSelection.selected(target);

  int get selectedGpuIndex => _gpuSelection.selectedIndex(target);

  /// The engine the dashboard reads. All dashboard GPU numbers - value, bar and
  /// sparkline - must come from this single engine.
  GpuEngine? get selectedEngine => PcStatus.busiestEngine(selectedGpu);

  String? get openGpuId => _openGpuId.isEmpty ? null : _openGpuId;

  int? get openGpuIndex {
    final String? id = openGpuId;
    if (id == null) return null;
    final GpuStatus? gpu = target.findGpu(id);
    if (gpu == null) return null;
    return target.gpus.indexOf(gpu);
  }

  /// Port of the `ui_service.c` status-text derivation, extended with the live
  /// link's own wording while the app is talking to a PC.
  String get statusText {
    if (isSimulated) return 'SIMULATED / 1 Hz';
    final String? link = _linkStatusText;
    if (link != null) return link;
    if (_deviceState == DeviceState.connected && isStale) return 'Data stale';
    return deviceStateText(_deviceState);
  }

  ConnectionKind get connectionKind {
    if (isSimulated) return ConnectionKind.simulated;
    return _linkKind;
  }

  String get connectionLabel => connectionBadge(connectionKind);

  /// Snapshot used for the CPU big number. Taken from target so a new sample
  /// lands instantly instead of easing in.
  int get cpuUsageTarget => _cpuUsageTarget;
  bool get cpuUsageTargetValid => _cpuUsageTargetValid;
  int get gpuUsageTarget => _gpuUsageTarget;
  bool get gpuUsageTargetValid => _gpuUsageTargetValid;

  // -------------------------------------------------------------------------
  // lifecycle
  // -------------------------------------------------------------------------

  Future<void> start() async {
    await _gpuSelection.load();
    _seedMock();
    notifyListeners();

    _slowTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// Switches between the simulator and the live host link.
  ///
  /// History is dropped on every switch: splicing a mock series onto a real
  /// one would draw a curve that never happened.
  void useSimulation(bool simulate) {
    final TelemetrySourceKind next =
        simulate ? TelemetrySourceKind.simulated : TelemetrySourceKind.live;
    if (_kind == next) return;
    _kind = next;
    _resetStream();
    if (simulate) _seedMock();
    notifyListeners();
  }

  /// Feeds one live `telemetry.snapshot` into the display pipeline.
  ///
  /// Called by the host link at whatever cadence the PC broadcasts - 1 Hz by
  /// default. Widgets animate toward the new values on their own tickers, so
  /// no intermediate stepping happens here.
  void pushSnapshot(PcStatus status) {
    if (isSimulated) return;
    _receivedAt = DateTime.now();
    _lastStatus = status;
    _cacheTargetValues(status);
    _pushHistory(status);
    notifyListeners();
  }

  /// Publishes the host link's status line, so the status bar has a single
  /// source no matter which transport is feeding it.
  void updateLinkStatus({required String text, required ConnectionKind kind}) {
    if (_linkStatusText == text && _linkKind == kind) return;
    _linkStatusText = text;
    _linkKind = kind;
    notifyListeners();
  }

  void _resetStream() {
    _lastStatus = null;
    _receivedAt = null;
    _mockLastSample = null;
    _cpuHistory.clear();
    _gpuHistory.clear();
    _gpuHistories.clear();
    _historyGpuId = '';
    _cpuUsageTarget = 0;
    _cpuUsageTargetValid = false;
    _gpuUsageTarget = 0;
    _gpuUsageTargetValid = false;
    _openGpuId = '';
  }

  @override
  void dispose() {
    _disposed = true;
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // -------------------------------------------------------------------------
  // navigation (ported from ui_app.c)
  // -------------------------------------------------------------------------

  /// `ui_app_show_gpu(index)` records the open adapter identity.
  void openGpuAt(int index) {
    final GpuStatus? gpu = target.gpuAt(index);
    if (gpu == null) {
      _openGpuId = '';
      return;
    }
    _openGpuId = gpu.protocolId;
    notifyListeners();
  }

  /// Picking an adapter in the device list both promotes it to dashboard
  /// adapter AND opens its detail page - one tap, two effects, exactly like
  /// `choose_gpu()` in `ui_gpu_detail.c`.
  Future<void> chooseGpu(int index) async {
    final GpuStatus? gpu = target.gpuAt(index);
    if (gpu == null) return;
    await _gpuSelection.select(gpu.protocolId);
    _openGpuId = gpu.protocolId;
    notifyListeners();
  }

  /// `ui_app_show_gpus()` short-circuits straight to the detail page when the
  /// host reports exactly one adapter.
  int? singleGpuShortcut() => target.gpuCount == 1 ? 0 : null;

  void clearOpenGpu() {
    _openGpuId = '';
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // data
  // -------------------------------------------------------------------------

  void _seedMock() {
    if (!isSimulated) return;
    final PcStatus first = _dataSource.status;
    _lastStatus = first;
    _receivedAt = DateTime.now();
    _mockLastSample = DateTime.now();
    _pushHistory(first);
    _cacheTargetValues(first);
  }

  /// The one and only periodic tick: advances the simulator at 1 Hz and
  /// refreshes the clock / stale badge. Bar easing lives in the framework.
  void _tick() {
    if (isSimulated) {
      final DateTime now = DateTime.now();
      final DateTime? last = _mockLastSample;
      if (last == null || now.difference(last).inMilliseconds >= 1000) {
        _mockLastSample = now;
        final PcStatus next = _dataSource.step();
        _lastStatus = next;
        _receivedAt = now;
        _cacheTargetValues(next);
        _pushHistory(next);
      }
    }
    notifyListeners();
  }

  void _cacheTargetValues(PcStatus status) {
    _cpuUsageTargetValid = status.cpuUsageValid;
    _cpuUsageTarget = status.cpuUsage;

    final GpuStatus? gpu = _gpuSelection.selected(status);
    final GpuEngine? engine = PcStatus.busiestEngine(gpu);
    if (engine != null) {
      _gpuUsageTargetValid = engine.usageValid;
      _gpuUsageTarget = engine.usage;
    } else {
      _gpuUsageTargetValid = gpu?.usageValid ?? false;
      _gpuUsageTarget = gpu?.usage ?? 0;
    }
  }

  void _pushHistory(PcStatus status) {
    final GpuStatus? gpu = _gpuSelection.selected(status);
    final GpuEngine? engine = PcStatus.busiestEngine(gpu);
    final String gpuId = gpu?.protocolId ?? '';

    // Switching adapters must never splice two unrelated series together.
    if (gpuId != _historyGpuId) {
      _historyGpuId = gpuId;
      _cpuHistory.clear();
      _gpuHistory.clear();
      _cpuHistory.addAll(List<double?>.filled(kDashboardHistoryPoints, null));
      _gpuHistory.addAll(List<double?>.filled(kDashboardHistoryPoints, null));
    }

    _cpuHistory.add(status.cpuUsageValid ? status.cpuUsage.toDouble() : null);
    _gpuHistory.add(
      engine != null && engine.usageValid ? engine.usage.toDouble() : null,
    );

    while (_cpuHistory.length > kDashboardHistoryPoints) {
      _cpuHistory.removeAt(0);
    }
    while (_gpuHistory.length > kDashboardHistoryPoints) {
      _gpuHistory.removeAt(0);
    }

    // Every adapter gets a window of its own so the device list can draw a
    // curve per card. These are deliberately independent of the switch above.
    for (final GpuStatus adapter in status.gpus) {
      final String id = adapter.protocolId;
      if (id.isEmpty) continue;
      // growable: true is load-bearing. List.filled defaults to a fixed
      // length, so the series.add(...) below threw UnsupportedError on the
      // first adapter - leaving that adapter stuck with an all-null window
      // (grid but no curve on its card) and aborting the loop before the
      // remaining adapters ever got a window at all (completely blank cards).
      final List<double?> series = _gpuHistories.putIfAbsent(
        id,
        () => List<double?>.filled(kDashboardHistoryPoints, null, growable: true),
      );
      series.add(plotValueFor(adapter));
      while (series.length > kDashboardHistoryPoints) {
        series.removeAt(0);
      }
    }
  }

  /// The value the device list plots for one adapter: its **adapter-level
  /// total utilisation**.
  ///
  /// The device list compares whole adapters, so every visual on a card - the
  /// headline number, the bar and the 60 s curve - reads from this single
  /// source. It deliberately does NOT use the busiest engine any more: a card
  /// labelled "PEAK: 3D" made the number, the bar and the curve disagree with
  /// the adapter the user actually picked.
  static double? plotValueFor(GpuStatus gpu) {
    return gpu.usageValid ? gpu.usage.toDouble() : null;
  }

  /// Sets the simulated connection state, for demoing the status badge.
  void setDeviceState(DeviceState state) {
    _deviceState = state;
    notifyListeners();
  }

  /// Replaces the history with a flat line, used when the widget tree is first
  /// laid out so the sparkline starts from a defined baseline.
  void primeHistory(PcStatus status) {
    if (_cpuHistory.length >= kDashboardHistoryPoints) return;
    _pushHistory(status);
  }
}

/// Lightweight average used by the sparkline when a series is mostly gaps.
double? averageOf(Iterable<double?> values) {
  double sum = 0;
  int count = 0;
  for (final double? value in values) {
    if (value == null || !value.isFinite) continue;
    sum += value;
    count++;
  }
  if (count == 0) return null;
  return sum / count;
}

/// Convenience for tests and previews.
double mhzToGhz(num megahertz) => megahertz.toDouble() / 1000.0;

/// Clamp helper shared by the chart painters.
double clamp01(double value) => math.min(1.0, math.max(0.0, value));
