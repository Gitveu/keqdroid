import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/traffic_split.dart';
import '../services/traffic_split_service.dart';
import '../services/traffic_split_store.dart';
import '../tunnel/tunnel_state.dart';
import '../utils/mihomo_api_session.dart';
import 'providers.dart';

const _pollInterval = Duration(seconds: 1);

const _saveInterval = Duration(seconds: 5);

final trafficSplitProvider = StreamProvider<TrafficSplit?>((ref) {
  final enabled = ref.watch(
    settingsNotifierProvider.select((s) => s.value?.showTrafficSplit ?? false),
  );
  final connected = ref.watch(
    vpnStateProvider.select((a) => a.value?.status == VpnStatus.connected),
  );
  if (!enabled || !connected) return Stream<TrafficSplit?>.value(null);

  final tracker = TrafficSplitTracker();
  final controller = StreamController<TrafficSplit?>();
  TrafficSplit? last;
  var inFlight = false;
  // только раз: повторное чтение файла откатит счёт назад
  var restoreTried = false;
  DateTime? savedAt;
  ConnectionsSnapshot? lastSnapshot;
  // без подсчёта не пишем, иначе уход в фон во время чтения затрёт прошлый счёт пустым
  var counted = false;

  void save({required bool now}) {
    final snapshot = lastSnapshot;
    if (snapshot == null || !counted) return;
    final at = DateTime.now();
    if (!now && savedAt != null && at.difference(savedAt!) < _saveInterval) {
      return;
    }
    final state = tracker.stateFor(
      coreDownload: snapshot.coreDownload,
      coreUpload: snapshot.coreUpload,
    );
    if (state == null) return;
    savedAt = at;
    counted = false;
    unawaited(TrafficSplitStore.save(state));
  }

  Future<void> poll() async {
    if (inFlight || controller.isClosed) return;
    inFlight = true;
    try {
      final api = MihomoApiSession();
      final port = api.port;
      if (port == null || !api.isActive) {
        tracker.reset();
        last = null;
        if (!controller.isClosed) controller.add(null);
        return;
      }
      final snapshot = await TrafficSplitSource.fetch(
        port: port,
        secret: api.secret,
      );
      if (controller.isClosed) return;
      if (snapshot == null) {
        controller.add(last);
        return;
      }
      final session = TrafficSplitStore.sessionKey(
        port: port,
        secret: api.secret,
      );
      if (!restoreTried) {
        restoreTried = true;
        final stored = await TrafficSplitStore.load();
        if (controller.isClosed) return;
        if (stored != null &&
            stored.belongsTo(
              session: session,
              coreDownload: snapshot.coreDownload,
              coreUpload: snapshot.coreUpload,
            )) {
          tracker.restore(stored);
        }
      }
      lastSnapshot = snapshot;
      last = tracker.add(snapshot.connections, session: session);
      counted = true;
      controller.add(last);
      save(now: false);
    } finally {
      inFlight = false;
    }
  }

  final timer = Timer.periodic(_pollInterval, (_) => unawaited(poll()));
  unawaited(poll());

  // на Android движок уничтожают сразу после ухода в фон, пишем сейчас
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        save(now: true);
      }
    },
  );

  ref.onDispose(() {
    timer.cancel();
    lifecycle.dispose();
    unawaited(controller.close());
  });
  return controller.stream;
});
