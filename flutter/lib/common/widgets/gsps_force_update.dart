// GSPSoporte: pantalla bloqueante de "actualización requerida". Se muestra en
// lugar del home cuando GspsApi.checkMinVersion detecta versión < app_min_version.
// Es el kill-switch confiable de builds viejos (server-driven, plan §2.3/2.6).
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../../models/state_model.dart';

/// Envuelve el home del app: si `forceUpdate` está activo, muestra la pantalla
/// bloqueante en lugar del contenido normal.
class GspsForceUpdateGate extends StatelessWidget {
  final Widget child;
  const GspsForceUpdateGate({Key? key, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() =>
        stateGlobal.forceUpdate.value ? const _GspsForceUpdateScreen() : child);
  }
}

class _GspsForceUpdateScreen extends StatelessWidget {
  const _GspsForceUpdateScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update_alt, size: 64),
                const SizedBox(height: 20),
                Text(
                  translate('Update required'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  translate(
                      'This version is no longer supported. Please update to continue.'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(translate('Update')),
                  onPressed: () {
                    final url = stateGlobal.forceUpdateUrl;
                    if (url.isNotEmpty) {
                      launchUrl(Uri.parse(url));
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
