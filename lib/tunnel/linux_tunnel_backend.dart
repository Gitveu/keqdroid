import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../core/exceptions.dart';
import '../services/core_dial_failures.dart';
import '../services/xray_route_decisions.dart';
import '../utils/xray_session_log.dart';
import '../services/ephemeral_xray_ping.dart';
import '../utils/keqrnel_config.dart';
import '../utils/mihomo_api_session.dart';
import '../utils/singbox_tun_config.dart';
import 'connection_mode.dart';
import 'core_capabilities.dart';
import 'desktop_traffic_stats.dart';
import 'linux_core_paths.dart';
import 'linux_elevation.dart';
import 'linux_system_proxy.dart';
import 'local_port_plan.dart';
import 'local_proxy_probe.dart';
import 'socks_credential_generator.dart';
import 'tun_failure_hints.dart';
import 'tunnel_backend.dart';
import 'tunnel_session_request.dart';
import 'tunnel_state.dart';
import 'vpn_backend.dart';
import 'xray_session_stats.dart';

final StreamController<void> _linuxTunRememberController =
    StreamController<void>.broadcast();
Stream<void> get linuxTunRememberOffers => _linuxTunRememberController.stream;

class LinuxTunnelBackend with DesktopTrafficStats implements TunnelBackend {
  static const tunInterfaceName = 'tun-keqdis';

  // pkexec не держит наш pipe, причину падения ядра видно только из файла.
  // в каталоге сессии (0700), а не в /tmp: root создаёт его 0644, а в логе адреса серверов
  String get _coreLogPath =>
      _sessionDir == null ? '' : p.join(_sessionDir!.path, 'core.log');

  // по mtime отличаем свежий лог от прошлой сессии: при падении самого pkexec файл не обнулён
  DateTime? _keqrnelLaunchedAt;

  static LinuxTunnelBackend? activeInstance;

  final _stateCtrl = StreamController<VpnState>.broadcast();

  Process? _xrayProcess;
  Process? _singboxProcess;
  File? _rootSentinel;
  Directory? _sessionDir;
  ConnectionMode? _activeMode;

  @override
  ConnectionMode? get activeMode => _activeMode;
  final StringBuffer _xrayLog = StringBuffer();
  final StringBuffer _singboxLog = StringBuffer();

  String? _xrayBinPath;
  int? _keqrnelClashPort;

  String? _keqrnelClashSecret;

  int _xrayLogThreshold = 0;

  Process? _mihomoProcess;

  int? get clashApiPort =>
      _keqrnelClashPort ??
      (_mihomoProcess != null ? MihomoApiSession().port : null);

  String get clashApiSecret => _keqrnelClashPort != null
      ? _keqrnelClashSecret ?? ''
      : MihomoApiSession().secret;

  static String _newSecret() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  Map<String, int> get activeCorePids => {
    if (_xrayProcess != null) 'keqrnel': _xrayProcess!.pid,
    if (_mihomoProcess != null)
      _mihomoRunsAsRoot ? 'mihomo (root, TUN)' : 'mihomo': _mihomoProcess!.pid,
    if (_singboxProcess != null) 'keqrnel (root, TUN)': _singboxProcess!.pid,
  };

  // root-процессу обычный пользователь сигнал не пошлёт, останавливаем удалением сентинела
  bool _mihomoRunsAsRoot = false;

  // пока идёт штатный стоп, вотчдог не должен принять наш kill за смерть ядра
  bool _stoppingSession = false;


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
      ..writeln('=== xray ===')
      ..writeln(_xrayLog)
      ..writeln('=== sing-box ===')
      ..writeln(_singboxLog);
    return _tail(combined, maxLines: maxLines);
  }

  // не в общий /tmp: там адреса серверов и посещённые сайты
  Future<void> _dumpLogsToFile() async {
    try {
      final runtime = Platform.environment['XDG_RUNTIME_DIR'];
      final private = runtime != null && Directory(runtime).existsSync();
      final dir = private
          ? runtime
          : (await getApplicationSupportDirectory()).path;
      final path = p.join(dir, coresLogName);
      await File(path).writeAsString(exportSessionLogs(maxLines: 2000));
      if (!private) await Process.run('chmod', ['600', path]);
      AppLogger.instance.info('Core logs written to $path');
    } catch (_) {}
  }

  static const coresLogName = 'keqdroid_cores.log';

  @override
  Future<({String username, String password})> fetchSocksCredentials() async {
    return SocksCredentialGenerator.generatePair();
  }

  @override
  Future<void> startSession(TunnelSessionRequest request) async {
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
      _sessionDir = await LinuxCorePaths.sessionDir();

      final isTun = request.mode == ConnectionMode.tun;
      switch (request.vpnBackend) {
        case VpnBackend.mihomo:
          await _startMihomoSession(request);
        case VpnBackend.xray:
          await (isTun
              ? _startKeqrnelTunSession(request)
              : _startKeqrnelProxySession(request));
      }

      startStatsLoop(request.mode);
      emitConnectedTelemetry(request.mode);

      unawaited(_verifyChainReachable(request));

      // без вотчдога смерть ядра оставляла UI в Connected, а системный прокси на мёртвом порту
      _watchProcessExit(_xrayProcess, 'keqrnel');
      _watchProcessExit(_mihomoProcess, 'mihomo');
      _watchProcessExit(_singboxProcess, 'keqrnel TUN');
    } catch (e, st) {
      AppLogger.instance.error(
        'Linux tunnel start failed',
        error: e,
        stackTrace: st,
      );
      await _dumpLogsToFile();
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

  Future<void> _startKeqrnelProxySession(TunnelSessionRequest request) async {
    final bin = await LinuxCorePaths.keqrnelExecutable();
    if (bin == null) {
      throw VpnStartException(
        'keqrnel not found. ${LinuxCorePaths.binariesHint}',
      );
    }
    _xrayBinPath = bin;

    final clashPort = await _freePort();
    final clashSecret = _newSecret();
    final xrayLog = XraySessionLog.raise(request.xrayConfig);
    _xrayLogThreshold = xrayLog.threshold;
    final merged = KeqrnelConfig.proxyWithStats(
      xrayConfig: xrayLog.config,
      socksPort: request.socksPort,
      httpPort: request.httpPort,
      clashPort: clashPort,
      clashApiSecret: clashSecret,
      findProcess: request.debugMode,
    );
    _keqrnelClashPort = clashPort;
    _keqrnelClashSecret = clashSecret;
    final configFile = File(p.join(_sessionDir!.path, 'keqrnel.json'));
    await configFile.writeAsString(merged);

    // HTTP-инбаунд ядро поднимает всегда (через него ходит апдейтер), занятый порт роняет всё
    await _ensurePortsAvailable(request, needsHttp: true);

    final geoDir = await LinuxCorePaths.geoAssetDir();
    _xrayProcess = await Process.start(
      bin,
      ['run', '-c', configFile.path],
      workingDirectory: _sessionDir!.path,
      environment: _coreProcessEnvironment(geoDir),
      mode: ProcessStartMode.normal,
    );
    _pipeProcessOutput(_xrayProcess!, _xrayLog);

    final socksReady = await _waitForPort(
      '127.0.0.1',
      request.socksPort,
      process: _xrayProcess,
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
        process: _xrayProcess,
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
  }

  Future<void> _startKeqrnelTunSession(TunnelSessionRequest request) async {
    final singConfig = request.singboxConfig;
    if (singConfig == null || singConfig.isEmpty) {
      throw const VpnStartException('singboxConfig is required for TUN mode');
    }
    await _ensurePortsAvailable(request, needsHttp: true);

    final clashPort = await _freePort();
    final clashSecret = _newSecret();
    final xrayLog = XraySessionLog.raise(request.xrayConfig);
    _xrayLogThreshold = xrayLog.threshold;
    final merged = KeqrnelConfig.fromChain(
      singboxConfig: singConfig,
      xrayConfig: xrayLog.config,
      windows: false,
      clashApiPort: clashPort,
      clashApiSecret: clashSecret,
    );
    _keqrnelClashPort = clashPort;
    _keqrnelClashSecret = clashSecret;
    await _runKeqrnelAsRoot(merged);
  }

  Future<void> _startMihomoSession(TunnelSessionRequest request) async {
    final bin = await LinuxCorePaths.mihomoExecutable();
    if (bin == null) {
      throw VpnStartException(
        'mihomo not found. ${LinuxCorePaths.binariesHint}',
      );
    }
    final config = request.mihomoConfig;
    if (config == null || config.isEmpty) {
      throw const VpnStartException('mihomoConfig is required for mihomo');
    }

    final isTun = request.mode == ConnectionMode.tun;
    await _ensurePortsAvailable(request, needsHttp: true);

    // ядро ждёт .yaml, а JSON для YAML 1.2 подмножество
    final configFile = File(p.join(_sessionDir!.path, 'mihomo.yaml'));
    await configFile.writeAsString(config);

    if (isTun) {
      _mihomoRunsAsRoot = true;
      // дом в каталоге сессии: иначе root наплодил бы в кэше файлов, которые обычный запуск не перепишет
      final home = await _stageGeoAssetsForRoot() ?? _sessionDir!.path;
      final rootBin = await _stageBinaryForRoot(bin, 'mihomo');

      _mihomoProcess = await _startElevatedCore(
        binPath: rootBin,
        configPath: configFile.path,
        geoOrHomeDir: home,
        kind: 'mihomo',
        label: 'mihomo',
        log: _singboxLog,
        onStarted: (p) => _mihomoProcess = p,
      );

      final ready = await _waitForTunCore(
        process: _mihomoProcess!,
        log: _singboxLog,
      );
      final coreLog = await _readRootCoreLog();
      if (coreLog.trim().isNotEmpty) {
        _singboxLog
          ..writeln('=== mihomo (core) ===')
          ..writeln(coreLog);
      }
      if (!ready) {
        final tail = coreLog.trim().isEmpty
            ? _tail(_singboxLog)
            : _tail(StringBuffer(coreLog));
        throw VpnStartException(tunStartFailureMessage(
          fallback: 'The mihomo TUN tunnel did not start.',
          coreOutput: coreLog.trim().isEmpty ? _singboxLog.toString() : coreLog,
          windows: false,
          tail: tail,
        ));
      }
      return;
    }

    _mihomoRunsAsRoot = false;
    _mihomoProcess = await Process.start(
      bin,
      ['-d', await LinuxCorePaths.mihomoHomeDir(), '-f', configFile.path],
      workingDirectory: _sessionDir!.path,
      mode: ProcessStartMode.normal,
    );
    _pipeProcessOutput(_mihomoProcess!, _xrayLog);

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

  // путь версионирован: тело обёртки это контракт по позициям аргументов, и со старым путём
  // у тех, кто уже поставил правило, mihomo запускался бы командой keqrnel

  static const _polkitHelperPath = '/usr/local/lib/keqdroid/core-tun-root';

  // старый хелпер сносим, иначе он остался бы разрешён в polkit навсегда
  static const _legacyPolkitHelperPath =
      '/usr/local/lib/keqdroid/keqrnel-tun-root';

  static const _polkitRulePath = '/etc/polkit-1/rules.d/49-keqdroid-tun.rules';

  static const _trustedCoresDir = '/usr/local/lib/keqdroid/cores';

  // хелпер без метки запускал от root любой бинарь из аргумента
  static const _helperVersionMark = '[wrap v5';

  static const _untrustedCoreExit = 4;

  @visibleForTesting
  static String get tunWrapperBodyForTest => _tunWrapperBody;

  @visibleForTesting
  static String get polkitRuleForTest => _polkitRuleContent;

  @visibleForTesting
  static const polkitHelperPathForTest = _polkitHelperPath;

  @visibleForTesting
  static const helperVersionMarkForTest = _helperVersionMark;

  static bool _rememberOfferedThisRun = false;

  // хелпер без пароля запускает только ядро, байт в байт совпавшее с доверенной копией, и запускает саму копию.
  // modprobe tun здесь: это единственное место, где мы root, а без модуля нет /dev/net/tun
  static const _tunWrapperBody = r'''SB="$1"; CFG="$2"; GEO="$3"; LOGF="$4"; SENT="$5"; APPPID="$6"; AUTHF="$7"; KIND="$8"
HELPER=/usr/local/lib/keqdroid/core-tun-root
CORES=/usr/local/lib/keqdroid/cores
NAME=keqrnel
[ "$KIND" = "mihomo" ] && NAME=mihomo
if [ "$0" = "$HELPER" ]; then
  [ "$(sha256sum <"$SB")" = "$(sha256sum <"$CORES/$NAME")" ] || exit 4
  SB="$CORES/$NAME"
elif grep -q '\[wrap v5' "$HELPER" 2>/dev/null; then
  mkdir -p "$CORES" && install -m 0755 "$SB" "$CORES/$NAME"
elif [ -f "$HELPER" ]; then
  rm -f "$HELPER" /usr/local/lib/keqdroid/keqrnel-tun-root /etc/polkit-1/rules.d/49-keqdroid-tun.rules
fi
: >"$LOGF"
: >"$AUTHF"
echo "[wrap v5 sentinel] start KIND=$KIND SENT=$SENT exists=$([ -e "$SENT" ] && echo y || echo n) APPPID=$APPPID app=$(kill -0 "$APPPID" 2>/dev/null && echo y || echo n)" >>"$LOGF"
if [ ! -e /dev/net/tun ]; then
  echo "[wrap] /dev/net/tun missing, loading module" >>"$LOGF"
  modprobe tun >>"$LOGF" 2>&1 || echo "[wrap] modprobe tun failed" >>"$LOGF"
fi
if [ "$KIND" = "mihomo" ]; then
  "$SB" -d "$GEO" -f "$CFG" >>"$LOGF" 2>&1 &
else
  if [ -n "$GEO" ]; then export XRAY_LOCATION_ASSET="$GEO"; fi
  "$SB" run -c "$CFG" >>"$LOGF" 2>&1 &
fi
sb=$!
while [ -e "$SENT" ] && kill -0 "$APPPID" 2>/dev/null; do
  kill -0 "$sb" 2>/dev/null || break
  sleep 1
done
echo "[wrap v5 sentinel] stop sent=$([ -e "$SENT" ] && echo y || echo n) app=$(kill -0 "$APPPID" 2>/dev/null && echo y || echo n) sb=$(kill -0 "$sb" 2>/dev/null && echo y || echo n)" >>"$LOGF"
kill -TERM "$sb" 2>/dev/null
wait "$sb"
''';

  static const _polkitRuleContent =
      '''// keqdroid: passwordless authorization for TUN mode (installed on user request).
// Removing this file restores the password prompt on every TUN connect.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "$_polkitHelperPath" &&
        subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
''';

  // правило не статим: /etc/polkit-1/rules.d с правами 0700, existsSync оттуда всегда false. признак это хелпер
  static bool isPasswordlessTunInstalled() {
    if (!Platform.isLinux) return false;
    try {
      final helper = File(_polkitHelperPath);
      return helper.existsSync() &&
          helper.readAsStringSync().contains(_helperVersionMark);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> installPasswordlessTun() async {
    if (!Platform.isLinux) return false;
    final helper = '#!/bin/sh\n$_tunWrapperBody';
    final cores = <String, String?>{
      'keqrnel': await LinuxCorePaths.keqrnelExecutable(),
      'mihomo': await LinuxCorePaths.mihomoExecutable(),
    };
    final installCores = [
      for (final MapEntry(:key, :value) in cores.entries)
        if (value != null)
          "install -m 0755 ${_shellQuote(value)} '$_trustedCoresDir/$key'",
    ].join('\n');
    // <<'EOF' в кавычках: $1 и $(...) пишутся в файл буквально
    final script = '''
set -e
mkdir -p /usr/local/lib/keqdroid '$_trustedCoresDir'
rm -f '$_legacyPolkitHelperPath'
$installCores
cat > '$_polkitHelperPath' <<'KEQDROID_HELPER_EOF'
$helper
KEQDROID_HELPER_EOF
chmod 0755 '$_polkitHelperPath'
chown root:root '$_polkitHelperPath' 2>/dev/null || true
mkdir -p /etc/polkit-1/rules.d
cat > '$_polkitRulePath' <<'KEQDROID_RULE_EOF'
$_polkitRuleContent
KEQDROID_RULE_EOF
chmod 0644 '$_polkitRulePath'
chown root:root '$_polkitRulePath' 2>/dev/null || true
''';
    try {
      final res = await Process.run('pkexec', ['sh', '-c', script]);
      if (res.exitCode != 0) {
        AppLogger.instance.warn(
          'installPasswordlessTun failed: code=${res.exitCode} '
          'err=${res.stderr}',
        );
      }
      return res.exitCode == 0;
    } catch (e, st) {
      AppLogger.instance
          .error('installPasswordlessTun error', error: e, stackTrace: st);
      return false;
    }
  }

  static Future<bool> removePasswordlessTun() async {
    if (!Platform.isLinux) return false;
    final script =
        "rm -f '$_polkitHelperPath' '$_legacyPolkitHelperPath' '$_polkitRulePath'; "
        "rm -rf '$_trustedCoresDir'";
    try {
      final res = await Process.run('pkexec', ['sh', '-c', script]);
      return res.exitCode == 0;
    } catch (e, st) {
      AppLogger.instance
          .error('removePasswordlessTun error', error: e, stackTrace: st);
      return false;
    }
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  Future<void> _runKeqrnelAsRoot(String config) async {
    final singBin = await LinuxCorePaths.keqrnelExecutable();
    if (singBin == null) {
      throw VpnStartException(
        'keqrnel not found (required for TUN mode). ${LinuxCorePaths.binariesHint}',
      );
    }

    final stackFix = applyTunStackFallback(
      config,
      gvisorAvailable: await CoreCapabilities.hasGvisor(singBin),
    );
    if (stackFix.downgradedFrom != null) {
      AppLogger.instance.warn(
        'TUN stack "${stackFix.downgradedFrom}" needs a core built with '
        '-tags with_gvisor; this keqrnel has none, falling back to "system".',
      );
    }

    final singConfigFile = File(p.join(_sessionDir!.path, 'keqrnel-tun.json'));
    await singConfigFile.writeAsString(stackFix.config);
    final rootGeoDir = await _stageGeoAssetsForRoot();
    final rootSingBin = await _stageBinaryForRoot(singBin, 'keqrnel');

    _singboxProcess = await _startElevatedCore(
      binPath: rootSingBin,
      configPath: singConfigFile.path,
      geoOrHomeDir: rootGeoDir ?? '',
      kind: '',
      label: 'keqrnel',
      log: _singboxLog,
      onStarted: (p) => _singboxProcess = p,
    );

    final ready = await _waitForTunCore(
      process: _singboxProcess!,
      log: _singboxLog,
    );

    final coreLog = await _readRootCoreLog();
    if (coreLog.trim().isNotEmpty) {
      _singboxLog
        ..writeln('=== keqrnel (core) ===')
        ..writeln(coreLog);
    }

    if (!ready) {
      final tail = coreLog.trim().isEmpty
          ? _tail(_singboxLog)
          : _tail(StringBuffer(coreLog));
      throw VpnStartException(tunStartFailureMessage(
        fallback: 'The TUN tunnel did not start.',
        coreOutput: coreLog.trim().isEmpty ? _singboxLog.toString() : coreLog,
        windows: false,
        tail: tail,
      ));
    }
  }

  // монт AppImage root не видит, pkexec падает с Permission denied, поэтому копия в каталоге сессии
  Future<String> _stageBinaryForRoot(String binPath, String name) async {
    final staged = p.join(_sessionDir!.path, name);
    try {
      await File(binPath).copy(staged);
      await Process.run('chmod', ['0755', staged]);
    } catch (e) {
      throw VpnStartException('Could not stage $name for elevation: $e');
    }
    return staged;
  }

  Future<String> _readRootCoreLog() async {
    try {
      return await File(_coreLogPath).readAsString();
    } catch (_) {
      return '';
    }
  }

  // onStarted сразу после запуска: стоп в этом окне обязан найти процесс и снять сентинел,
  // иначе root-ядро останется с поднятым TUN
  Future<Process> _startElevatedCore({
    required String binPath,
    required String configPath,
    required String geoOrHomeDir,
    required String kind,
    required String label,
    required StringBuffer log,
    required void Function(Process) onStarted,
    bool allowPasswordless = true,
  }) async {
    // pkexec не пробрасывает сигналы root-потомку, а stdin у него сразу на EOF,
    // поэтому жизнь ядра привязана к файлу-сентинелу и kill -0 по pid приложения
    final sentinelFile = File(p.join(_sessionDir!.path, 'core.run'));
    await sentinelFile.writeAsString('1');
    _rootSentinel = sentinelFile;
    // маркер создаёт обёртка сразу после polkit: по нему отличаем ввод пароля от старта ядра
    final authMarker = File(p.join(_sessionDir!.path, 'core.auth'));
    _keqrnelLaunchedAt = DateTime.now();

    // позиции аргументов это контракт с телом обёртки, менять только вместе с путём хелпера
    final coreArgs = <String>[
      binPath,
      configPath,
      geoOrHomeDir,
      _coreLogPath,
      sentinelFile.path,
      '$pid',
      authMarker.path,
      kind,
    ];
    final usePasswordless = allowPasswordless && isPasswordlessTunInstalled();
    final launch = planElevation(
      coreArgs: coreArgs,
      wrapperBody: _tunWrapperBody,
      helperPath: _polkitHelperPath,
      asRoot: runningAsRoot(),
      passwordless: usePasswordless,
    );
    if (launch.viaPkexec && LinuxCorePaths.findPkexec() == null) {
      throw const VpnStartException(
        'TUN mode needs root through pkexec, and polkit is not installed. '
        'Install polkit with an authentication agent, run the app as root '
        '(sudo), or use Proxy mode.',
      );
    }
    final Process process;
    try {
      process = await Process.start(
        launch.executable,
        launch.args,
        workingDirectory: _sessionDir!.path,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (e) {
      // только message: $e затащил бы сюда команду целиком
      throw VpnStartException(
        'Could not launch $label with elevated privileges through '
        '${launch.executable}: ${e.message}',
      );
    }
    onStarted(process);
    _pipeProcessOutput(process, log);

    // сначала ждём polkit: иначе бюджет готовности TUN тикал, пока человек вводил пароль
    final authorized = await _waitForElevation(
      process: process,
      authMarker: authMarker,
      log: log,
      untrustedCoreExit: usePasswordless ? _untrustedCoreExit : null,
    );
    if (!authorized) {
      AppLogger.instance.info(
        '$label changed since passwordless TUN was set up; asking for the '
        'password once to trust the new one',
      );
      return _startElevatedCore(
        binPath: binPath,
        configPath: configPath,
        geoOrHomeDir: geoOrHomeDir,
        kind: kind,
        label: label,
        log: log,
        onStarted: onStarted,
        allowPasswordless: false,
      );
    }

    if (launch.viaPkexec && !usePasswordless && !_rememberOfferedThisRun) {
      _rememberOfferedThisRun = true;
      if (!_linuxTunRememberController.isClosed) {
        _linuxTunRememberController.add(null);
      }
    }
    return process;
  }

  Future<String?> _stageGeoAssetsForRoot() async {
    final geoDir = await LinuxCorePaths.geoAssetDir();
    if (geoDir == null) return null;

    final rootGeoDir = Directory(p.join(_sessionDir!.path, 'geo'));
    if (!rootGeoDir.existsSync()) rootGeoDir.createSync(recursive: true);

    var copied = false;
    for (final name in LinuxCorePaths.geoFileNames) {
      final src = File(p.join(geoDir, name));
      if (!src.existsSync()) continue;
      await src.copy(p.join(rootGeoDir.path, name));
      copied = true;
    }
    return copied ? rootGeoDir.path : null;
  }

  Future<bool> _waitForElevation({
    required Process process,
    required File authMarker,
    required StringBuffer log,
    int? untrustedCoreExit,
  }) async {
    const maxWait = Duration(minutes: 2);
    final sw = Stopwatch()..start();
    while (sw.elapsed < maxWait) {
      final code = await _exitCodeOrNull(process);
      if (code != null) {
        if (code == untrustedCoreExit) return false;
        throw VpnStartException(_elevationError(code, log));
      }
      if (authMarker.existsSync()) return true;
      if (await _tunInterfaceExists()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // auth не выдана и root-потомка ещё нет, сворачивать pkexec безопасно
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
    throw const VpnStartException(
      'Polkit authorization timed out (2 min). Approve the password prompt '
      'to start TUN mode, or use Proxy mode.',
    );
  }

  Future<bool> _waitForTunCore({
    required Process process,
    required StringBuffer log,
  }) async {
    var waited = 0;
    while (waited < 20000) {
      final code = await _exitCodeOrNull(process);
      if (code != null) {
        throw VpnStartException(_elevationError(code, log));
      }
      // строка только от sing-box: баннер встроенного xray печатается раньше tun-инбаунда
      if (singboxTunReady(log.toString())) return true;
      if (await _tunInterfaceExists()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      waited += 300;
    }
    if (await _tunInterfaceExists()) return true;

    try {
      final coreLog = await File(_coreLogPath).readAsString();
      if (coreLog.trim().isNotEmpty) {
        log
          ..writeln('=== keqrnel (core, timeout) ===')
          ..writeln(coreLog);
      }
    } catch (_) {}

    final stillRunning = await _exitCodeOrNull(process);
    if (stillRunning != null) {
      throw VpnStartException(_elevationError(stillRunning, log));
    }
    return false;
  }

  // 126 значит окно пароля закрыли, 127 не авторизовано или нет агента polkit
  String _elevationError(int code, StringBuffer log) {
    switch (code) {
      case 126:
        return 'Authorization cancelled. TUN mode needs root via pkexec '
            '(polkit) — approve the password prompt, or use Proxy mode.';
      case 127:
        return 'Could not get root for TUN mode: no polkit agent answered '
            '(pkexec). Install/start a polkit authentication agent, or use '
            'Proxy mode.';
      default:
        var coreTail = '';
        try {
          final coreLog = File(_coreLogPath);
          final launchedAt = _keqrnelLaunchedAt;
          if (launchedAt != null &&
              !coreLog.lastModifiedSync().isBefore(launchedAt)) {
            coreTail = coreLog.readAsStringSync().trim();
          }
        } catch (_) {}
        final detail =
            coreTail.isNotEmpty ? _tail(StringBuffer(coreTail)) : _tail(log);
        final hint = tunFailureHint(
          coreTail.isNotEmpty ? coreTail : log.toString(),
          windows: false,
        );
        if (hint != null) {
          return 'The tunnel core exited with code $code.\n'
              '${hint.message}\n$detail';
        }
        return 'keqrnel exited with code $code (TUN/elevation failed?).\n'
            '$detail';
    }
  }

  Future<bool> _tunInterfaceExists() async {
    return Directory('/sys/class/net/$tunInterfaceName').exists();
  }

  Future<void> _verifyChainReachable(TunnelSessionRequest request) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (_activeMode == null) return;
    final result = await probeLocalHttpProxy(request.httpPort);
    if (probeWentThrough(result)) return;
    final outcome = result.status != null
        ? 'status=${result.status}'
        : 'failed (${result.error})';
    if (_activeMode == null) return;
    AppLogger.instance.warn(
      'The tunnel is up, but a test request through the core did not go '
      'through ($outcome). Nothing will load until this is fixed — the usual '
      'reasons are an unreachable or expired server, wrong server settings, or '
      'a routing rule that blocks the test address.',
    );
  }

  Future<void> _applySystemProxy(TunnelSessionRequest request) async {
    final ok = await (await LinuxSystemProxy.system()).enable(
      httpPort: request.httpPort,
      socksPort: request.socksPort,
    );
    if (!ok) {
      AppLogger.instance.warn(
        'Could not set the system proxy (neither gsettings nor KDE settings '
        'are available). The local proxy is up on 127.0.0.1: '
        'SOCKS ${request.socksPort} / HTTP ${request.httpPort}.',
      );
    }
  }

  static Future<void> _restoreSystemProxy() async {
    try {
      await (await LinuxSystemProxy.system()).disable();
    } catch (e) {
      AppLogger.instance.warn('Could not restore the system proxy', error: e);
    }
  }

  static Future<void> cleanupStaleState() => _restoreSystemProxy();

  void _watchProcessExit(Process? process, String label) {
    if (process == null) return;
    unawaited(process.exitCode.then((code) async {
      if (_stoppingSession) return;
      if (!identical(process, _xrayProcess) &&
          !identical(process, _singboxProcess) &&
          !identical(process, _mihomoProcess)) {
        return;
      }
      AppLogger.instance.error(
        '$label exited unexpectedly with code $code; tearing the session down',
      );
      try {
        await stopSession();
      } catch (_) {}
      emit(VpnState(
        status: VpnStatus.error,
        errorMessage:
            '$label stopped unexpectedly (exit code $code). Disconnected.',
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
    stopStatsLoop();
    if (emitStates) emit(const VpnState(status: VpnStatus.disconnecting));

    if (_singboxProcess != null ||
        _xrayProcess != null ||
        _mihomoProcess != null) {
      await _dumpLogsToFile();
    }

    // прокси возвращаем всегда, даже если ставил не этот экземпляр (прошлое падение)
    await _restoreSystemProxy();

    // сначала ядро с TUN: трафик должен падать закрытым, а не в мёртвый socks
    await _stopRootCore(_singboxProcess, 'keqrnel');
    if (_mihomoRunsAsRoot) {
      await _stopRootCore(_mihomoProcess, 'mihomo');
    } else {
      await _killProcess(_mihomoProcess);
    }
    await _killProcess(_xrayProcess);
    _singboxProcess = null;
    _mihomoProcess = null;
    _mihomoRunsAsRoot = false;
    _xrayProcess = null;
    _xrayBinPath = null;
    _keqrnelClashPort = null;
    _keqrnelClashSecret = null;

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
  Future<bool> requestTunnelPermission() async => true;

  @override
  Future<VpnState> getCurrentState() async {
    if (_xrayProcess != null ||
        _mihomoProcess != null ||
        _singboxProcess != null) {
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
    final seen = <String>{};
    final apps = <Map<String, dynamic>>[];
    try {
      await for (final entry in Directory('/proc').list(followLinks: false)) {
        final pid = p.basename(entry.path);
        if (int.tryParse(pid) == null) continue;

        String? exePath;
        try {
          exePath = await Link('${entry.path}/exe').target();
        } catch (_) {
          exePath = null;
        }

        String name;
        if (exePath != null && exePath.isNotEmpty) {
          name = p.basename(exePath);
        } else {
          if (!includeSystem) continue;
          try {
            name = (await File('${entry.path}/comm').readAsString()).trim();
          } catch (_) {
            continue;
          }
        }
        if (name.isEmpty || !seen.add(name.toLowerCase())) continue;

        apps.add({
          'packageName': name,
          'appName': name,
          'isRunning': true,
          'isSystem': exePath == null,
          'installPath': ?exePath,
        });
      }
    } catch (e, st) {
      AppLogger.instance.warn(
        'listProcesses (/proc) failed',
        error: e,
        stackTrace: st,
      );
    }
    apps.sort(
      (a, b) => (a['appName'] as String).toLowerCase().compareTo(
        (b['appName'] as String).toLowerCase(),
      ),
    );
    return apps;
  }

  @override
  Future<String?> getAppIcon(String path) async => null;

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
    List<
      ({String id, bool success, int? latencyMs, String error, int? httpStatus})
    >
  >
  xrayUrlTestBatch({
    required List<(String id, String xrayConfig)> items,
    required int socksPort,
    VpnBackend core = VpnBackend.xray,
    String testUrl = 'https://connectivitycheck.gstatic.com/generate_204',
    int timeoutMs = 15000,
    bool keepAlive = true,
  }) async {
    if (items.isEmpty) return [];
    final raw = await EphemeralXrayPing.urlTestBatch(
      items: items.map((e) => (id: e.$1, xrayConfigJson: e.$2)).toList(),
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
  Future<List<({String id, bool success, int? kbps, String error})>>
  xraySpeedTestBatch({
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

  static Map<String, String>? _coreProcessEnvironment(String? geoDir) {
    if (geoDir == null) return null;
    return {...Platform.environment, 'XRAY_LOCATION_ASSET': geoDir};
  }

  void _pipeProcessOutput(Process process, StringBuffer buffer) {
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

    // allowMalformed: строка ядра не в UTF-8 иначе роняет весь пайп лога
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

  // убитый сигналом процесс на Linux даёт отрицательный код, поэтому вышел значит не null
  static Future<int?> _exitCodeOrNull(Process process) => process.exitCode
      .then<int?>((c) => c)
      .timeout(const Duration(milliseconds: 1), onTimeout: () => null);

  Future<void> _stopRootCore(Process? proc, String coreName) async {
    if (proc == null) return;
    try {
      final sentinel = _rootSentinel;
      if (sentinel != null && sentinel.existsSync()) sentinel.deleteSync();
    } catch (_) {}
    _rootSentinel = null;
    try {
      await proc.exitCode.timeout(const Duration(seconds: 8));
    } catch (_) {
      // обёртка не вышла вовремя: добиваем, чтобы root-ядро не держало TUN (может спросить пароль)
      try {
        await Process.run('pkexec', ['pkill', '-TERM', '-x', coreName]);
      } catch (_) {}
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }

    // процесс мёртв, а устройство ещё нет: поверх живого tun-keqdis следующая сессия падает
    const budgetMs = 6000;
    var waited = 0;
    while (waited < budgetMs && await _tunInterfaceExists()) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited += 250;
    }
    if (waited >= budgetMs) {
      AppLogger.instance.warn(
        'TUN interface $tunInterfaceName is still present '
        '${budgetMs ~/ 1000}s after the core was stopped.',
      );
    }
  }

  Future<void> _killProcess(Process? process) async {
    if (process == null) return;
    try {
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
            throw VpnStartException(
              '$processLabel exited with code $code.\n${_tail(log ?? StringBuffer())}',
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

  Future<int> _freePort() async {
    final s = await ServerSocket.bind('127.0.0.1', 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<void> _ensurePortsAvailable(
    TunnelSessionRequest request, {
    required bool needsHttp,
  }) async {
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
    if (!needsHttp) return;
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

  String _tail(StringBuffer buffer, {int maxLines = 12}) {
    final lines = buffer
        .toString()
        .split('\n')
        .where((l) => l.trim().isNotEmpty);
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




  // счётчики API ядра, а не интерфейса: рукопожатия TCP отвечает локальный стек,
  // и пришло было бы и от мёртвого сервера
  @override
  Future<({int down, int up})?> sessionTrafficCounters() async {
    if (_mihomoProcess != null) {
      final api = MihomoApiSession();
      final port = api.port;
      return port == null ? null : queryClashTraffic(port, secret: api.secret);
    }
    final port = _keqrnelClashPort;
    return port == null
        ? null
        : queryClashTraffic(port, secret: _keqrnelClashSecret ?? '');
  }

  @override
  Future<void> pollTrafficStats(ConnectionMode mode, {bool force = false}) async {
    if (!statsPollingEnabled && !force) return;
    if (_xrayProcess == null &&
        _mihomoProcess == null &&
        _singboxProcess == null) {
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
      } else if (mode == ConnectionMode.tun) {
        // в интерфейс ядро ОС пишет исходящее (tx) и читает ответы (rx)
        final c = await _queryTunCounters();
        if (c == null) {
          emitConnectedTelemetry(mode);
          return;
        }
        inOctets = c.rx;
        outOctets = c.tx;
      } else if (_keqrnelClashPort != null) {
        final t = await queryClashTraffic(
          _keqrnelClashPort!,
          secret: _keqrnelClashSecret ?? '',
        );
        if (t == null) {
          emitConnectedTelemetry(mode);
          return;
        }
        inOctets = t.down;
        outOctets = t.up;
      } else if (_xrayProcess != null) {
        final xrayBin = _xrayBinPath;
        if (xrayBin == null) return;
        final counters = await XraySessionStats.queryInboundCounters(
          xrayExecutable: xrayBin,
        );
        if (counters == null) return;
        inOctets = counters.download;
        outOctets = counters.upload;
      } else {
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

      final deltaIn = inOctets >= prevInOctets ? inOctets - prevInOctets : 0;
      final deltaOut = outOctets >= prevOutOctets
          ? outOctets - prevOutOctets
          : 0;
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
      AppLogger.instance.debug('Linux getTrafficStats failed: $e');
    }
  }




  Future<({int rx, int tx})?> _queryTunCounters() async {
    try {
      final base = '/sys/class/net/$tunInterfaceName/statistics';
      final rx = int.parse(
        (await File('$base/rx_bytes').readAsString()).trim(),
      );
      final tx = int.parse(
        (await File('$base/tx_bytes').readAsString()).trim(),
      );
      return (rx: rx, tx: tx);
    } catch (_) {
      return null;
    }
  }



}
