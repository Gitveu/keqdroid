// только по имени пакета: на русском телефоне кириллицей подписаны и системные, и чужие приложения
library;

// каждый префикс сверен с Google Play или RuStore (26.09.2026), пополнять так же, не по памяти
const _companyPrefixes = <String>[
  'com.yandex.',
  'com.vkontakte.',
  'com.vk.',
  'com.avito.',
  'com.idamob.tinkoff.',
  'com.wildberries.',
  'com.lamoda.',
  'com.kaspersky.',
  'com.kms.',
  'com.drweb.',
  'com.citymobil.',
  'com.taxsee.',
  'com.icemobile.lenta.',
  'com.ncloudtech.',
  'gpm.tnt_premier',
];

const _exactPackages = <String>{
  'com.drweb',
  'com.citymobil',
  'com.deliveryclub',
  'com.punicapp.whoosh',
};

// хвост .ru только у несистемных: производитель может назвать региональную сборку своей программы с .ru
bool isRussianApp(String packageName, {required bool isSystem}) {
  final pkg = packageName.trim().toLowerCase();
  if (pkg.isEmpty) return false;
  if (_exactPackages.contains(pkg)) return true;
  if (_companyPrefixes.any(pkg.startsWith)) return true;

  final labels = pkg.split('.');
  if (labels.length < 2) return false;
  if (labels.first == 'ru' || labels.first == 'su') return true;
  return !isSystem && labels.length > 2 && labels.last == 'ru';
}
