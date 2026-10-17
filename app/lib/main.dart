import 'dart:async';

import 'package:flutter/material.dart';

import 'src/core/app_log.dart';
import 'src/host/file_associations.dart';
import 'src/ui/home_page.dart';
import 'src/ui/theme.dart';
import 'src/vm/vm_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await log.init();
  FlutterError.onError = (details) {
    log.error('FlutterError', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  final controller = VmController();
  await controller.init();
  WidgetsBinding.instance.platformDispatcher.onError = (e, st) {
    log.error('Erro não tratado', e, st);
    return true;
  };
  runApp(SecadaApp(controller: controller));
  // Faz o gerenciador de arquivos abrir .apk/.xapk no SECADA Emulator (idempotente).
  unawaited(FileAssociations.ensure());
}

class SecadaApp extends StatelessWidget {
  const SecadaApp({super.key, required this.controller});
  final VmController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SECADA Emulator',
      debugShowCheckedModeBanner: false,
      theme: SecadaTheme.dark(),
      home: HomePage(controller: controller),
    );
  }
}
