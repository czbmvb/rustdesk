// GSPCOMS: Reporte de hardware del equipo local.
// Muestra specs (CPU/RAM/disco+salud/video/batería), exporta a PDF + Excel y
// los guarda en el inventario de dispositivos del sistema (gspcoms-api).
//
// Estrategia: CPU/RAM/OS/hostname vienen de Rust (bind.mainGetHardwareSpecs,
// que usa sysinfo). Disco/salud/GPU/batería/uptime se obtienen en Windows con
// PowerShell (la app corre con privilegios suficientes para el estado SMART
// básico). En otras plataformas se reporta lo que haya, sin romper.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:excel/excel.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

/// Recolecta el reporte completo. Nunca lanza: si algo falla, ese campo queda vacío.
Future<Map<String, dynamic>> gatherHardwareReport() async {
  final report = <String, dynamic>{
    'rustdesk_id': '',
    'hostname': '',
    'os': '',
    'cpu': '',
    'ram_gb': 0,
    'gpu': '',
    'is_laptop': false,
    'battery_percent': null,
    'uptime_hours': null,
    'disks': <dynamic>[],
    'volumes': <dynamic>[],
  };

  // 1) Base desde Rust (sysinfo): cpu, memory, os, hostname.
  try {
    final raw = bind.mainGetHardwareSpecs();
    if (raw.isNotEmpty) {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      report['cpu'] = (m['cpu'] ?? '').toString();
      report['os'] = (m['os'] ?? '').toString();
      report['hostname'] = (m['hostname'] ?? '').toString();
      // "memory" viene como "16GB"; extraemos el número.
      final mem = (m['memory'] ?? '').toString();
      final num = RegExp(r'([\d.]+)').firstMatch(mem)?.group(1);
      if (num != null) report['ram_gb'] = double.tryParse(num)?.round() ?? 0;
    }
  } catch (_) {}

  // 2) ID del equipo (RustDesk ID) para ligarlo en el inventario.
  try {
    report['rustdesk_id'] = await bind.mainGetMyId();
  } catch (_) {}

  // 3) Disco/salud/GPU/batería/uptime — Windows vía PowerShell.
  if (Platform.isWindows) {
    try {
      final ps = await _runPowerShell(_psHardwareScript);
      if (ps != null) {
        report['disks'] = ps['disks'] ?? [];
        report['volumes'] = ps['volumes'] ?? [];
        final gpus = (ps['gpu'] as List?)?.whereType<String>().toList() ?? [];
        report['gpu'] = gpus.join(', ');
        report['uptime_hours'] = ps['uptime_hours'];
        if (ps['battery_percent'] != null) {
          report['battery_percent'] = ps['battery_percent'];
          report['is_laptop'] = true;
        }
      }
    } catch (_) {}
  }

  return report;
}

const _psHardwareScript = r'''
$ErrorActionPreference='SilentlyContinue'
$disks = Get-PhysicalDisk | ForEach-Object { @{ name="$($_.FriendlyName)"; type="$($_.MediaType)"; health="$($_.HealthStatus)"; size_gb=[math]::Round($_.Size/1GB) } }
$vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } | ForEach-Object { @{ drive="$($_.DriveLetter)"; size_gb=[math]::Round($_.Size/1GB); free_gb=[math]::Round($_.SizeRemaining/1GB) } }
$gpu = Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name)" }
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$uptime = if ($boot) { [math]::Round(((Get-Date) - $boot).TotalHours) } else { $null }
$bat = Get-CimInstance Win32_Battery | Select-Object -First 1
$batPct = if ($bat) { [int]$bat.EstimatedChargeRemaining } else { $null }
@{ disks=@($disks); volumes=@($vols); gpu=@($gpu); uptime_hours=$uptime; battery_percent=$batPct } | ConvertTo-Json -Compress -Depth 5
''';

Future<Map<String, dynamic>?> _runPowerShell(String script) async {
  try {
    final res = await Process.run(
      'powershell',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    ).timeout(const Duration(seconds: 20));
    final out = (res.stdout ?? '').toString().trim();
    if (out.isEmpty) return null;
    final decoded = jsonDecode(out);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Sube el reporte al inventario del sistema (gspcoms-api). Devuelve null si OK,
/// o un mensaje de error.
Future<String?> _pushToInventory(Map<String, dynamic> report) async {
  try {
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (token.isEmpty) return translate('Login required');
    final url = await bind.mainGetApiServer();
    final body = {
      'rustdesk_id': report['rustdesk_id'],
      'hostname': report['hostname'],
      'os': report['os'],
      'cpu': report['cpu'],
      'ram_gb': report['ram_gb'],
      'gpu': report['gpu'],
      'is_laptop': report['is_laptop'],
      'battery_percent': report['battery_percent'],
      'specs': {
        'disks': report['disks'],
        'volumes': report['volumes'],
        'uptime_hours': report['uptime_hours'],
      },
    };
    final resp = await http.post(
      Uri.parse('$url/api/devices'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: json.encode(body),
    );
    if (resp.statusCode == 200) return null;
    return 'HTTP ${resp.statusCode}';
  } catch (e) {
    return e.toString();
  }
}

// ---------- Formato legible ----------

List<List<String>> _reportRows(Map<String, dynamic> r) {
  final rows = <List<String>>[
    ['Equipo (ID)', '${r['rustdesk_id']}'],
    ['Nombre', '${r['hostname']}'],
    ['Sistema', '${r['os']}'],
    ['Procesador', '${r['cpu']}'],
    ['Memoria RAM', '${r['ram_gb']} GB'],
    ['Video', '${r['gpu']}'.isEmpty ? 'N/D' : '${r['gpu']}'],
    ['Tipo', r['is_laptop'] == true ? 'Laptop' : 'PC'],
  ];
  if (r['battery_percent'] != null) {
    rows.add(['Batería', '${r['battery_percent']}%']);
  }
  if (r['uptime_hours'] != null) {
    rows.add(['Tiempo encendido', '${r['uptime_hours']} h']);
  }
  final disks = (r['disks'] as List?) ?? [];
  for (final d in disks) {
    final m = d as Map;
    rows.add([
      'Disco ${m['name'] ?? ''}',
      '${m['size_gb'] ?? '?'} GB · ${m['type'] ?? ''} · salud: ${m['health'] ?? '?'}',
    ]);
  }
  final vols = (r['volumes'] as List?) ?? [];
  for (final v in vols) {
    final m = v as Map;
    rows.add([
      'Unidad ${m['drive'] ?? ''}:',
      '${m['size_gb'] ?? '?'} GB total · ${m['free_gb'] ?? '?'} GB libres',
    ]);
  }
  return rows;
}

// ---------- Export PDF ----------

Future<String> _exportPdf(Map<String, dynamic> r) async {
  final doc = pw.Document();
  final rows = _reportRows(r);
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('GSPCOMS — Reporte de equipo',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 12),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey),
            columnWidths: {0: const pw.FlexColumnWidth(2), 1: const pw.FlexColumnWidth(3)},
            children: rows
                .map((row) => pw.TableRow(
                      children: row
                          .map((c) => pw.Padding(
                                padding: const pw.EdgeInsets.all(6),
                                child: pw.Text(c),
                              ))
                          .toList(),
                    ))
                .toList(),
          ),
          pw.SizedBox(height: 16),
          pw.Text('Generado por GSPSoporte · gspcoms.net',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey)),
        ],
      ),
    ),
  );
  final bytes = await doc.save();
  return _saveFile(r, 'pdf', bytes);
}

// ---------- Export Excel ----------

Future<String> _exportExcel(Map<String, dynamic> r) async {
  final excel = Excel.createExcel();
  final sheet = excel['Equipo'];
  sheet.appendRow([
    TextCellValue('Campo'),
    TextCellValue('Valor'),
  ]);
  for (final row in _reportRows(r)) {
    sheet.appendRow([TextCellValue(row[0]), TextCellValue(row[1])]);
  }
  final bytes = excel.save();
  return _saveFile(r, 'xlsx', bytes == null ? <int>[] : bytes);
}

Future<String> _saveFile(Map<String, dynamic> r, String ext, List<int> bytes) async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } catch (_) {}
  dir ??= await getApplicationDocumentsDirectory();
  final name = ('${r['hostname']}'.isEmpty ? 'equipo' : '${r['hostname']}')
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final path = '${dir.path}${Platform.pathSeparator}GSPCOMS_$name.$ext';
  await File(path).writeAsBytes(bytes);
  return path;
}

// ---------- Diálogo ----------

void showHardwareReportDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => const _HardwareReportDialog(),
  );
}

class _HardwareReportDialog extends StatefulWidget {
  const _HardwareReportDialog();

  @override
  State<_HardwareReportDialog> createState() => _HardwareReportDialogState();
}

class _HardwareReportDialogState extends State<_HardwareReportDialog> {
  Map<String, dynamic>? _report;
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await gatherHardwareReport();
    if (mounted) setState(() => _report = r);
  }

  Future<void> _doExport(bool pdf) async {
    if (_report == null) return;
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final path = pdf ? await _exportPdf(_report!) : await _exportExcel(_report!);
      setState(() => _status = '${translate("Saved")}: $path');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _doPush() async {
    if (_report == null) return;
    setState(() {
      _busy = true;
      _status = '';
    });
    final err = await _pushToInventory(_report!);
    setState(() {
      _busy = false;
      _status = err == null ? translate('Successful') : 'Error: $err';
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.memory, size: 22),
          const SizedBox(width: 8),
          Text(translate('Device report')),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: r == null
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ..._reportRows(r).map((row) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                  width: 150,
                                  child: Text(row[0],
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600))),
                              Expanded(child: Text(row[1])),
                            ],
                          ),
                        )),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(_status,
                          style: const TextStyle(fontSize: 12),
                          textAlign: TextAlign.center),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy || r == null ? null : () => _doExport(true),
          child: Text(translate('Export PDF')),
        ),
        TextButton(
          onPressed: _busy || r == null ? null : () => _doExport(false),
          child: Text(translate('Export Excel')),
        ),
        ElevatedButton(
          onPressed: _busy || r == null ? null : _doPush,
          child: Text(translate('Save to inventory')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(translate('Close')),
        ),
      ],
    );
  }
}
