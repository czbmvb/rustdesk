// GSPSoporte: cliente del app hacia gspcoms-api (backend en cuentas.gspcoms.net,
// que ya es el default de mainGetApiServer). Por ahora expone el chequeo de
// versión mínima (forced-update server-driven, plan §2.3). Este servicio crecerá
// con el login-gate y la medición de sesión (start/beat/end).
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../common.dart';
import '../common/widgets/login.dart';
import '../utils/http_service.dart' as http;
import 'platform_model.dart';
import 'state_model.dart';

class GspsApi {
  GspsApi._();
  static final GspsApi instance = GspsApi._();

  String get _platform {
    if (isAndroid) return 'android';
    if (isIOS) return 'ios';
    if (isWindows) return 'windows';
    if (isMacOS) return 'macos';
    if (isLinux) return 'linux';
    return 'other';
  }

  /// GET /api/app/version. Si la versión instalada es menor que `min_version`,
  /// activa el gate de actualización forzada (pantalla bloqueante).
  /// Fail-open: ante cualquier error/timeout NO bloquea, para no tumbar a todos
  /// si el server no responde.
  Future<void> checkMinVersion() async {
    if (isWeb) return;
    try {
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return;
      final resp = await http
          .get(Uri.parse('$base/api/app/version?platform=$_platform'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      final minVersion = (m['min_version'] ?? '').toString();
      if (minVersion.isEmpty) return;
      final current = await bind.mainGetVersion();
      if (current.isEmpty) return;
      if (versionCmp(current, minVersion) < 0) {
        stateGlobal.forceUpdateUrl = (m['update_url'] ?? '').toString();
        stateGlobal.forceUpdate.value = true;
      }
    } catch (e) {
      debugPrint('GspsApi.checkMinVersion (fail-open): $e');
    }
  }

  Map<String, String> _authHeaders(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  /// POST /api/gsps/session/start. Devuelve el session_id si el server autoriza,
  /// o null si no (no logueado / sin pase / concurrencia llena / cuenta pendiente).
  /// No lanza: la medición nunca debe romper la conexión.
  Future<int?> sessionStart(String peerId) async {
    try {
      final token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return null;
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return null;
      final resp = await http
          .post(Uri.parse('$base/api/gsps/session/start'),
              headers: _authHeaders(token),
              body: jsonEncode({'peer_id': peerId}))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      if (m['allowed'] == true && m['session_id'] != null) {
        return (m['session_id'] as num).toInt();
      }
      return null;
    } catch (e) {
      debugPrint('GspsApi.sessionStart: $e');
      return null;
    }
  }

  /// POST /api/gsps/session/beat (latido). Silencioso.
  Future<void> sessionBeat(int sessionId) async {
    try {
      final token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return;
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return;
      await http
          .post(Uri.parse('$base/api/gsps/session/beat'),
              headers: _authHeaders(token),
              body: jsonEncode({'session_id': sessionId}))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('GspsApi.sessionBeat: $e');
    }
  }

  /// POST /api/gsps/session/end (cierra + calcula duración + nota para la bitácora).
  Future<void> sessionEnd(int sessionId, {String note = ''}) async {
    try {
      final token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return;
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return;
      await http
          .post(Uri.parse('$base/api/gsps/session/end'),
              headers: _authHeaders(token),
              body: jsonEncode({'session_id': sessionId, 'note': note}))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('GspsApi.sessionEnd: $e');
    }
  }

  /// Login-gate: verifica cuenta + pase ANTES de conectar. Devuelve true si se
  /// puede proceder, false si hay que abortar la conexión (muestra el login o un
  /// aviso según el caso). Fail-open ante error de red para no bloquear soporte
  /// por un hipo del server (enforcement cooperativo/honesto, no criptográfico).
  Future<bool> ensureCanConnect() async {
    if (isWeb) return true; // el gate aplica al cliente instalado
    // 1) Login: si no hay sesión GSPCOMS, pedirla.
    var token = bind.mainGetLocalOption(key: 'access_token');
    if (token.isEmpty) {
      final ok = await loginDialog();
      if (ok != true) return false; // canceló o falló el login
      token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return false;
    }
    // 2) Pase: consultar el estado del servicio.
    try {
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return true; // sin API configurada: no bloquear
      final resp = await http
          .get(Uri.parse('$base/api/gsps/status'), headers: _authHeaders(token))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return true; // fail-open ante error del server
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      final active = m['active'] == true || m['unlimited'] == true;
      if (!active) {
        showToast(translate('You need an active pass to connect.'));
        return false;
      }
      final used = (m['concurrency_used'] as num?)?.toInt() ?? 0;
      final limit = (m['concurrency_limit'] as num?)?.toInt() ?? 1;
      if (used >= limit) {
        showToast(translate('Your concurrent sessions limit is reached.'));
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('GspsApi.ensureCanConnect (fail-open): $e');
      return true; // fail-open ante error de red
    }
  }
}
