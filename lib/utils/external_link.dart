import 'package:url_launcher/url_launcher.dart';

Future<bool> openExternalLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !isSafeExternalLink(uri)) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

// javascript:, file: и intent: из заголовка чужого сервера открывать нельзя
bool isSafeExternalLink(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.hasAuthority &&
    uri.host.isNotEmpty;
