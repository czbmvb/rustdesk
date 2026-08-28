// GSPCOMS: "recuérdame" del técnico.
//
// Antes la app nunca guardaba la contraseña: guardaba un pase que caducaba, y
// al caducar volvía a pedir usuario y contraseña. Como el técnico entra en días
// salteados y desde varios equipos, eso se sentía aleatorio y estorbaba justo
// cuando urge dar soporte.
//
// Aquí se guardan usuario y contraseña para poder volver a entrar solos. La
// contraseña se cifra con la llave del equipo (main_encrypt_secret, el mismo
// mecanismo con el que RustDesk ya persiste el PIN y el proxy): copiar el
// archivo a otra máquina NO sirve de nada.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import '../../common.dart';

const _kUsuario = 'gspcoms_remember_user';
const _kSecreto = 'gspcoms_remember_pass';

/// Usuario guardado (cadena vacía si no hay). Sirve para precargar el campo.
String usuarioRecordado() => bind.mainGetLocalOption(key: _kUsuario);

bool hayCredencialesGuardadas() =>
    bind.mainGetLocalOption(key: _kUsuario).isNotEmpty &&
    bind.mainGetLocalOption(key: _kSecreto).isNotEmpty;

Future<void> guardarCredenciales(String usuario, String contrasena) async {
  await bind.mainSetLocalOption(key: _kUsuario, value: usuario);
  await bind.mainSetLocalOption(
      key: _kSecreto, value: bind.mainEncryptSecret(s: contrasena));
}

Future<void> olvidarCredenciales() async {
  await bind.mainSetLocalOption(key: _kUsuario, value: '');
  await bind.mainSetLocalOption(key: _kSecreto, value: '');
}

/// Vuelve a entrar solo cuando el pase se venció o lo revocaron y hay
/// credenciales guardadas. Devuelve true si logró restaurar la sesión.
///
/// Nunca lanza: ante cualquier error la app queda como estaba y el técnico
/// entra a mano, que es como funcionaba antes.
Future<bool> reloginAutomatico() async {
  try {
    if (!hayCredencialesGuardadas()) return false;

    // Al arrancar, el pase vencido TODAVÍA está guardado: quien lo borra es
    // refreshCurrentUser (user_model.dart) cuando el servidor le responde 401,
    // y esa rutina devuelve void, así que no se puede esperar. Le damos margen
    // para que ocurra antes de decidir; si el pase sobrevive, no hay nada que
    // hacer y salimos sin tocar nada.
    for (var i = 0; i < 10; i++) {
      if (bind.mainGetLocalOption(key: 'access_token').isEmpty) break;
      await Future.delayed(const Duration(seconds: 1));
    }
    if (bind.mainGetLocalOption(key: 'access_token').isNotEmpty) return false;

    final usuario = bind.mainGetLocalOption(key: _kUsuario);
    final contrasena =
        bind.mainDecryptSecret(s: bind.mainGetLocalOption(key: _kSecreto));
    if (usuario.isEmpty || contrasena.isEmpty) return false;

    final resp = await gFFI.userModel.login(LoginRequest(
        username: usuario,
        password: contrasena,
        id: await bind.mainGetMyId(),
        uuid: await bind.mainGetUuid(),
        autoLogin: true,
        type: HttpType.kAuthReqTypeAccount));

    if (resp.type == HttpType.kAuthResTypeToken && resp.access_token != null) {
      await bind.mainSetLocalOption(
          key: 'access_token', value: resp.access_token!);
      await bind.mainSetLocalOption(
          key: 'user_info', value: jsonEncode(resp.user ?? {}));
      gFFI.userModel.refreshCurrentUser();
      debugPrint('reloginAutomatico: sesión restaurada');
      return true;
    }

    // El servidor respondió pero no dio pase: la contraseña cambió, la cuenta
    // se desactivó o pide segundo factor. Se olvidan las credenciales para no
    // reintentar en cada arranque (y para no dejar una contraseña que ya no
    // sirve guardada en el equipo).
    await olvidarCredenciales();
    debugPrint('reloginAutomatico: credenciales ya no válidas, se olvidaron');
  } catch (e) {
    // Error de red: NO se olvidan las credenciales, se reintenta al próximo
    // arranque. Solo se descartan cuando el servidor las rechaza de verdad.
    debugPrint('reloginAutomatico (silencioso): $e');
  }
  return false;
}
