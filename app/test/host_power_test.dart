import 'package:secada/src/host/host_power.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lê energia do host com valores válidos', () async {
    final p = await HostPower.read();
    expect(p.level, inInclusiveRange(0, 100));
    expect([2, 3, 4, 5], contains(p.status));
  });

  test('idioma do host vira BCP-47', () {
    final l = HostPower.locale();
    if (l != null) expect(l, matches(RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$')));
  });
}
