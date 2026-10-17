import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/vm_settings.dart';
import '../vm/vm_controller.dart';

/// Painel de configurações da VM (persistentes em ~/.config/secada).
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.controller});
  final VmController controller;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late VmSettings s = widget.controller.settings;
  late final _image = TextEditingController(text: s.imagePath);
  late final _qemu = TextEditingController(text: s.qemuPath);
  late final _adb = TextEditingController(text: s.adbPath);
  late final _port = TextEditingController(text: '${s.adbPort}');
  late final _disk = TextEditingController(text: '${s.diskGb}');
  late final _width = TextEditingController(text: '${s.width}');
  late final _height = TextEditingController(text: '${s.height}');

  static const _resolutions = [
    (960, 540), (1280, 720), (1600, 900), (1920, 1080), (2560, 1440),
  ];
  static const _dpis = [160, 200, 240, 280, 320, 400];

  int get _maxCpus => widget.controller.host.logicalCpus > 0
      ? widget.controller.host.logicalCpus
      : 16;
  int get _maxMem {
    final total = widget.controller.host.memTotalMb;
    return total > 3072 ? ((total - 1024) ~/ 512) * 512 : 8192;
  }

  VmSettings _collect() => s.copyWith(
        imagePath: _image.text.trim(),
        qemuPath: _qemu.text.trim(),
        adbPath: _adb.text.trim(),
        adbPort: int.tryParse(_port.text) ?? s.adbPort,
        diskGb: int.tryParse(_disk.text) ?? s.diskGb,
        width: int.tryParse(_width.text) ?? s.width,
        height: int.tryParse(_height.text) ?? s.height,
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final current = _collect();
    final warnings = <String>[];
    final errors = current.validate(widget.controller.host, warnings: warnings);
    final active = widget.controller.state.isActive;
    final customRes = !_resolutions.contains((current.width, current.height));

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Text(title, style: tt.titleSmall?.copyWith(color: cs.primary)),
        );

    return AlertDialog(
      title: const Text('Configurações'),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (active)
                _Banner(
                  icon: Icons.info_outline,
                  text: 'A VM está em execução: as alterações valem a partir '
                      'da próxima inicialização.',
                  color: cs.secondaryContainer,
                ),
              section('Recursos'),
              _LabeledSlider(
                label: 'Núcleos virtuais (vCPUs)',
                value: s.cpus.clamp(1, _maxCpus).toDouble(),
                min: 1,
                max: _maxCpus.toDouble(),
                divisions: _maxCpus > 1 ? _maxCpus - 1 : null,
                display: '${s.cpus} de $_maxCpus',
                onChanged: (v) => setState(() => s = s.copyWith(cpus: v.round())),
              ),
              _LabeledSlider(
                label: 'Memória RAM',
                value: s.memoryMb.clamp(2048, _maxMem).toDouble(),
                min: 2048,
                max: _maxMem.toDouble(),
                divisions: (_maxMem - 2048) ~/ 512 > 0 ? (_maxMem - 2048) ~/ 512 : null,
                display: '${s.memoryMb} MB',
                onChanged: (v) => setState(() =>
                    s = s.copyWith(memoryMb: (v / 512).round() * 512)),
              ),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _disk,
                    decoration: const InputDecoration(
                      labelText: 'Armazenamento (GB)',
                      helperText: 'Só pode ser ampliado',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
              section('Tela'),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<(int, int)?>(
                    initialValue: customRes ? null : (current.width, current.height),
                    decoration: const InputDecoration(labelText: 'Resolução'),
                    items: [
                      for (final r in _resolutions)
                        DropdownMenuItem(value: r, child: Text('${r.$1} × ${r.$2}')),
                      const DropdownMenuItem(value: null, child: Text('Personalizada')),
                    ],
                    onChanged: (r) => setState(() {
                      if (r != null) {
                        _width.text = '${r.$1}';
                        _height.text = '${r.$2}';
                      }
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _width,
                    decoration: const InputDecoration(labelText: 'Largura'),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _height,
                    decoration: const InputDecoration(labelText: 'Altura'),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: DropdownButtonFormField<int>(
                    initialValue: _dpis.contains(s.dpi) ? s.dpi : 240,
                    decoration: const InputDecoration(labelText: 'DPI'),
                    items: [
                      for (final d in _dpis) DropdownMenuItem(value: d, child: Text('$d')),
                    ],
                    onChanged: (v) => setState(() => s = s.copyWith(dpi: v)),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              DropdownButtonFormField<GraphicsMode>(
                initialValue: s.graphics,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Gráficos'),
                items: [
                  for (final g in GraphicsMode.values)
                    DropdownMenuItem(value: g, child: Text(g.label)),
                ],
                onChanged: (v) => setState(() => s = s.copyWith(graphics: v)),
              ),
              section('Sistema Android'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Iniciar o Android ao abrir o SECADA Emulator'),
                value: s.autoStart,
                onChanged: (v) => setState(() => s = s.copyWith(autoStart: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Android enxuto'),
                subtitle: const Text('Desligado de fábrica. Ligado, remove apps '
                    'Google, telemetria e apps pré-instalados dispensáveis '
                    '(reversível)'),
                value: s.leanAndroid,
                onChanged: (v) => setState(() => s = s.copyWith(leanAndroid: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tradução ARM'),
                subtitle: const Text('Roda apps feitos só para celular ARM (32 bits) '
                    'com o libhoudini do Android-x86, baixado na primeira vez '
                    '(~43 MB). Apps só ARM64 não são suportados.'),
                value: s.armTranslation,
                onChanged: (v) => setState(() => s = s.copyWith(armTranslation: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Áudio'),
                subtitle: const Text('Som do Android pelo PulseAudio/PipeWire do computador'),
                value: s.audio,
                onChanged: (v) => setState(() => s = s.copyWith(audio: v)),
              ),
              section('Entrada'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Esc funciona como "Voltar" no Android'),
                subtitle: const Text('Desativado: Esc apenas sai da tela cheia'),
                value: s.escAsBack,
                onChanged: (v) => setState(() => s = s.copyWith(escAsBack: v)),
              ),
              section('Imagem'),
              _PathField(
                controller: _image,
                label: 'Imagem Android (ISO)',
                hint: 'Automático: ~/.local/share/secada/images/*.iso',
                extensions: const ['iso'],
                onChanged: () => setState(() {}),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Avançado', style: tt.labelLarge),
                children: [
                  _PathField(
                    controller: _qemu,
                    label: 'Executável do QEMU',
                    hint: 'Automático',
                    onChanged: () => setState(() {}),
                  ),
                  _PathField(
                    controller: _adb,
                    label: 'Executável do ADB',
                    hint: 'Automático',
                    onChanged: () => setState(() {}),
                  ),
                  TextField(
                    controller: _port,
                    decoration: const InputDecoration(
                      labelText: 'Porta ADB local (127.0.0.1)',
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
              for (final e in errors) _Banner(icon: Icons.error_outline, text: e, color: cs.errorContainer),
              for (final w in warnings)
                _Banner(icon: Icons.warning_amber_rounded, text: w, color: cs.tertiaryContainer),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            s = const VmSettings();
            _image.text = s.imagePath;
            _qemu.text = s.qemuPath;
            _adb.text = s.adbPath;
            _port.text = '${s.adbPort}';
            _disk.text = '${s.diskGb}';
            _width.text = '${s.width}';
            _height.text = '${s.height}';
          }),
          child: const Text('Restaurar padrões'),
        ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(
          onPressed: errors.isEmpty
              ? () async {
                  await widget.controller.saveSettings(_collect());
                  if (context.mounted) Navigator.pop(context, true);
                }
              : null,
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
  });
  final String label;
  final double value, min, max;
  final int? divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(width: 190, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max > min ? max : min + 1,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ),
      SizedBox(width: 90, child: Text(display, textAlign: TextAlign.end)),
    ]);
  }
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.onChanged,
    this.extensions,
  });
  final TextEditingController controller;
  final String label, hint;
  final List<String>? extensions;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        onChanged: (_) => onChanged(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: IconButton(
            tooltip: 'Procurar…',
            icon: const Icon(Icons.folder_open),
            onPressed: () async {
              final f = await openFile(acceptedTypeGroups: [
                if (extensions != null) XTypeGroup(label: label, extensions: extensions),
              ]);
              if (f != null) {
                controller.text = f.path;
                onChanged();
              }
            },
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ]),
    );
  }
}
