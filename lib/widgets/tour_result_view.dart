import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../logic/eta_calculator.dart';
import '../logic/speed_profile.dart';

class TourResultView extends StatelessWidget {
  final EtaResult result;
  final String origin;
  final String destination;
  final RoadMixAnalysis? roadMix;

  const TourResultView({
    super.key,
    required this.result,
    required this.origin,
    required this.destination,
    this.roadMix,
  });

  @override
  Widget build(BuildContext context) {
    final summary = result.summary;
    if (summary == null || result.arrival == null) {
      return const SizedBox.shrink();
    }
    final visibleSteps = result.steps.where((step) => !step.technical).toList();
    EtaStep? nextRequiredStop;
    for (final step in visibleSteps) {
      if (step.type == EtaEventType.breakTime ||
          step.type == EtaEventType.dailyRest ||
          step.type == EtaEventType.weeklyRest) {
        nextRequiredStop = step;
        break;
      }
    }

    return Semantics(
      label: 'Berechneter Tourablauf von $origin nach $destination',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TourHeader(
            origin: origin,
            destination: destination,
            summary: summary,
            arrival: result.arrival!,
          ),
          const SizedBox(height: 16),
          _SummaryGrid(summary: summary, arrival: result.arrival!),
          if (roadMix != null && roadMix!.hasBreakdown) ...[
            const SizedBox(height: 10),
            _RoadMixBanner(analysis: roadMix!),
          ],
          if (nextRequiredStop != null) ...[
            const SizedBox(height: 10),
            _NextStopBanner(step: nextRequiredStop),
          ],
          const SizedBox(height: 18),
          Text(
            'Tourablauf',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
              child: Column(
                children: [
                  for (var index = 0; index < visibleSteps.length; index++)
                    _TimelineRow(
                      step: visibleSteps[index],
                      isLast: index == visibleSteps.length - 1,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0A7A4B), Color(0xFF075E3A)],
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                const Text(
                  'Voraussichtliche Ankunft',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('EEEE, dd.MM. – HH:mm', 'de')
                      .format(result.arrival!),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoadMixBanner extends StatelessWidget {
  final RoadMixAnalysis analysis;

  const _RoadMixBanner({required this.analysis});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.add_road_rounded, size: 20),
              SizedBox(width: 8),
              Text(
                'Straßenmix der Route',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${analysis.fastPercent} % schnell/autobahnähnlich  ·  '
            '${analysis.mainRoadPercent} % Haupt-/Bundesstraße  ·  '
            '${analysis.slowPercent} % langsam/lokal',
          ),
          const SizedBox(height: 4),
          Text(
            'Distanzgewichtete Schätzung aus den Fahrtdauern der einzelnen Routenabschnitte.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _NextStopBanner extends StatelessWidget {
  final EtaStep step;

  const _NextStopBanner({required this.step});

  @override
  Widget build(BuildContext context) {
    final isBreak = step.type == EtaEventType.breakTime;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(isBreak ? Icons.coffee_rounded : Icons.nightlight_round),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isBreak ? 'Nächste Lenkpause' : 'Nächste Ruhezeit',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (step.start != null)
                  Text(DateFormat('EEEE, HH:mm', 'de').format(step.start!)),
              ],
            ),
          ),
          Text(
            _duration(step.duration.inMinutes),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _TourHeader extends StatelessWidget {
  final String origin;
  final String destination;
  final EtaSummary summary;
  final DateTime arrival;

  const _TourHeader({
    required this.origin,
    required this.destination,
    required this.summary,
    required this.arrival,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF102A43),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'DEINE TOUR',
            style: TextStyle(
              color: Color(0xFF9FB3C8),
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_shortPlace(origin)}  →  ${_shortPlace(destination)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${summary.distanceKm.toStringAsFixed(0)} km · '
            '${_duration(summary.drivingMinutes)} reine Fahrzeit · '
            'Ø ${_speed(summary.averageKmh)} km/h',
            style: const TextStyle(color: Color(0xFFD9E2EC), fontSize: 15),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.flag_rounded, color: Color(0xFF69F0AE)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Ankunft ${DateFormat('EEEE, HH:mm', 'de').format(arrival)}',
                  style: const TextStyle(
                    color: Color(0xFF69F0AE),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  final EtaSummary summary;
  final DateTime arrival;

  const _SummaryGrid({required this.summary, required this.arrival});

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label, String value, Color color})>[
      (
        icon: Icons.route_rounded,
        label: 'Noch zu fahren',
        value: '${summary.distanceKm.toStringAsFixed(0)} km',
        color: const Color(0xFF1565C0),
      ),
      (
        icon: Icons.local_shipping_rounded,
        label: 'Reine Fahrzeit',
        value: _duration(summary.drivingMinutes),
        color: const Color(0xFF6A1B9A),
      ),
      (
        icon: Icons.hotel_rounded,
        label: 'Pausen / Ruhe',
        value: _duration(summary.nonDrivingMinutes),
        color: const Color(0xFFEF6C00),
      ),
      (
        icon: Icons.flag_rounded,
        label: 'ETA',
        value: DateFormat('EEE HH:mm', 'de').format(arrival),
        color: const Color(0xFF087F5B),
      ),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760
          ? 4
          : constraints.maxWidth >= 330
              ? 2
              : 1;
      const gap = 10.0;
      final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final item in items)
                SizedBox(
                  width: width,
                  child: _SummaryCard(
                    icon: item.icon,
                    label: item.label,
                    value: item.value,
                    color: item.color,
                  ),
                ),
            ],
          ),
          if (summary.tenHourDaysUsed > 0 ||
              summary.reducedDailyRestsUsed > 0) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (summary.tenHourDaysUsed > 0)
                  Chip(
                    avatar: const Icon(Icons.schedule_rounded, size: 18),
                    label: Text(
                        '10-h-Fahrt: ${summary.tenHourDaysUsed} von 2 verwendet'),
                  ),
                if (summary.reducedDailyRestsUsed > 0)
                  Chip(
                    avatar: const Icon(Icons.nightlight_round, size: 18),
                    label: Text(
                        '9-h-Ruhe: ${summary.reducedDailyRestsUsed} von 3 verwendet'),
                  ),
              ],
            ),
          ],
        ],
      );
    });
  }
}

String _speed(double kmh) {
  return kmh == kmh.roundToDouble()
      ? kmh.toStringAsFixed(0)
      : kmh.toStringAsFixed(1);
}

class _SummaryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 23),
          const SizedBox(height: 14),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: color,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final EtaStep step;
  final bool isLast;

  const _TimelineRow({required this.step, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final visual = _visualFor(step.type);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 42,
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: visual.color.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(visual.icon, color: visual.color, size: 20),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title ?? step.text,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (step.start != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      _eventTime(step),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if ((step.detail ?? '').isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(step.detail!),
                  ],
                  if (step.restSatisfied != null) ...[
                    const SizedBox(height: 7),
                    _RestBadge(satisfied: step.restSatisfied!),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RestBadge extends StatelessWidget {
  final bool satisfied;

  const _RestBadge({required this.satisfied});

  @override
  Widget build(BuildContext context) {
    final color = satisfied ? const Color(0xFF087F5B) : const Color(0xFFC2410C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        satisfied ? '✓ Ruhezeit erfüllt' : 'Ruhezeit noch nicht erfüllt',
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

({IconData icon, Color color}) _visualFor(EtaEventType type) {
  return switch (type) {
    EtaEventType.start => (
        icon: Icons.local_shipping_rounded,
        color: const Color(0xFF1565C0)
      ),
    EtaEventType.drive => (
        icon: Icons.route_rounded,
        color: const Color(0xFF1565C0)
      ),
    EtaEventType.breakTime => (
        icon: Icons.coffee_rounded,
        color: const Color(0xFF8D6E63)
      ),
    EtaEventType.dailyRest => (
        icon: Icons.nightlight_round,
        color: const Color(0xFF6A1B9A)
      ),
    EtaEventType.weeklyRest => (
        icon: Icons.hotel_rounded,
        color: const Color(0xFF4527A0)
      ),
    EtaEventType.tank => (
        icon: Icons.local_gas_station_rounded,
        color: const Color(0xFFEF6C00)
      ),
    EtaEventType.wait => (
        icon: Icons.hourglass_bottom_rounded,
        color: const Color(0xFF455A64)
      ),
    EtaEventType.ferry => (
        icon: Icons.directions_boat_rounded,
        color: const Color(0xFF0277BD)
      ),
    EtaEventType.stop => (
        icon: Icons.anchor_rounded,
        color: const Color(0xFF0277BD)
      ),
    EtaEventType.destination => (
        icon: Icons.flag_rounded,
        color: const Color(0xFF087F5B)
      ),
    EtaEventType.notice => (
        icon: Icons.info_outline_rounded,
        color: const Color(0xFF455A64)
      ),
  };
}

String _eventTime(EtaStep step) {
  final start = step.start!;
  final end = step.end;
  final startText = DateFormat('EEE, dd.MM. HH:mm', 'de').format(start);
  if (end == null || end == start) return startText;
  final sameDay = start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  return sameDay
      ? '$startText – ${DateFormat('HH:mm').format(end)}'
      : '$startText – ${DateFormat('EEE, dd.MM. HH:mm', 'de').format(end)}';
}

String _duration(int minutes) {
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest min';
  if (rest == 0) return '$hours h';
  return '$hours h ${rest.toString().padLeft(2, '0')} min';
}

String _shortPlace(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '–';
  return trimmed.split(',').first.trim();
}
