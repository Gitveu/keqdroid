Future<List<R>> mapPooled<T, R>(
  List<T> items,
  int concurrency,
  Future<R> Function(T item) action,
) async {
  if (items.isEmpty) return <R>[];

  final results = List<R?>.filled(items.length, null);

  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= items.length) return;
      results[index] = await action(items[index]);
    }
  }

  final workers = concurrency < 1
      ? 1
      : (concurrency < items.length ? concurrency : items.length);
  await Future.wait([for (var i = 0; i < workers; i++) worker()]);

  return [for (final r in results) r as R];
}
