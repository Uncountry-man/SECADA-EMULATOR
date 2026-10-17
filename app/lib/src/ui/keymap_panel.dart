import 'package:flutter/material.dart';

import '../keymap/keymap_controller.dart';
import '../keymap/keymap_models.dart';

/// Painel do mapeador de teclas: liga/desliga, perfil, edição e preferências.
class KeymapPanel extends StatelessWidget {
  const KeymapPanel({super.key, required this.controller});
  final KeymapController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Dialog(
      alignment: Alignment.centerRight,
      insetPadding: const EdgeInsets.fromLTRB(24, 24, 72, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final c = controller;
            final profile = c.profile;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.sports_esports_rounded, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Mapeador de teclas', style: tt.titleLarge)),
                    if (c.busy)
                      const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      Switch(
                        value: c.enabled,
                        onChanged: (v) async {
                          final ok = await c.setEnabled(v);
                          if (!ok && v && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text(
                                    'Não foi possível ligar a tela de toque. Veja os logs do SECADA Emulator.')));
                          }
                        },
                      ),
                  ]),
                  const SizedBox(height: 8),
                  if (!c.enabled)
                    Text(
                      'Transforma teclado e mouse em toques, como nos emuladores de jogos: '
                      'WASD vira direcional, o mouse mira, cada tecla toca num ponto da tela. '
                      'Ao ligar, o Android ganha uma tela de toque com multitoque (andar e atirar '
                      'ao mesmo tempo); ao desligar ela é removida e o mouse volta ao normal.',
                      style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    )
                  else ...[
                    _info(context, Icons.apps_rounded, 'App em primeiro plano',
                        c.foregroundPackage ?? 'detectando…'),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<KeymapProfile?>(
                      key: ValueKey('${profile?.name}|${c.store.user.length}'),
                      initialValue: profile,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Perfil de teclas',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: _items(c),
                      onChanged: (p) => c.selectProfile(p),
                    ),
                    if (profile != null && profile.note.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(profile.note,
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                        onPressed: profile == null
                            ? null
                            : () {
                                Navigator.pop(context);
                                c.beginEdit();
                              },
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: const Text('Editar posições'),
                      ),
                      PopupMenuButton<KeymapProfile?>(
                        tooltip: 'Criar um perfil novo',
                        onSelected: (t) {
                          Navigator.pop(context);
                          if (t == null) {
                            c.beginBlank();
                          } else {
                            c.beginFromTemplate(t);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: null, child: Text('Em branco')),
                          const PopupMenuDivider(),
                          for (final t in c.templates)
                            PopupMenuItem(value: t, child: Text(t.name)),
                        ],
                        child: IgnorePointer(
                          child: OutlinedButton.icon(
                            onPressed: () {},
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Novo perfil'),
                          ),
                        ),
                      ),
                      if (profile != null && c.store.isUser(profile))
                        TextButton.icon(
                          onPressed: () => _confirmDelete(context, profile),
                          icon: Icon(Icons.delete_outline_rounded, size: 18, color: cs.error),
                          label: Text('Excluir', style: TextStyle(color: cs.error)),
                        ),
                    ]),
                    const Divider(height: 28),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mostrar as teclas na tela'),
                      value: c.prefs.showHud,
                      onChanged: c.setShowHud,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Trocar o perfil sozinho por app'),
                      subtitle: const Text('Usa o perfil do jogo que está aberto'),
                      value: c.prefs.autoProfile && !c.pinned,
                      onChanged: c.setAutoProfile,
                    ),
                    const SizedBox(height: 4),
                    Text('Sensibilidade da mira: ${c.prefs.sensitivity.toStringAsFixed(1)}×',
                        style: tt.bodyMedium),
                    Slider(
                      min: .2,
                      max: 4,
                      divisions: 38,
                      value: c.prefs.sensitivity.clamp(.2, 4.0),
                      onChanged: (v) => c.setSensitivity(v, persist: false),
                      onChangeEnd: (v) => c.setSensitivity(v),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'F8 pausa o mapeamento para você digitar (o mouse continua como dedo). '
                      'No modo de mira, Esc volta ao cursor normal.',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                        onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _info(BuildContext context, IconData icon, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 10),
        Text('$label: ', style: Theme.of(context).textTheme.bodyMedium),
        Expanded(
          child: Text(value,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  List<DropdownMenuItem<KeymapProfile?>> _items(KeymapController c) {
    DropdownMenuItem<KeymapProfile?> header(String t) => DropdownMenuItem<KeymapProfile?>(
          enabled: false,
          value: KeymapProfile(name: '#$t'),
          child: Text(t, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        );
    DropdownMenuItem<KeymapProfile?> item(KeymapProfile p) =>
        DropdownMenuItem(value: p, child: Text(p.name, overflow: TextOverflow.ellipsis));
    final templates = c.store.builtin.where((p) => p.name.startsWith('Modelo:')).toList();
    final games = c.store.builtin.where((p) => !p.name.startsWith('Modelo:')).toList();
    return [
      const DropdownMenuItem<KeymapProfile?>(value: null, child: Text('Nenhum (teclas normais)')),
      if (c.store.user.isNotEmpty) ...[header('MEUS PERFIS'), ...c.store.user.map(item)],
      header('JOGOS'),
      ...games.map(item),
      header('MODELOS'),
      ...templates.map(item),
    ];
  }

  Future<void> _confirmDelete(BuildContext context, KeymapProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir perfil?'),
        content: Text('"${p.name}" será removido. Os perfis que acompanham o SECADA Emulator não são afetados.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok == true) await controller.deleteProfile(p);
  }
}
