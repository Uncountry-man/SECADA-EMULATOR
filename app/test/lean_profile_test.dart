import 'package:secada/src/android/lean_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nunca remove componentes essenciais do Android', () {
    const essential = [
      'android',
      'com.android.systemui',
      'com.android.settings',
      'com.android.launcher3',
      'com.android.phone',
      'com.android.shell',
      'com.google.android.packageinstaller',
      'com.google.android.webview',
      'com.android.inputmethod.latin',
      'com.android.providers.settings',
      'com.android.providers.media',
      'com.android.providers.downloads',
      'com.android.providers.contacts',
      'com.android.providers.telephony',
      'com.android.documentsui',
      'com.android.externalstorage',
      'com.android.defcontainer',
      'com.android.keychain',
      'com.android.certinstaller',
      'com.google.android.ext.services',
      'com.google.android.ext.shared',
    ];
    for (final p in essential) {
      expect(LeanProfile.packages, isNot(contains(p)), reason: p);
    }
  });

  test('remove a pilha Google e a telemetria', () {
    expect(LeanProfile.packages, containsAll(<String>[
      'com.google.android.gms',
      'com.android.vending',
      'com.google.android.googlequicksearchbox',
      'org.android_x86.analytics',
    ]));
    expect(LeanProfile.packages.toSet().length, LeanProfile.packages.length);
  });
}
