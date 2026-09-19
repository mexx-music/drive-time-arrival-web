/// Länder, die in der UI gesperrt werden können.
///
/// Bewusst kurz gehalten: die für LKW-Fahrer praktisch relevanten Länder
/// (Maut/Vignette, Zoll, Visum, Versicherungsauflagen).
class AvoidableCountry {
  final String iso;
  final String nameDe;
  const AvoidableCountry(this.iso, this.nameDe);

  /// Flaggen-Emoji aus dem ISO-Code (Regional Indicator Symbols).
  String get flag {
    if (iso.length != 2) return '';
    const base = 0x1F1E6;
    return String.fromCharCodes([
      base + iso.codeUnitAt(0) - 0x41,
      base + iso.codeUnitAt(1) - 0x41,
    ]);
  }

  String get label => '$nameDe $flag';
}

const List<AvoidableCountry> kAvoidableCountries = [
  AvoidableCountry('CH', 'Schweiz'),
  AvoidableCountry('RS', 'Serbien'),
  AvoidableCountry('BA', 'Bosnien und Herzegowina'),
  AvoidableCountry('ME', 'Montenegro'),
  AvoidableCountry('MK', 'Nordmazedonien'),
  AvoidableCountry('XK', 'Kosovo'),
  AvoidableCountry('AL', 'Albanien'),
  AvoidableCountry('BY', 'Belarus'),
  AvoidableCountry('UA', 'Ukraine'),
  AvoidableCountry('MD', 'Moldau'),
  AvoidableCountry('RU', 'Russland'),
  AvoidableCountry('TR', 'Türkei'),
  AvoidableCountry('GB', 'Vereinigtes Königreich'),
];

String avoidableCountryNameDe(String iso) {
  for (final c in kAvoidableCountries) {
    if (c.iso == iso) return c.nameDe;
  }
  return iso;
}
