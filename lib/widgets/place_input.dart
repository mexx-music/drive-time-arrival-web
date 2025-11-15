import 'package:flutter/material.dart';
import '../widgets/places_autocomplete.dart';
import '../core/feature_flags.dart';
import '../secrets.dart';

class PlaceInput extends StatefulWidget {
  final String label;
  final String hint;
  final String initialText;
  final ValueChanged<String>? onConfirmed;
  final ValueChanged<String>? onChanged;
  final bool inlineAutocomplete; // if true show inline suggestions (no modal)

  const PlaceInput({
    super.key,
    required this.label,
    required this.hint,
    this.initialText = '',
    this.onConfirmed,
    this.onChanged,
    this.inlineAutocomplete = false,
  });

  @override
  State<PlaceInput> createState() => _PlaceInputState();
}

class _PlaceInputState extends State<PlaceInput>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _ctl;
  late final FocusNode _focus;

  // Shorten a full place description for display in the text field
  String _shorten(String s) {
    if (s.isEmpty) return s;
    final i = s.indexOf(',');
    final base = (i > 0) ? s.substring(0, i).trim() : s.trim();
    return (base.length > 30) ? base.substring(0, 30).trimRight() + '…' : base;
  }

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialText);
    _focus = FocusNode();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _confirm() async {
    // When user confirms, open a modal with PlacesAutocompleteField so network
    // activity only happens on explicit action.
    final res = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final c = TextEditingController(text: _ctl.text);
        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SizedBox(
            height: 420,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                          child: Text('Suche Ort',
                              style: Theme.of(ctx).textTheme.titleMedium)),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        icon: const Icon(Icons.close),
                      )
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: PlacesAutocompleteField(
                      apiKey: GOOGLE_MAPS_API_KEY, // use global API key
                      controller: c,
                      onPlacePicked: (description, placeId, lat, lng) {
                        // Return the full description from the modal but display only the short name
                        Navigator.of(ctx).pop(description);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (res != null && res.isNotEmpty) {
      final short = _shorten(res);
      _ctl.text = short; // show short in the field
      // call parent with full description for geocoding/timezone etc.
      widget.onConfirmed?.call(res);
    } else {
      // If modal returned null, still call onConfirmed with current text (raw)
      widget.onConfirmed?.call(_ctl.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // If inlineAutocomplete is requested, render the existing PlacesAutocompleteField
    // directly (it manages its own debounce and overlay). We reuse our persistent
    // controller so the controller/focus remains stable across rebuilds.
    if (widget.inlineAutocomplete) {
      return PlacesAutocompleteField(
        apiKey: GOOGLE_MAPS_API_KEY,
        controller: _ctl,
        hintText: widget.hint,
        mode: PlacesAutocompleteMode.inline,
        onPlacePicked: (description, placeId, lat, lng) {
          // show shortened text but inform parent with full description
          final short = _shorten(description);
          _ctl.text = short;
          widget.onConfirmed?.call(description);
        },
        onSearchPressed: () => widget.onConfirmed?.call(_ctl.text),
      );
    }

    if (!FeatureFlags.keepAlivePlaceInputs) {
      // Fallback: simple TextField when flag disabled; keep behavior minimal.
      return TextField(
        controller: _ctl,
        focusNode: _focus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Suchen',
                  icon: const Icon(Icons.search),
                  onPressed: _confirm,
                ),
                IconButton(
                  tooltip: 'Tastatur ausblenden',
                  icon: const Icon(Icons.keyboard_hide),
                  onPressed: () => FocusScope.of(context).unfocus(),
                ),
              ],
            )),
        onChanged: (s) => widget.onChanged?.call(s),
        onSubmitted: (_) => _confirm(),
      );
    }

    return TextField(
      controller: _ctl,
      focusNode: _focus,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Suchen',
              icon: const Icon(Icons.search),
              onPressed: _confirm,
            ),
            IconButton(
              tooltip: 'Tastatur ausblenden',
              icon: const Icon(Icons.keyboard_hide),
              onPressed: () => FocusScope.of(context).unfocus(),
            ),
          ],
        ),
      ),
      onChanged: (s) => widget.onChanged?.call(s),
      onSubmitted: (_) => _confirm(),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
