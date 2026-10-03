import 'dart:js_interop';
import 'dart:js_interop_unsafe';

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
