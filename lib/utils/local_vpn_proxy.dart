import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'socks5_credentials.dart';

typedef LocalProxyPortResolver = int? Function();

// двоеточие и ; в логине dart:io разобрал бы неверно, наши пароли из букв и цифр
String localProxyDirective(
  int? httpPort, {
  String username = '',
  String password = '',
}) {
  if (httpPort == null) return 'DIRECT';
  final host = InternetAddress.loopbackIPv4.address;
  if (username.isEmpty || password.isEmpty) return 'PROXY $host:$httpPort';
  return 'PROXY $username:$password@$host:$httpPort';
}

// пароль в строке прокси, а не через addProxyCredentials: на 407 dart:io повторяет запомненный пароль без конца,
// и после переподключения запрос крутился в петле, память росла до гигабайт
void configureHttpClientForLocalVpnProxy(
  HttpClient client,
  LocalProxyPortResolver resolvePort, {
  String? username,
  String? password,
}) {
  client.findProxy = (_) => localProxyDirective(
        resolvePort(),
        // синглтон читаем в момент запроса: после пересоздания изолята креды приезжают позже
        username: username ?? Socks5Credentials().username,
        password: password ?? Socks5Credentials().password,
      );
}

void configureDioForLocalVpnProxy(
  Dio dio,
  LocalProxyPortResolver resolvePort, {
  String? username,
  String? password,
}) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(
        client,
        resolvePort,
        username: username,
        password: password,
      );
      return client;
    },
  );
}

void configureDioForLocalVpnHttpProxy(
  Dio dio, {
  required int httpPort,
  String? username,
  String? password,
}) =>
    configureDioForLocalVpnProxy(
      dio,
      () => httpPort,
      username: username,
      password: password,
    );

void configureDioForActiveVpn(
  Dio dio, {
  required bool useLocalProxy,
  required int httpPort,
}) {
  if (!useLocalProxy) return;
  configureDioForLocalVpnHttpProxy(dio, httpPort: httpPort);
}

Future<LocalProxyPortResolver?> resolveLocalProxyForBackground(
  int? activeHttpPort,
) async {
  final port = activeHttpPort;
  if (port == null) return null;
  if (!await localHttpProxyIsListening(port)) return null;
  return () => port;
}

Future<bool> localHttpProxyIsListening(
  int port, {
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
