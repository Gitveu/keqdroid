enum ConnectionMode {
  proxy,

  tun;

  static const storageKey = 'connectionMode';

  static ConnectionMode fromStorage(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'proxy':
        return ConnectionMode.proxy;
      case 'tun':
        return ConnectionMode.tun;
      default:
        return ConnectionMode.tun;
    }
  }

  String get storageValue => name;

  static ConnectionMode platformDefault() {
    return ConnectionMode.tun;
  }
}
