/// Port of `PCMonitorFirmware/services/gpu_selection_service.{h,c}`.
///
/// The adapter shown on the dashboard is decoupled from the adapter whose
/// detail page is open. Identity is always the host `protocol_id` - never an
/// array index, which can be reshuffled between samples.
library;

import 'dart:io';

import '../models/pc_status.dart';

class GpuSelectionService {
  GpuSelectionService({this.persist = true});

  /// Storage key must match the firmware's `GPU_SELECTION_ID_SIZE` contract:
  /// the stored id is a `protocol_id`, capped at 129 bytes.
  static const int idSize = 129;
  static const String _storageFileName = 'gpu_selection.txt';

  final bool persist;

  String _stored = '';
  File? _file;

  String get storedId => _stored;

  /// True when the user has explicitly picked an adapter.
  bool get hasUserSelection => _stored.isNotEmpty;

  /// Port of `default_index()`: the first discrete GPU, otherwise the first
  /// adapter. Returns `-1` when the host reports no adapter at all.
  int defaultIndex(PcStatus? status) {
    final int count = status?.gpuCount ?? 0;
    if (status == null || count <= 0) return -1;
    for (int i = 0; i < count; i++) {
      final GpuStatus gpu = status.gpus[i];
      if (gpu.discreteValid && gpu.isDiscrete) return i;
    }
    return 0;
  }

  /// Port of `selected_index()`.
  int selectedIndex(PcStatus? status) {
    if (status == null) return -1;
    if (_stored.isNotEmpty) {
      final GpuStatus? chosen = status.findGpu(_stored);
      if (chosen != null) return status.gpus.indexOf(chosen);
    }
    return defaultIndex(status);
  }

  /// Port of `gpu_selection_get_selected()`. `null` when there is no adapter.
  GpuStatus? selected(PcStatus? status) {
    final int index = selectedIndex(status);
    if (status == null || index < 0 || index >= status.gpuCount) return null;
    return status.gpus[index];
  }

  /// Port of `gpu_selection_select()`. Returns `false` for an empty or
  /// oversized id. Re-selecting the same id is a no-op that never writes.
  Future<bool> select(String id) async {
    if (id.isEmpty || id.length >= idSize) return false;
    if (id == _stored) return true;
    _stored = id;
    await _write();
    return true;
  }

  /// Port of `gpu_selection_is_selected()`. An empty id never matches.
  bool isSelected(String id) => id.isNotEmpty && id == _stored;

  /// Loads the persisted selection. Tolerates a missing or unreadable file.
  Future<void> load() async {
    if (!persist) return;
    try {
      final File file = await _storageFile();
      if (!file.existsSync()) return;
      final String value = (await file.readAsString()).trim();
      if (value.isNotEmpty && value.length < idSize) _stored = value;
    } on Object {
      // Persistence is best-effort; the dashboard falls back to the default
      // adapter when nothing can be restored.
    }
  }

  Future<void> clear() async {
    _stored = '';
    if (!persist) return;
    try {
      final File file = await _storageFile();
      if (file.existsSync()) await file.delete();
    } on Object {
      // Ignored - clearing is best-effort.
    }
  }

  Future<File> _storageFile() async {
    if (_file != null) return _file!;
    final String base = _storageBasePath();
    final Directory dir = Directory('$base${Platform.pathSeparator}PCMonitor');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _file = File('${dir.path}${Platform.pathSeparator}$_storageFileName');
  }

  /// Where `gpu_selection.txt` lives.
  ///
  /// Windows still uses `%LOCALAPPDATA%` and desktop Linux/macOS still use
  /// `$HOME`, unchanged. iOS is the one platform that has to differ: `$HOME`
  /// there is the app container **root**, which is not a place an app may
  /// create files, so the container's persistent, backed-up `Documents`
  /// directory is used instead. The file's name and format are identical, so
  /// this is a location change only - the persisted selection still behaves
  /// exactly as the firmware's `gpu_selection_service.c` does.
  static String _storageBasePath() {
    final Map<String, String> env = Platform.environment;
    if (Platform.isIOS) {
      final String? home = env['HOME'];
      if (home != null && home.isNotEmpty) return '$home/Documents';
    }
    return env['LOCALAPPDATA'] ?? env['HOME'] ?? Directory.systemTemp.path;
  }

  Future<void> _write() async {
    if (!persist) return;
    try {
      final File file = await _storageFile();
      await file.writeAsString(_stored, flush: true);
    } on Object {
      // Ignored - an unwritable store only costs the user the selection across
      // restarts, it never breaks the dashboard.
    }
  }
}
