import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Informações extraídas de um APK sem ferramentas externas (aapt).
class ApkInfo {
  ApkInfo({
    required this.path,
    required this.size,
    required this.packageName,
    required this.versionName,
    required this.minSdk,
    required this.nativeAbis,
  });

  final String path;
  final int size;
  final String packageName;
  final String? versionName;
  final int? minSdk;

  /// ABIs com bibliotecas nativas em `lib/<abi>/`. Vazio = só código Java/Kotlin.
  final Set<String> nativeAbis;

  bool get hasX86Code =>
      nativeAbis.contains('x86_64') || nativeAbis.contains('x86');

  /// O Android-x86 deste projeto não inclui tradução ARM (native bridge).
  bool get armOnly => nativeAbis.isNotEmpty && !hasX86Code;
}

/// Decide se as bibliotecas nativas de um app rodam no Android-x86 do SECADA Emulator.
///
/// Código x86/x86_64 (ou nenhum código nativo) roda direto. Código ARM roda
/// pela tradução ARM (libhoudini, "native bridge" do Android-x86): ARM 32
/// bits (`armeabi-v7a`/`armeabi`) sempre, ARM64 (`arm64-v8a`) quando o
/// tradutor de 64 bits está disponível ([arm64]). Com os dois, o Android
/// instala a versão ARM64, a mesma que um celular atual usa.
abstract final class AbiPolicy {
  static bool hasX86(Set<String> abis) => abis.contains('x86_64') || abis.contains('x86');
  static bool hasArm32(Set<String> abis) =>
      abis.contains('armeabi-v7a') || abis.contains('armeabi');
  static bool hasArm64(Set<String> abis) => abis.contains('arm64-v8a');

  /// Precisa da tradução ARM para rodar.
  static bool needsTranslation(Set<String> abis) => abis.isNotEmpty && !hasX86(abis);

  /// Mensagem de recusa, ou null se o app pode ser instalado.
  static String? rejection(Set<String> abis,
      {required bool armTranslation, bool arm64 = false, String what = 'O APK'}) {
    if (abis.isEmpty || hasX86(abis)) return null;
    final list = abis.join(', ');
    if (hasArm32(abis) || hasArm64(abis)) {
      if (!armTranslation) {
        return '$what contém apenas código nativo ARM ($list). Ative "Tradução ARM" '
            'nas configurações do SECADA Emulator para instalar e rodar apps só ARM.';
      }
      if (hasArm32(abis) || arm64) return null;
      return '$what contém apenas código ARM64 ($list) e o tradutor ARM 64 bits '
          '(houdini9_z.sfs) não está instalado; a tradução ARM desta VM cobre só '
          'ARM 32 bits (armeabi-v7a).';
    }
    return 'Incompatível: $what usa arquiteturas não suportadas ($list).';
  }
}

class ApkFormatError implements Exception {
  ApkFormatError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ApkInspector {
  static Future<ApkInfo> inspect(String path) async {
    final file = File(path);
    if (!await file.exists()) throw ApkFormatError('Arquivo não encontrado.');
    final raf = await file.open();
    try {
      final size = await raf.length();
      final entries = await _readCentralDirectory(raf, size);
      final abis = <String>{};
      for (final e in entries.keys) {
        final m = RegExp(r'^lib/([^/]+)/[^/]+\.so$').firstMatch(e);
        if (m != null) abis.add(m.group(1)!);
      }
      final manifestEntry = entries['AndroidManifest.xml'];
      if (manifestEntry == null) {
        throw ApkFormatError('APK inválido: AndroidManifest.xml ausente.');
      }
      final manifest = await _readEntry(raf, manifestEntry);
      final axml = _AxmlManifest.parse(manifest);
      if (axml.packageName == null || axml.packageName!.isEmpty) {
        throw ApkFormatError('APK inválido: nome do pacote não encontrado.');
      }
      return ApkInfo(
        path: path,
        size: size,
        packageName: axml.packageName!,
        versionName: axml.versionName,
        minSdk: axml.minSdk,
        nativeAbis: abis,
      );
    } on ApkFormatError {
      rethrow;
    } on FormatException catch (e) {
      throw ApkFormatError('O arquivo não é um APK válido (${e.message}).');
    } on RangeError {
      throw ApkFormatError('O arquivo não é um APK válido (estrutura corrompida).');
    } finally {
      await raf.close();
    }
  }

  static Future<Map<String, _ZipEntry>> _readCentralDirectory(
      RandomAccessFile raf, int size) async {
    final tailLen = size < 66000 ? size : 66000;
    await raf.setPosition(size - tailLen);
    final tail = await raf.read(tailLen);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 5 && tail[i + 3] == 6) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('fim do diretório ZIP não encontrado');
    final bd = ByteData.sublistView(tail);
    final count = bd.getUint16(eocd + 10, Endian.little);
    final cdSize = bd.getUint32(eocd + 12, Endian.little);
    final cdOffset = bd.getUint32(eocd + 16, Endian.little);
    if (cdOffset == 0xffffffff) throw const FormatException('ZIP64 não suportado');
    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);
    final cbd = ByteData.sublistView(cd);
    final result = <String, _ZipEntry>{};
    var pos = 0;
    for (var i = 0; i < count && pos + 46 <= cd.length; i++) {
      if (cbd.getUint32(pos, Endian.little) != 0x02014b50) break;
      final method = cbd.getUint16(pos + 10, Endian.little);
      final compSize = cbd.getUint32(pos + 20, Endian.little);
      final nameLen = cbd.getUint16(pos + 28, Endian.little);
      final extraLen = cbd.getUint16(pos + 30, Endian.little);
      final commentLen = cbd.getUint16(pos + 32, Endian.little);
      final localOffset = cbd.getUint32(pos + 42, Endian.little);
      final name = utf8.decode(cd.sublist(pos + 46, pos + 46 + nameLen),
          allowMalformed: true);
      result[name] = _ZipEntry(method, compSize, localOffset);
      pos += 46 + nameLen + extraLen + commentLen;
    }
    return result;
  }

  static Future<Uint8List> _readEntry(RandomAccessFile raf, _ZipEntry e) async {
    await raf.setPosition(e.localOffset);
    final header = await raf.read(30);
    final hb = ByteData.sublistView(header);
    if (hb.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('cabeçalho local ZIP inválido');
    }
    final nameLen = hb.getUint16(26, Endian.little);
    final extraLen = hb.getUint16(28, Endian.little);
    await raf.setPosition(e.localOffset + 30 + nameLen + extraLen);
    final data = await raf.read(e.compressedSize);
    switch (e.method) {
      case 0:
        return data;
      case 8:
        return Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
      default:
        throw FormatException('compressão ZIP ${e.method} não suportada');
    }
  }
}

class _ZipEntry {
  _ZipEntry(this.method, this.compressedSize, this.localOffset);
  final int method;
  final int compressedSize;
  final int localOffset;
}

/// Parser do XML binário (AXML) do Android, só o necessário para o manifesto.
class _AxmlManifest {
  String? packageName;
  String? versionName;
  int? minSdk;

  static const _attrMinSdk = 0x0101020c;
  static const _attrVersionName = 0x0101021c;

  static _AxmlManifest parse(Uint8List data) {
    final m = _AxmlManifest();
    final bd = ByteData.sublistView(data);
    if (data.length < 8 || bd.getUint16(0, Endian.little) != 0x0003) {
      throw const FormatException('manifesto binário inválido');
    }
    var strings = <String>[];
    var resIds = <int>[];
    var pos = bd.getUint16(2, Endian.little);
    while (pos + 8 <= data.length) {
      final type = bd.getUint16(pos, Endian.little);
      final headerSize = bd.getUint16(pos + 2, Endian.little);
      final size = bd.getUint32(pos + 4, Endian.little);
      if (size < 8 || pos + size > data.length) break;
      if (type == 0x0001) {
        strings = _readStringPool(bd, data, pos);
      } else if (type == 0x0180) {
        final n = (size - headerSize) ~/ 4;
        resIds = [
          for (var i = 0; i < n; i++)
            bd.getUint32(pos + headerSize + i * 4, Endian.little)
        ];
      } else if (type == 0x0102) {
        final nameIdx = bd.getUint32(pos + 20, Endian.little);
        final attrStart = bd.getUint16(pos + 24, Endian.little);
        final attrSize = bd.getUint16(pos + 26, Endian.little);
        final attrCount = bd.getUint16(pos + 28, Endian.little);
        final tag = nameIdx < strings.length ? strings[nameIdx] : '';
        for (var i = 0; i < attrCount; i++) {
          final a = pos + 16 + attrStart + i * attrSize;
          final an = bd.getUint32(a + 4, Endian.little);
          final raw = bd.getUint32(a + 8, Endian.little);
          final dataType = data[a + 15];
          final value = bd.getUint32(a + 16, Endian.little);
          final attrName = an < strings.length ? strings[an] : '';
          final resId = an < resIds.length ? resIds[an] : 0;
          String? str() => raw != 0xffffffff && raw < strings.length
              ? strings[raw]
              : (dataType == 0x03 && value < strings.length ? strings[value] : null);
          if (tag == 'manifest') {
            if (attrName == 'package') m.packageName = str();
            if (attrName == 'versionName' || resId == _attrVersionName) {
              m.versionName = str() ?? m.versionName;
            }
          } else if (tag == 'uses-sdk' &&
              (attrName == 'minSdkVersion' || resId == _attrMinSdk)) {
            if (dataType >= 0x10 && dataType <= 0x1f) {
              m.minSdk = value;
            } else {
              final s = str();
              // Codinomes de prévia ("Q", "R"...) = SDK acima do suportado.
              m.minSdk = int.tryParse(s ?? '') ?? (s != null ? 10000 : null);
            }
          }
        }
      }
      pos += size;
    }
    return m;
  }

  static List<String> _readStringPool(ByteData bd, Uint8List data, int start) {
    final count = bd.getUint32(start + 8, Endian.little);
    final flags = bd.getUint32(start + 16, Endian.little);
    final stringsStart = bd.getUint32(start + 20, Endian.little);
    final headerSize = bd.getUint16(start + 2, Endian.little);
    final utf8Pool = (flags & 0x100) != 0;
    final out = <String>[];
    for (var i = 0; i < count; i++) {
      final off = bd.getUint32(start + headerSize + i * 4, Endian.little);
      var p = start + stringsStart + off;
      if (utf8Pool) {
        // comprimento UTF-16 (ignorado) e comprimento em bytes UTF-8
        p += (data[p] & 0x80 != 0) ? 2 : 1;
        var len = data[p];
        if (len & 0x80 != 0) {
          len = ((len & 0x7f) << 8) | data[p + 1];
          p += 2;
        } else {
          p += 1;
        }
        out.add(utf8.decode(data.sublist(p, p + len), allowMalformed: true));
      } else {
        var len = bd.getUint16(p, Endian.little);
        if (len & 0x8000 != 0) {
          len = ((len & 0x7fff) << 16) | bd.getUint16(p + 2, Endian.little);
          p += 4;
        } else {
          p += 2;
        }
        final units = [for (var k = 0; k < len; k++) bd.getUint16(p + k * 2, Endian.little)];
        out.add(String.fromCharCodes(units));
      }
    }
    return out;
  }
}
