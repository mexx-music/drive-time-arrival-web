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

  const PlaceInput({
    super.key,
    required this.label,
    required this.hint,
    this.initialText = '',
    this.onConfirmed,
    this.onChanged,
  });

  @override
  State<PlaceInput> createState() => _PlaceInputState();
}

class _PlaceInputState extends State<PlaceInput>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _ctl;
  late final FocusNode _focus;

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
      _ctl.text = res;
      widget.onConfirmed?.call(res);
    } else {
      // If modal returned null, still call onConfirmed with current text
      widget.onConfirmed?.call(_ctl.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!FeatureFlags.keepAlivePlaceInputs) {
      // Fallback: simple TextField when flag disabled; keep behavior minimal.
      return TextField(
        controller: _ctl,
        focusNode: _focus,
        decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            suffixIcon: IconButton(
                icon: const Icon(Icons.search), onPressed: _confirm)),
        onChanged: (s) => widget.onChanged?.call(s),
        onSubmitted: (s) => widget.onConfirmed?.call(s),
      );
    }

    return TextField(
      controller: _ctl,
      focusNode: _focus,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixIcon: IconButton(
          icon: const Icon(Icons.search),
          onPressed: _confirm,
        ),
      ),
      onChanged: (s) => widget.onChanged?.call(s),
      onSubmitted: (s) => widget.onConfirmed?.call(s),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
