import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;

/// Findet die nächste planmäßige Fährabfahrt.
///
/// Die Abfahrtszeiten im Fahrplan gelten in der Ortszeit des Abfahrtshafens.
/// Wer von Österreich aus eine Abfahrt in Patras plant, würde sich sonst um
/// eine Stunde vertun, weil Griechenland eine Zeitzone weiter östlich liegt.
class FerrySchedule {
  const FerrySchedule._();

  /// Nächste Abfahrt ab [from] (Gerätezeit), zurückgegeben in Gerätezeit.
  /// Liefert null, wenn keine brauchbare Zeit im Fahrplan steht.
  static DateTime? nextDeparture(
    DateTime from,
    List<String> departuresLocal,
    String tzName, {
    Map<int, List<String>> departuresByWeekday = const {},
  }) {
    final dailyTimes = _parse(departuresLocal);
    final weeklyTimes = {
      for (final entry in departuresByWeekday.entries)
        entry.key: _parse(entry.value),
    };
    if (dailyTimes.isEmpty &&
        weeklyTimes.values.every((times) => times.isEmpty)) {
      return null;
    }

    final location = _location(tzName);
    if (location == null) {
      // Ohne Zeitzonendaten: Zeiten als Gerätezeit behandeln (wie bisher).
      return _nextInLocalTime(from, dailyTimes, weeklyTimes);
    }

    final fromPort = tz.TZDateTime.from(from, location);
    final searchDays = weeklyTimes.isEmpty ? 1 : 7;
    for (var dayOffset = 0; dayOffset <= searchDays; dayOffset++) {
      final day = tz.TZDateTime(
        location,
        fromPort.year,
        fromPort.month,
        fromPort.day + dayOffset,
      );
      final times = weeklyTimes.isEmpty
          ? dailyTimes
          : weeklyTimes[day.weekday] ?? const <_Hm>[];
      for (final t in times) {
        final candidate = tz.TZDateTime(
            location, day.year, day.month, day.day, t.hour, t.minute);
        if (!candidate.isBefore(fromPort)) {
          return DateTime.fromMillisecondsSinceEpoch(
              candidate.millisecondsSinceEpoch);
        }
      }
    }
    return null;
  }

  static DateTime? _nextInLocalTime(
    DateTime from,
    List<_Hm> dailyTimes,
    Map<int, List<_Hm>> weeklyTimes,
  ) {
    final searchDays = weeklyTimes.isEmpty ? 1 : 7;
    for (var dayOffset = 0; dayOffset <= searchDays; dayOffset++) {
      final day = DateTime(from.year, from.month, from.day + dayOffset);
      final times = weeklyTimes.isEmpty
          ? dailyTimes
          : weeklyTimes[day.weekday] ?? const <_Hm>[];
      for (final t in times) {
        final candidate =
            DateTime(day.year, day.month, day.day, t.hour, t.minute);
        if (!candidate.isBefore(from)) return candidate;
      }
    }
    return null;
  }

  static tz.Location? _location(String name) {
    if (name.trim().isEmpty) return null;
    try {
      return tz.getLocation(name);
    } catch (e) {
      if (kDebugMode)
        debugPrint('[FerrySchedule] Zeitzone "$name" unbekannt: $e');
      return null;
    }
  }

  static List<_Hm> _parse(List<String> values) {
    final out = <_Hm>[];
    for (final value in values) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
      if (m == null) continue;
      final h = int.parse(m.group(1)!);
      final min = int.parse(m.group(2)!);
      if (h <= 23 && min <= 59) out.add(_Hm(h, min));
    }
    out.sort((a, b) => a.hour != b.hour
        ? a.hour.compareTo(b.hour)
        : a.minute.compareTo(b.minute));
    return out;
  }
}

class _Hm {
  final int hour;
  final int minute;
  const _Hm(this.hour, this.minute);
}
