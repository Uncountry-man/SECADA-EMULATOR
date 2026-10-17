import 'dart:io';
import 'dart:typed_data';

/// Entrada do diretório raiz de uma imagem ISO 9660.
class IsoEntry {
  IsoEntry(this.name, this.lba, this.size, this.isDirectory);
  final String name; // normalizado: minúsculas, sem ";1" nem ponto final
  final int lba;
  final int size;
  final bool isDirectory;
}

/// Leitor mínimo de ISO 9660 — suficiente para listar a raiz e extrair o
/// kernel e o initrd do Android-x86 sem depender de 7z/xorriso no host.
class Iso9660 {
  Iso9660._(this._file, this.volumeId, this.root);

  static const int sectorSize = 2048;
  final RandomAccessFile _file;
  final String volumeId;
  final List<IsoEntry> root;

  static Future<Iso9660> open(String path) async {
    final raf = await File(path).open();
    try {
      // Procura o Primary Volume Descriptor a partir do setor 16.
      for (var sector = 16; sector < 32; sector++) {
        await raf.setPosition(sector * sectorSize);
        final d = await raf.read(sectorSize);
        if (d.length < sectorSize) break;
        final type = d[0];
        final ident = String.fromCharCodes(d.sublist(1, 6));
        if (ident != 'CD001') break;
        if (type == 255) break;
        if (type != 1) continue;
        final volumeId = String.fromCharCodes(d.sublist(40, 72)).trim();
        final rootRecord = ByteData.sublistView(d, 156, 156 + 34);
        final rootLba = rootRecord.getUint32(2, Endian.little);
        final rootSize = rootRecord.getUint32(10, Endian.little);
        final entries = await _readDirectory(raf, rootLba, rootSize);
        return Iso9660._(raf, volumeId, entries);
      }
    } catch (_) {
      await raf.close();
      rethrow;
    }
    await raf.close();
    throw const FormatException('Arquivo não é uma imagem ISO 9660 válida.');
  }

  static Future<List<IsoEntry>> _readDirectory(
      RandomAccessFile raf, int lba, int size) async {
    await raf.setPosition(lba * sectorSize);
    final data = await raf.read(size);
    final entries = <IsoEntry>[];
    var pos = 0;
    while (pos < data.length) {
      final len = data[pos];
      if (len == 0) {
        // Registros não cruzam setores: pula para o próximo setor.
        pos = ((pos ~/ sectorSize) + 1) * sectorSize;
        continue;
      }
      if (pos + len > data.length) break;
      final rec = ByteData.sublistView(data, pos, pos + len);
      final extent = rec.getUint32(2, Endian.little);
      final fileSize = rec.getUint32(10, Endian.little);
      final flags = data[pos + 25];
      final nameLen = data[pos + 32];
      final rawName = data.sublist(pos + 33, pos + 33 + nameLen);
      if (!(nameLen == 1 && (rawName[0] == 0 || rawName[0] == 1))) {
        var name = String.fromCharCodes(rawName).toLowerCase();
        final semi = name.indexOf(';');
        if (semi >= 0) name = name.substring(0, semi);
        if (name.endsWith('.')) name = name.substring(0, name.length - 1);
        entries.add(IsoEntry(name, extent, fileSize, (flags & 2) != 0));
      }
      pos += len;
    }
    return entries;
  }

  IsoEntry? find(String name) {
    final n = name.toLowerCase();
    for (final e in root) {
      if (e.name == n) return e;
    }
    return null;
  }

  Future<void> extract(IsoEntry entry, String destination) async {
    final out = await File(destination).open(mode: FileMode.write);
    try {
      var remaining = entry.size;
      await _file.setPosition(entry.lba * sectorSize);
      const chunk = 1 << 20;
      while (remaining > 0) {
        final bytes = await _file.read(remaining < chunk ? remaining : chunk);
        if (bytes.isEmpty) throw const FileSystemException('ISO truncada');
        await out.writeFrom(bytes);
        remaining -= bytes.length;
      }
    } finally {
      await out.close();
    }
  }

  Future<void> close() => _file.close();
}
