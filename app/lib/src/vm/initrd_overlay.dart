import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';

/// Arquivo extra para o initramfs.
class OverlayFile {
  const OverlayFile(this.path, this.content, {this.mode = 0x1ed /* 0755 */});
  final String path;
  final String content;
  final int mode;
}

/// Arquivo cpio "newc" (o formato do initramfs do Linux) com [files].
Uint8List buildNewcCpio(List<OverlayFile> files) {
  final out = BytesBuilder();
  var ino = 1;
  void pad() {
    while (out.length % 4 != 0) {
      out.addByte(0);
    }
  }

  void entry(String name, int mode, List<int> data) {
    final nameBytes = utf8.encode(name);
    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    final header = StringBuffer('070701')
      ..write(hex(ino++))
      ..write(hex(mode))
      ..write(hex(0)) // uid
      ..write(hex(0)) // gid
      ..write(hex(1)) // nlink
      ..write(hex(0)) // mtime
      ..write(hex(data.length))
      ..write(hex(0)) // devmajor
      ..write(hex(0)) // devminor
      ..write(hex(0)) // rdevmajor
      ..write(hex(0)) // rdevminor
      ..write(hex(nameBytes.length + 1))
      ..write(hex(0)); // check
    out
      ..add(ascii.encode(header.toString()))
      ..add(nameBytes)
      ..addByte(0);
    pad();
    out.add(data);
    pad();
  }

  final dirs = <String>{};
  for (final f in files) {
    var d = p.posix.dirname(f.path);
    final chain = <String>[];
    while (d != '.' && d != '/' && dirs.add(d)) {
      chain.insert(0, d);
      d = p.posix.dirname(d);
    }
    for (final dir in chain) {
      entry(dir, 0x41ed /* dir 0755 */, const []);
    }
    entry(f.path, 0x8000 | f.mode, utf8.encode(f.content));
  }
  entry('TRAILER!!!', 0, const []);
  return out.toBytes();
}

/// Ajustes do SECADA Emulator aplicados pelo initrd do Android-x86 antes do boot.
///
/// O initrd da ISO executa (com `source`) todo arquivo em `/scripts/`, já
/// dentro de `/android`, a raiz do Android num tmpfs gravável. O Linux aceita
/// vários arquivos cpio concatenados no initramfs; então o SECADA Emulator anexa um cpio
/// pequeno ao initrd original, sem alterar a ISO.
abstract final class InitrdOverlay {
  /// Tradução ARM 64 bits (houdini64, ver `Arm64Translation`):
  ///
  /// * ABIs: `default.prop` é lido antes do `build.prop` e, no Android 9,
  ///   uma propriedade `ro.*` vale pela primeira definição. Assim
  ///   `arm64-v8a` entra nas ABIs suportadas (o PackageManager instala a
  ///   versão ARM64 dos apps, a mesma de um celular).
  /// * Serviço `nativebridge64`: o `enable_nativebridge` do Android-x86 já
  ///   aceita o argumento `64` (monta `houdini9_z.sfs` em
  ///   `/system/lib64/arm64` e registra os executáveis ARM64), mas nenhum
  ///   serviço o chama. Roda depois do de 32 bits para não disputarem o
  ///   `binfmt_misc`.
  static const arm64Script = r'''
# SECADA Emulator: tradução ARM 64 bits.
cat >> /android/default.prop <<'SECADA'
ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
ro.product.cpu.abilist64=x86_64,arm64-v8a
ro.vendor.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
ro.vendor.product.cpu.abilist64=x86_64,arm64-v8a
SECADA
for rc in /android/init.android_x86_64.rc /android/init.android_x86.rc; do
  [ -e $rc ] || continue
  cat >> $rc <<'SECADA'

service nativebridge64 /system/bin/enable_nativebridge 64
    class main
    disabled
    oneshot
    seclabel u:r:zygote:s0

on property:persist.sys.nativebridge=1 && property:init.svc.nativebridge=stopped
    start nativebridge64
SECADA
  break
done
''';

  static List<OverlayFile> files({required bool arm64}) => [
        if (arm64) const OverlayFile('scripts/99-secada-arm64', arm64Script),
      ];

  /// Initrd a usar no boot: o original quando não há ajustes; senão uma
  /// cópia com o cpio do SECADA Emulator (gzip) anexado. São ~3 MB, regravados a cada
  /// boot para refletir a configuração atual.
  static Future<String> prepare(String originalInitrd, {required bool arm64}) async {
    final overlay = files(arm64: arm64);
    if (overlay.isEmpty) return originalInitrd;
    final target = p.join(p.dirname(originalInitrd), 'initrd-secada.img');
    log.info('Initrd com ajustes do SECADA Emulator: ${overlay.map((f) => f.path).join(', ')}');
    final original = File(originalInitrd);
    final origLen = await original.length();
    final sink = File(target).openWrite();
    await sink.addStream(original.openRead());
    // Zeros entre os arquivos do initramfs são ignorados pelo kernel; o
    // alinhamento a 4 bytes evita depender disso.
    sink.add(Uint8List(((origLen + 3) & ~3) - origLen));
    sink.add(gzip.encode(buildNewcCpio(overlay)));
    await sink.close();
    return target;
  }
}
