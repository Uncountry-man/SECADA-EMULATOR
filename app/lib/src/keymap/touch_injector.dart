/// Envia toques multitoque ao Android pelo dispositivo `virtio-multitouch`
/// do QEMU (via QMP `input-send-event`, eventos `mtt`).
///
/// Detalhes do protocolo (QEMU 8.2 + kernel 4.19 do Android-x86):
/// * `begin` abre o ponto (slot) com um `tracking-id` único; `end` o fecha e
///   exige `tracking-id = -1`;
/// * o dispositivo declara `BTN_TOUCH`, e sem ele o Android trata o toque como
///   "pairando": o botão `touch` fica pressionado enquanto houver algum dedo;
/// * os campos `axis`/`value` são obrigatórios até nos eventos `begin`/`end`;
/// * coordenadas vão de 0 a 32767 e cobrem a tela lógica inteira.
class TouchInjector {
  TouchInjector(this._send);

  /// Entrega uma lista de eventos ao QEMU (sem esperar resposta).
  final void Function(List<Map<String, Object?>> events) _send;

  /// Faixa absoluta do dispositivo (INPUT_EVENT_ABS_MAX do QEMU).
  static const absMax = 32767;

  /// Pontos simultâneos suportados (ABS_MT_SLOT máximo = 9).
  static const slots = 10;

  final Map<int, int> _tracking = {};
  int _nextTracking = 1;

  bool get hasTouch => _tracking.isNotEmpty;
  bool isDown(int slot) => _tracking.containsKey(slot);

  static int _raw(double v) => (v.clamp(0.0, 1.0) * absMax).round();

  static Map<String, Object?> _mtt(String type, int slot, int tracking, String axis, int value) => {
        'type': 'mtt',
        'data': {
          'type': type,
          'slot': slot,
          'tracking-id': tracking,
          'axis': axis,
          'value': value,
        },
      };

  static Map<String, Object?> _touchButton(bool down) => {
        'type': 'btn',
        'data': {'down': down, 'button': 'touch'},
      };

  List<Map<String, Object?>> _position(int slot, int tracking, double x, double y) => [
        _mtt('data', slot, tracking, 'x', _raw(x)),
        _mtt('data', slot, tracking, 'y', _raw(y)),
      ];

  /// Encosta um dedo em ([x], [y]) (frações 0..1).
  void down(int slot, double x, double y) {
    if (slot < 0 || slot >= slots) return;
    if (_tracking.containsKey(slot)) {
      move(slot, x, y);
      return;
    }
    final first = _tracking.isEmpty;
    final id = _nextTracking;
    _nextTracking = _nextTracking >= 60000 ? 1 : _nextTracking + 1;
    _tracking[slot] = id;
    _send([
      _mtt('begin', slot, id, 'x', 0),
      if (first) _touchButton(true),
      ..._position(slot, id, x, y),
    ]);
  }

  /// Move um dedo que já está encostado.
  void move(int slot, double x, double y) {
    final id = _tracking[slot];
    if (id == null) return;
    _send([
      _mtt('update', slot, id, 'x', 0),
      ..._position(slot, id, x, y),
    ]);
  }

  /// Levanta o dedo.
  void up(int slot) {
    if (_tracking.remove(slot) == null) return;
    _send([
      _mtt('end', slot, -1, 'x', 0),
      if (_tracking.isEmpty) _touchButton(false),
    ]);
  }

  /// Levanta todos os dedos (perda de foco, desativação do mapeador).
  void upAll() {
    for (final s in _tracking.keys.toList()) {
      up(s);
    }
  }
}
