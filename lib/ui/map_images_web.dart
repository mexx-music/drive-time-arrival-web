import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Merkt sich jede MapLibre-Karte, sobald sie ein Bild bekommt (über
/// `maplibregl.Map.prototype.addImage`). Einmal je Seite; vor dem ersten
/// eigenen addImage aufrufen.
void trackMapImages() {
  final lib = globalContext['maplibregl'];
  if (lib == null) return;
  // Map ist eine Klasse, also eine JS-Funktion (kein reines Objekt).
  final mapClass = (lib as JSObject)['Map'];
  if (mapClass == null) return;
  final proto = (mapClass as JSObject)['prototype'];
  if (proto == null) return;
  _patch(proto as JSObject);
}

void _patch(JSObject proto) {
  if (proto['__dtTracked'] != null) return;
  final original = proto['addImage'] as JSFunction;
  proto['addImage'] = ((JSObject self, JSAny? id, JSAny? image, JSAny? options) {
    _maps.add(self);
    return original.callAsFunction(self, id, image, options);
  }).toJSCaptureThis;
  proto['__dtTracked'] = true.toJS;
}

final Set<JSObject> _maps = {};

/// Bild [name] aus allen bekannten Karten entfernen, wo vorhanden.
void removeMapImage(String name) {
  final id = name.toJS;
  // Entsorgte Karten (Container nicht mehr im Dokument) vergessen.
  _maps.removeWhere((m) {
    try {
      final c = m.callMethod<JSObject>('getContainer'.toJS);
      return !(c['isConnected'] as JSBoolean).toDart;
    } catch (_) {
      return true;
    }
  });
  for (final m in _maps) {
    try {
      if ((m.callMethod<JSBoolean>('hasImage'.toJS, id)).toDart) {
        m.callMethod<JSAny?>('removeImage'.toJS, id);
      }
    } catch (_) {
      // Karte schon entsorgt – ignorieren.
    }
  }
}

/// Die Karte, die schon das Bild [probe] hat (die eigene Tourkarte).
JSObject? _mapWith(String probe) {
  final id = probe.toJS;
  for (final m in _maps.toList().reversed) {
    try {
      final c = m.callMethod<JSObject>('getContainer'.toJS);
      if (!(c['isConnected'] as JSBoolean).toDart) continue;
      if ((m.callMethod<JSBoolean>('hasImage'.toJS, id)).toDart) return m;
    } catch (_) {}
  }
  return null;
}

/// Rohe RGBA-Pixel direkt an MapLibre geben – ohne das PNG-Dekodieren des
/// Plugins (reines Dart, Pixel für Pixel). Liefert false, wenn die Karte
/// nicht gefunden wird; dann nimmt der Aufrufer den bisherigen Weg.
bool addRawMapImage(String name, int width, int height, Uint8List rgba, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return false;
  try {
    if ((m.callMethod<JSBoolean>('hasImage'.toJS, name.toJS)).toDart) return true;
    final image = JSObject()
      ..['width'] = width.toJS
      ..['height'] = height.toJS
      ..['data'] = rgba.toJS;
    final options = JSObject()..['pixelRatio'] = 1.toJS;
    m.callMethod<JSAny?>('addImage'.toJS, name.toJS, image, options);
    return true;
  } catch (_) {
    return false;
  }
}

/// Pixeldichte der Kartenfläche höchstens [max] (z. B. 1,5 statt 2 auf dem
/// iPad: 44 % weniger Bildpunkte zu zeichnen). Die Flutter-Ebenen (HUD,
/// Texte) bleiben in voller Schärfe.
void capMapPixelRatio(double max, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return;
  try {
    final current = (m.callMethod<JSNumber>('getPixelRatio'.toJS)).toDartDouble;
    if (current > max) m.callMethod<JSAny?>('setPixelRatio'.toJS, max.toJS);
  } catch (_) {}
}

/// Icon des ersten gezeichneten Symbols der Ebene [layer] (Videoexport:
/// Nachweis, dass das gewünschte Fahrzeugbild wirklich gezeichnet ist).
String? renderedIcon(String layer, {required String sameMapAs}) {
  final m = _mapWith(sameMapAs);
  if (m == null) return null;
  try {
    final options = JSObject()..['layers'] = [layer.toJS].toJS;
    final list = m.callMethod<JSArray<JSObject>>('queryRenderedFeatures'.toJS, options).toDart;
    if (list.isEmpty) return null;
    final props = list.first['properties'] as JSObject?;
    final icon = props?['icon'];
    return icon == null ? null : (icon as JSString).toDart;
  } catch (_) {
    return null;
  }
}
