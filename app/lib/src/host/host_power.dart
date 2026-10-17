import 'dart:io';

/// Estado de energia do computador host, lido de /sys/class/power_supply.
class HostPower {
  const HostPower({required this.hasBattery, required this.level,
      required this.acOnline, required this.status});

  final bool hasBattery;
  final int level; // 0..100
  final bool acOnline;

  /// Status no formato do BatteryManager do Android:
  /// 2 = carregando, 3 = descarregando, 4 = não carregando, 5 = cheia.
  final int status;

  static Future<HostPower> read() async {
    var hasBattery = false, level = 100, ac = false;
    String? batStatus;
    final dir = Directory('/sys/class/power_supply');
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        Future<String?> attr(String n) async {
          final f = File('${e.path}/$n');
          return await f.exists() ? (await f.readAsString()).trim() : null;
        }

        final type = await attr('type');
        if (type == 'Battery' && (await attr('scope')) != 'Device') {
          hasBattery = true;
          level = int.tryParse(await attr('capacity') ?? '') ?? level;
          batStatus = await attr('status');
        } else if (type == 'Mains' || type == 'USB') {
          if ((await attr('online')) == '1') ac = true;
        }
      }
    }
    if (!hasBattery) {
      return const HostPower(hasBattery: false, level: 100, acOnline: true, status: 5);
    }
    final status = switch (batStatus) {
      'Charging' => 2,
      'Discharging' => 3,
      'Full' => 5,
      _ => ac ? (level >= 100 ? 5 : 4) : 3,
    };
    return HostPower(hasBattery: true, level: level.clamp(0, 100), acOnline: ac, status: status);
  }

  /// Fuso horário do host (ex.: America/Sao_Paulo).
  static Future<String?> timezone() async {
    try {
      final f = File('/etc/timezone');
      if (await f.exists()) {
        final tz = (await f.readAsString()).trim();
        if (tz.isNotEmpty) return tz;
      }
      final link = await Link('/etc/localtime').target();
      final i = link.indexOf('zoneinfo/');
      if (i >= 0) return link.substring(i + 9);
    } catch (_) {}
    return null;
  }

  /// Idioma do host no formato BCP-47 aceito pelo Android (ex.: pt-BR).
  static String? locale() {
    final env = Platform.environment;
    final raw = env['LC_ALL']?.isNotEmpty == true
        ? env['LC_ALL']!
        : (env['LANG']?.isNotEmpty == true ? env['LANG']! : '');
    final m = RegExp(r'^([a-z]{2,3})(?:_([A-Z]{2}))?').firstMatch(raw);
    if (m == null || m.group(1) == 'C') return null;
    return m.group(2) == null ? m.group(1) : '${m.group(1)}-${m.group(2)}';
  }
}
