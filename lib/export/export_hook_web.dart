import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Stellt `window.drivetimeExport` bereit:
/// - `step()` rechnet genau ein Bild (1/30 s) weiter, liefert die Zeit (s),
/// - `total()` die Gesamtdauer (s),
/// - `pending()` wie viele Fahrzeugbilder noch entstehen.
/// Ein Aufnahmeskript ruft `step()`, wartet bis `pending()` 0 ist und die
/// Karte fertig gezeichnet hat, und nimmt dann das Bild auf.
void registerExportHook({
  required double Function() step,
  required double Function() total,
  required int Function() pending,
}) {
  final o = JSObject();
  o['step'] = (() => step()).toJS;
  o['total'] = (() => total()).toJS;
  o['pending'] = (() => pending()).toJS;
  globalContext['drivetimeExport'] = o;
}
