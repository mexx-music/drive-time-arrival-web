import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/places_autocomplete.dart';
import '../services/geocoding_service.dart';
import '../core/feature_flags.dart';
import 'package:driverroute_eta/secrets.dart';

class PlaceInput extends StatefulWidget {
  final String label;
  final String hint;
  final String initialText;
  final TextEditingController controller;
  final ValueChanged<String>? onConfirmed;
  final ValueChanged<String>? onChanged;
  final bool inlineAutocomplete; // if true show inline suggestions (no modal)

  const PlaceInput({
    super.key,
    required this.label,
    required this.hint,
    this.initialText = '',
    required this.controller,
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
  final FocusNode _focusNode = FocusNode();

  String? _resolvedPreview;
  int _reqCounter = 0;
  int _activeReqId = 0;
  String _pendingQuery = '';
  String? _lastSelectedSuggestion;
  bool _hasSelectedSuggestion = false;
  bool _suppressControllerListener = false;
  bool _isTyping = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _ctl = widget.controller;
    if (_ctl.text.isEmpty && widget.initialText.isNotEmpty) {
      _ctl.text = widget.initialText;
    }

    _ctl.addListener(_handleControllerChange);

    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _handleFocusLost();
      }
    });
  }

  @override
  void dispose() {
    _ctl.removeListener(_handleControllerChange);
    _typingTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleControllerChange() {
    if (_suppressControllerListener) return;

    _isTyping = true;
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 700), () {
      _isTyping = false;
    });

    if (_lastSelectedSuggestion != null || _hasSelectedSuggestion) {
      _lastSelectedSuggestion = null;
      _hasSelectedSuggestion = false;
      if (_isDestinationField) {
        debugPrint('destination typed text changed, stale suggestion cleared');
      }
    }
  }

  bool get _isDestinationField {
    final lab = widget.label.toLowerCase();
    return lab.contains('ziel') ||
        lab.contains('destination') ||
        lab.contains('dest');
  }

  bool get _isStartField {
    final lab = widget.label.toLowerCase();
    return lab.contains('start');
  }

  void _applyResolvedValue(String value) {
    _suppressControllerListener = true;
    _ctl.text = value;
    _suppressControllerListener = false;
    _resolvedPreview = value;

    setState(() {});

    widget.onChanged?.call(value);
    widget.onConfirmed?.call(value);

    debugPrint('applied resolved place for ${widget.label}: $value');
  }

  Future<void> _handleFocusLost() async {
    final raw = _ctl.text.trim();
    if (raw.isEmpty) return;

    if (_hasSelectedSuggestion) {
      debugPrint('focus loss: has explicit selection, skipping fallback');
      return;
    }

    if (_isTyping) {
      debugPrint('focus loss: skipping geocoding during typing');
      return;
    }

    debugPrint('focus loss: triggering geocoding fallback');

    try {
      final res = await GeocodingService.resolve(raw);
      if (res != null && res.description.isNotEmpty) {
        _applyResolvedValue(res.description);
        debugPrint('preview resolved ${widget.label}: ${res.description}');
      }
    } catch (e) {
      debugPrint('geocoding fallback failed on focus loss: $e');
    }
  }

  Future<void> _verifyCurrentText() async {
    final raw = _ctl.text.trim();
    if (raw.isEmpty) return;

    if (_isTyping) {
      // User explicitly pressed verify; cancel typing debounce and proceed immediately
      _typingTimer?.cancel();
      _isTyping = false;
      debugPrint('verify button: forcing finalization immediately');
    }

    try {
      final res = await GeocodingService.resolve(raw);
      if (res != null && res.description.isNotEmpty) {
        _applyResolvedValue(res.description);
        debugPrint('preview resolved ${widget.label}: ${res.description}');
      }
    } catch (e) {
      debugPrint('verify button geocoding failed for ${widget.label}: $e');
    }
  }

  Future<void> _finalizeInput({bool force = false}) async {
    final raw = _ctl.text.trim();
    if (raw.isEmpty) return;

    if (!force && _isTyping) {
      debugPrint('typing: no geocoding');
      return;
    }

    if (!force) {
      debugPrint('focus loss: no autocomplete applied');
      return;
    }

    final myId = ++_reqCounter;
    _activeReqId = myId;

    debugPrint(
      'autocomplete request started for field "${widget.label}": $raw (id=$myId)',
    );

    if (force) {
      debugPrint('geocoding triggered by submit/calculate');
    }

    if (_hasSelectedSuggestion && _lastSelectedSuggestion != null) {
      debugPrint('explicit autocomplete selection: ${_lastSelectedSuggestion}');
      _hasSelectedSuggestion = false;
      return;
    }

    try {
      final res = await GeocodingService.resolve(raw);

      if (_activeReqId != myId || _ctl.text.trim() != raw) {
        debugPrint(
          'stale autocomplete response ignored for field "${widget.label}" (id=$myId)',
        );
        return;
      }

      if (res != null && res.description.isNotEmpty) {
        _applyResolvedValue(res.description);

        if (_isStartField) {
          debugPrint('visible finalization for start: ${res.description}');
          debugPrint('visible finalization by submit for start: ${res.description}');
        } else if (_isDestinationField) {
          debugPrint(
            'destination finalized from raw text via geocoding: ${res.description}',
          );
          debugPrint(
            'visible finalization by submit for destination: ${res.description}',
          );
        } else {
          debugPrint('visible finalization: ${res.description}');
          debugPrint(
            'visible finalization by submit for ${widget.label}: ${res.description}',
          );
        }

        _hasSelectedSuggestion = false;
        debugPrint('geocoding finalized: ${res.description}');
        debugPrint('geocoding finalized from stable input: ${res.description}');
        return;
      }
    } catch (e) {
      debugPrint('geocoding finalize failed for field "${widget.label}": $e');
    }

    if (_isDestinationField) {
      debugPrint('destination focus loss current text: $raw');
      debugPrint(
        'destination last selected suggestion: ${_lastSelectedSuggestion ?? ''}',
      );

      if (_lastSelectedSuggestion != null && _lastSelectedSuggestion!.isNotEmpty) {
        final lowCur = raw.toLowerCase();
        final lowSel = _lastSelectedSuggestion!.toLowerCase();

        final relevant = lowCur.isEmpty ||
            lowSel.contains(lowCur) ||
            lowSel.startsWith(lowCur) ||
            lowCur.startsWith(lowSel);

        if (!relevant) {
          debugPrint(
            'stale destination selected value ignored: ${_lastSelectedSuggestion}',
          );
          _lastSelectedSuggestion = null;
          _hasSelectedSuggestion = false;
        }
      }

      debugPrint('destination focus loss with no explicit selection, keeping raw text');
    }
  }

  Future<void> _confirm() async {
    final res = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final c = TextEditingController(text: _ctl.text);
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SizedBox(
            height: 420,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Suche Ort',
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: PlacesAutocompleteField(
                      apiKey: GOOGLE_MAPS_API_KEY,
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
      final full = res;
      debugPrint('modal suggestion selected: $full');

      _lastSelectedSuggestion = full;
      _hasSelectedSuggestion = true;
      _applyResolvedValue(full);

      if (_isDestinationField) {
        debugPrint('destination explicit autocomplete selection applied: $full');
      }

      FocusScope.of(context).unfocus();
    } else {
      widget.onConfirmed?.call(_ctl.text);
    }
  }

  Widget _buildResolvedPreview() {
    if (_resolvedPreview == null) return const SizedBox.shrink();

    return Column(
      children: [
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Aufgelöst: ${_resolvedPreview!}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                final applied = _resolvedPreview!;
                _lastSelectedSuggestion = applied;
                _hasSelectedSuggestion = true;
                _applyResolvedValue(applied);
                debugPrint('applied resolved place for ${widget.label}: $applied');
              },
              child: const Text('Übernehmen'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (widget.inlineAutocomplete) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlacesAutocompleteField(
            apiKey: GOOGLE_MAPS_API_KEY,
            controller: _ctl,
            hintText: widget.hint,
            mode: PlacesAutocompleteMode.inline,
            onPlacePicked: (description, placeId, lat, lng) {
              debugPrint(
                'inline suggestion tapped for field "${widget.label}": $description',
              );

              final current = _ctl.text.trim();

              if (_isDestinationField) {
                debugPrint('destination inline selection: current text: $current');
                debugPrint('destination suggestion query: $description');

                final lowCur = current.toLowerCase();
                final lowDesc = description.toLowerCase();

                final relevant = lowCur.isEmpty ||
                    lowDesc.contains(lowCur) ||
                    lowDesc.startsWith(lowCur) ||
                    lowCur.startsWith(lowDesc);

                if (!relevant) {
                  debugPrint('stale destination suggestion ignored: $description');
                  _pendingQuery = '';
                  _activeReqId = 0;
                  return;
                }
              }

              _activeReqId = ++_reqCounter;
              _pendingQuery = description;
              _lastSelectedSuggestion = description;
              _hasSelectedSuggestion = true;

              _applyResolvedValue(description);

              debugPrint('inline selection applied to field: $description');

              if (_isDestinationField) {
                debugPrint('destination explicit autocomplete selection applied: $description');
              }
            },
            onSearchPressed: _verifyCurrentText,
          ),
          _buildResolvedPreview(),
        ],
      );
    }

    if (!FeatureFlags.keepAlivePlaceInputs) {
      return TextField(
        controller: _ctl,
        focusNode: _focusNode,
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
              TextButton(
                onPressed: _verifyCurrentText,
                child: const Text('Ort prüfen', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        onChanged: (s) => widget.onChanged?.call(s),
        onSubmitted: (value) async {
          // User pressed Enter: cancel typing debounce and finalize immediately
          _typingTimer?.cancel();
          _isTyping = false;
          debugPrint('submit: forcing finalization immediately');
          final raw = value.trim();
          if (raw.isEmpty) return;

          try {
            final res = await GeocodingService.resolve(raw);
            if (res != null && res.description.isNotEmpty) {
              _applyResolvedValue(res.description);
              debugPrint('visible finalization by submit: ${res.description}');
              return;
            }
          } catch (e) {
            debugPrint('geocoding on submit failed: $e');
          }

          await _finalizeInput(force: true);
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctl,
          focusNode: _focusNode,
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
                TextButton(
                  onPressed: _verifyCurrentText,
                  child: const Text('Ort prüfen', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          onChanged: (s) => widget.onChanged?.call(s),
          onSubmitted: (value) async {
            // User pressed Enter: cancel typing debounce and finalize immediately
            _typingTimer?.cancel();
            _isTyping = false;
            debugPrint('submit: forcing finalization immediately');
            final raw = value.trim();
            if (raw.isEmpty) return;

            try {
              final res = await GeocodingService.resolve(raw);
              if (res != null && res.description.isNotEmpty) {
                _applyResolvedValue(res.description);
                debugPrint('visible finalization by submit: ${res.description}');
                return;
              }
            } catch (e) {
              debugPrint('geocoding on submit failed: $e');
            }

            await _finalizeInput(force: true);
          },
        ),
        _buildResolvedPreview(),
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;
}