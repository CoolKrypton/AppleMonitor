/// Dart port of `PCMonitorFirmware/pc_status.h`.
///
/// The cardinal rule of this model is preserved verbatim: every sensor carries
/// its own `*Valid` flag. When a flag is `false` the value is *unknown* and the
/// UI must render a placeholder. `0` is a perfectly valid reading and must
/// never be confused with "missing".
library;

/// Hard capacity limits - identical to the firmware `PC_MAX_*` macros.
class PcLimits {
  const PcLimits._();

  static const int cpuCores = 64;
  static const int gpus = 4;
  static const int gpuEngines = 32;
  static const int disks = 8;
}

/// Clamp `value` into `0..capacity`. Mirrors `pc_status_count()`.
int pcCount(int value, int capacity) =>
    value < 0 ? 0 : (value > capacity ? capacity : value);

/// Clamp a percentage into `0..100`. Mirrors `pc_status_percent()`.
int pcPercent(int value) => pcCount(value, 100);

/// A single GPU engine (3D / Copy / Compute / Video Decode ...).
class GpuEngine {
  const GpuEngine({
    this.protocolId = '',
    this.name = '',
    this.usageValid = false,
    this.usage = 0,
  });

  /// Stable protocol handle. Empty string never matches anything.
  final String protocolId;
  final String name;
  final bool usageValid;
  final int usage;

  factory GpuEngine.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['usagePercent'];
    return GpuEngine(
      protocolId: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      usageValid: raw is num,
      usage: pcPercent(raw is num ? raw.round() : 0),
    );
  }
}

/// A GPU adapter. `protocolId` is the only legal identity - array index is not.
class GpuStatus {
  const GpuStatus({
    this.protocolId = '',
    this.id = 0,
    this.name = '',
    this.vendor = '',
    this.discreteValid = false,
    this.isDiscrete = false,
    this.usageValid = false,
    this.tempValid = false,
    this.powerValid = false,
    this.vramUsageValid = false,
    this.vramUsedValid = false,
    this.vramTotalValid = false,
    this.usage = 0,
    this.temp = 0,
    this.power = 0,
    this.vramUsage = 0,
    this.vramUsed = 0,
    this.vramTotal = 0,
    this.engines = const <GpuEngine>[],
  });

  final String protocolId;
  final int id;
  final String name;
  final String vendor;

  final bool discreteValid;
  final bool isDiscrete;

  /// Host-level overall sensor. The dashboard deliberately ignores this and
  /// reads the busiest engine instead, exactly like the firmware.
  final bool usageValid;
  final int usage;

  final bool tempValid;
  final double temp; // Celsius

  final bool powerValid;
  final double power; // Watts

  final bool vramUsageValid;
  final int vramUsage;

  final bool vramUsedValid;
  final bool vramTotalValid;
  final double vramUsed; // GiB
  final double vramTotal; // GiB

  final List<GpuEngine> engines;

  GpuStatus copyWith({
    String? protocolId,
    String? name,
    bool? discreteValid,
    bool? isDiscrete,
    bool? usageValid,
    int? usage,
    bool? tempValid,
    double? temp,
    bool? powerValid,
    double? power,
    bool? vramUsageValid,
    int? vramUsage,
    bool? vramUsedValid,
    bool? vramTotalValid,
    double? vramUsed,
    double? vramTotal,
    List<GpuEngine>? engines,
  }) {
    return GpuStatus(
      protocolId: protocolId ?? this.protocolId,
      id: id,
      name: name ?? this.name,
      vendor: vendor,
      discreteValid: discreteValid ?? this.discreteValid,
      isDiscrete: isDiscrete ?? this.isDiscrete,
      usageValid: usageValid ?? this.usageValid,
      usage: usage ?? this.usage,
      tempValid: tempValid ?? this.tempValid,
      temp: temp ?? this.temp,
      powerValid: powerValid ?? this.powerValid,
      power: power ?? this.power,
      vramUsageValid: vramUsageValid ?? this.vramUsageValid,
      vramUsage: vramUsage ?? this.vramUsage,
      vramUsedValid: vramUsedValid ?? this.vramUsedValid,
      vramTotalValid: vramTotalValid ?? this.vramTotalValid,
      vramUsed: vramUsed ?? this.vramUsed,
      vramTotal: vramTotal ?? this.vramTotal,
      engines: engines ?? this.engines,
    );
  }

  factory GpuStatus.fromJson(Map<String, dynamic> json) {
    final Object? vram = json['vram'];
    final Map<String, dynamic> vramMap =
        vram is Map ? Map<String, dynamic>.from(vram) : const <String, dynamic>{};

    final List<dynamic> rawEngines =
        (json['engines'] as List<dynamic>?) ?? const <dynamic>[];
    final List<GpuEngine> engines = rawEngines
        .whereType<Map>()
        .map((Map e) => GpuEngine.fromJson(Map<String, dynamic>.from(e)))
        .take(PcLimits.gpuEngines)
        .toList(growable: false);

    final Object? usage = json['usagePercent'];
    final Object? temp = json['temperatureC'];
    final Object? power = json['powerW'];

    return GpuStatus(
      protocolId: (json['id'] as String?) ?? '',
      id: (json['id'] as String?)?.hashCode ?? 0,
      name: (json['name'] as String?) ?? '',
      vendor: (json['vendor'] as String?) ?? '',
      discreteValid: json['isDiscrete'] is bool,
      isDiscrete: (json['isDiscrete'] as bool?) ?? false,
      usageValid: usage is num,
      usage: pcPercent(usage is num ? usage.round() : 0),
      tempValid: temp is num,
      temp: temp is num ? temp.toDouble() : 0,
      powerValid: power is num,
      power: power is num ? power.toDouble() : 0,
      vramUsageValid: vramMap['usagePercent'] is num,
      vramUsage: pcPercent(
          vramMap['usagePercent'] is num ? (vramMap['usagePercent'] as num).round() : 0),
      vramUsedValid: vramMap['usedBytes'] is num,
      vramTotalValid: vramMap['totalBytes'] is num,
      vramUsed: vramMap['usedBytes'] is num
          ? (vramMap['usedBytes'] as num).toDouble() / 1073741824.0
          : 0,
      vramTotal: vramMap['totalBytes'] is num
          ? (vramMap['totalBytes'] as num).toDouble() / 1073741824.0
          : 0,
      engines: engines,
    );
  }
}

/// A physical disk.
class DiskStatus {
  const DiskStatus({
    this.protocolId = '',
    this.name = '',
    this.readValid = false,
    this.writeValid = false,
    this.activityValid = false,
    this.tempValid = false,
    this.readMbS = 0,
    this.writeMbS = 0,
    this.activity = 0,
    this.temp = 0,
  });

  final String protocolId;
  final String name;

  final bool readValid;
  final bool writeValid;
  final bool activityValid;
  final bool tempValid;

  /// Decimal MB/s (not Mbit/s) - matches the wire unit.
  final double readMbS;
  final double writeMbS;
  final int activity;
  final double temp;

  DiskStatus copyWith({
    String? protocolId,
    String? name,
    bool? readValid,
    bool? writeValid,
    bool? activityValid,
    bool? tempValid,
    double? readMbS,
    double? writeMbS,
    int? activity,
    double? temp,
  }) {
    return DiskStatus(
      protocolId: protocolId ?? this.protocolId,
      name: name ?? this.name,
      readValid: readValid ?? this.readValid,
      writeValid: writeValid ?? this.writeValid,
      activityValid: activityValid ?? this.activityValid,
      tempValid: tempValid ?? this.tempValid,
      readMbS: readMbS ?? this.readMbS,
      writeMbS: writeMbS ?? this.writeMbS,
      activity: activity ?? this.activity,
      temp: temp ?? this.temp,
    );
  }

  factory DiskStatus.fromJson(Map<String, dynamic> json) {
    final Object? read = json['readBytesPerSecond'];
    final Object? write = json['writeBytesPerSecond'];
    final Object? activity = json['activityPercent'];
    final Object? temp = json['temperatureC'];

    return DiskStatus(
      protocolId: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      readValid: read is num,
      writeValid: write is num,
      activityValid: activity is num,
      tempValid: temp is num,
      readMbS: read is num ? read.toDouble() / 1000000.0 : 0,
      writeMbS: write is num ? write.toDouble() / 1000000.0 : 0,
      activity: pcPercent(activity is num ? activity.round() : 0),
      temp: temp is num ? temp.toDouble() : 0,
    );
  }
}

/// The complete snapshot. Mirrors `PCStatus`.
class PcStatus {
  const PcStatus({
    this.received = false,
    this.simulated = false,
    this.sampleTimeMs = 0,
    this.cpuName = '',
    this.cpuUsageValid = false,
    this.cpuUsage = 0,
    this.cpuTempValid = false,
    this.cpuTemp = 0,
    this.cpuPowerValid = false,
    this.cpuPower = 0,
    this.cpuClockValid = false,
    this.cpuClock = 0, // GHz
    this.cpuCoreIds = const <int>[],
    this.cpuCoreValues = const <int>[],
    this.cpuCoreValid = const <bool>[],
    this.ramUsageValid = false,
    this.ramUsage = 0,
    this.ramUsedValid = false,
    this.ramTotalValid = false,
    this.ramUsed = 0, // GiB
    this.ramTotal = 0, // GiB
    this.gpus = const <GpuStatus>[],
    this.disks = const <DiskStatus>[],
    this.netDownValid = false,
    this.netUpValid = false,
    this.netDownMbS = 0,
    this.netUpMbS = 0,
  });

  final bool received;
  final bool simulated;
  final int sampleTimeMs;

  final String cpuName;
  final bool cpuUsageValid;
  final int cpuUsage;
  final bool cpuTempValid;
  final double cpuTemp;
  final bool cpuPowerValid;
  final double cpuPower;
  final bool cpuClockValid;
  final double cpuClock;

  final List<int> cpuCoreIds;
  final List<int> cpuCoreValues;
  final List<bool> cpuCoreValid;

  final bool ramUsageValid;
  final int ramUsage;
  final bool ramUsedValid;
  final bool ramTotalValid;
  final double ramUsed;
  final double ramTotal;

  final List<GpuStatus> gpus;
  final List<DiskStatus> disks;

  final bool netDownValid;
  final bool netUpValid;
  final double netDownMbS;
  final double netUpMbS;

  int get cpuCoreCount => pcCount(cpuCoreValues.length, PcLimits.cpuCores);
  int get gpuCount => pcCount(gpus.length, PcLimits.gpus);
  int get diskCount => pcCount(disks.length, PcLimits.disks);

  bool get hasCpu => received;

  /// Mirrors `pc_status_find_gpu()`. An empty id never matches.
  GpuStatus? findGpu(String id) {
    if (id.isEmpty) return null;
    for (final GpuStatus gpu in gpus) {
      if (gpu.protocolId.isNotEmpty && gpu.protocolId == id) return gpu;
    }
    return null;
  }

  /// Mirrors `pc_status_find_gpu()` but by index with clamping.
  GpuStatus? gpuAt(int index) {
    final int count = gpuCount;
    if (index < 0 || index >= count) return null;
    return gpus[index];
  }

  /// Mirrors `pc_status_find_engine()`. Empty engine ids fall back to name
  /// comparison, matching `display_smoother.c`.
  static GpuEngine? findEngine(GpuStatus? gpu, String id) {
    if (gpu == null || id.isEmpty) return null;
    for (final GpuEngine engine in gpu.engines) {
      if (engine.protocolId.isNotEmpty && engine.protocolId == id) {
        return engine;
      }
    }
    return null;
  }

  /// Mirrors `pc_status_busiest_engine()`: the highest `usageValid` reading.
  /// Returns `null` when no engine reports a valid usage.
  static GpuEngine? busiestEngine(GpuStatus? gpu) {
    if (gpu == null || gpu.engines.isEmpty) return null;
    GpuEngine? best;
    for (final GpuEngine engine in gpu.engines) {
      if (!engine.usageValid) continue;
      if (best == null || engine.usage > best.usage) best = engine;
    }
    return best;
  }

  /// Mirrors `pc_status_primary_gpu()`.
  GpuStatus? primaryGpu(int primaryIndex) {
    final int count = gpuCount;
    if (count == 0) return null;
    return gpus[pcCount(primaryIndex, count - 1)];
  }

  PcStatus copyWith({
    bool? received,
    bool? simulated,
    int? sampleTimeMs,
    String? cpuName,
    bool? cpuUsageValid,
    int? cpuUsage,
    bool? cpuTempValid,
    double? cpuTemp,
    bool? cpuPowerValid,
    double? cpuPower,
    bool? cpuClockValid,
    double? cpuClock,
    List<int>? cpuCoreIds,
    List<int>? cpuCoreValues,
    List<bool>? cpuCoreValid,
    bool? ramUsageValid,
    int? ramUsage,
    bool? ramUsedValid,
    bool? ramTotalValid,
    double? ramUsed,
    double? ramTotal,
    List<GpuStatus>? gpus,
    List<DiskStatus>? disks,
    bool? netDownValid,
    bool? netUpValid,
    double? netDownMbS,
    double? netUpMbS,
  }) {
    return PcStatus(
      received: received ?? this.received,
      simulated: simulated ?? this.simulated,
      sampleTimeMs: sampleTimeMs ?? this.sampleTimeMs,
      cpuName: cpuName ?? this.cpuName,
      cpuUsageValid: cpuUsageValid ?? this.cpuUsageValid,
      cpuUsage: cpuUsage ?? this.cpuUsage,
      cpuTempValid: cpuTempValid ?? this.cpuTempValid,
      cpuTemp: cpuTemp ?? this.cpuTemp,
      cpuPowerValid: cpuPowerValid ?? this.cpuPowerValid,
      cpuPower: cpuPower ?? this.cpuPower,
      cpuClockValid: cpuClockValid ?? this.cpuClockValid,
      cpuClock: cpuClock ?? this.cpuClock,
      cpuCoreIds: cpuCoreIds ?? this.cpuCoreIds,
      cpuCoreValues: cpuCoreValues ?? this.cpuCoreValues,
      cpuCoreValid: cpuCoreValid ?? this.cpuCoreValid,
      ramUsageValid: ramUsageValid ?? this.ramUsageValid,
      ramUsage: ramUsage ?? this.ramUsage,
      ramUsedValid: ramUsedValid ?? this.ramUsedValid,
      ramTotalValid: ramTotalValid ?? this.ramTotalValid,
      ramUsed: ramUsed ?? this.ramUsed,
      ramTotal: ramTotal ?? this.ramTotal,
      gpus: gpus ?? this.gpus,
      disks: disks ?? this.disks,
      netDownValid: netDownValid ?? this.netDownValid,
      netUpValid: netUpValid ?? this.netUpValid,
      netDownMbS: netDownMbS ?? this.netDownMbS,
      netUpMbS: netUpMbS ?? this.netUpMbS,
    );
  }

  /// Parses the protocol V1 telemetry payload.
  factory PcStatus.fromTelemetry(Map<String, dynamic> payload) {
    final Map<String, dynamic> cpu =
        _mapOf(payload['cpu']) ?? const <String, dynamic>{};
    final Map<String, dynamic> memory =
        _mapOf(payload['memory']) ?? const <String, dynamic>{};

    final Map<String, dynamic> storage =
        _mapOf(payload['storage']) ?? const <String, dynamic>{};
    final Map<String, dynamic> network =
        _mapOf(payload['network']) ?? const <String, dynamic>{};

    // `logicalProcessors` may arrive either as a list of objects
    // (`{id, usagePercent}`) or as a bare list of percentages. Both shapes are
    // accepted and normalised into the parallel id/value/valid triplets that
    // the rest of the UI consumes.
    final List<dynamic> rawCoreValues =
        (cpu['logicalProcessors'] as List<dynamic>?) ?? const <dynamic>[];
    final List<int> coreValues = <int>[];
    final List<bool> coreValid = <bool>[];
    final List<int> coreIdentifiers = <int>[];
    for (int i = 0; i < rawCoreValues.length && i < PcLimits.cpuCores; i++) {
      final Object? raw = rawCoreValues[i];
      if (raw is Map) {
        final Map<String, dynamic> entry = Map<String, dynamic>.from(raw);
        coreIdentifiers.add((entry['id'] as num?)?.toInt() ?? i);
        final Object? usage = entry['usagePercent'];
        coreValid.add(usage is num);
        coreValues.add(pcPercent(usage is num ? usage.round() : 0));
      } else {
        coreIdentifiers.add(i);
        coreValid.add(raw is num);
        coreValues.add(pcPercent(raw is num ? raw.round() : 0));
      }
    }

    final List<GpuStatus> gpus = ((payload['gpus'] as List<dynamic>?) ??
            const <dynamic>[])
        .whereType<Map>()
        .map((Map e) => GpuStatus.fromJson(Map<String, dynamic>.from(e)))
        .take(PcLimits.gpus)
        .toList(growable: false);

    final List<DiskStatus> disks =
        ((storage['disks'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((Map e) => DiskStatus.fromJson(Map<String, dynamic>.from(e)))
            .take(PcLimits.disks)
            .toList(growable: false);

    final Object? cpuUsage = cpu['usagePercent'];
    final Object? cpuTemp = cpu['temperatureC'];
    final Object? cpuPower = cpu['powerW'];
    final Object? cpuClock = cpu['frequencyMHz'];
    final Object? ramUsage = memory['usagePercent'];
    final Object? ramUsed = memory['usedBytes'];
    final Object? ramTotal = memory['totalBytes'];
    final Object? netDown = network['downloadBytesPerSecond'];
    final Object? netUp = network['uploadBytesPerSecond'];

    return PcStatus(
      received: true,
      simulated: false,
      cpuName: (cpu['name'] as String?) ?? '',
      cpuUsageValid: cpuUsage is num,
      cpuUsage: pcPercent(cpuUsage is num ? cpuUsage.round() : 0),
      cpuTempValid: cpuTemp is num,
      cpuTemp: cpuTemp is num ? cpuTemp.toDouble() : 0,
      cpuPowerValid: cpuPower is num,
      cpuPower: cpuPower is num ? cpuPower.toDouble() : 0,
      cpuClockValid: cpuClock is num,
      cpuClock: cpuClock is num ? cpuClock.toDouble() / 1000.0 : 0,
      cpuCoreIds: coreIdentifiers,
      cpuCoreValues: coreValues,
      cpuCoreValid: coreValid,
      ramUsageValid: ramUsage is num,
      ramUsage: pcPercent(ramUsage is num ? ramUsage.round() : 0),
      ramUsedValid: ramUsed is num,
      ramTotalValid: ramTotal is num,
      ramUsed: ramUsed is num ? ramUsed.toDouble() / 1073741824.0 : 0,
      ramTotal: ramTotal is num ? ramTotal.toDouble() / 1073741824.0 : 0,
      gpus: gpus,
      disks: disks,
      netDownValid: netDown is num,
      netUpValid: netUp is num,
      netDownMbS: netDown is num ? netDown.toDouble() / 1000000.0 : 0,
      netUpMbS: netUp is num ? netUp.toDouble() / 1000000.0 : 0,
    );
  }

  static Map<String, dynamic>? _mapOf(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}
