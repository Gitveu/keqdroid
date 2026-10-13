// новый шрифт должен покрывать кириллицу
class AppFont {
  final String id;

  final String label;

  final String? family;

  const AppFont({required this.id, required this.label, this.family});
}

const String kDefaultFontId = 'system';

const List<AppFont> kAppFonts = <AppFont>[
  AppFont(id: kDefaultFontId, label: 'System'),
  AppFont(id: 'comfortaa', label: 'Comfortaa', family: 'Comfortaa'),
  AppFont(id: 'montserrat', label: 'Montserrat', family: 'Montserrat'),
  AppFont(id: 'rubik', label: 'Rubik', family: 'Rubik'),
];

AppFont resolveAppFont(String id) =>
    kAppFonts.firstWhere((f) => f.id == id, orElse: () => kAppFonts.first);
