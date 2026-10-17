import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ZipFormatError implements Exception {
  ZipFormatError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Entrada do diretório central de um ZIP.
class ZipEntry {
  ZipEntry(this.name, this.method, this.compressedSize, this.size, this.localOffset,
      {this.encrypted = false});
  final String name;
  final int method;
  final int compressedSize;

  /// Tamanho descompactado.
  final int size;
  final int localOffset;
  final bool encrypted;

  bool get isDirectory => name.endsWith('/');
}

/// Leitor de ZIP sem dependências: diretório central (com ZIP64) e leitura de
/// entradas em fluxo, descompactando em blocos. Serve para XAPK, cujos
/// arquivos OBB têm gigabytes e não podem ser carregados na memória.
class ZipReader {
  ZipReader._(this.path, this._raf, this.entries);

  final String path;
  final RandomAccessFile _raf;
  final Map<String, ZipEntry> entries;

  static Future<ZipReader> open(String path) async {
    final file = File(path);
    if (!await file.exists()) throw ZipFormatError('Arquivo não encontrado.');
    final raf = await file.open();
    try {
      return ZipReader._(path, raf, await _readCentralDirectory(raf));
    } catch (e) {
      await raf.close();
      if (e is ZipFormatError) rethrow;
      if (e is FormatException || e is RangeError) {
        throw ZipFormatError('O arquivo não é um ZIP válido.');
      }
      rethrow;
    }
  }

  Future<void> close() => _raf.close();

  ZipEntry? operator [](String name) => entries[name];

  static int _u64(ByteData d, int o) =>
      d.getUint32(o, Endian.little) | (d.getUint32(o + 4, Endian.little) << 32);

  static Future<Map<String, ZipEntry>> _readCentralDirectory(RandomAccessFile raf) async {
    final size = await raf.length();
    if (size < 22) throw ZipFormatError('O arquivo não é um ZIP válido.');
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
    if (eocd < 0) throw ZipFormatError('O arquivo não é um ZIP válido (fim do diretório ausente).');
    final bd = ByteData.sublistView(tail);
    var count = bd.getUint16(eocd + 10, Endian.little);
    var cdSize = bd.getUint32(eocd + 12, Endian.little);
    var cdOffset = bd.getUint32(eocd + 16, Endian.little);

    if (count == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff) {
      // ZIP64: o localizador fica logo antes do EOCD e aponta para o registro.
      final loc = eocd - 20;
      if (loc < 0 || bd.getUint32(loc, Endian.little) != 0x07064b50) {
        throw ZipFormatError('ZIP64 malformado.');
      }
      final rec = _u64(bd, loc + 8);
      await raf.setPosition(rec);
      final h = await raf.read(56);
      final hb = ByteData.sublistView(h);
      if (hb.getUint32(0, Endian.little) != 0x06064b50) {
        throw ZipFormatError('ZIP64 malformado.');
      }
      count = _u64(hb, 32);
      cdSize = _u64(hb, 40);
      cdOffset = _u64(hb, 48);
    }

    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);
    final cbd = ByteData.sublistView(cd);
    final result = <String, ZipEntry>{};
    var pos = 0;
    for (var i = 0; i < count && pos + 46 <= cd.length; i++) {
      if (cbd.getUint32(pos, Endian.little) != 0x02014b50) break;
      final flags = cbd.getUint16(pos + 8, Endian.little);
      final method = cbd.getUint16(pos + 10, Endian.little);
      var compSize = cbd.getUint32(pos + 20, Endian.little);
      var size = cbd.getUint32(pos + 24, Endian.little);
      final nameLen = cbd.getUint16(pos + 28, Endian.little);
      final extraLen = cbd.getUint16(pos + 30, Endian.little);
      final commentLen = cbd.getUint16(pos + 32, Endian.little);
      var localOffset = cbd.getUint32(pos + 42, Endian.little);
      final nameStart = pos + 46;
      final name = utf8.decode(cd.sublist(nameStart, nameStart + nameLen), allowMalformed: true);

      // Campo extra ZIP64 (0x0001): só traz os valores que valem 0xFFFFFFFF.
      var ex = nameStart + nameLen;
      final exEnd = ex + extraLen;
      while (ex + 4 <= exEnd) {
        final id = cbd.getUint16(ex, Endian.little);
        final len = cbd.getUint16(ex + 2, Endian.little);
        if (id == 0x0001) {
          var o = ex + 4;
          if (size == 0xffffffff && o + 8 <= exEnd) {
            size = _u64(cbd, o);
            o += 8;
          }
          if (compSize == 0xffffffff && o + 8 <= exEnd) {
            compSize = _u64(cbd, o);
            o += 8;
          }
          if (localOffset == 0xffffffff && o + 8 <= exEnd) {
            localOffset = _u64(cbd, o);
          }
        }
        ex += 4 + len;
      }
      result[name] = ZipEntry(name, method, compSize, size, localOffset,
          encrypted: flags & 1 != 0);
      pos += 46 + nameLen + extraLen + commentLen;
    }
    return result;
  }

  /// Posição do primeiro byte de dados da entrada.
  Future<int> _dataStart(ZipEntry e) async {
    await _raf.setPosition(e.localOffset);
    final header = await _raf.read(30);
    final hb = ByteData.sublistView(header);
    if (header.length < 30 || hb.getUint32(0, Endian.little) != 0x04034b50) {
      throw ZipFormatError('Cabeçalho local do ZIP inválido em "${e.name}".');
    }
    final nameLen = hb.getUint16(26, Endian.little);
    final extraLen = hb.getUint16(28, Endian.little);
    return e.localOffset + 30 + nameLen + extraLen;
  }

  /// Conteúdo descompactado da entrada, em blocos.
  Stream<List<int>> openRead(ZipEntry e, {int chunkSize = 256 * 1024}) async* {
    if (e.encrypted) throw ZipFormatError('"${e.name}" está protegido por senha.');
    if (e.method != 0 && e.method != 8) {
      throw ZipFormatError('Compressão ZIP ${e.method} não suportada em "${e.name}".');
    }
    var pos = await _dataStart(e);
    var left = e.compressedSize;
    if (e.method == 0) {
      while (left > 0) {
        await _raf.setPosition(pos);
        final chunk = await _raf.read(left < chunkSize ? left : chunkSize);
        if (chunk.isEmpty) throw ZipFormatError('ZIP truncado em "${e.name}".');
        pos += chunk.length;
        left -= chunk.length;
        yield chunk;
      }
      return;
    }
    // Deflate: cada bloco lido alimenta o descompactador em modo "chunked".
    final out = <List<int>>[];
    final sink = _ListSink(out);
    final conv = ZLibDecoder(raw: true).startChunkedConversion(sink);
    try {
      while (left > 0) {
        await _raf.setPosition(pos);
        final chunk = await _raf.read(left < chunkSize ? left : chunkSize);
        if (chunk.isEmpty) throw ZipFormatError('ZIP truncado em "${e.name}".');
        pos += chunk.length;
        left -= chunk.length;
        conv.add(chunk);
        while (out.isNotEmpty) {
          yield out.removeAt(0);
        }
      }
      conv.close();
      while (out.isNotEmpty) {
        yield out.removeAt(0);
      }
    } on FormatException {
      throw ZipFormatError('Dados corrompidos em "${e.name}".');
    }
  }

  /// Lê a entrada inteira (apenas para arquivos pequenos, como manifestos).
  Future<Uint8List> readAll(ZipEntry e) async {
    final b = BytesBuilder(copy: false);
    await for (final c in openRead(e)) {
      b.add(c);
    }
    return b.takeBytes();
  }

  /// Grava a entrada em [dest] e devolve o tamanho gravado.
  Future<int> extractTo(ZipEntry e, String dest, {void Function(int bytes)? onBytes}) async {
    final out = File(dest).openWrite();
    var total = 0;
    try {
      await for (final c in openRead(e)) {
        out.add(c);
        total += c.length;
        onBytes?.call(c.length);
      }
    } finally {
      await out.close();
    }
    return total;
  }
}

class _ListSink implements Sink<List<int>> {
  _ListSink(this._list);
  final List<List<int>> _list;
  @override
  void add(List<int> data) => _list.add(data);
  @override
  void close() {}
}
