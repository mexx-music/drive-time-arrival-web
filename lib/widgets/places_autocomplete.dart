import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

enum PlacesAutocompleteMode { inline, bottomSheet }

const int _kMinChars = 3;
const Duration _kDebounce = Duration(milliseconds: 500);

class PlacesAutocompleteField extends StatefulWidget {
  const PlacesAutocompleteField({
    super.key,
    required this.apiKey,
    required this.controller,
    this.hintText,
    this.language = 'de',
    this.country,
    this.onPlacePicked,
    this.originLat,
    this.originLng,
    this.biasRadiusMeters,
    this.includedPrimaryTypes,
    this.includeQueryPredictions = false,
    this.mode = PlacesAutocompleteMode.inline,
    this.onSearchPressed,
  });

  final String apiKey;
  final TextEditingController controller;
  final String? hintText;
  final String language;
  final String? country;
  final void Function(
          String description, String placeId, double? lat, double? lng)?
      onPlacePicked;
  final PlacesAutocompleteMode mode;
  final VoidCallback? onSearchPressed;

  // Bias / Filter
  final double? originLat;
  final double? originLng;
  final int? biasRadiusMeters;
  final List<String>? includedPrimaryTypes;
  final bool includeQueryPredictions;

  @override
  State<PlacesAutocompleteField> createState() =>
      _PlacesAutocompleteFieldState();
}

class _PlacesAutocompleteFieldState extends State<PlacesAutocompleteField> {
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  List<_Pred> _items = [];
  String _sessionToken = const Uuid().v4();
  bool _showInlineList = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_handleFocus);
    _focus.dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (!_focus.hasFocus) {
      setState(() => _showInlineList = false);
    }
  }

  String _short(String desc) {
    if (desc.isEmpty) return desc;
    final i = desc.indexOf(',');
    final base = (i > 0) ? desc.substring(0, i).trim() : desc.trim();
    return (base.length > 30) ? '${base.substring(0, 30).trimRight()}…' : base;
  }

  double? _safeRadiusMeters(int? v) {
    if (v == null) return null;
    final d = v.toDouble();
    if (d <= 0) return null;
    return d > 50000 ? 50000.0 : d;
  }

  void _onChanged(String s) {
    _debounce?.cancel();
    if (s.trim().length < _kMinChars) {
      setState(() {
        _items = [];
        _showInlineList = false;
      });
      return;
    }
    _debounce = Timer(_kDebounce, () => _fetch(s));
  }

  Future<void> _fetch(String q) async {
    final Map<String, dynamic> originPart =
        (widget.originLat != null && widget.originLng != null)
            ? {
                'origin': {
                  'latitude': widget.originLat,
                  'longitude': widget.originLng,
                }
              }
            : {};

    final double? safeR = _safeRadiusMeters(widget.biasRadiusMeters);
    final Map<String, dynamic> biasPart =
        (safeR != null && widget.originLat != null && widget.originLng != null)
            ? {
                'locationBias': {
                  'circle': {
                    'center': {
                      'latitude': widget.originLat,
                      'longitude': widget.originLng,
                    },
                    'radius': safeR,
                  }
                }
              }
            : {};

    final body = <String, dynamic>{
      'input': q,
      'languageCode': widget.language,
      'sessionToken': _sessionToken,
      'includeQueryPredictions': widget.includeQueryPredictions,
      if (widget.country != null) 'regionCode': widget.country!.toUpperCase(),
      'includedPrimaryTypes':
          widget.includedPrimaryTypes ?? const ['locality', 'postal_code'],
      ...originPart,
      ...biasPart,
    };

    try {
      final res = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': widget.apiKey,
          'X-Goog-FieldMask': '*',
        },
        body: jsonEncode(body),
      );

      if (res.statusCode != 200) {
        if (kDebugMode) {
          // ignore: avoid_print
          print('[PlacesAutocomplete] HTTP ${res.statusCode}');
          // ignore: avoid_print
          print('[PlacesAutocomplete] ${res.body}');
        }
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Places Autocomplete: HTTP ${res.statusCode}')));
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['suggestions'] as List? ?? []);
      final newItems = list.map((s) {
        final pred = (s['placePrediction'] as Map<String, dynamic>?) ?? {};
        final text = (pred['text']?['text'] ?? '') as String;
        final id = (pred['placeId'] ?? '') as String;
        return _Pred(text, id);
      }).toList();

      if (!mounted) return;
      setState(() {
        _items = newItems;
      });

      if (widget.mode == PlacesAutocompleteMode.inline) {
        setState(() => _showInlineList = _items.isNotEmpty);
      } else {
        // bottomSheet mode
        if (!kIsWeb) {
          _showBottomSheet(_items);
        } else {
          // as fallback show inline on desktop/web
          setState(() => _showInlineList = _items.isNotEmpty);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[PlacesAutocomplete] fetch error: $e');
      }
    }
  }

  Future<void> _showBottomSheet(List<_Pred> itemsSnapshot) async {
    final res = await showModalBottomSheet<String?>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: itemsSnapshot.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Keine Vorschläge'))
                : ListView.separated(
                    itemCount: itemsSnapshot.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = itemsSnapshot[i];
                      final desc = it.description ?? '';
                      final short = _short(desc);
                      return ListTile(
                        title: Text(short),
                        subtitle: desc != short ? Text(desc) : null,
                        onTap: () {
                          Navigator.of(ctx).pop(it.description);
                        },
                      );
                    },
                  ),
          ),
        );
      },
    );

    if (res != null) {
      // res contains full description
      await _handleSelection(res, null, null);
    }
  }

  Future<void> _handleSelection(
      String description, double? lat, double? lng) async {
    final short = _short(description);
    widget.controller.text = short;
    widget.onPlacePicked?.call(description, '', lat, lng);
    try {
      FocusScope.of(context).unfocus();
    } catch (_) {}
  }

  Future<void> _pickDetailAndSelect(_Pred p) async {
    // fetch details to get lat/lng, then select
    double? lat;
    double? lng;
    try {
      final detRes = await http.get(
        Uri.parse(
            'https://places.googleapis.com/v1/places/${Uri.encodeComponent(p.placeId)}'),
        headers: {
          'X-Goog-Api-Key': widget.apiKey,
          'X-Goog-FieldMask': '*',
        },
      );

      if (detRes.statusCode == 200) {
        final body = jsonDecode(detRes.body) as Map<String, dynamic>;
        final loc = body['location'] as Map<String, dynamic>?;
        if (loc != null) {
          lat = (loc['latitude'] as num).toDouble();
          lng = (loc['longitude'] as num).toDouble();
        }
      }
    } catch (_) {}

    await _handleSelection(p.description, lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == PlacesAutocompleteMode.inline) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            focusNode: _focus,
            controller: widget.controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: widget.hintText,
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Suchen',
                    onPressed: widget.onSearchPressed),
                IconButton(
                    icon: const Icon(Icons.keyboard_hide),
                    tooltip: 'Tastatur ausblenden',
                    onPressed: () => FocusScope.of(context).unfocus()),
              ]),
            ),
            onChanged: _onChanged,
            onSubmitted: (_) => widget.onSearchPressed?.call(),
          ),
          if (_showInlineList && _items.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8)),
              margin: const EdgeInsets.only(top: 4),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  final desc = it.description ?? '';
                  final short = _short(desc);
                  return ListTile(
                    title: Text(short),
                    subtitle: desc != short
                        ? Text(desc,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54))
                        : null,
                    onTap: () async => await _pickDetailAndSelect(it),
                  );
                },
              ),
            ),
        ],
      );
    }

    // bottomSheet mode: show only a TextField; results are shown in bottomSheet
    return TextField(
      focusNode: _focus,
      controller: widget.controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
          labelText: widget.hintText,
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Suchen',
                onPressed: widget.onSearchPressed),
            IconButton(
                icon: const Icon(Icons.keyboard_hide),
                tooltip: 'Tastatur ausblenden',
                onPressed: () => FocusScope.of(context).unfocus()),
          ])),
      onChanged: _onChanged,
      onSubmitted: (_) => widget.onSearchPressed?.call(),
    );
  }
}

class _Pred {
  _Pred(this.description, this.placeId);
  final String description;
  final String placeId;
}
