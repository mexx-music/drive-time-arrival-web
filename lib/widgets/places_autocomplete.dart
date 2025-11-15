import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

enum PlacesAutocompleteMode { inline, overlay, bottomSheet }

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
    this.mode = PlacesAutocompleteMode.overlay,
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
  final _focus = FocusNode();
  final _link = LayerLink();
  OverlayEntry? _overlay;
  Timer? _debounce;
  List<_Pred> _items = [];
  String _sessionToken = const Uuid().v4();
  bool _isPickingFromOverlay = false;
  bool _isOpenOverlay = false;
  bool _showInlineList = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _removeOverlay();
    _focus.removeListener(_handleFocus);
    _focus.dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (!_focus.hasFocus && !_isPickingFromOverlay) _removeOverlay();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
    _isOpenOverlay = false;
  }

  // ✅ Bias: max. 50 km – sonst weglassen
  double? _safeRadiusMeters(int? v) {
    if (v == null) return null;
    final d = v.toDouble();
    if (d <= 0) return null;
    return d > 50000 ? 50000.0 : d;
  }

  Future<void> _fetch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _items = []);
      _removeOverlay();
      return;
    }

    // ✅ origin: direkt {latitude, longitude}
    final Map<String, dynamic> originPart =
        (widget.originLat != null && widget.originLng != null)
            ? {
                'origin': {
                  'latitude': widget.originLat,
                  'longitude': widget.originLng,
                }
              }
            : {};

    // ✅ locationBias.circle.center: ebenfalls direkt {latitude, longitude}
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
                    'radius': safeR, // <= 50000.0 garantiert
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

      setState(() => _items = newItems);
      _showOverlay();
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[PlacesAutocomplete] fetch error: $e');
      }
    }
  }

  Future<void> _pick(_Pred p) async {
    final desc = p.description;
    // write short description to controller for display
    final short = desc.contains(',') ? desc.split(',').first.trim() : (desc.length > 30 ? '${desc.substring(0, 30).trim()}…' : desc);
    widget.controller.text = short;

    // if inline mode, clear inline list; overlays will be closed by their path
    if (widget.mode == PlacesAutocompleteMode.inline) {
      setState(() {
        _items = [];
        _showInlineList = false;
      });
    } else {
      _removeOverlay();
    }

    double? lat, lng;
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

    widget.onPlacePicked?.call(p.description, p.placeId, lat, lng);
    _sessionToken = const Uuid().v4();
    // close keyboard after selection (exactly once, here)
    try {
      FocusScope.of(context).unfocus();
    } catch (_) {}
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

  void _showOverlay() {
    // For inline mode we render suggestions inside build(); for overlay/bottomSheet use existing behaviour
    if (widget.mode == PlacesAutocompleteMode.inline) {
      setState(() => _showInlineList = _items.isNotEmpty);
      return;
    }

    if (_isOpenOverlay) return; // guard against double opens
    _isOpenOverlay = true;

    _removeOverlay();

    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? const Size(320, 48);

    // On mobile prefer a bottom sheet so suggestions are visible above the IME
    if (widget.mode == PlacesAutocompleteMode.bottomSheet &&
        (Platform.isAndroid || Platform.isIOS)) {
      final itemsSnapshot = List<_Pred>.from(_items);
      // show sheet (do not change focus here)
      showModalBottomSheet<void>(
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
                        final short = desc.contains(',')
                            ? desc.split(',').first.trim()
                            : (desc.length > 30
                                ? '${desc.substring(0, 30).trim()}…'
                                : desc);
                        return ListTile(
                          title: Text(short),
                          subtitle: desc != short ? Text(desc) : null,
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _pick(it);
                          },
                        );
                      },
                    ),
            ),
          );
        },
      ).whenComplete(() => _isOpenOverlay = false);
      return;
    }

    // overlay mode (desktop / web) – show an OverlayEntry positioned below field
    _overlay = OverlayEntry(builder: (overlayContext) {
      return Positioned(
        width: size.width,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          offset: Offset(0, size.height + 4),
          child: Material(
            color: Colors.white, // make explicit for Android
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  return InkWell(
                    onTapDown: (_) => _isPickingFromOverlay = true,
                    onTap: () async {
                      try {
                        await _pick(it);
                      } finally {
                        _isPickingFromOverlay = false;
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      child: Builder(builder: (_) {
                        final desc = it.description ?? '';
                        final short = desc.contains(',')
                            ? desc.split(',').first.trim()
                            : (desc.length > 30
                                ? '${desc.substring(0, 30).trim()}…'
                                : desc);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(short,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.black)),
                            if (desc != short)
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Text(desc,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.black54, fontSize: 12)),
                              ),
                          ],
                        );
                      }),
                    ),
                  );
                },
              ),
            ),
          ),
        },
      );
    });

    final overlayState = Overlay.of(context);
    overlayState?.insert(_overlay!);
    // when overlay removed elsewhere, clear flag in _removeOverlay
  }

  void _removeInlineSuggestions() {
    setState(() {
      _items = [];
      _showInlineList = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Inline mode: render TextField + suggestions list below inside this widget
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
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Suchen',
                    icon: const Icon(Icons.search),
                    onPressed: widget.onSearchPressed,
                  ),
                  IconButton(
                    tooltip: 'Tastatur ausblenden',
                    icon: const Icon(Icons.keyboard_hide),
                    onPressed: () => FocusScope.of(context).unfocus(),
                  ),
                ],
              ),
            ),
            onChanged: _onChanged,
            onSubmitted: (_) => widget.onPlacePicked?.call(widget.controller.text, '', null, null),
          ),
          if (_showInlineList && _items.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black12),
                borderRadius: BorderRadius.circular(8),
              ),
              margin: const EdgeInsets.only(top: 4),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  final desc = it.description ?? '';
                  final short = desc.contains(',')
                      ? desc.split(',').first.trim()
                      : (desc.length > 30 ? '${desc.substring(0, 30).trim()}…' : desc);
                  return ListTile(
                    title: Text(short),
                    subtitle: desc != short ? Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.black54)) : null,
                    onTap: () async {
                      await _pick(it);
                      // notify parent via callback
                      widget.onPlacePicked?.call(it.description, it.placeId, null, null);
                    },
                  );
                },
              ),
            ),
        ],
      );
    }

    return CompositedTransformTarget(
      link: _link,
      child: TextField(
        focusNode: _focus,
        controller: widget.controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(labelText: widget.hintText),
        onChanged: _onChanged,
        onSubmitted: (_) => widget.onPlacePicked?.call(widget.controller.text, '', null, null),
      ),
    );
  }
}

class _Pred {
  _Pred(this.description, this.placeId);
  final String description;
  final String placeId;
}
