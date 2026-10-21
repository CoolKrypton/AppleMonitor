/// A rolling window of samples, each carrying the moment it describes.
///
/// The plot used to be addressed by index: `x = i * width / (n - 1)`. That made
/// the *number of slots* the time axis, so any change in that number - and it
/// was derived from measured packet arrivals - rescaled the whole curve. Here
/// every sample carries its own timestamp instead, so the horizontal position
/// is a function of time and nothing else: a late packet widens a gap on the
/// right edge rather than squeezing the minute before it.
///
/// [values] and [timesMs] are parallel and always the same length; this class
/// is the only place that pairs them, so no caller can zip the wrong ones.
/// Ascending in time, oldest first.
class HistoryWindow {
  const HistoryWindow({required this.values, required this.timesMs});

  /// The empty window. A card that has never been sampled renders its ruled
  /// background from this, not a curve.
  static const HistoryWindow empty =
      HistoryWindow(values: <double?>[], timesMs: <int>[]);

  final List<double?> values;
  final List<int> timesMs;

  int get length => values.length;
  bool get isEmpty => values.isEmpty;
  bool get isNotEmpty => values.isNotEmpty;

  /// Timestamp of the newest sample, or 0 for an empty window.
  int get newestMs => timesMs.isEmpty ? 0 : timesMs.last;

  /// Timestamp of the oldest sample, or 0 for an empty window.
  int get oldestMs => timesMs.isEmpty ? 0 : timesMs.first;

  /// How much history the window actually holds, in milliseconds.
  ///
  /// Reaches 60 000 once the plot is full. It is the number to assert on when
  /// the question is "is the window still a minute long", which is exactly the
  /// invariant the old point count could not give.
  int get spanMs => timesMs.isEmpty ? 0 : timesMs.last - timesMs.first;
}
