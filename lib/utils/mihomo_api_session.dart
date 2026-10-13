import 'dart:io';

import '../tunnel/socks_credential_generator.dart';

class MihomoApiSession {
  static final MihomoApiSession _instance = MihomoApiSession._internal();

  factory MihomoApiSession() => _instance;
  MihomoApiSession._internal();

  int? _port;
  String _secret = '';

  int? get port => _port;
  String get secret => _secret;
  bool get isActive => _port != null && _secret.isNotEmpty;

  Future<void> renew() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = socket.port;
    await socket.close();
    _secret = SocksCredentialGenerator.randomToken(32);
  }

  void restore({required int? port, required String secret}) {
    if (port == null || port <= 0 || secret.isEmpty) return;
    _port = port;
    _secret = secret;
  }

  void clear() {
    _port = null;
    _secret = '';
  }
}
