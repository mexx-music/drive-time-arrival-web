import 'package:flutter/material.dart';

import '../logic/avoidable_countries.dart';

/// Kleine, unauffällige Auswahl gesperrter Länder.
///
/// Zugeklappt:  🌍 Länder vermeiden · Keine ▾
/// Bei Auswahl: 🌍 Länder vermeiden · 2 aktiv ▾
///
/// Der Fahrer wählt hier nur, welches Land er nicht befahren will – wie
/// umfahren wird, entscheidet die App automatisch.
class AvoidCountriesSelector extends StatefulWidget {
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  const AvoidCountriesSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<AvoidCountriesSelector> createState() => _AvoidCountriesSelectorState();
}

class _AvoidCountriesSelectorState extends State<AvoidCountriesSelector> {
  bool _open = false;

  String get _summary {
    final n = widget.selected.length;
    if (n == 0) return 'Keine';
    if (n == 1) {
      return avoidableCountryNameDe(widget.selected.first);
    }
    return '$n aktiv';
  }

  void _toggle(String iso, bool on) {
    final next = Set<String>.from(widget.selected);
    if (on) {
      next.add(iso);
    } else {
      next.remove(iso);
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.selected.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🌍 ', style: TextStyle(fontSize: 13)),
                // Flexible + Ellipsis: lange Ländernamen (z. B. "Bosnien und
                // Herzegowina") dürfen die Zeile auf schmalen Displays nicht
                // sprengen.
                Flexible(
                  child: Text(
                    'Länder vermeiden · $_summary',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                      color: active ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
                Icon(
                  _open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 18,
                  color: active ? theme.colorScheme.primary : null,
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.6)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in kAvoidableCountries)
                  InkWell(
                    onTap: () => _toggle(c.iso, !widget.selected.contains(c.iso)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: Checkbox(
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              value: widget.selected.contains(c.iso),
                              onChanged: (v) => _toggle(c.iso, v ?? false),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(c.label,
                                style: theme.textTheme.bodySmall),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
