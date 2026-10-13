String normalizeSubscriptionUrl(String url) {
  final trimmed = url.trim();
  try {
    final uri = Uri.parse(trimmed);
    final normalizedPath = uri.path.length > 1 && uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: normalizedPath,
        )
        .toString();
  } catch (_) {
    return trimmed;
  }
}
