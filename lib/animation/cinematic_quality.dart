/// Renderqualität der 2.5D-Tour.
///
/// Trennt Vorschau und Film: Alle Profile zeigen dieselbe Tour mit derselben
/// Zeitleiste – Positionen, Tempo, Kamerawege, Shot-Timing, Zooms, Fähre,
/// Tageszeit, Länder, Kilometer, Zielanflug und Outro kommen unverändert
/// aus Planung und Regie. Ein Profil ändert nur, wie fein gezeichnet wird.
///
/// - [previewPerformance]: iPad, Smartphone, schwächere Geräte – flüssig
///   und stabil zuerst.
/// - [previewHigh]: leistungsfähige Rechner – höhere Live-Qualität.
/// - [exportFullHD]: der Film (Bild für Bild, 1080 × 1920, 30 fps) – nie von
///   der Leistung des Geräts abhängig, auf dem die Vorschau lief.
class CinematicQuality {
  const CinematicQuality._(
    this.id, {
    required this.spritePx,
    required this.outroSpritePx,
    required this.maxDriveSprites,
    required this.maxDriveSpritesOutro,
    this.maxMapPixelRatio,
  });

  final String id;

  /// Lkw-/Fährenbild in der Fahrt: Bildpunkte je Fahrzeugmeter. Die Größe
  /// auf dem Bildschirm bleibt gleich; nur die Auflösung des Bildes ändert
  /// sich.
  final double spritePx;

  /// Lkw-Bild im Outro (nah, mit Lichtzustand).
  final double outroSpritePx;

  /// Höchstzahl gehaltener Fahrzeugbilder in der Fahrt und ab dem
  /// Zielanflug (siehe Bildspeicher in der Szene).
  final int maxDriveSprites;
  final int maxDriveSpritesOutro;

  /// Höchste Pixeldichte der Kartenfläche (null: die des Geräts). HUD und
  /// Texte (Flutter) bleiben unberührt scharf.
  final double? maxMapPixelRatio;

  static const previewPerformance = CinematicQuality._(
    'previewPerformance',
    spritePx: 8,
    outroSpritePx: 16,
    maxDriveSprites: 48,
    maxDriveSpritesOutro: 160,
    maxMapPixelRatio: 1.5,
  );

  /// Bisheriger Live-Stand.
  static const previewHigh = CinematicQuality._(
    'previewHigh',
    spritePx: 12,
    outroSpritePx: 24,
    maxDriveSprites: 48,
    maxDriveSpritesOutro: 160,
  );

  /// Film: volle Qualität. Heute wie [previewHigh] (so entstanden die
  /// bisherigen Exporte); höher aufgelöste Lkw-Bilder und Hero-Assets kommen
  /// später nur hier hinzu.
  static const exportFullHD = CinematicQuality._(
    'exportFullHD',
    spritePx: 12,
    outroSpritePx: 24,
    maxDriveSprites: 160,
    maxDriveSpritesOutro: 400,
  );

  /// Profil für die Wiedergabe: Film immer [exportFullHD]; sonst Touch-
  /// Geräte (iPad, Smartphone) [previewPerformance], übrige [previewHigh].
  /// Bewusst keine Geräteliste.
  static CinematicQuality choose({required bool videoExport, required bool touchDevice}) {
    if (videoExport) return exportFullHD;
    return touchDevice ? previewPerformance : previewHigh;
  }
}
