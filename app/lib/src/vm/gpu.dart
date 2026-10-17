import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import 'qemu_locator.dart';

/// Nó de renderização DRM do host (`/dev/dri/renderD*`).
class RenderNode {
  const RenderNode(this.path, this.driver, {required this.accessible});
  final String path;

  /// Driver do kernel (amdgpu, i915, xe, nouveau, nvidia...).
  final String driver;
  final bool accessible;

  @override
  String toString() => '$path ($driver)';
}

/// GPU escolhida para o VirGL.
class GpuChoice {
  const GpuChoice(this.node);
  final RenderNode node;
}

/// Seleção da GPU do host para o modo VirGL, em qualquer distribuição.
///
/// 1. Lista os nós `/dev/dri/renderD*` com o driver de cada um.
/// 2. Ordena: drivers Mesa primeiro (amdgpu, i915/xe, radeon, nouveau,
///    virtio_gpu, vmwgfx...), NVIDIA proprietário por último (só funciona com
///    GBM, driver 495+ e `nvidia-drm.modeset=1`) e ignora o vgem (sem GPU).
/// 3. Testa cada nó acessível com uma sonda do próprio QEMU (sobe só a placa
///    `virtio-vga-gl` com o display D-Bus/GL, sem convidado, e sai por QMP;
///    leva ~0,1 s). O primeiro que passar é usado.
///
/// Se nenhum passar, [select] devolve null e [lastError] explica o motivo; o
/// SECADA Emulator então cai para a renderização por software.
abstract final class Gpu {
  static String lastError = '';

  static const _mesaDrivers = [
    'amdgpu', 'i915', 'xe', 'radeon', 'nouveau', 'virtio_gpu', 'virtio-pci',
    'vmwgfx', 'panfrost', 'lima', 'v3d', 'msm', 'etnaviv', 'qxl',
  ];

  static Future<List<RenderNode>> renderNodes() async {
    final dir = Directory('/dev/dri');
    if (!await dir.exists()) return const [];
    final nodes = <RenderNode>[];
    await for (final e in dir.list()) {
      final name = p.basename(e.path);
      if (!name.startsWith('renderD')) continue;
      var driver = 'desconhecido';
      try {
        driver = p.basename(
            await Link('/sys/class/drm/$name/device/driver').resolveSymbolicLinks());
      } catch (_) {}
      if (driver == 'vgem') continue;
      nodes.add(RenderNode(e.path, driver, accessible: await _canOpen(e.path)));
    }
    int rank(RenderNode n) {
      final i = _mesaDrivers.indexOf(n.driver);
      if (i >= 0) return i;
      return n.driver.startsWith('nvidia') ? 1000 : 500;
    }

    nodes.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.path.compareTo(b.path);
    });
    return nodes;
  }

  // Só leitura: o modo de escrita do Dart tenta posicionar no fim do arquivo,
  // o que falha em dispositivos. A permissão de escrita é validada pela sonda.
  static Future<bool> _canOpen(String path) async {
    try {
      final f = await File(path).open();
      await f.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Escolhe a GPU para o VirGL ou devolve null (ver [lastError]).
  static Future<GpuChoice?> select(QemuInstall qemu) async {
    final nodes = await renderNodes();
    if (nodes.isEmpty) {
      lastError = 'nenhuma GPU com nó de renderização (/dev/dri/renderD*) '
          'encontrada';
      return null;
    }
    final usable = nodes.where((n) => n.accessible).toList();
    if (usable.isEmpty) {
      lastError = 'sem permissão em ${nodes.map((n) => n.path).join(', ')}: '
          'adicione o usuário ao grupo "render" (sudo usermod -aG render '
          '\$USER) e reabra a sessão';
      return null;
    }
    final errors = <String>[];
    for (final n in usable) {
      final err = await probe(qemu, n.path);
      if (err == null) {
        log.info('GPU para VirGL: $n');
        return GpuChoice(n);
      }
      log.warn('GPU $n recusada pelo QEMU: $err');
      errors.add('$n: $err');
    }
    lastError = errors.join('; ');
    return null;
  }

  /// Sobe o QEMU só com a placa 3D e o display D-Bus com GL no nó [node].
  /// Retorna null se funcionou ou a mensagem de erro do QEMU.
  static Future<String?> probe(QemuInstall qemu, String node) async {
    try {
      final proc = await Process.start(
        qemu.binary,
        [
          for (final d in qemu.firmwareDirs) ...['-L', d],
          '-machine', 'pc,accel=tcg', '-m', '64', '-nodefaults', '-S',
          '-vga', 'none', '-device', 'virtio-vga-gl',
          '-display', 'dbus,p2p=yes,gl=on,rendernode=$node',
          '-qmp', 'stdio', '-monitor', 'none', '-serial', 'none',
          '-parallel', 'none',
        ],
        environment: qemu.env,
      );
      final err = proc.stderr.transform(utf8.decoder).join();
      final out = proc.stdout.transform(utf8.decoder).join();
      proc.stdin.write('{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n');
      await proc.stdin.close().catchError((_) {});
      final code = await proc.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
      await out;
      final msg = (await err).trim();
      if (code == 0) return null;
      if (code == -1) return 'tempo esgotado';
      return msg.isEmpty ? 'código $code' : msg.split('\n').last;
    } catch (e) {
      return '$e';
    }
  }
}
