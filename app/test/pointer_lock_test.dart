import 'package:flutter_test/flutter_test.dart';

import 'package:secada/src/android/pointer_lock_watcher.dart';

void main() {
  group('PointerLockWatcher', () {
    test('lê as linhas lock/unlock do logcat', () {
      expect(PointerLockWatcher.parseLine('lock'), isTrue);
      expect(PointerLockWatcher.parseLine('unlock\r'), isFalse);
      expect(PointerLockWatcher.parseLine('  lock  '), isTrue);
      expect(PointerLockWatcher.parseLine('lock 17'), isTrue);
      expect(PointerLockWatcher.parseLine('lock 18\r'), isTrue);
      expect(PointerLockWatcher.parseLine('locked out'), isNull);
      expect(PointerLockWatcher.parseLine('--------- beginning of main'), isNull);
      expect(PointerLockWatcher.parseLine(''), isNull);
    });

    test('lock mantido pelo batimento; unlock solta na hora', () {
      final w = PointerLockWatcher();
      final changes = <bool>[];
      w.onChanged = changes.add;
      final t0 = DateTime(2026, 10, 16, 12);
      w.feed('lock', t0);
      expect(w.locked, isTrue);
      w.feed('lock', t0.add(const Duration(seconds: 1)));
      w.tick(t0.add(const Duration(seconds: 3)));
      expect(w.locked, isTrue, reason: 'batimento recente mantém a trava');
      w.feed('unlock', t0.add(const Duration(seconds: 4)));
      expect(w.locked, isFalse);
      expect(changes, [true, false]);
    });

    test('sem batimento o estado volta a solto sozinho (nunca fica preso por engano)', () {
      final w = PointerLockWatcher();
      final t0 = DateTime(2026, 10, 16, 12);
      w.feed('lock', t0);
      w.tick(t0.add(const Duration(milliseconds: 3000)));
      expect(w.locked, isTrue);
      w.tick(t0.add(PointerLockWatcher.expiry + const Duration(milliseconds: 100)));
      expect(w.locked, isFalse);
      // o app volta e repete o aviso: trava de novo
      w.feed('lock', t0.add(const Duration(seconds: 10)));
      expect(w.locked, isTrue);
    });
  });
}
