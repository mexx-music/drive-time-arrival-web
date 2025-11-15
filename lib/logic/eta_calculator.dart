import 'package:intl/intl.dart';

/// Fahrregeln / Optionen
class DriveRulesConfig {
  final bool tenHourDay1;
  final bool tenHourDay2;
  final bool nineHourRest1;
  final bool nineHourRest2;
  final bool nineHourRest3;
  final bool tankPause;

  const DriveRulesConfig({
    required this.tenHourDay1,
    required this.tenHourDay2,
    required this.nineHourRest1,
    required this.nineHourRest2,
    required this.nineHourRest3,
    required this.tankPause,
  });
}

class EtaStep {
  final String text;
  EtaStep(this.text);
}

class EtaResult {
  final List<EtaStep> steps;
  final DateTime? arrival;
  const EtaResult(this.steps, this.arrival);
}

/// Interner Fahrzustand, damit wir über Segmente hinweg korrekt weiterrechnen
class _DriveState {
  DateTime current;
  int tenUsed;
  int nineUsed;
  bool tankUsed;

  _DriveState({
    required this.current,
    this.tenUsed = 0,
    this.nineUsed = 0,
    this.tankUsed = false,
  });
}

class EtaCalculator {
  // ======= Bestehende einfache Ein-Segment-Berechnung =======
  static EtaResult compute({
    required DateTime start,
    required int alreadyDrivenMin,
    required int dutyTimeOffsetMin,
    required double km,
    required double avgKmh,
    required DriveRulesConfig rules,
  }) {
    final steps = <EtaStep>[];
    var state = _DriveState(current: start);

    // Einsatzzeit rückrechnen
    if (dutyTimeOffsetMin > 0) {
      state.current =
          state.current.subtract(Duration(minutes: dutyTimeOffsetMin));
      steps.add(EtaStep(
          '🔁 Startzeit korrigiert (Einsatzzeit): ${_fmt(state.current)}'));
    }

    // Gesamtfahrzeit dieses Segments
    var totalMin = _minsFromKm(km, avgKmh);

    // Bisher gefahrene Minuten anrechnen
    if (alreadyDrivenMin > 0) {
      totalMin += alreadyDrivenMin;
      steps.add(
          EtaStep('🕒 Fahrtzeit bisher angerechnet: ${alreadyDrivenMin} min'));
    }

    _runLeg(
        steps: steps,
        state: state,
        totalMin: totalMin,
        rules: rules,
        avgKmh: avgKmh);

    return EtaResult(steps, state.current);
  }

  // ======= NEU: Zwei Segmente + Fähre dazwischen =======
  /// Rechnet:
  /// 1) Start → Abfahrtshafen (kmBefore)
  /// 2) Warten bis Abfahrt (aus departuresHHmm, optional manuell)
  /// 3) Fähre (ferryDurationMin), zählt als Ruhe, wenn >= 540
  /// 4) Ankunftshafen → Ziel (kmAfter)
  static EtaResult computeTwoLegsWithFerry({
    required DateTime start,
    required int alreadyDrivenMin,
    required int dutyTimeOffsetMin,
    required double kmBefore, // z. B. Hamburg → Bari
    required double kmAfter, // z. B. Igoumenitsa → Sindos
    required double avgKmh,
    required DriveRulesConfig rules,
    required String ferryLabel, // z. B. "Bari–Igoumenitsa (Grimaldi)"
    required int ferryDurationMin, // z. B. 600 für 10h
    List<String>? departuresHHmm, // lokale Abfahrtzeiten "HH:mm"
    DateTime? manualDeparture, // hat Vorrang gegenüber departuresHHmm
  }) {
    final steps = <EtaStep>[];
    var state = _DriveState(current: start);

    // Einsatzzeit rückrechnen
    if (dutyTimeOffsetMin > 0) {
      state.current =
          state.current.subtract(Duration(minutes: dutyTimeOffsetMin));
      steps.add(EtaStep(
          '🔁 Startzeit korrigiert (Einsatzzeit): ${_fmt(state.current)}'));
    }

    // ggf. bereits gefahrene Minuten in das erste Segment einrechnen
    var seg1Min = _minsFromKm(kmBefore, avgKmh) +
        (alreadyDrivenMin > 0 ? alreadyDrivenMin : 0);
    if (alreadyDrivenMin > 0) {
      steps.add(
          EtaStep('🕒 Fahrtzeit bisher angerechnet: ${alreadyDrivenMin} min'));
    }

    // --- Segment 1: bis zum Abfahrtshafen
    _runLeg(
        steps: steps,
        state: state,
        totalMin: seg1Min,
        rules: rules,
        avgKmh: avgKmh);

    // --- Warten auf Fähre (manuell oder nächste passende Abfahrt)
    DateTime departTime;
    if (manualDeparture != null) {
      // Manuell vorgegeben
      if (manualDeparture.isAfter(state.current)) {
        final wait = manualDeparture.difference(state.current).inMinutes;
        steps.add(EtaStep(
            '⏱ Wartezeit bis Fähre: ${_fmtHM(wait)} → Abfahrt: ${DateFormat('HH:mm').format(manualDeparture)}'));
      } else {
        steps.add(EtaStep(
            '⚠️ Manuelle Fährzeit liegt nicht in der Zukunft – Abfahrt sofort angesetzt.'));
      }
      departTime = manualDeparture;
    } else if (departuresHHmm != null && departuresHHmm.isNotEmpty) {
      departTime = _nextDepartureFromList(state.current, departuresHHmm);
      final wait = departTime.difference(state.current).inMinutes;
      if (wait > 0) {
        steps.add(EtaStep(
            '⏱ Wartezeit bis Fähre: ${_fmtHM(wait)} → Abfahrt: ${DateFormat('HH:mm').format(departTime)}'));
      }
    } else {
      // Keine Zeiten vorhanden → sofort
      departTime = state.current;
      steps.add(EtaStep('⏱ Keine Fährzeiten definiert → Abfahrt sofort.'));
    }

    // --- Fähre fährt
    state.current = departTime.add(Duration(minutes: ferryDurationMin));
    steps.add(EtaStep(
        '🚢 Fähre $ferryLabel ${_fmtHM(ferryDurationMin)} → Ankunft: ${_fmt(state.current)}'));

    // --- Ruhe während Fähre erfüllt?
    if (ferryDurationMin >= 540) {
      steps.add(EtaStep(
          '✅ Pause während der Fähre vollständig erfüllt (≥ 9h). Zähler werden zurückgesetzt.'));
      // Zähler resetten, Tankpause bleibt verbraucht, wenn vorher genutzt (realistisch ist: Reset der Tagesfahrleistung/Zähler, Tank bleibt egal)
      state.tenUsed = 0;
      state.nineUsed = 0;
      // Tankpause absichtlich NICHT zurücksetzen – sie ist ein optionaler Bonus und wurde bereits genutzt.
    }

    // --- Segment 2: vom Ankunftshafen zum Ziel
    final seg2Min = _minsFromKm(kmAfter, avgKmh);
    _runLeg(
        steps: steps,
        state: state,
        totalMin: seg2Min,
        rules: rules,
        avgKmh: avgKmh);

    return EtaResult(steps, state.current);
  }

  // ======= Hilfsroutinen =======

  static void _runLeg({
    required List<EtaStep> steps,
    required _DriveState state,
    required int totalMin,
    required DriveRulesConfig rules,
    required double avgKmh,
  }) {
    while (totalMin > 0) {
      final allow10 = (state.tenUsed == 0 && rules.tenHourDay1) ||
          (state.tenUsed == 1 && rules.tenHourDay2);
      final maxDrive = allow10 ? 600 : 540;
      final driven = totalMin > maxDrive ? maxDrive : totalMin;

      int pauseMin;
      if (driven >= 600) {
        pauseMin = 90;
        state.tenUsed += 1;
      } else if (driven >= 540) {
        pauseMin = 45;
      } else {
        pauseMin = (driven ~/ 270) * 45;
      }

      if (rules.tankPause && !state.tankUsed) {
        pauseMin += 30;
        state.tankUsed = true;
      }

      final end = state.current.add(Duration(minutes: driven + pauseMin));
      steps.add(EtaStep(
          '📆 ${DateFormat('EEE HH:mm').format(state.current)} → ${driven ~/ 60}h${(driven % 60).toString().padLeft(2, '0')} + ${pauseMin} min → ${DateFormat('HH:mm').format(end)}'));
      state.current = end;
      totalMin -= driven;
      if (totalMin <= 0) break;

      // Ruhezeit zwischen Fahrblöcken
      final canNine = (state.nineUsed == 0 && rules.nineHourRest1) ||
          (state.nineUsed == 1 && rules.nineHourRest2) ||
          (state.nineUsed == 2 && rules.nineHourRest3);
      final rest = canNine ? 540 : 660;
      state.current = state.current.add(Duration(minutes: rest));
      steps.add(EtaStep(
          '🌙 Ruhezeit ${rest ~/ 60}h → Neustart: ${_fmt(state.current)}'));
      if (canNine) state.nineUsed += 1;
    }
  }

  static int _minsFromKm(double km, double avgKmh) {
    if (avgKmh <= 0) return 0;
    return (km / avgKmh * 60).round();
  }

  static DateTime _nextDepartureFromList(DateTime now, List<String> hhmmList) {
    // Sortiert und sucht die erste Abfahrt heute >= now, sonst morgen die erste
    final parsed = hhmmList
        .map((s) => s.trim())
        .where((s) => RegExp(r'^\d{1,2}:\d{2}$').hasMatch(s))
        .map((s) {
      final p = s.split(':');
      return TimeOfDayLite(int.parse(p[0]), int.parse(p[1]));
    }).toList()
      ..sort(
          (a, b) => a.hour != b.hour ? a.hour - b.hour : a.minute - b.minute);

    for (final t in parsed) {
      final candidate =
          DateTime(now.year, now.month, now.day, t.hour, t.minute);
      if (!candidate.isBefore(now)) return candidate;
    }
    // sonst: nächste am Folgetag
    final first = parsed.first;
    return DateTime(now.year, now.month, now.day, first.hour, first.minute)
        .add(const Duration(days: 1));
  }

  static String _fmt(DateTime dt) => DateFormat('yyyy-MM-dd HH:mm').format(dt);

  static String _fmtHM(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h}h${m.toString().padLeft(2, '0')}';
  }
}

/// Minimaler Ersatz für TimeOfDay (ohne Flutter-Import hier)
class TimeOfDayLite {
  final int hour;
  final int minute;
  TimeOfDayLite(this.hour, this.minute);
}
