/// Mock telemetry source.
///
/// Ported from `PCMonitorSimulator/src/pc_simulator.c` (a lively 32-core /
/// 2-GPU / 3-disk desktop) and `PCMonitorFirmware/main/mock_data.c` (the
/// firmware's simpler 16-core / 1-GPU profile). This lets the whole UI run and
/// be reviewed without a host on the network.
library;

import 'dart:math' as math;

import '../models/pc_status.dart';

/// Which canned profile to drive.
enum MockProfile {
  /// `pc_simulator.c` - 32 cores, discrete + integrated GPU, 3 disks.
  workstation,

  /// `mock_data.c` - the firmware's minimal profile, 16 cores, 1 GPU.
  firmware,
}

class MockDataSource {
  MockDataSource({this.profile = MockProfile.workstation}) {
    _seed();
  }

  final MockProfile profile;

  late PcStatus _status;
  int _tick = 0;
  int _random = 0x324b;

  final List<double> _coreValues = <double>[];
  final List<List<double>> _engineValues = <List<double>>[
    <double>[50, 10],
    <double>[50, 10],
    <double>[50, 10],
    <double>[50, 10],
  ];

  static const List<String> _engineNames = <String>[
    '3D',
    'Copy',
    'Compute',
    'Video Decode',
    'Video Encode',
    'CUDA / Compute 0',
    'Video Processing',
    'Compute 1',
  ];

  int get _coreCount => profile == MockProfile.workstation ? 32 : 16;
  int get _gpuCount => profile == MockProfile.workstation ? 2 : 1;
  int get _diskCount => profile == MockProfile.workstation ? 3 : 3;

  /// LCG identical to the C sources so the traffic pattern feels the same.
  double _noise() {
    _random = (_random * 1664525 + 1013904223) & 0xFFFFFFFF;
    return ((_random >> 16) & 0xFFFF) / 32767.5 - 1.0;
  }

  double _clamp(double value, double low, double high) =>
      value < low ? low : (value > high ? high : value);

  double _approach(double value, double target, double factor, double step) =>
      value + _clamp((target - value) * factor, -step, step);

  void _seed() {
    _coreValues
      ..clear()
      ..addAll(List<double>.generate(PcLimits.cpuCores, (int i) => 28.0 + (i % 16) * 2.0));

    final bool ws = profile == MockProfile.workstation;

    final List<GpuStatus> gpus = <GpuStatus>[];
    for (int g = 0; g < _gpuCount; g++) {
      final int base = ws ? (g == 0 ? 100 : 200) : 1;
      gpus.add(GpuStatus(
        protocolId: 'mock-$base',
        id: base,
        name: ws
            ? (g == 0 ? 'NVIDIA GeForce RTX 4070' : 'Intel UHD Graphics 770')
            : 'Mock GPU',
        vendor: ws ? (g == 0 ? 'NVIDIA' : 'Intel') : 'Mock',
        discreteValid: true,
        isDiscrete: ws ? g == 0 : false,
        usageValid: true,
        usage: 50,
        tempValid: true,
        temp: ws ? (g == 0 ? 49.0 : 38.0) : 60.0,
        powerValid: true,
        power: ws ? (g == 0 ? 80.0 : 9.0) : 120.0,
        vramUsageValid: true,
        vramUsage: 45,
        vramUsedValid: true,
        vramTotalValid: true,
        vramUsed: ws ? (g == 0 ? 5.4 : 0.5) : 5.0,
        vramTotal: ws ? (g == 0 ? 12.0 : 4.0) : 12.0,
        engines: List<GpuEngine>.generate(
          ws ? 6 : 5,
          (int e) => GpuEngine(
            protocolId: 'mock-engine-$g-$e',
            name: _engineNames[e],
            usageValid: true,
            usage: ws ? (e == 0 ? 50 : 10) : 25 + e * 10,
          ),
        ),
      ));
    }

    const List<String> wsDisks = <String>[
      'Samsung 990 PRO',
      'WD Blue SSD',
      'Seagate BarraCuda',
    ];

    final List<DiskStatus> disks = <DiskStatus>[];
    for (int d = 0; d < _diskCount; d++) {
      disks.add(DiskStatus(
        protocolId: 'mock-disk-$d',
        name: ws ? wsDisks[d] : 'Disk $d / Mock SSD',
        readValid: true,
        writeValid: true,
        activityValid: true,
        tempValid: true,
        readMbS: ws ? 40.0 / (d + 1) : 40.0,
        writeMbS: ws ? 16.0 / (d + 1) : 20.0,
        activity: 30,
        temp: 38.0 + d,
      ));
    }

    _status = PcStatus(
      received: true,
      simulated: true,
      sampleTimeMs: 0,
      cpuName: ws
          ? 'Intel Core i9-14900K'
          : 'Mock CPU @ 4.20GHz',
      cpuUsageValid: true,
      cpuUsage: 45,
      cpuTempValid: true,
      cpuTemp: ws ? 47.0 : 55.0,
      cpuPowerValid: true,
      cpuPower: ws ? 45.0 : 65.0,
      cpuClockValid: true,
      cpuClock: 4.2,
      cpuCoreIds: List<int>.generate(_coreCount, (int i) => i),
      cpuCoreValues:
          List<int>.generate(_coreCount, (int i) => _coreValues[i].round()),
      cpuCoreValid: List<bool>.filled(_coreCount, true),
      ramUsageValid: true,
      ramUsage: ws ? 48 : 50,
      ramUsedValid: true,
      ramTotalValid: true,
      ramUsed: ws ? 15.3 : 16.0,
      ramTotal: 32.0,
      gpus: gpus,
      disks: disks,
      netDownValid: true,
      netUpValid: true,
      netDownMbS: 12.0,
      netUpMbS: 1.6,
    );
  }

  PcStatus get status => _status;

  /// Advances one sample and returns the new snapshot.
  PcStatus step() {
    if (profile == MockProfile.firmware) {
      return _stepFirmware();
    }
    return _stepWorkstation();
  }

  /// Port of `pc_simulator_next()`.
  PcStatus _stepWorkstation() {
    final double t = (_tick % 3600).toDouble();
    _tick++;

    int cpuSum = 0;
    final List<int> coreInts = <int>[];
    final List<bool> coreValid = <bool>[];
    for (int c = 0; c < _coreCount; c++) {
      final double target = 44.0 +
          19.0 * math.sin(t * 0.085) +
          23.0 * math.sin(t * 0.17 + c * 0.63) +
          _noise() * 8.0;
      _coreValues[c] = _approach(_coreValues[c], _clamp(target, 3.0, 99.0), 0.36, 9.0);
      final int value = (_coreValues[c] + 0.5).toInt();
      coreInts.add(value);
      coreValid.add(true);
      cpuSum += value;
    }
    final int usage = (cpuSum + _coreCount ~/ 2) ~/ _coreCount;

    final double cpuTemp =
        _approach(_status.cpuTemp, 35.0 + usage * 0.48, 0.09, 0.7);
    final double cpuPower =
        _approach(_status.cpuPower, 16.0 + usage * 1.1, 0.28, 6.0);
    final double cpuClock =
        _approach(_status.cpuClock, 3.4 + usage * 0.022, 0.25, 0.12);
    final double ramUsed =
        _approach(_status.ramUsed, 16.4 + 2.5 * math.sin(t * 0.025), 0.10, 0.12);

    final List<GpuStatus> gpus = <GpuStatus>[];
    for (int g = 0; g < _gpuCount; g++) {
      final GpuStatus old = _status.gpus[g];
      // Low-load engines come and go; the dominant engine persists.
      final int engineCount = g == 0 ? 6 + ((_tick ~/ 24) % 2) * 2 : 4;
      final int active = ((_tick ~/ 18) + g) % (g == 0 ? 5 : 4);

      double peak = 0.0;
      final List<GpuEngine> engines = <GpuEngine>[];
      for (int e = 0; e < engineCount; e++) {
        double target = e == active
            ? 74.0 + 18.0 * math.sin(t * 0.13 + g)
            : 12.0 + 10.0 * math.sin(t * 0.11 + e);
        if (g == 1) target *= 0.45;
        final List<double> store = _engineValues[g];
        while (store.length <= e) {
          store.add(10);
        }
        store[e] = _approach(store[e], _clamp(target + _noise() * 3.0, 0.0, 100.0), 0.3, 8.0);
        final int value = (store[e] + 0.5).toInt();
        if (store[e] > peak) peak = store[e];
        engines.add(GpuEngine(
          protocolId: 'mock-engine-$g-$e',
          name: _engineNames[e],
          usageValid: true,
          usage: value,
        ));
      }

      final double temp = _approach(old.temp, 34.0 + peak * 0.46, 0.07, 0.6);
      final double power = _approach(
          old.power, (g == 0 ? 24.0 : 4.0) + peak * (g == 0 ? 2.25 : 0.4), 0.23, 11.0);
      final double vramUsed = _approach(
          old.vramUsed,
          (g == 0 ? 4.0 : 0.3) + peak * (g == 0 ? 0.048 : 0.015),
          0.10,
          0.15);

      gpus.add(old.copyWith(
        engines: engines,
        temp: temp,
        power: power,
        vramUsed: vramUsed,
        usage: engines.isEmpty ? 0 : engines.first.usage,
        vramUsage: old.vramTotal <= 0
            ? 0
            : ((vramUsed / old.vramTotal) * 100 + 0.5).toInt(),
      ));
    }

    final double netDown =
        _approach(_status.netDownMbS, 15.0 + 12.0 * math.sin(t * 0.12) + _noise(), 0.3, 3.0);
    final double netUp =
        _approach(_status.netUpMbS, 2.2 + 1.8 * math.sin(t * 0.09 + 1.0), 0.25, 0.5);

    final List<DiskStatus> disks = <DiskStatus>[];
    for (int d = 0; d < _diskCount; d++) {
      final DiskStatus old = _status.disks[d];
      final double scale = d == 0 ? 1.0 : (d == 1 ? 0.12 : 0.35);
      final double read = _approach(
          old.readMbS,
          (120.0 + 105.0 * math.sin(t * 0.15 + d)) * scale,
          0.3,
          24.0 * scale);
      final double write = _approach(
          old.writeMbS,
          (55.0 + 45.0 * math.sin(t * 0.10 + d)) * scale,
          0.28,
          12.0 * scale);
      final double busy = (read + write) / (d == 0 ? 4.0 : 1.5);
      disks.add(old.copyWith(
        readMbS: read,
        writeMbS: write,
        activity: _clamp(busy + 0.5, 0, 100).toInt(),
        temp: _approach(old.temp, 34.0 + busy * 0.2, 0.07, 0.3),
      ));
    }

    _status = _status.copyWith(
      sampleTimeMs: _tick * 1000,
      received: true,
      cpuUsage: usage,
      cpuUsageValid: true,
      cpuTemp: cpuTemp,
      cpuTempValid: true,
      cpuPower: cpuPower,
      cpuPowerValid: true,
      cpuClock: cpuClock,
      cpuClockValid: true,
      cpuCoreIds: List<int>.generate(_coreCount, (int i) => i),
      cpuCoreValues: coreInts,
      cpuCoreValid: coreValid,
      ramUsed: ramUsed,
      ramUsedValid: true,
      ramUsageValid: true,
      ramUsage: ((ramUsed / _status.ramTotal) * 100 + 0.5).toInt(),
      gpus: gpus,
      disks: disks,
      netDownMbS: netDown,
      netUpMbS: netUp,
      netDownValid: true,
      netUpValid: true,
    );

    return _status;
  }

  /// Port of `mock_data_step()`.
  PcStatus _stepFirmware() {
    _tick++;
    double walk(double old, double delta, double lo, double hi) =>
        _clamp(old + _noise() * delta, lo, hi);

    final int usage = walk(_status.cpuUsage.toDouble(), 5, 20, 80).toInt();
    final List<int> cores = <int>[];
    for (int i = 0; i < _coreCount; i++) {
      final double base = i < _status.cpuCoreValues.length
          ? _status.cpuCoreValues[i].toDouble()
          : 40.0;
      cores.add(walk(base, 8, 10, 95).toInt());
    }

    final GpuStatus oldGpu = _status.gpus.first;
    final List<GpuEngine> engines = <GpuEngine>[];
    for (int e = 0; e < oldGpu.engines.length; e++) {
      final GpuEngine oldEngine = oldGpu.engines[e];
      engines.add(GpuEngine(
        protocolId: oldEngine.protocolId,
        name: oldEngine.name,
        usageValid: true,
        usage: walk(oldEngine.usage.toDouble(), 6, 10, 95).toInt(),
      ));
    }
    final double gpuTemp = walk(oldGpu.temp, 1, 40, 85);
    final double gpuPower = walk(oldGpu.power, 6, 50, 220);
    final double vramUsed = walk(oldGpu.vramUsed, 0.1, 3, 9);

    final double ramUsed = walk(_status.ramUsed, 0.15, 9.6, 22.4);

    final List<DiskStatus> disks = <DiskStatus>[];
    for (final DiskStatus disk in _status.disks) {
      disks.add(disk.copyWith(
        readMbS: walk(disk.readMbS, 8, 0, 500),
        writeMbS: walk(disk.writeMbS, 5, 0, 250),
        activity: walk(disk.activity.toDouble(), 5, 0, 100).toInt(),
        temp: walk(disk.temp, 0.3, 30, 60),
      ));
    }

    _status = _status.copyWith(
      sampleTimeMs: _tick * 1000,
      received: true,
      cpuUsage: usage,
      cpuUsageValid: true,
      cpuTemp: walk(_status.cpuTemp, 1, 40, 80),
      cpuTempValid: true,
      cpuPower: walk(_status.cpuPower, 4, 30, 120),
      cpuPowerValid: true,
      cpuClock: walk(_status.cpuClock, 0.08, 3, 5),
      cpuClockValid: true,
      cpuCoreValues: cores,
      cpuCoreValid: List<bool>.filled(_coreCount, true),
      ramUsed: ramUsed,
      ramUsedValid: true,
      ramUsageValid: true,
      ramUsage: ((ramUsed / _status.ramTotal) * 100 + 0.5).toInt(),
      gpus: <GpuStatus>[
        oldGpu.copyWith(
          engines: engines,
          temp: gpuTemp,
          tempValid: true,
          power: gpuPower,
          powerValid: true,
          vramUsed: vramUsed,
          vramUsedValid: true,
          vramUsageValid: true,
          vramUsage: ((vramUsed / oldGpu.vramTotal) * 100 + 0.5).toInt(),
          usageValid: true,
          usage: engines.isEmpty ? 0 : engines.first.usage,
        ),
      ],
      disks: disks,
    );

    return _status;
  }

  /// Demonstrates the `valid == false` path so the placeholder rendering can be
  /// reviewed: strips the CPU package sensors and every disk temperature.
  void hideSensorsForReview() {
    _status = _status.copyWith(
      cpuTempValid: false,
      cpuPowerValid: false,
      cpuClockValid: false,
      disks: _status.disks
          .map((DiskStatus d) => d.copyWith(tempValid: false))
          .toList(growable: false),
    );
  }
}
