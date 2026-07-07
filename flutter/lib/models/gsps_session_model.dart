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

/// Resultado de reservar/iniciar una sesión de soporte.
class GspsStartResult {
  final int? sessionId; // no-null si el server autorizó (hay pase + cupo)
  final bool networkError; // true si no se pudo contactar al server
  final String? reason; // 'no_active_pass' | 'concurrency_full' | 'account_pending_approval'
  GspsStartResult({this.sessionId, this.networkError = false, this.reason});
}

class GspsApi {
  GspsApi._();
  static final GspsApi instance = GspsApi._();

  // Reservas hechas en el gate (peer_id destino -> session_id), que el FfiModel
  // recoge cuando la conexión se establece (handlePeerInfo).
  final Map<String, int> _reservations = {};

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

  /// POST /api/gsps/session/start. Reserva la sesión: valida pase + concurrencia y
  /// crea la fila que el RECEPTOR consulta (authorize). Distingue denegación clara
  /// (sin pase / cupo lleno) de error de red. No lanza.
  Future<GspsStartResult> sessionStart(String peerId) async {
    try {
      final token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return GspsStartResult(reason: 'not_logged_in');
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return GspsStartResult(networkError: true);
      final resp = await http
          .post(Uri.parse('$base/api/gsps/session/start'),
              headers: _authHeaders(token),
              body: jsonEncode({'peer_id': peerId}))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return GspsStartResult(networkError: true);
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      if (m['allowed'] == true && m['session_id'] != null) {
        return GspsStartResult(sessionId: (m['session_id'] as num).toInt());
      }
      return GspsStartResult(reason: (m['reason'] ?? 'denied').toString());
    } catch (e) {
      debugPrint('GspsApi.sessionStart: $e');
      return GspsStartResult(networkError: true);
    }
  }

  /// Reserva en el GATE (antes de conectar): guarda el session_id por peer_id para
  /// que el FfiModel lo recoja al establecerse la conexión.
  Future<GspsStartResult> reserve(String peerId) async {
    final r = await sessionStart(peerId);
    if (r.sessionId != null) _reservations[peerId] = r.sessionId!;
    return r;
  }

  /// El FfiModel recoge (y quita) la reserva hecha en el gate para este peer.
  int? takeReservation(String peerId) => _reservations.remove(peerId);

  /// POST /api/gsps/session/beat (latido). Devuelve keep_alive: `false` SOLO si el
  /// server cerró la sesión (admin / pase vencido / sweeper) → el controlador debe
  /// desconectar. Ante error/timeout devuelve true (no forzar desconexión por un hipo).
  Future<bool> sessionBeat(int sessionId) async {
    try {
      final token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return true;
      final base = await bind.mainGetApiServer();
      if (base.isEmpty) return true;
      final resp = await http
          .post(Uri.parse('$base/api/gsps/session/beat'),
              headers: _authHeaders(token),
              body: jsonEncode({'session_id': sessionId}))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return true;
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      return m['keep_alive'] != false; // false explícito => desconectar
    } catch (e) {
      debugPrint('GspsApi.sessionBeat: $e');
      return true;
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

  /// Login-gate: verifica cuenta + RESERVA la sesión ANTES de conectar (para que
  /// el receptor la vea). Devuelve true si se puede proceder, false si hay que
  /// abortar. Fail-open del lado controlador ante error de red (el RECEPTOR es
  /// quien hace cumplir el cobro, fail-closed). `peerId` = id destino.
  Future<bool> ensureCanConnect(String peerId) async {
    if (isWeb) return true; // el gate aplica al cliente instalado
    // 1) Login: si no hay sesión GSPCOMS, pedirla.
    var token = bind.mainGetLocalOption(key: 'access_token');
    if (token.isEmpty) {
      final ok = await loginDialog();
      if (ok != true) return false; // canceló o falló el login
      token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) return false;
    }
    // 2) Reservar (valida el pase Y crea la fila que el receptor consulta).
    final r = await reserve(peerId);
    if (r.sessionId != null) return true;
    if (r.networkError) return true; // fail-open aquí; el receptor hace cumplir
    // Denegación clara del server: avisar y abortar.
    if (r.reason == 'concurrency_full') {
      showToast(translate('Your concurrent sessions limit is reached.'));
    } else {
      showToast(translate('You need an active pass to connect.'));
    }
    return false;
  }
}
