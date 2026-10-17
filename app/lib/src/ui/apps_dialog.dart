import 'package:flutter/material.dart';

import '../android/android_controller.dart';

/// Lista de aplicativos instalados pelo usuário, com abrir/desinstalar.
class AppsDialog extends StatefulWidget {
  const AppsDialog({super.key, required this.android, required this.onInstall});
  final AndroidController android;
  final VoidCallback onInstall;

  @override
  State<AppsDialog> createState() => _AppsDialogState();
}

class _AppsDialogState extends State<AppsDialog> {
  late Future<List<InstalledApp>> _apps = widget.android.listUserApps();
  String? _busy;

  void _reload() => setState(() => _apps = widget.android.listUserApps());

  Future<void> _act(String pkg, Future<void> Function() action, {bool close = false}) async {
    setState(() => _busy = pkg);
    try {
      await action();
      if (close && mounted) {
        Navigator.pop(context);
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) {
      setState(() => _busy = null);
      if (!close) _reload();
    }
  }

  Future<void> _confirmUninstall(String pkg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desinstalar aplicativo?'),
        content: Text('$pkg e todos os seus dados serão removidos do Android.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Desinstalar')),
        ],
      ),
    );
    if (ok == true) await _act(pkg, () => widget.android.uninstall(pkg));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(children: [
        const Expanded(child: Text('Aplicativos instalados')),
        IconButton(tooltip: 'Atualizar', onPressed: _reload, icon: const Icon(Icons.refresh)),
      ]),
      content: SizedBox(
        width: 520,
        height: 420,
        child: FutureBuilder<List<InstalledApp>>(
          future: _apps,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('${snap.error}', style: TextStyle(color: cs.error)));
            }
            final apps = snap.data!;
            if (apps.isEmpty) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.apps_outlined, size: 48, color: cs.outline),
                  const SizedBox(height: 8),
                  const Text('Nenhum aplicativo instalado pelo usuário.'),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onInstall();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Instalar APK / XAPK'),
                  ),
                ]),
              );
            }
            return ListView.separated(
              itemCount: apps.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final app = apps[i];
                final busy = _busy == app.packageName;
                return ListTile(
                  leading: const Icon(Icons.android),
                  title: Text(app.packageName),
                  trailing: busy
                      ? const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: 'Desinstalar',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _confirmUninstall(app.packageName),
                          ),
                          const SizedBox(width: 4),
                          FilledButton.tonal(
                            onPressed: () => _act(app.packageName,
                                () => widget.android.launch(app.packageName),
                                close: true),
                            child: const Text('Abrir'),
                          ),
                        ]),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
      ],
    );
  }
}
