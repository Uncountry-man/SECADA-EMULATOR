/// Perfil "Android enxuto": o que o SECADA Emulator remove da imagem Android-x86.
///
/// A partição de sistema é somente leitura (squashfs na ISO), então os pacotes
/// são removidos **para o usuário** (`pm uninstall -k --user 0`): deixam de
/// existir para o Android, não rodam e não ocupam memória, mas podem ser
/// restaurados (`cmd package install-existing`).
///
/// Mantido: framework, SystemUI, Configurações, Launcher3, instalador de
/// pacotes e permissões, provedores de conteúdo, teclado, WebView, telefonia
/// interna (com.android.phone), rede, armazenamento e seletor de arquivos.
/// Como o Chrome é removido, o WebView standalone (com.google.android.webview)
/// é habilitado e definido como provedor.
abstract final class LeanProfile {
  /// Removidos sempre, com ou sem o perfil enxuto: a VM não tem câmera, então
  /// esses apps só abrem uma tela preta.
  static const alwaysRemoved = <String>[
    'com.android.camera2',
    'net.sourceforge.opencamera',
  ];

  static const packages = <String>[
    // Pilha Google: não funciona sem atualização do Play Services e é o maior
    // consumidor de memória (~750 MB de PSS medidos).
    'com.google.android.gms',
    'com.google.android.gms.setup',
    'com.google.android.gsf',
    'com.google.android.gsf.login',
    'com.android.vending',
    'com.google.android.googlequicksearchbox',
    'com.google.android.gm',
    'com.google.android.setupwizard',
    'com.google.android.partnersetup',
    'com.google.android.onetimeinitializer',
    'com.google.android.feedback',
    'com.google.android.apps.restore',
    'com.google.android.backuptransport',
    'com.google.android.syncadapters.calendar',
    'com.google.android.syncadapters.contacts',
    'com.google.android.printservice.recommendation',
    // Telemetria do Android-x86 e modo desktop.
    'org.android_x86.analytics',
    'com.farmerbb.taskbar.androidx86',
    // Aplicativos de usuário pré-instalados.
    'com.android.chrome',
    'com.android.calculator2',
    'com.android.calendar',
    'com.android.contacts',
    'com.android.deskclock',
    'com.android.dialer',
    'com.android.gallery3d',
    'com.android.development',
    'com.android.egg',
    'com.android.emergency',
    'com.android.htmlviewer',
    'com.example.android.notepad',
    'com.example.android.rssreader',
    'com.termoneplus',
    'org.lineageos.eleven',
    'org.zeroxlab.util.tscal',
    'com.android.traceur',
    'com.android.dreams.basic',
    'com.android.wallpaper.livepicker',
    // Serviços sem hardware/uso numa VM (SMS, alertas de operadora, MTP,
    // impressão, MIDI Bluetooth, perfis de trabalho).
    'com.android.basicsmsreceiver',
    'com.android.cellbroadcastreceiver',
    'com.android.calllogbackup',
    'com.android.simappdialog',
    'com.android.carrierdefaultapp',
    'com.android.bluetoothmidiservice',
    'com.android.bookmarkprovider',
    'com.android.providers.partnerbookmarks',
    'com.android.printspooler',
    'com.android.bips',
    'com.android.managedprovisioning',
    'com.android.mtp',
  ];

  /// Cartões de sugestão das Configurações ("Proteger seu smartphone",
  /// "Configurar impressão digital"...), sem sentido num emulador.
  static const settingsSuggestions = <String>[
    r'com.android.settings/.Settings$NightDisplaySuggestionActivity',
    'com.android.settings/.fingerprint.FingerprintEnrollSuggestionActivity',
    'com.android.settings/.fingerprint.FingerprintSuggestionActivity',
    'com.android.settings/.notification.ZenSuggestionActivity',
    'com.android.settings/.password.ScreenLockSuggestionActivity',
    'com.android.settings/.support.NewDeviceIntroSuggestionActivity',
    'com.android.settings/.wallpaper.WallpaperSuggestionActivity',
    'com.android.settings/.wifi.calling.WifiCallingSuggestionActivity',
  ];
}
