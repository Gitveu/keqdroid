library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class AppIconCache {
  AppIconCache(this._fetch, {this.maxConcurrent = 2, this.maxEntries = 512});

  final Future<String?> Function(String path) _fetch;

  final int maxConcurrent;

  final int maxEntries;

  // null тоже кэшируем: иначе exe без иконки дёргался бы на каждом появлении строки
  final _cache = <String, Uint8List?>{};

  final _queue = <String>[];

  // без этого вторая строка с тем же exe получила бы второй вызов
  final _inFlight = <String>{};

  final _wanted = <String, int>{};

  final _waiters = <String, List<Completer<Uint8List?>>>{};

  int _active = 0;

  bool has(String path) => _cache.containsKey(path);

  Uint8List? peek(String path) => _cache[path];

  Future<Uint8List?> request(String path) {
    if (path.isEmpty) return Future.value(null);
    _wanted.update(path, (n) => n + 1, ifAbsent: () => 1);
    if (_cache.containsKey(path)) return Future.value(_cache[path]);

    final completer = Completer<Uint8List?>();
    _waiters.putIfAbsent(path, () => []).add(completer);
    if (!_inFlight.contains(path) && !_queue.contains(path)) _queue.add(path);
    _pump();
    return completer.future;
  }

  void release(String path) {
    final left = (_wanted[path] ?? 0) - 1;
    if (left > 0) {
      _wanted[path] = left;
      return;
    }
    _wanted.remove(path);
    if (_queue.remove(path)) {
      _complete(path, null, cache: false);
    }
  }

  void _pump() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final path = _queue.removeLast();
      if ((_wanted[path] ?? 0) == 0) {
        _complete(path, null, cache: false);
        continue;
      }
      _active++;
      _inFlight.add(path);
      unawaited(_run(path));
    }
  }

  Future<void> _run(String path) async {
    Uint8List? bytes;
    try {
      final encoded = await _fetch(path);
      if (encoded != null && encoded.isNotEmpty) {
        bytes = base64Decode(encoded);
      }
    } catch (_) {
      bytes = null;
    } finally {
      _active--;
      _inFlight.remove(path);
    }
    _complete(path, bytes);
    _pump();
  }

  void _complete(String path, Uint8List? bytes, {bool cache = true}) {
    if (cache) {
      _cache[path] = bytes;
      if (_cache.length > maxEntries) _cache.remove(_cache.keys.first);
    }
    final waiters = _waiters.remove(path);
    if (waiters == null) return;
    for (final completer in waiters) {
      if (!completer.isCompleted) completer.complete(bytes);
    }
  }
}
