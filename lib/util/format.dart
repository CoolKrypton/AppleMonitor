/// Formatting helpers ported 1:1 from the firmware.
///
/// Every helper takes an explicit `valid` flag and returns the firmware's exact
/// placeholder string when the sensor is missing. Never substitute a guessed or
/// zero value for an unknown sensor.
library;

import 'dart:math' as math;

/// Placeholder strings, identical to the ones used by the LVGL UI.
class Ph {
  const Ph._();

  static const String percent = '--%';
  static const String celsius = '-- C';
  static const String watt = '-- W';
  static const String gigahertz = '-- GHz';
  static const String gib = '-- GiB';
  static const String rate = '--';
  static const String count = '--';
  static const String day = '--';
  static const String month = '---';
  static const String weekday = '---';
  static const String date = '---- / -- / --';
  static const String clock = '--';
}

/// `ui_metric()` equivalent: `valid ? value : placeholder`.
String uiMetric(String Function() value, bool valid, String placeholder) =>
    valid ? value() : placeholder;

/// `"%d%%"` or `"--%"`.
String fmtPercent(int value, bool valid) =>
    valid ? '${pcPercentLocal(value)}%' : Ph.percent;

int pcPercentLocal(int value) => value < 0 ? 0 : (value > 100 ? 100 : value);

/// `"%.0f%%"`.
String fmtPercentFloat(double value, bool valid) =>
    valid ? '${_clampPercent(value).round()}%' : Ph.percent;

double _clampPercent(double value) {
  if (value.isNaN || value < 0) return 0;
  if (value > 100) return 100;
  return value;
}

/// `"%.1f C"` or `"-- C"`.
String fmtTemp(double value, bool valid, {int digits = 1}) =>
    valid && value.isFinite
        ? '${value.toStringAsFixed(digits)} C'
        : Ph.celsius;

/// `"%.0f C"` for the dashboard detail row.
String fmtTempShort(double value, bool valid) =>
    valid && value.isFinite ? value.toStringAsFixed(0) : '--';

/// `"%.0f W"` or `"-- W"`.
String fmtPower(double value, bool valid) =>
    valid && value.isFinite ? '${value.toStringAsFixed(0)} W' : Ph.watt;

/// `"%.0f W"` without the unit (dashboard detail row).
String fmtPowerShort(double value, bool valid) =>
    valid && value.isFinite ? value.toStringAsFixed(0) : '--';

/// `"%.2f GHz"` or `"-- GHz"`.
String fmtClock(double value, bool valid) =>
    valid && value.isFinite
        ? '${value.toStringAsFixed(2)} GHz'
        : Ph.gigahertz;

/// `"%s / %s GiB"` where each side degrades to `"--"` independently.
String fmtCapacityPair(double used, bool usedValid, double total,
    bool totalValid) {
  final String u = usedValid && used.isFinite ? used.toStringAsFixed(1) : '--';
  final String t =
      totalValid && total.isFinite ? total.toStringAsFixed(1) : '--';
  return '$u / $t GiB';
}

/// `"%s GiB"` or `"-- GiB"`.
String fmtGiB(double value, bool valid) =>
    valid && value.isFinite ? '${value.toStringAsFixed(1)} GiB' : Ph.gib;

/// Port of `ui_format_rate()`. Input is decimal MB/s.
///
/// * non-finite or invalid -> `"--"`
/// * `>= 1000 MB/s` -> GB/s with 1 decimal
/// * `>= 1 MB/s`    -> MB/s with 1 decimal
/// * `>= 0.001 MB/s` -> KB/s with 1 decimal
/// * otherwise      -> B/s with 0 decimals
String uiFormatRate(double mbPerSecond, bool valid) {
  if (!valid || !mbPerSecond.isFinite) return Ph.rate;

  if (mbPerSecond >= 1000.0) {
    return '${(mbPerSecond / 1000.0).toStringAsFixed(1)} GB/s';
  }
  if (mbPerSecond >= 1.0) {
    return '${mbPerSecond.toStringAsFixed(1)} MB/s';
  }
  if (mbPerSecond >= 0.001) {
    return '${(mbPerSecond * 1000.0).toStringAsFixed(1)} KB/s';
  }
  return '${(mbPerSecond * 1000000.0).toStringAsFixed(0)} B/s';
}

/// True when the reading crosses the firmware's hot threshold and the detail
/// row must switch to the accent-hot colour.
bool isHot(double temperature, bool valid) => valid && temperature >= 85.0;

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

const List<String> kMonths = <String>[
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
];

const List<String> kWeekdays = <String>[
  'SUNDAY', 'MONDAY', 'TUESDAY', 'WEDNESDAY',
  'THURSDAY', 'FRIDAY', 'SATURDAY',
];

/// A fully validated clock snapshot. `valid == false` means the caller must
/// render the firmware placeholders for every field.
class ClockFields {
  const ClockFields({
    required this.valid,
    this.month = Ph.month,
    this.day = Ph.day,
    this.weekday = Ph.weekday,
    this.date = Ph.date,
    this.hours = Ph.clock,
    this.minutes = Ph.clock,
    this.seconds = Ph.clock,
  });

  const ClockFields.invalid()
      : valid = false,
        month = Ph.month,
        day = Ph.day,
        weekday = Ph.weekday,
        date = Ph.date,
        hours = Ph.clock,
        minutes = Ph.clock,
        seconds = Ph.clock;

  final bool valid;
  final String month;
  final String day;
  final String weekday;
  final String date;
  final String hours;
  final String minutes;
  final String seconds;
}

/// Port of `ui_dashboard_update_clock()` including its range validation: a
/// single out-of-range field invalidates the entire clock.
ClockFields clockFields(DateTime? now) {
  if (now == null) return const ClockFields.invalid();

  final int year = now.year;
  final int month = now.month; // 1..12
  final int day = now.day; // 1..31
  final int weekday = now.weekday == 7 ? 0 : now.weekday; // Sunday == 0
  final int hour = now.hour;
  final int minute = now.minute;
  final int second = now.second;

  final bool inRange = year >= 1900 &&
      year <= 9999 &&
      month >= 1 &&
      month <= 12 &&
      day >= 1 &&
      day <= 31 &&
      weekday >= 0 &&
      weekday <= 6 &&
      hour >= 0 &&
      hour <= 23 &&
      minute >= 0 &&
      minute <= 59 &&
      second >= 0 &&
      second <= 60;

  if (!inRange) return const ClockFields.invalid();

  return ClockFields(
    valid: true,
    month: kMonths[month - 1],
    day: day.toString().padLeft(2, '0'),
    weekday: kWeekdays[weekday],
    date: '$year / ${month.toString().padLeft(2, '0')} / '
        '${day.toString().padLeft(2, '0')}',
    hours: hour.toString().padLeft(2, '0'),
    minutes: minute.toString().padLeft(2, '0'),
    seconds: second.toString().padLeft(2, '0'),
  );
}

// ---------------------------------------------------------------------------
// Model-name wrapping
// ---------------------------------------------------------------------------

/// Port of `wrap_model_text()`: greedy word wrap that never splits a token
/// such as `i9-9900k`, capped at [maxLines] lines. The final line is
/// ellipsised with `...` when it does not fit.
///
/// The LVGL original measures pixels with `lv_text_get_size`. In Flutter we
/// approximate by character budget; [maxChars] is the tuned per-line budget
/// (74 for the 480x480 layout, 104 for the 800x480 layout).
String wrapModelText(
  String text,
  int maxChars, {
  int maxLines = 3,
}) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return '--';
  if (maxChars <= 0) return trimmed;

  final List<String> words = trimmed.split(RegExp(r'\s+'));
  final List<String> lines = <String>[];
  final StringBuffer current = StringBuffer();

  void flush() {
    if (current.isNotEmpty) {
      lines.add(current.toString());
      current.clear();
    }
  }

  for (final String word in words) {
    if (current.isEmpty) {
      // A token longer than the budget cannot be split; it takes its own line.
      current.write(word);
      continue;
    }
    if (current.length + 1 + word.length <= maxChars) {
      current.write(' ');
      current.write(word);
    } else {
      flush();
      current.write(word);
    }
  }
  flush();

  if (lines.isEmpty) return trimmed;

  if (lines.length <= maxLines) return lines.join('\n');

  final List<String> kept = lines.take(maxLines).toList();
  final String last = kept[maxLines - 1];
  kept[maxLines - 1] =
      last.length + 3 <= maxChars ? '$last...' : '${last.substring(0, math.max(0, last.length - 3))}...';
  return kept.join('\n');
}

/// `snprintf(buf, "%.40s", name)` equivalent for the CPU model name.
String clampName(String name, int maxChars) {
  final String value = name.isEmpty ? '--' : name;
  if (value.length <= maxChars) return value;
  return value.substring(0, maxChars);
}

/// Estimated visual width of a monospace-ish digit string, used to place the
/// `%` unit glyph after a large number.
double measureDigits(String text, double fontSize) => text.length * fontSize * 0.58;
