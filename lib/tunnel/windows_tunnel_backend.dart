import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import '../core/exceptions.dart';
import '../models/tun_settings.dart';
import '../services/core_dial_failures.dart';
import '../services/xray_route_decisions.dart';
import '../utils/xray_session_log.dart';
import '../services/debug_log_service.dart';
import '../services/ephemeral_xray_ping.dart';
import '../services/windows_desktop_service.dart';
import '../utils/keqrnel_config.dart';
import '../utils/mihomo_api_session.dart';
import '../utils/singbox_tun_config.dart';
import 'connection_mode.dart';
import 'core_capabilities.dart';
import 'desktop_traffic_stats.dart';
import 'local_port_plan.dart';
import 'local_proxy_probe.dart';
import 'socks_credential_generator.dart';
import 'tun_failure_hints.dart';
import 'tunnel_backend.dart';
import 'tunnel_session_request.dart';
import 'tunnel_state.dart';
import 'vpn_backend.dart';
import 'windows_core_paths.dart';
import 'xray_session_stats.dart';

class WindowsTunnelBackend with DesktopTrafficStats implements TunnelBackend {
  static const _method = MethodChannel('keqdis_vpn_channel');

  static WindowsTunnelBackend? activeInstance;

  // после teardown activeInstance обнуляется, а логи нужнее всего как раз после смерти ядра
  static String lastSessionLogs = '';

  final _stateCtrl = StreamController<VpnState>.broadcast();
  Process? _xrayProcess;
  Process? _keqrnelProcess;
  int? _keqrnelClashPort;

  int _xrayLogThreshold = 0;

  // выключаем только если включали: рассылка WM_SETTINGCHANGE стоит до пяти секунд на занятом окне,
  // а остатки после падения снимает нативная уборка до старта Dart
  bool _systemProxyApplied = false;

  Process? _mihomoProcess;

  int? get clashApiPort =>
      _keqrnelClashPort ?? (_mihomoProcess != null ? MihomoApiSession().port : null);

  Map<String, int> get activeCorePids => {
    if (_keqrnelProcess != null) 'keqrnel': _keqrnelProcess!.pid,
    if (_mihomoProcess != null) 'mihomo': _mihomoProcess!.pid,
    if (_xrayProcess != null) 'xray': _xrayProcess!.pid,
  };
  Directory? _sessionDir;
  ({String username, String password})? _pendingCreds;
  ConnectionMode? _activeMode;

  @override
  ConnectionMode? get activeMode => _activeMode;
  final StringBuffer _xrayLog = StringBuffer();
  final StringBuffer _singboxLog = StringBuffer();

  // пока идёт штатный стоп, вотчдог не должен принять наш kill за смерть ядра
  bool _stoppingSession = false;

  String? _xrayBinPath;

  @override
  Stream<VpnState> get stateStream => _stateCtrl.stream;

  @override
  void init() {}

  @override
  void dispose() {
    if (identical(activeInstance, this)) activeInstance = null;
    unawaited(stopSession());
    _stateCtrl.close();
  }

  String exportSessionLogs({int maxLines = 400}) {
    final combined = StringBuffer()
      ..writeln(_xrayLog)
      ..writeln(_singboxLog);
    return _tail(combined, maxLines: maxLines);
  }

  // на null попытку не блокируем, пусть ядро скажет своё
  Future<bool?> _isElevated() async {
    try {
      return await _method.invokeMethod<bool>('requestTunnelPermission');
    } on PlatformException {
      return null;
    }
  }

  String _sessionLogTail({int maxLines = 10}) {
    final text = exportSessionLogs(maxLines: maxLines).trim();
    return text == '(no process output)' ? '' : text;
  }

  @override
  Future<({String username, String password})> fetchSocksCredentials() async {
    _pendingCreds = SocksCredentialGenerator.generatePair();
    return _pendingCreds!;
  }

  @override
  Future<void> startSession(TunnelSessionRequest request) async {
    final creds = _pendingCreds;
    if (creds == null || creds.username.isEmpty || creds.password.isEmpty) {
      throw const VpnException(
        'Call fetchSocksCredentials before startSession on Windows',
      );
    }

    emit(VpnState(status: VpnStatus.connecting, activeMode: request.mode));
    _activeMode = request.mode;
    _xrayLog.clear();
    _singboxLog.clear();
    XrayRouteDecisions.reset();

    try {
      await _cleanupForRestart();
      activeInstance = this;
      // _cleanupForRestart обнуляет режим, без возврата опрос счётчиков после трея не перезапустится
      _activeMode = request.mode;

      // без прав администратора ядро просто умирает с exit code 1, отсекаем заранее.
      // слова administrator rights ловит explainError (UiErrorCode.tunAdmin)
      if (request.mode == ConnectionMode.tun && await _isElevated() == false) {
        throw const VpnStartException(
          'TUN mode needs administrator rights: the wintun adapter and the '
          'system route table cannot be set up without them. Restart the app '
          'as administrator, or use Proxy mode.',
        );
      }

      _sessionDir = await WindowsCorePaths.sessionDir();

      switch (request.vpnBackend) {
        case VpnBackend.mihomo:
          await _startMihomoSession(request);
        case VpnBackend.xray:
          await _startKeqrnelSession(request);
      }

      startStatsLoop(request.mode);
      emitConnectedTelemetry(request.mode);

      unawaited(_verifyChainReachable(request));

      // без вотчдога смерть ядра оставляла UI в Connected, а системный прокси на мёртвом порту
      _watchProcessExit(_keqrnelProcess, 'keqrnel');
      _watchProcessExit(_mihomoProcess, 'mihomo');
      _watchProcessExit(_xrayProcess, 'xray');
    } catch (e, st) {
      AppLogger.instance.error('Windows tunnel start failed', error: e, stackTrace: st);
      await _cleanupForRestart();
      emit(
        VpnState(
          status: VpnStatus.error,
          errorMessage: e.toString(),
          activeMode: request.mode,
        ),
      );
      if (e is AppException) rethrow;
      throw VpnStartException(e.toString(), cause: e);
    }
  }

  Future<void> _startKeqrnelSession(TunnelSessionRequest request) async {
    if (request.mode == ConnectionMode.tun) {
      await _startKeqrnelTunSession(request);
    } else {
      await _startKeqrnelProxySession(request);
    }
  }

  Future<void> _startKeqrnelProxySession(TunnelSessionRequest request) async {
    final bin = await WindowsCorePaths.keqrnelExecutable();
    if (bin == null) {
      throw VpnStartException(
        'keqrnel.exe not found. ${WindowsCorePaths.binariesHint}',
      );
    }

    final clashPort = await _freePort();
    final xrayLog = XraySessionLog.raise(request.xrayConfig);
    _xrayLogThreshold = xrayLog.threshold;
    final merged = KeqrnelConfig.proxyWithStats(
      xrayConfig: xrayLog.config,
      socksPort: request.socksPort,
      httpPort: request.httpPort,
      clashPort: clashPort,
      findProcess: request.debugMode,
    );
    _keqrnelClashPort = clashPort;
    final configFile = File('${_sessionDir!.path}/keqrnel.json');
    await configFile.writeAsString(merged);

    await _ensurePortsAvailable(request);

    final workDir = p.dirname(bin);
    final geoDir = await WindowsCorePaths.geoAssetDir();

    _keqrnelProcess = await Process.start(
      bin,
      [configFile.path],
      workingDirectory: workDir,
      environment: _coreProcessEnvironment(geoDir),
      mode: ProcessStartMode.normal,
    );
    _pipeProcessOutput(_keqrnelProcess!, _xrayLog, 'keqrnel');

    final socksReady = await _waitForPort(
      '127.0.0.1',
      request.socksPort,
      process: _keqrnelProcess,
      log: _xrayLog,
      processLabel: 'keqrnel',
    );
    if (!socksReady) {
      throw VpnStartException(
        'keqrnel SOCKS port ${request.socksPort} did not open.\n${_tail(_xrayLog)}',
      );
    }

    if (request.systemProxy) {
      final httpReady = await _waitForPort(
        '127.0.0.1',
        request.httpPort,
        process: _keqrnelProcess,
        log: _xrayLog,
        processLabel: 'keqrnel HTTP',
      );
      if (!httpReady) {
        throw VpnStartException(
          'keqrnel HTTP port ${request.httpPort} did not open. '
          'System proxy needs the HTTP inbound.\n${_tail(_xrayLog)}',
        );
      }
      await _applySystemProxy(request);
    }

    await WindowsDesktopService.registerSessionCoreProcesses(
      xrayPid: _keqrnelProcess?.pid ?? 0,
      singboxPid: 0,
    );
  }

  Future<void> _startKeqrnelTunSession(TunnelSessionRequest request) async {
    final bin = await WindowsCorePaths.keqrnelExecutable();
    if (bin == null) {
      throw VpnStartException(
        'keqrnel.exe not found. ${WindowsCorePaths.binariesHint}',
      );
    }
    final singConfig = request.singboxConfig;
    if (singConfig == null || singConfig.isEmpty) {
      throw const VpnStartException(
        'singboxConfig is required for keqrnel TUN',
      );
    }

    await _ensureTunPrerequisites(bin, request);

    final clashPort = await _freePort();
    final xrayLog = XraySessionLog.raise(request.xrayConfig);
    _xrayLogThreshold = xrayLog.threshold;
    final merged = KeqrnelConfig.fromChain(
      singboxConfig: await _tunStackForCore(singConfig, bin),
      xrayConfig: xrayLog.config,
      windows: true,
      clashApiPort: clashPort,
    );
    _keqrnelClashPort = clashPort;
    final configFile = File('${_sessionDir!.path}/keqrnel.json');
    await configFile.writeAsString(merged);

    // рядом с wintun.dll, xray-ассеты через env
    final workDir = p.dirname(bin);
    final geoDir = await WindowsCorePaths.geoAssetDir();

    _keqrnelProcess = await Process.start(
      bin,
      [configFile.path],
      workingDirectory: workDir,
      environment: _coreProcessEnvironment(geoDir),
      mode: ProcessStartMode.normal,
    );
    _pipeProcessOutput(_keqrnelProcess!, _singboxLog, 'keqrnel');

    final ready = await _waitForSingbox(
      process: _keqrnelProcess!,
      log: _singboxLog,
    );
    if (!ready) {
      throw VpnStartException(_tunStartError(_singboxLog));
    }

    await WindowsDesktopService.registerSessionCoreProcesses(
      xrayPid: _keqrnelProcess?.pid ?? 0,
      singboxPid: 0,
    );
  }

  Future<void> _startMihomoSession(TunnelSessionRequest request) async {
    final bin = await WindowsCorePaths.mihomoExecutable();
    if (bin == null) {
      throw VpnStartException(
        'mihomo.exe not found. ${WindowsCorePaths.binariesHint}',
      );
    }
    final config = request.mihomoConfig;
    if (config == null || config.isEmpty) {
      throw const VpnStartException('mihomoConfig is required for mihomo');
    }

    final isTun = request.mode == ConnectionMode.tun;
    if (isTun) {
      await _ensureTunPrerequisites(bin, request);
    } else {
      await _ensurePortsAvailable(request);
    }

    // ядро ждёт .yaml, а JSON для YAML 1.2 подмножество
    final configFile = File('${_sessionDir!.path}/mihomo.yaml');
    await configFile.writeAsString(config);

    final home = await WindowsCorePaths.mihomoHomeDir();

    _mihomoProcess = await Process.start(
      bin,
      ['-d', home, '-f', configFile.path],
      // wintun.dll ядро грузит по имени, то есть из каталога процесса
      workingDirectory: p.dirname(bin),
      mode: ProcessStartMode.normal,
    );
    _pipeProcessOutput(_mihomoProcess!, _xrayLog, 'mihomo');

    if (isTun) {
      final ready = await _waitForMihomoTun(
        process: _mihomoProcess!,
        log: _xrayLog,
      );
      if (!ready) {
        throw VpnStartException(_tunStartError(_xrayLog, core: 'mihomo.exe'));
      }
    } else {
      final socksReady = await _waitForPort(
        '127.0.0.1',
        request.socksPort,
        process: _mihomoProcess,
        log: _xrayLog,
        processLabel: 'mihomo',
      );
      if (!socksReady) {
        throw VpnStartException(
          'mihomo SOCKS port ${request.socksPort} did not open.\n'
          '${_tail(_xrayLog)}',
        );
      }
      if (request.systemProxy) {
        final httpReady = await _waitForPort(
          '127.0.0.1',
          request.httpPort,
          process: _mihomoProcess,
          log: _xrayLog,
          processLabel: 'mihomo HTTP',
        );
        if (!httpReady) {
          throw VpnStartException(
            'mihomo HTTP port ${request.httpPort} did not open. '
            'System proxy needs the HTTP inbound.\n${_tail(_xrayLog)}',
          );
        }
        await _applySystemProxy(request);
      }
    }

    await WindowsDesktopService.registerSessionCoreProcesses(
      xrayPid: _mihomoProcess?.pid ?? 0,
      singboxPid: 0,
    );
  }

  // по адресу нельзя: его mihomo считает из fake-ip-range, а имя задаём сами
  Future<bool> _waitForMihomoTun({
    required Process process,
    required StringBuffer log,
  }) async {
    var waited = 0;
    while (waited < _tunReadyBudgetMs) {
      final code = await _exitCodeOrNull(process);
      if (code != null) {
        throw VpnStartException(
          'mihomo exited with code $code before the tunnel came up.\n'
          '${_tunStartError(log, core: 'mihomo.exe')}',
        );
      }
      if (log.toString().contains('Tun adapter listening at')) return true;
      if (await _tunAdapterUp(extraAddress: _mihomoTunAddress)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      waited += 300;
    }
    return false;
  }

  Future<int> _freePort() async {
    final s = await ServerSocket.bind('127.0.0.1', 0);
    final port = s.port;
    await s.close();
    return port;
  }

  // wintun.dll сносит антивирус и теряет ручная распаковка, без него адаптера нет вовсе
  Future<void> _ensureTunPrerequisites(
    String binPath,
    TunnelSessionRequest request,
  ) async {
    final wintun = File(p.join(p.dirname(binPath), 'wintun.dll'));
    if (!wintun.existsSync()) {
      throw VpnStartException(
        'wintun.dll is missing next to ${p.basename(binPath)} (${wintun.path}). '
        'TUN mode cannot create the network adapter without it — antivirus '
        'quarantine and half-unpacked portable builds are the usual reasons. '
        'Reinstall the app or use Proxy mode.',
      );
    }
    await _ensurePortsAvailable(request);
  }

  // HTTP-инбаунд ядро поднимает всегда, занятый HTTP-порт роняет его целиком
  Future<void> _ensurePortsAvailable(TunnelSessionRequest request) async {
    final socksIssue =
        await LocalPortResolver.probe('127.0.0.1', request.socksPort);
    if (socksIssue != null) {
      throw VpnStartException(
        localPortBlockedMessage(
          label: 'SOCKS',
          port: request.socksPort,
          issue: socksIssue,
        ),
      );
    }
    final httpIssue =
        await LocalPortResolver.probe('127.0.0.1', request.httpPort);
    if (httpIssue != null) {
      throw VpnStartException(
        localPortBlockedMessage(
          label: 'HTTP',
          port: request.httpPort,
          issue: httpIssue,
        ),
      );
    }
  }

  Future<void> _applySystemProxy(TunnelSessionRequest request) async {
    AppLogger.instance.info(
      'setSystemProxy: socks=${request.socksPort} http=${request.httpPort}',
    );
    // до вызова: наполовину применённый прокси тоже надо снять
    _systemProxyApplied = true;
    try {
      final proxyResult = await _method.invokeMethod<Map<Object?, Object?>>(
        'setSystemProxy',
        {
          'enabled': true,
          'host': '127.0.0.1',
          'socksPort': request.socksPort,
          'httpPort': request.httpPort,
          'probe': false,
        },
      );
      final registryEnabled = proxyResult?['registryEnabled'] == true;
      final registryServer = proxyResult?['registryServer']?.toString() ?? '';
      final logFile = proxyResult?['logFile']?.toString() ?? '';
      AppLogger.instance.info(
        'System proxy OK: registry enabled=$registryEnabled '
        'server=$registryServer logFile=$logFile',
      );
      unawaited(_logProxyProbesInBackground(request.httpPort));
      if (!registryEnabled ||
          !_registryProxyMatchesHttp(registryServer, request.httpPort)) {
        await _appendProxyDebugLogs('validation failed');
        throw VpnStartException(
          'System proxy was not applied (enabled=$registryEnabled, '
          'server="$registryServer", expected HTTP on 127.0.0.1:${request.httpPort}). '
          'Check Windows proxy settings (Settings → Network → Proxy).',
        );
      }
    } on PlatformException catch (e) {
      await _appendProxyDebugLogs('setSystemProxy PlatformException');
      final details = e.details;
      final detailLogs = details is Map ? details['logs']?.toString() : null;
      final logFile = details is Map ? details['logFile']?.toString() : null;
      final buffer = StringBuffer(e.message ?? e.code);
      if (logFile != null && logFile.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('Log file: $logFile');
      }
      if (detailLogs != null && detailLogs.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('--- Proxy debug (native) ---');
        buffer.writeln(detailLogs);
      }
      throw VpnStartException(buffer.toString(), cause: e);
    }
  }

  void _watchProcessExit(Process? process, String label) {
    if (process == null) return;
    unawaited(process.exitCode.then((code) async {
      if (_stoppingSession) return;
      if (!identical(process, _keqrnelProcess) &&
          !identical(process, _mihomoProcess) &&
          !identical(process, _xrayProcess)) {
        return;
      }
      // хвост до teardown: голый exit code ничего не говорит, а после остановки логов уже нет
      final details = _sessionLogTail();
      // причину ищем во всём выводе: настоящая ошибка часто выше десятка строк агонии ядра
      final hint = tunFailureHint(exportSessionLogs(), windows: true);
      AppLogger.instance.error(
        '$label exited unexpectedly with code $code; tearing the session down'
        '${hint == null ? '' : '\n${hint.message}'}'
        '${details.isEmpty ? '' : '\n$details'}',
      );
      try {
        await stopSession();
      } catch (_) {}
      emit(VpnState(
        status: VpnStatus.error,
        errorMessage:
            '$label stopped unexpectedly (exit code $code). Disconnected.'
            '${hint == null ? '' : '\n${hint.message}'}'
            '${details.isEmpty ? '' : '\n$details'}',
      ));
    }));
  }

  @override
  Future<void> stopSession() async {
    _stoppingSession = true;
    try {
      await _stopSessionInner();
    } finally {
      _stoppingSession = false;
    }
  }

  // без эмитов: disconnected из стрима проходит в UI и при connect-in-flight, кнопка проваливалась в серое
  Future<void> _cleanupForRestart() async {
    _stoppingSession = true;
    try {
      await _stopSessionInner(emitStates: false);
    } finally {
      _stoppingSession = false;
    }
  }

  Future<void> _stopSessionInner({bool emitStates = true}) async {
    final wasTun = _activeMode == ConnectionMode.tun;
    stopStatsLoop();
    final logs = exportSessionLogs();
    if (logs.trim().isNotEmpty && logs.trim() != '(no process output)') {
      lastSessionLogs = logs;
    }
    if (emitStates) emit(const VpnState(status: VpnStatus.disconnecting));

    if (_systemProxyApplied) {
      try {
        await _method.invokeMethod<void>('setSystemProxy', {'enabled': false});
      } catch (_) {}
      _systemProxyApplied = false;
    }

    // сначала владелец TUN и мягко, чтобы встроенный sing-box вернул адаптер, маршруты и DNS
    await _killProcess(_keqrnelProcess, graceful: true);
    // mihomo слушает сигналы, а не stdin, на Windows это жёсткий TerminateProcess.
    // уборку адаптера доделывает драйвер, её ждёт _awaitTunAdapterGone
    await _killProcess(_mihomoProcess);
    await _killProcess(_xrayProcess);
    _xrayProcess = null;
    _keqrnelProcess = null;
    _mihomoProcess = null;
    _keqrnelClashPort = null;
    _xrayBinPath = null;

    await WindowsDesktopService.clearSessionCoreProcesses();

    // процесс мёртв, адаптер ещё нет: на занятом имени sing-tun делает OpenAdapter и настраивает умирающий.
    // ждём только после TUN: чужой sing-box рядом держит тот же 172.19.0.1
    if (wasTun) await _awaitTunAdapterGone();

    final dir = _sessionDir;
    _sessionDir = null;
    if (dir != null && dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }

    _activeMode = null;
    if (identical(activeInstance, this)) activeInstance = null;
    if (emitStates) emit(VpnState.disconnected);
  }

  @override
  Future<bool> requestTunnelPermission() async {
    try {
      final ok = await _method.invokeMethod<bool>('requestTunnelPermission');
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  // счётчики API ядра, а не адаптера: рукопожатия TCP отвечает локальный стек,
  // и пришло было бы и от мёртвого сервера
  @override
  Future<({int down, int up})?> sessionTrafficCounters() async {
    if (_mihomoProcess != null) {
      final api = MihomoApiSession();
      final port = api.port;
      return port == null ? null : queryClashTraffic(port, secret: api.secret);
    }
    final port = _keqrnelClashPort;
    if (_keqrnelProcess == null || port == null) return null;
    return queryClashTraffic(port);
  }

  @override
  Future<VpnState> getCurrentState() async {
    if (_xrayProcess != null ||
        _keqrnelProcess != null ||
        _mihomoProcess != null) {
      return buildConnectedState(_activeMode);
    }
    return VpnState.disconnected;
  }

  @override
  Future<int?> getPing(String address, int port) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 5),
      );
      sw.stop();
      await s.close();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getInstalledApps({
    bool includeSystem = false,
  }) async {
    try {
      final result = await _method.invokeMethod<List<dynamic>>(
        'listProcesses',
        <String, dynamic>{'includeSystem': includeSystem},
      );
      return result
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [];
    } on PlatformException catch (e) {
      AppLogger.instance.warn('listProcesses failed: ${e.message}');
      return [];
    } catch (e, st) {
      AppLogger.instance.error('listProcesses failed', error: e, stackTrace: st);
      return [];
    }
  }

  @override
  Future<String?> getAppIcon(String path) async {
    if (path.isEmpty) return null;
    try {
      final result = await _method.invokeMethod<String>(
        'getAppIcon',
        <String, dynamic>{'path': path},
      );
      if (result == null || result.isEmpty) return null;
      return result;
    } on PlatformException catch (e) {
      AppLogger.instance.debug('getAppIcon failed: ${e.message}');
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<
    List<
      ({String id, bool success, int? latencyMs, String error, int? httpStatus})
    >?
  >
  xrayUrlTestMulti({
    required String config,
    required List<(String id, int port)> probes,
    VpnBackend core = VpnBackend.xray,
    String testUrl = 'https://connectivitycheck.gstatic.com/generate_204',
    int timeoutMs = 15000,
    bool keepAlive = true,
    int concurrency = 16,
    UrlTestProgress? onEach,
  }) async =>
      null;

  @override
  Future<
      List<({
        String id,
        bool success,
        int? latencyMs,
        String error,
        int? httpStatus,
      })>> xrayUrlTestBatch({
    required List<(String id, String xrayConfig)> items,
    required int socksPort,
    VpnBackend core = VpnBackend.xray,
    String testUrl = 'https://connectivitycheck.gstatic.com/generate_204',
    int timeoutMs = 15000,
    bool keepAlive = true,
  }) async {
    if (items.isEmpty) return [];
    final raw = await EphemeralXrayPing.urlTestBatch(
      items: items
          .map((e) => (id: e.$1, xrayConfigJson: e.$2))
          .toList(),
      socksPort: socksPort,
      core: core,
      testUrl: testUrl,
      timeoutMs: timeoutMs,
      keepAlive: keepAlive,
    );
    return raw
        .map(
          (r) => (
            id: r.id,
            success: r.success,
            latencyMs: r.latencyMs,
            error: r.error,
            httpStatus: r.httpStatus,
          ),
        )
        .toList();
  }

  @override
  Future<
      List<({
        String id,
        bool success,
        int? kbps,
        String error,
      })>> xraySpeedTestBatch({
    required List<(String id, String xrayConfig)> items,
    required int socksPort,
    VpnBackend core = VpnBackend.xray,
    String downloadUrl = kDefaultSpeedTestUrl,
    int timeoutMs = 20000,
  }) async {
    if (items.isEmpty) return [];
    return EphemeralXrayPing.speedTestBatch(
      items: items.map((e) => (id: e.$1, xrayConfigJson: e.$2)).toList(),
      socksPort: socksPort,
      core: core,
      downloadUrl: downloadUrl,
      timeoutMs: timeoutMs,
    );
  }

  // с environment Process.start заменяет окружение целиком, поэтому мержим с родительским
  static Map<String, String>? _coreProcessEnvironment(String? geoDir) {
    if (geoDir == null) return null;
    return {...Platform.environment, 'XRAY_LOCATION_ASSET': geoDir};
  }

  void _pipeProcessOutput(Process process, StringBuffer buffer, String tag) {
    // только буфер: лог на каждую строку ядра подтормаживал UI при подключении
    void append(String line) {
      CoreDialFailures.observe(line);
      XrayRouteDecisions.observe(line);
      if (!XraySessionLog.keep(line, _xrayLogThreshold)) return;
      buffer.writeln(line);
      if (buffer.length > 64 * 1024) {
        final trimmed = _tail(buffer, maxLines: 200);
        buffer
          ..clear()
          ..writeln(trimmed);
      }
    }

    // allowMalformed: строка ядра в ANSI-кодировке русской Windows иначе роняет весь пайп лога
    const decoder = Utf8Decoder(allowMalformed: true);
    // строки режем по всему потоку: кусок пайпа обрывается где попало
    process.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(append);
    process.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(append);
  }

  static Future<int?> _exitCodeOrNull(Process process) => process.exitCode
      .then<int?>((c) => c)
      .timeout(const Duration(milliseconds: 1), onTimeout: () => null);

  Future<void> _killProcess(Process? process, {bool graceful = false}) async {
    if (process == null) return;
    try {
      if (graceful) {
        // kill на Windows это жёсткий TerminateProcess, и sing-box не вернул бы адаптер, маршруты и DNS.
        // keqrnel мягко выходит по EOF на stdin
        try {
          await process.stdin.close();
        } catch (_) {}
        final code = await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -2,
        );
        if (code != -2) return;
      }
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
  }

  Future<bool> _waitForSingbox({
    required Process process,
    StringBuffer? log,
  }) async {
    var waited = 0;
    while (waited < _tunReadyBudgetMs) {
      final code = await _exitCodeOrNull(process);
      if (code != null) {
        throw VpnStartException(
          'keqrnel exited with code $code before the tunnel came up.\n'
          '${_tunStartError(log ?? StringBuffer())}',
        );
      }
      // строка только от sing-box: баннер встроенного xray печатается раньше tun-инбаунда
      if (singboxTunReady((log ?? StringBuffer()).toString())) return true;
      // адаптер не сразу: после kill прошлой сессии он живёт ещё пару секунд
      if (waited >= 5000 && await _tunAdapterUp()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      waited += 300;
    }
    final stillRunning = await _exitCodeOrNull(process);
    if (stillRunning == null) {
      AppLogger.instance.warn(
        'keqrnel TUN: no readiness signal in '
        '${_tunReadyBudgetMs ~/ 1000}s, assuming it is up because the process '
        'is alive.\n${_tail(log ?? StringBuffer())}',
      );
    }
    return stillRunning == null;
  }

  // 30 с: сюда входит разбор geo-баз встроенным xray и создание адаптера
  static const _tunReadyBudgetMs = 30000;

  String _tunStartError(StringBuffer log, {String core = 'keqrnel.exe'}) {
    final text = log.toString();
    return tunStartFailureMessage(
      fallback: 'The TUN tunnel did not start. Run the app as Administrator '
          'and make sure wintun.dll sits next to $core.',
      coreOutput: text,
      windows: true,
      tail: _tail(log),
    );
  }

  Future<String> _tunStackForCore(String singboxConfig, String binPath) async {
    final result = applyTunStackFallback(
      singboxConfig,
      gvisorAvailable: await CoreCapabilities.hasGvisor(binPath),
    );
    if (result.downgradedFrom != null) {
      AppLogger.instance.warn(
        'TUN stack "${result.downgradedFrom}" needs a core built with '
        '-tags with_gvisor; this keqrnel has none, falling back to "system". '
        'On Windows the system stack needs an inbound Windows Firewall rule — '
        'if there is no traffic at all, that rule is the first thing to check.',
      );
    } else if (result.config.contains('"stack": "${TunSettings.stackSystem}"')) {
      AppLogger.instance.warn(
        'TUN stack is "system": on Windows it terminates TCP with a listener on '
        'the TUN interface address and therefore needs an inbound Windows '
        'Firewall rule. sing-tun adds it itself but ignores the result — if the '
        'tunnel comes up and no traffic flows at all, that rule (or a '
        'third-party firewall blocking it) is the first suspect. The gVisor '
        'stack does not depend on it.',
      );
    } else if (result.config.contains('"stack": "${TunSettings.stackMixed}"')) {
      AppLogger.instance.warn(
        'TUN stack is "mixed": on Windows its TCP goes through the system stack, '
        'a listener on the TUN interface address that needs an inbound Windows '
        'Firewall rule; only UDP goes through gVisor. sing-tun adds the rule '
        'itself but ignores the result — if games and calls work but websites '
        'and launchers do not, that rule (or a third-party firewall blocking '
        'it) is the first suspect. The gVisor stack does not depend on it.',
      );
    }
    return result.config;
  }

  Future<void> _awaitTunAdapterGone() async {
    const budgetMs = 6000;
    var waited = 0;
    while (waited < budgetMs) {
      if (!await _tunAdapterUp()) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited += 250;
    }
    AppLogger.instance.warn(
      'TUN adapter $kTunInterfaceAddress is still up ${budgetMs ~/ 1000}s after '
      'the core was stopped. The next TUN start may take over the dying '
      'adapter instead of creating a new one.',
    );
  }

  // ищем по адресу: его задаём мы, а имя интерфейса на Windows зависит от системы
  Future<bool> _tunAdapterUp({String? extraAddress}) async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        if (iface.name == kTunInterfaceName) return true;
        for (final addr in iface.addresses) {
          if (addr.address == kTunInterfaceAddress) return true;
          if (extraAddress != null && addr.address == extraAddress) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  // первый адрес fake-ip-range
  static const _mihomoTunAddress = '198.18.0.1';

  Future<bool> _waitForPort(
    String host,
    int port, {
    Process? process,
    StringBuffer? log,
    String processLabel = 'Process',
  }) async {
    var waited = 0;
    while (waited < 20000) {
      if (process != null) {
        final code = await _exitCodeOrNull(process);
        if (code != null) {
          if (code != 0) {
            final buffer = log ?? StringBuffer();
            final hint = tunFailureHint(buffer.toString(), windows: true);
            throw VpnStartException(
              '$processLabel exited with code $code.'
              '${hint == null ? '' : '\n${hint.message}'}'
              '\n${_tail(buffer)}',
            );
          }
          return false;
        }
      }
      try {
        final s = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 400),
        );
        await s.close();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        waited += 300;
      }
    }
    return false;
  }

  String _tail(StringBuffer buffer, {int maxLines = 12}) {
    final lines = buffer.toString().split('\n').where((l) => l.trim().isNotEmpty);
    final tail = lines.length > maxLines
        ? lines.skip(lines.length - maxLines)
        : lines;
    final text = tail.join('\n');
    return text.isEmpty ? '(no process output)' : text;
  }

  @override
  void emit(VpnState state) {
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }




  @override


  @override
  Future<void> pollTrafficStats(ConnectionMode mode, {bool force = false}) async {
    if (!statsPollingEnabled && !force) return;
    if (_xrayProcess == null &&
        _keqrnelProcess == null &&
        _mihomoProcess == null) {
      return;
    }
    try {
      final int inOctets;
      final int outOctets;

      if (_mihomoProcess != null) {
        final api = MihomoApiSession();
        final port = api.port;
        if (port == null) {
          emitConnectedTelemetry(mode);
          return;
        }
        final t = await queryClashTraffic(port, secret: api.secret);
        if (t == null) {
          emitConnectedTelemetry(mode);
          return;
        }
        inOctets = t.down;
        outOctets = t.up;
      } else if (mode == ConnectionMode.proxy && _xrayProcess != null) {
        final xrayBin = _xrayBinPath;
        if (xrayBin == null) return;
        final counters = await XraySessionStats.queryInboundCounters(
          xrayExecutable: xrayBin,
        );
        if (counters == null) return;
        inOctets = counters.download;
        outOctets = counters.upload;
      } else if (mode == ConnectionMode.tun) {
        final result = await _method.invokeMethod<Map<Object?, Object?>>(
          'getTrafficStats',
          {'mode': 'tun'},
        );
        if (result == null || result['ok'] != true) {
          emitConnectedTelemetry(mode);
          return;
        }
        inOctets = (result['inOctets'] as num?)?.toInt() ?? 0;
        outOctets = (result['outOctets'] as num?)?.toInt() ?? 0;
      } else if (mode == ConnectionMode.proxy && _keqrnelClashPort != null) {
        final t = await queryClashTraffic(_keqrnelClashPort!);
        if (t == null) {
          emitConnectedTelemetry(mode);
          return;
        }
        inOctets = t.down;
        outOctets = t.up;
      } else {
        emitConnectedTelemetry(mode);
        return;
      }

      if (!statsBaselineTaken) {
        statsBaselineTaken = true;
        prevInOctets = inOctets;
        prevOutOctets = outOctets;
        resumeBaselinePending = false;
        emitConnectedTelemetry(mode);
        return;
      }

      final deltaIn =
          inOctets >= prevInOctets ? inOctets - prevInOctets : 0;
      final deltaOut =
          outOctets >= prevOutOctets ? outOctets - prevOutOctets : 0;
      prevInOctets = inOctets;
      prevOutOctets = outOctets;
      totalDownload += deltaIn;
      totalUpload += deltaOut;

      final suppressSpeed = resumeBaselinePending;
      resumeBaselinePending = false;
      emitConnectedTelemetry(
        mode,
        downloadSpeed: suppressSpeed ? null : deltaIn,
        uploadSpeed: suppressSpeed ? null : deltaOut,
      );
    } catch (e) {
      AppLogger.instance.debug('getTrafficStats failed: $e');
    }
  }







  Future<void> _logProxyProbesInBackground(int httpPort) async {
    try {
      final localProbe = await _probeLocalHttpProxy(httpPort);
      await _proxyDebugLogViaChannel('Background local HTTP probe: $localProbe');
      final result = await _method.invokeMethod<Map<Object?, Object?>>(
        'testSystemProxyHttp',
      );
      final winInet = result?['winInet'];
      final winHttp = result?['winHttp'];
      AppLogger.instance.info(
        'System proxy probes (background): winInet=$winInet winHttp=$winHttp',
      );
      await _proxyDebugLogViaChannel(
        'Background OS probes: winInet=$winInet winHttp=$winHttp '
        '(204=system proxy works like Chrome)',
      );
      if (winInet != 204 && winHttp != 204) {
        AppLogger.instance.warn(
          'System proxy registry is set but OS HTTP probes did not return 204. '
          'Fully quit and restart the browser. Firefox: enable system proxy.',
        );
      }
    } catch (e) {
      AppLogger.instance.debug('Background proxy probes failed: $e');
    }
  }

  Future<void> _verifyChainReachable(TunnelSessionRequest request) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (_activeMode == null) return;
    final result = await _probeLocalHttpProxy(request.httpPort);
    if (result.contains('status=204') || result.contains('status=200')) return;
    if (_activeMode == null) return;
    AppLogger.instance.warn(
      'The tunnel is up, but a test request through the core did not go '
      'through ($result). Nothing will load until this is fixed — the usual '
      'reasons are an unreachable or expired server, wrong server settings, or '
      'a routing rule that blocks the test address.',
    );
  }

  Future<String> _probeLocalHttpProxy(int httpPort) async {
    final result = await probeLocalHttpProxy(httpPort);
    if (result.status != null) return 'status=${result.status}';
    return 'FAILED (${result.error}) — Xray HTTP inbound on 127.0.0.1:$httpPort '
        'may be down or routing blocks the test URL';
  }

  Future<void> _proxyDebugLogViaChannel(String message) async {
    try {
      await _method.invokeMethod<void>('appendProxyDebugLog', {
        'message': message,
      });
    } catch (_) {}
  }

  Future<void> _appendProxyDebugLogs(String reason) async {
    try {
      final path = await DebugLogService.getProxyDebugLogPath();
      final logs = await DebugLogService.getProxyDebugLogs(maxLines: 200);
      AppLogger.instance.error(
        'Proxy debug ($reason)\nFile: $path\n$logs',
      );
    } catch (e) {
      AppLogger.instance.warn('Proxy debug logs unavailable: $e');
    }
  }

  static bool _registryProxyMatchesHttp(String registryServer, int httpPort) {
    if (registryServer.isEmpty) return false;
    final hostPort = '127.0.0.1:$httpPort';
    if (registryServer == hostPort) return true;
    return registryServer.contains('http=$hostPort') &&
        registryServer.contains('https=$hostPort');
  }
}
