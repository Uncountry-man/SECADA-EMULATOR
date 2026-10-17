import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/paths.dart';
import 'iso9660.dart';

/// Imagem Android-x86 validada e pronta para boot.
class AndroidImage {
  AndroidImage({
    required this.isoPath,
    required this.kernelPath,
    required this.initrdPath,
    required this.volumeId,
  });

  final String isoPath;
  final String kernelPath;
  final String initrdPath;
  final String volumeId;
}

class ImageError implements Exception {
  ImageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Localiza, valida e prepara a ISO do Android-x86.
///
/// A ISO é anexada à VM como CD-ROM somente leitura (o initrd do Android-x86
/// encontra `system.sfs` e `ramdisk.img` nela). O kernel e o initrd são
/// extraídos para o diretório da VM para que o QEMU possa passá-los com
/// `-kernel/-initrd` junto da linha de comando personalizada.
class AndroidImageManager {
  static const requiredFiles = ['kernel', 'initrd.img', 'ramdisk.img', 'system.sfs'];

  /// Procura uma ISO: caminho configurado, ou o primeiro `*.iso` (preferindo
  /// x86_64) em `~/.local/share/secada/images` e na pasta `images/` do pacote.
  static Future<String?> findIso(String configured) async {
    if (configured.isNotEmpty) {
      return await File(configured).exists() ? configured : null;
    }
    final dirs = [
      SecadaPaths.instance.imagesDir,
      p.join(SecadaPaths.bundleDir, 'images'),
    ];
    final found = <String>[];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!await dir.exists()) continue;
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.iso')) found.add(e.path);
      }
    }
    if (found.isEmpty) return null;
    found.sort((a, b) {
      final ax = a.contains('x86_64') ? 0 : 1;
      final bx = b.contains('x86_64') ? 0 : 1;
      return ax != bx ? ax - bx : a.compareTo(b);
    });
    return found.first;
  }

  /// Valida a ISO e extrai kernel/initrd para [vmDir]/boot (com cache).
  static Future<AndroidImage> prepare(String isoPath, String vmDir) async {
    final stat = await File(isoPath).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw ImageError('Imagem Android não encontrada: $isoPath');
    }
    final Iso9660 iso;
    try {
      iso = await Iso9660.open(isoPath);
    } catch (e) {
      throw ImageError('O arquivo não é uma ISO válida: $isoPath ($e)');
    }
    try {
      final missing = requiredFiles.where((f) => iso.find(f) == null).toList();
      if (missing.isNotEmpty) {
        throw ImageError('A ISO não parece ser do Android-x86 (faltando: '
            '${missing.join(', ')}). Use uma imagem Android-x86 64 bits.');
      }
      final kernel = iso.find('kernel')!;
      if (!await _isX86_64Kernel(isoPath, kernel)) {
        throw ImageError('O kernel da ISO não é x86-64. Use a variante '
            'android-x86_64.');
      }
      final bootDir = Directory(p.join(vmDir, 'boot'));
      await bootDir.create(recursive: true);
      final stampFile = File(p.join(bootDir.path, 'source.json'));
      final stamp = jsonEncode({
        'iso': isoPath,
        'size': stat.size,
        'mtime': stat.modified.millisecondsSinceEpoch,
      });
      final kernelPath = p.join(bootDir.path, 'kernel');
      final initrdPath = p.join(bootDir.path, 'initrd.img');
      final cached = await stampFile.exists() &&
          await stampFile.readAsString() == stamp &&
          await File(kernelPath).exists() &&
          await File(initrdPath).exists();
      if (!cached) {
        log.info('Extraindo kernel e initrd de $isoPath');
        await iso.extract(kernel, kernelPath);
        await iso.extract(iso.find('initrd.img')!, initrdPath);
        await stampFile.writeAsString(stamp);
      }
      return AndroidImage(
        isoPath: isoPath,
        kernelPath: kernelPath,
        initrdPath: initrdPath,
        volumeId: iso.volumeId,
      );
    } finally {
      await iso.close();
    }
  }

  /// Verifica o cabeçalho bzImage: flag XLF_KERNEL_64 (bit 0 de xloadflags,
  /// offset 0x236) indica kernel com ponto de entrada 64 bits.
  static Future<bool> _isX86_64Kernel(String isoPath, IsoEntry kernel) async {
    final raf = await File(isoPath).open();
    try {
      await raf.setPosition(kernel.lba * Iso9660.sectorSize);
      final h = await raf.read(0x240);
      if (h.length < 0x240) return false;
      final magic = String.fromCharCodes(h.sublist(0x202, 0x206));
      if (magic != 'HdrS') return false;
      final xloadflags = h[0x236] | (h[0x237] << 8);
      return (xloadflags & 1) != 0;
    } finally {
      await raf.close();
    }
  }
}
