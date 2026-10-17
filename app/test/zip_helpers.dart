import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Gera um AndroidManifest.xml binário (AXML) mínimo:
/// `<manifest package=... versionName=...><uses-sdk minSdkVersion=N/></manifest>`
Uint8List buildAxml(String pkg, {String version = '1.0', int minSdk = 21}) {
  final strings = ['package', 'versionName', 'minSdkVersion', 'manifest', 'uses-sdk', pkg, version];
  int idx(String s) => strings.indexOf(s);

  // String pool UTF-16.
  final pool = BytesBuilder();
  final offsets = <int>[];
  final data = BytesBuilder();
  for (final s in strings) {
    offsets.add(data.length);
    final b = ByteData(2)..setUint16(0, s.length, Endian.little);
    data.add(b.buffer.asUint8List());
    for (final c in s.codeUnits) {
      data.add((ByteData(2)..setUint16(0, c, Endian.little)).buffer.asUint8List());
    }
    data.add([0, 0]);
  }
  while (data.length % 4 != 0) {
    data.addByte(0);
  }
  const headerSize = 28;
  final stringsStart = headerSize + offsets.length * 4;
  final poolSize = stringsStart + data.length;
  final ph = ByteData(headerSize)
    ..setUint16(0, 0x0001, Endian.little)
    ..setUint16(2, headerSize, Endian.little)
    ..setUint32(4, poolSize, Endian.little)
    ..setUint32(8, strings.length, Endian.little)
    ..setUint32(12, 0, Endian.little)
    ..setUint32(16, 0, Endian.little) // UTF-16
    ..setUint32(20, stringsStart, Endian.little)
    ..setUint32(24, 0, Endian.little);
  pool.add(ph.buffer.asUint8List());
  for (final o in offsets) {
    pool.add((ByteData(4)..setUint32(0, o, Endian.little)).buffer.asUint8List());
  }
  pool.add(data.toBytes());

  Uint8List startTag(String name, List<(String, int, int, int)> attrs) {
    // attrs: (nome, rawValueIdx, dataType, data)
    final size = 36 + attrs.length * 20;
    final b = ByteData(size)
      ..setUint16(0, 0x0102, Endian.little)
      ..setUint16(2, 16, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, 1, Endian.little)
      ..setUint32(12, 0xffffffff, Endian.little)
      ..setUint32(16, 0xffffffff, Endian.little)
      ..setUint32(20, idx(name), Endian.little)
      ..setUint16(24, 20, Endian.little)
      ..setUint16(26, 20, Endian.little)
      ..setUint16(28, attrs.length, Endian.little);
    for (var i = 0; i < attrs.length; i++) {
      final a = 36 + i * 20;
      final (n, raw, type, value) = attrs[i];
      b
        ..setUint32(a, 0xffffffff, Endian.little)
        ..setUint32(a + 4, idx(n), Endian.little)
        ..setUint32(a + 8, raw, Endian.little)
        ..setUint16(a + 12, 8, Endian.little)
        ..setUint8(a + 14, 0)
        ..setUint8(a + 15, type)
        ..setUint32(a + 16, value, Endian.little);
    }
    return b.buffer.asUint8List();
  }

  final body = BytesBuilder()
    ..add(pool.toBytes())
    ..add(startTag('manifest', [
      ('package', idx(pkg), 0x03, idx(pkg)),
      ('versionName', idx(version), 0x03, idx(version)),
    ]))
    ..add(startTag('uses-sdk', [('minSdkVersion', 0xffffffff, 0x10, minSdk)]));
  final total = 8 + body.length;
  final header = ByteData(8)
    ..setUint16(0, 0x0003, Endian.little)
    ..setUint16(2, 8, Endian.little)
    ..setUint32(4, total, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(body.toBytes()))
      .toBytes();
}

/// ZIP mínimo (entradas armazenadas ou deflate) — suficiente para o inspetor.
Uint8List buildZip(Map<String, List<int>> files, {Set<String> stored = const {}}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final isStored = stored.contains(e.key);
    final method = isStored ? 0 : 8;
    final deflated = isStored ? e.value : ZLibEncoder(raw: true).convert(e.value);
    final offset = out.length;
    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint32(18, deflated.length, Endian.little)
      ..setUint32(22, e.value.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(lh.buffer.asUint8List())
      ..add(name)
      ..add(deflated);
    final ch = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint32(20, deflated.length, Endian.little)
      ..setUint32(24, e.value.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(ch.buffer.asUint8List())
      ..add(name);
    count++;
  }
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, cd.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.toBytes();
}

