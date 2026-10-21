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
import '../models/history_window.dart';
import '../models/pc_status.dart';
import 'gpu_selection_service.dart';
import 'mock_data_source.dart';

/// The span every sparkline covers, whatever cadence the host broadcasts at.
///
/// This is a *duration*, not a slot count, and the difference is the whole
/// point. The firmware holds 60 samples and calls that "60 s", which is only
/// true for its own 1 Hz feed. The app used to do the same with a better excuse
/// - it measured the host's arrival interval and derived a slot count from it -
/// but the count was still what the plot was drawn against, so every wobble in
/// that estimate rescaled every curve on screen.
///
/// Now the window keeps the samples that fall inside this span, each with the
/// moment it describes, and the painter places them by time. A 4 Hz host
/// contributes 241 points and a 0.5 Hz host 31 - both ends of the minute are
/// inside it - and both cover the same minute; neither can stretch the other.
const Duration kHistoryWindow = Duration(seconds: 60);

/// Hard ceiling on samples kept per window: 600, i.e. a full minute at 10 Hz.
///
/// This is a memory bound, not a geometry one - a feed faster than 10 Hz keeps
/// a slightly shorter window rather than an unbounded list.
const int kMaxHistorySamples = 600;

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
  ///
  /// Every sample carries the moment it describes, so the plot is addressed by
  /// time; see [HistoryWindow] for why that matters. All of these windows age
  /// by the same rule: keep what is inside [kHistoryWindow], drop the rest.
  final _HistoryBuffer _cpuHistory = _HistoryBuffer();
  final _HistoryBuffer _gpuHistory = _HistoryBuffer();

  /// Where the newest sample sits on this app's continuous timeline, in epoch
  /// milliseconds. Reconstructed rather than read off a clock, so a jump in
  /// either machine's clock cannot move the plot; see [_stamp].
  int _timelineMs = 0;
  int _lastHostMs = 0;
  int _lastLocalMs = 0;

  /// Whether the host's envelope timestamps may be used as sample times.
  ///
  /// `null` until the first timestamp arrives. A host clock that disagrees with
  /// the phone by more than a day is not a wall clock either side can line up
  /// with, and its deltas are not worth trusting either - the app then falls
  /// back to arrival time, which is the behaviour it had before.
  bool? _hostClockTrusted;

  /// Per-adapter 60 s windows keyed by `protocol_id`, feeding the curves on the
  /// GPU device list. Unlike [_gpuHistory] these are never cleared by an
  /// adapter switch - every card owns its own continuous series.
  final Map<String, _HistoryBuffer> _gpuHistories = <String, _HistoryBuffer>{};

  /// Per-disk 60 s windows, keyed by [diskHistoryKey], feeding the read and
  /// write curves on the disk detail cards. Read and write are kept apart
  /// rather than summed: the card plots them as two lines, and a disk whose
  /// write stalls while it keeps reading must not draw as one flat total.
  final Map<String, _HistoryBuffer> _diskReadHistories =
      <String, _HistoryBuffer>{};
  final Map<String, _HistoryBuffer> _diskWriteHistories =
      <String, _HistoryBuffer>{};

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

  HistoryWindow get cpuHistory => _cpuHistory.snapshot();
  HistoryWindow get gpuHistory => _gpuHistory.snapshot();

  /// How many samples the CPU window holds at the host's current cadence.
  ///
  /// 61 at 1 Hz, 241 at 4 Hz, 31 at 0.5 Hz - the point *density* follows the
  /// host. Unlike before, this number is derived from the window rather than
  /// driving it: the span is always [kHistoryWindow] whatever it says.
  int get historyPoints => _cpuHistory.length;

  /// The 60 s window belonging to one adapter (empty when it has never been
  /// sampled). Used by the GPU device list.
  HistoryWindow gpuHistoryFor(String protocolId) =>
      _gpuHistories[protocolId]?.snapshot() ?? HistoryWindow.empty;

  /// The 60 s read / write windows belonging to one disk (empty when it has
  /// never been sampled). Used by the disk detail cards.
  HistoryWindow diskReadHistoryFor(String key) =>
      _diskReadHistories[key]?.snapshot() ?? HistoryWindow.empty;

  HistoryWindow diskWriteHistoryFor(String key) =>
      _diskWriteHistories[key]?.snapshot() ?? HistoryWindow.empty;

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
  ///
  /// [hostTimeMs] is the `timestamp` the host stamped on the envelope, and it
  /// is what the history windows are positioned by. Arrival time cannot do that
  /// job: a packet delayed 300 ms by the network, or two frames the socket
  /// delivered in one read, say nothing about when the PC sampled them. The
  /// host's own clock does, and a late frame still carries the moment it was
  /// built even if the send itself blocked.
  void pushSnapshot(PcStatus status, {int? hostTimeMs}) {
    if (isSimulated) return;
    final DateTime now = _now();
    final int stamp = _stamp(now, hostTimeMs);
    _receivedAt = now;
    _lastStatus = status;
    _cacheTargetValues(status);
    _pushHistory(status, stamp);
    notifyListeners();
  }

  /// Places one sample on the app's continuous timeline and returns its time.
  ///
  /// The timeline is *reconstructed* from deltas rather than read off a clock:
  /// each sample is the previous one plus the gap the host reports between them.
  /// That keeps the plot immune to both machines' wall clocks and to the phone
  /// sleeping, and it degrades to arrival time whenever the host's own stamp is
  /// missing or implausible - a negative gap, or one longer than the whole
  /// window, which is a reconnect rather than a cadence.
  int _stamp(DateTime local, int? hostTimeMs) {
    final int localMs = local.millisecondsSinceEpoch;
    final int? host = (hostTimeMs != null && hostTimeMs > 0) ? hostTimeMs : null;

    if (_hostClockTrusted == null && host != null) {
      _hostClockTrusted =
          (host - localMs).abs() <= const Duration(days: 1).inMilliseconds;
    }
    final bool useHost = _hostClockTrusted == true && host != null;

    if (_timelineMs == 0) {
      // First sample after a (re)connect: it only needs to be somewhere sane,
      // because every later position is a delta from it.
      _timelineMs = useHost ? host : localMs;
    } else {
      int delta = -1;
      if (useHost && _lastHostMs > 0) {
        delta = host - _lastHostMs;
      }
      if (delta <= 0) {
        // No host stamp, a repeated one, or a clock that went backwards: fall
        // back to the local gap so the sample still lands ahead of the last.
        delta = localMs - _lastLocalMs;
      }
      if (delta < 0) delta = 0;
      _timelineMs += delta;
    }

    _lastHostMs = useHost ? host : 0;
    _lastLocalMs = localMs;
    return _timelineMs;
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
    // The timeline belongs to the link that just went away. The next host may
    // broadcast at a different rate, be a different machine with a different
    // clock, or simply be reached through a fresh socket - all three make the
    // old positions meaningless.
    _timelineMs = 0;
    _lastHostMs = 0;
    _lastLocalMs = 0;
    _hostClockTrusted = null;
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
    _pushHistory(first, _stamp(now, null));
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
        _pushHistory(next, _stamp(now, null));
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

  void _pushHistory(PcStatus status, int timeMs) {
    final GpuStatus? gpu = _gpuSelection.selected(status);
    final GpuEngine? engine = PcStatus.busiestEngine(gpu);
    final String gpuId = gpu?.protocolId ?? '';

    // Switching adapters must never splice two unrelated series together.
    if (gpuId != _historyGpuId) {
      _historyGpuId = gpuId;
      _cpuHistory.clear();
      _gpuHistory.clear();
    }

    _append(
      _cpuHistory,
      timeMs,
      status.cpuUsageValid ? status.cpuUsage.toDouble() : null,
    );
    _append(
      _gpuHistory,
      timeMs,
      engine != null && engine.usageValid ? engine.usage.toDouble() : null,
    );

    // Every adapter gets a window of its own so the device list can draw a
    // curve per card. These are deliberately independent of the switch above.
    for (final GpuStatus adapter in status.gpus) {
      _appendIn(_gpuHistories, adapter.protocolId, timeMs,
          plotValueFor(adapter));
    }

    // Same idea for the physical disks, one window per direction - the disk
    // detail card plots read and write as two curves on one 60 s plot.
    for (final DiskStatus disk in status.disks) {
      final String key = diskHistoryKey(disk);
      _appendIn(_diskReadHistories, key, timeMs,
          disk.readValid ? disk.readMbS : null);
      _appendIn(_diskWriteHistories, key, timeMs,
          disk.writeValid ? disk.writeMbS : null);
    }
  }

  /// Appends one sample and retires everything that has aged out.
  ///
  /// This is the only place a window grows, which is what keeps every plot on
  /// the same minute: the rule is "keep what is inside [kHistoryWindow]", not
  /// "keep N of them".
  static void _append(_HistoryBuffer window, int timeMs, double? value) {
    window.add(timeMs, value);
    window.trim(timeMs, kHistoryWindow.inMilliseconds);
  }

  /// [append] for the per-device windows, which are created on first sight.
  ///
  /// An empty [key] means the host sent no id for that device; there is nothing
  /// to file the sample under, so it is dropped rather than pooling every
  /// unidentified device into one window.
  static void _appendIn(
    Map<String, _HistoryBuffer> store,
    String key,
    int timeMs,
    double? value,
  ) {
    if (key.isEmpty) return;
    _append(store.putIfAbsent(key, _HistoryBuffer.new), timeMs, value);
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
}

/// The mutable half of a [HistoryWindow]: two parallel lists that only ever
/// grow and trim together.
///
/// Kept private so no caller can add a value without its timestamp - the
/// alignment that makes the plot time-addressed is enforced here, not by
/// convention at every call site.
class _HistoryBuffer {
  final List<int> times = <int>[];
  final List<double?> values = <double?>[];

  int get length => values.length;

  void add(int timeMs, double? value) {
    times.add(timeMs);
    values.add(value);
  }

  /// Drops every sample older than [spanMs] before [newestMs], and any excess
  /// past [kMaxHistorySamples].
  ///
  /// Times are non-decreasing, so the expired ones are always a prefix: one
  /// scan, one range removal, no per-sample shifting.
  void trim(int newestMs, int spanMs) {
    int drop = 0;
    while (drop < times.length && newestMs - times[drop] > spanMs) {
      drop++;
    }
    final int excess = times.length - kMaxHistorySamples;
    if (excess > drop) drop = excess;
    if (drop == 0) return;
    times.removeRange(0, drop);
    values.removeRange(0, drop);
  }

  void clear() {
    times.clear();
    values.clear();
  }

  HistoryWindow snapshot() => HistoryWindow(
        values: List<double?>.unmodifiable(values),
        timesMs: List<int>.unmodifiable(times),
      );
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
