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

/// The span every sparkline covers, whatever cadence the host broadcasts at.
///
/// The firmware holds 60 samples and calls that "60 s", which is only true for
/// its own 1 Hz feed. A host sending 4 Hz would fill the same 60 slots in 15 s:
/// the plot would still be labelled 60 s while showing a quarter of it. So the
/// window is a *duration*, and the number of points behind it is derived from
/// the host's measured interval.
const Duration kHistoryWindow = Duration(seconds: 60);

/// Points the window holds at the host's default 1 Hz
/// (`UI_DASHBOARD_HISTORY_POINTS`), and the value every window starts at.
const int kDashboardHistoryPoints = 60;

/// Bounds on the derived point count.
///
/// The floor covers a host that sends one sample every five seconds (12
/// points); the ceiling a 10 Hz flood (600). Past either end the plot stops
/// being a plot - a dozen points cannot describe a minute, and six hundred
/// land below one pixel each on a phone.
const int kMinHistoryPoints = 12;
const int kMaxHistoryPoints = 600;

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
    DateTime Function()? clock,
  })  : _dataSource = MockDataSource(profile: profile),
        _now = clock ?? DateTime.now,
        _kind = simulate ? TelemetrySourceKind.simulated : TelemetrySourceKind.live {
    _gpuSelection = GpuSelectionService(persist: persistSelection);
  }

  final MockDataSource _dataSource;

  /// Where sample timestamps come from.
  ///
  /// Injectable so the cadence measurement - which is what sizes the 60 s
  /// windows - can be tested without waiting a real minute: a test hands in a
  /// clock it advances by hand.
  final DateTime Function() _now;
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

  /// How many points each window holds right now.
  ///
  /// Derived from [_sampleIntervalMs] rather than fixed: the window is always
  /// [kHistoryWindow] long, so a 4 Hz host needs 240 slots and a 0.5 Hz host
  /// needs 30. Every series follows this one number.
  int _historyPoints = kDashboardHistoryPoints;

  /// Spacing between two snapshots, in milliseconds: the trimmed mean of the
  /// recent arrivals, so a single stalled sample cannot rescale every plot.
  double _sampleIntervalMs =
      kHistoryWindow.inMilliseconds / kDashboardHistoryPoints;

  /// The last few arrival intervals, newest last. Bounded by [_intervalWindow].
  final List<double> _recentIntervals = <double>[];
  DateTime? _lastSampleAt;

  /// A median over this many arrivals outlives a single outlier (a GC pause,
  /// a dropped packet) while still reacting within a second or two.
  static const int _intervalWindow = 9;

  /// Per-adapter 60 s windows keyed by `protocol_id`, feeding the curves on the
  /// GPU device list. Unlike [_gpuHistory] these are never cleared by an
  /// adapter switch - every card owns its own continuous series.
  final Map<String, List<double?>> _gpuHistories = <String, List<double?>>{};

  /// Per-disk 60 s windows, keyed by [diskHistoryKey], feeding the read and
  /// write curves on the disk detail cards. Read and write are kept apart
  /// rather than summed: the card plots them as two lines, and a disk whose
  /// write stalls while it keeps reading must not draw as one flat total.
  final Map<String, List<double?>> _diskReadHistories = <String, List<double?>>{};
  final Map<String, List<double?>> _diskWriteHistories =
      <String, List<double?>>{};

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
    return _now().difference(at) > kStaleAfter;
  }

  List<double?> get cpuHistory => List<double?>.unmodifiable(_cpuHistory);
  List<double?> get gpuHistory => List<double?>.unmodifiable(_gpuHistory);

  /// Slots in each window at the host's current cadence. 60 at 1 Hz; the
  /// sparklines are always [kHistoryWindow] long regardless.
  int get historyPoints => _historyPoints;

  /// The host's measured sample interval, in milliseconds. Reported in the
  /// simulated status line's spirit - it is the number that decides how many
  /// points a 60 s window needs.
  double get sampleIntervalMs => _sampleIntervalMs;

  /// The 60 s window belonging to one adapter (empty when it has never been
  /// sampled). Used by the GPU device list.
  List<double?> gpuHistoryFor(String protocolId) => List<double?>.unmodifiable(
        _gpuHistories[protocolId] ?? const <double?>[],
      );

  /// The 60 s read / write windows belonging to one disk (empty when it has
  /// never been sampled). Used by the disk detail cards.
  List<double?> diskReadHistoryFor(String key) => List<double?>.unmodifiable(
        _diskReadHistories[key] ?? const <double?>[],
      );

  List<double?> diskWriteHistoryFor(String key) => List<double?>.unmodifiable(
        _diskWriteHistories[key] ?? const <double?>[],
      );

  /// The key a disk's windows are filed under.
  ///
  /// The protocol id when the host sends one, else the name - the same pairing
  /// rule the disk card uses to match a disk across snapshots, so a host that
  /// omits ids still gets a curve and two disks never share one window.
  static String diskHistoryKey(DiskStatus disk) =>
      disk.protocolId.isNotEmpty ? disk.protocolId : disk.name;

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
    final DateTime now = _now();
    _receivedAt = now;
    _lastStatus = status;
    _cacheTargetValues(status);
    _pushHistory(status, now);
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
    _diskReadHistories.clear();
    _diskWriteHistories.clear();
    _historyGpuId = '';
    // The cadence belongs to the link that just went away: the next host may
    // broadcast at a completely different rate, and a stale measurement would
    // size its windows for the wrong stream.
    _lastSampleAt = null;
    _recentIntervals.clear();
    _historyPoints = kDashboardHistoryPoints;
    _sampleIntervalMs = kHistoryWindow.inMilliseconds / kDashboardHistoryPoints;
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
    final DateTime now = _now();
    _lastStatus = first;
    _receivedAt = now;
    _mockLastSample = now;
    _pushHistory(first, now);
    _cacheTargetValues(first);
  }

  /// The one and only periodic tick: advances the simulator at 1 Hz and
  /// refreshes the clock / stale badge. Bar easing lives in the framework.
  void _tick() {
    if (isSimulated) {
      final DateTime now = _now();
      final DateTime? last = _mockLastSample;
      if (last == null || now.difference(last).inMilliseconds >= 1000) {
        _mockLastSample = now;
        final PcStatus next = _dataSource.step();
        _lastStatus = next;
        _receivedAt = now;
        _cacheTargetValues(next);
        _pushHistory(next, now);
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

  void _pushHistory(PcStatus status, DateTime at) {
    _noteCadence(at);

    final GpuStatus? gpu = _gpuSelection.selected(status);
    final GpuEngine? engine = PcStatus.busiestEngine(gpu);
    final String gpuId = gpu?.protocolId ?? '';

    // Switching adapters must never splice two unrelated series together.
    if (gpuId != _historyGpuId) {
      _historyGpuId = gpuId;
      _cpuHistory.clear();
      _gpuHistory.clear();
      _cpuHistory.addAll(List<double?>.filled(_historyPoints, null));
      _gpuHistory.addAll(List<double?>.filled(_historyPoints, null));
    }

    _cpuHistory.add(status.cpuUsageValid ? status.cpuUsage.toDouble() : null);
    _gpuHistory.add(
      engine != null && engine.usageValid ? engine.usage.toDouble() : null,
    );

    while (_cpuHistory.length > _historyPoints) {
      _cpuHistory.removeAt(0);
    }
    while (_gpuHistory.length > _historyPoints) {
      _gpuHistory.removeAt(0);
    }

    // Every adapter gets a window of its own so the device list can draw a
    // curve per card. These are deliberately independent of the switch above.
    for (final GpuStatus adapter in status.gpus) {
      _advance(_gpuHistories, adapter.protocolId, plotValueFor(adapter));
    }

    // Same idea for the physical disks, one window per direction - the disk
    // detail card plots read and write as two curves on one 60 s plot.
    for (final DiskStatus disk in status.disks) {
      final String key = diskHistoryKey(disk);
      _advance(_diskReadHistories, key, disk.readValid ? disk.readMbS : null);
      _advance(_diskWriteHistories, key, disk.writeValid ? disk.writeMbS : null);
    }
  }

  /// Measures the host's cadence and re-fits every window to match.
  ///
  /// The estimate is the trimmed mean of the last [_intervalWindow] arrivals:
  /// drop the fastest and the slowest, average the rest. The trim is what makes
  /// one late packet (a GC pause, a dropped datagram) harmless, and the mean is
  /// what makes a jittering feed stable - a median would snap to whichever side
  /// the jitter happened to fall on, and the point count would flip with it.
  /// Arrivals longer than the whole window are treated as a gap (a reconnect, a
  /// laptop waking from sleep) rather than as a cadence, and are skipped - as
  /// are arrivals closer together than [_minSampleIntervalMs], which can only
  /// come from two pushes in the same frame rather than from the host's timer.
  void _noteCadence(DateTime at) {
    final DateTime? previous = _lastSampleAt;
    _lastSampleAt = at;
    if (previous == null) return;

    final double ms = at.difference(previous).inMilliseconds.toDouble();
    if (ms < _minSampleIntervalMs || ms > kHistoryWindow.inMilliseconds) {
      return;
    }

    _recentIntervals.add(ms);
    if (_recentIntervals.length > _intervalWindow) {
      _recentIntervals.removeAt(0);
    }

    _sampleIntervalMs = _trimmedMean(List<double>.of(_recentIntervals)..sort());

    final int points = (kHistoryWindow.inMilliseconds / _sampleIntervalMs)
        .round()
        .clamp(kMinHistoryPoints, kMaxHistoryPoints);
    // One point either way is jitter around a rounding boundary, not a change
    // of rate: re-fitting for it would blink a gap in and out of the left edge
    // of every plot, because growing a window pads it with one missing sample.
    // A real rate change moves the count by tens of points.
    if ((points - _historyPoints).abs() < 2) return;
    _historyPoints = points;
    _resizeWindows();
  }

  /// The fastest cadence worth tracking: 25 Hz. Two pushes inside one frame
  /// say nothing about the host's timer.
  static const double _minSampleIntervalMs = 40;

  /// Mean of [sorted] with its extremes dropped (all of them when there are
  /// only one or two samples to work with).
  static double _trimmedMean(List<double> sorted) {
    if (sorted.isEmpty) return 0;
    if (sorted.length <= 2) {
      double sum = 0;
      for (final double value in sorted) {
        sum += value;
      }
      return sum / sorted.length;
    }
    double sum = 0;
    for (int i = 1; i < sorted.length - 1; i++) {
      sum += sorted[i];
    }
    return sum / (sorted.length - 2);
  }

  /// Re-fits every live window to [_historyPoints].
  ///
  /// Growing pads the *old* end with gaps rather than inventing samples: those
  /// slice-of-a-second slots were never measured, and a zero there would draw
  /// a minute of idle. Shrinking drops the oldest points, which is what a
  /// faster feed means - the same 60 s now needs more of them, and the newest
  /// are the ones worth keeping.
  void _resizeWindows() {
    for (final List<double?> series in <List<double?>>[
      _cpuHistory,
      _gpuHistory,
      ..._gpuHistories.values,
      ..._diskReadHistories.values,
      ..._diskWriteHistories.values,
    ]) {
      if (series.length > _historyPoints) {
        series.removeRange(0, series.length - _historyPoints);
      } else if (series.length < _historyPoints) {
        series.insertAll(
          0,
          List<double?>.filled(_historyPoints - series.length, null),
        );
      }
    }
  }

  /// Appends one sample to a rolling window, retiring the oldest point.
  ///
  /// One helper for every series: the GPU windows and the disk windows have to
  /// age identically, and they used to be written out by hand.
  ///
  /// An empty [key] means the host sent no id for that device; there is nothing
  /// to file the sample under, so it is dropped rather than pooling every
  /// unidentified device into one window.
  void _advance(
    Map<String, List<double?>> store,
    String key,
    double? value,
  ) {
    if (key.isEmpty) return;
    // growable: true is load-bearing. List.filled defaults to a fixed length,
    // so the series.add(...) below threw UnsupportedError on the first series
    // that used it - leaving that one stuck with an all-null window (grid but
    // no curve on its card) and aborting the loop before the remaining series
    // ever got a window at all (completely blank cards).
    final List<double?> series = store.putIfAbsent(
      key,
      () => List<double?>.filled(_historyPoints, null, growable: true),
    );
    series.add(value);
    while (series.length > _historyPoints) {
      series.removeAt(0);
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
    if (_cpuHistory.length >= _historyPoints) return;
    _pushHistory(status, _now());
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
