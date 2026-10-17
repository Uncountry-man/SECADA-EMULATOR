// Cliente RFB (VNC) mínimo para o servidor VNC embutido do QEMU.
//
// A conexão é feita exclusivamente por socket UNIX local (diretório 0700 em
// $XDG_RUNTIME_DIR), então nenhuma porta de rede é exposta. A tela é recebida
// em codificação Raw/CopyRect (o custo de banda é irrelevante num socket local
// e evita descompressão), e mouse/teclado são enviados como eventos RFB nativos
// (PointerEvent/KeyEvent), que o QEMU injeta nos dispositivos virtuais
// (usb-tablet absoluto e teclado PS/2).
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace secada {

class RfbClient {
 public:
  enum class State { kConnecting, kConnected, kDisconnected, kFailed };

  // Todos os callbacks são chamados na thread de leitura.
  struct Callbacks {
    std::function<void()> on_frame;
    std::function<void(int width, int height)> on_resize;
    std::function<void(State state, const std::string& detail)> on_state;
  };

  explicit RfbClient(Callbacks callbacks);
  ~RfbClient();
  RfbClient(const RfbClient&) = delete;
  RfbClient& operator=(const RfbClient&) = delete;

  // Conecta (com novas tentativas até |connect_timeout_ms|) em segundo plano.
  // |swap_red_blue|: compensa convidados que desenham BGR num framebuffer
  // XRGB (Android-x86 nos modos por software).
  void Start(const std::string& socket_path, int connect_timeout_ms,
             bool swap_red_blue = false);
  void Stop();

  // Entrada (thread-safe). Coordenadas em pixels do framebuffer da VM.
  void SendPointer(int x, int y, uint8_t button_mask);
  void SendKey(uint32_t keysym, bool down);
  // Extensão "QEMU Extended Key Event": envia o scancode XT (set 1; prefixo
  // e0 codificado como bit 0x80) sem passar pela tabela de layout do QEMU.
  // Retorna false se o servidor não anunciou suporte.
  bool SendScancode(uint32_t scancode, uint32_t keysym, bool down);
  bool supports_scancodes() const { return ext_key_.load(); }
  void RequestFullUpdate();
  // Com o display D-Bus ativo, o VNC deixa de pedir quadros (fica só como
  // reserva); |enabled| = true volta a pedir.
  void SetUpdatesEnabled(bool enabled);

  // Copia o quadro atual (RGBA, alfa = 255) se for mais novo que |*serial|.
  bool CopyFrameIfNewer(std::vector<uint8_t>* out, uint32_t* width,
                        uint32_t* height, uint64_t* serial);

  int width() const { return width_.load(); }
  int height() const { return height_.load(); }
  bool connected() const { return connected_.load(); }

 private:
  void Run(std::string socket_path, int connect_timeout_ms);
  bool ConnectSocket(const std::string& path, int timeout_ms);
  bool Handshake(std::string* error);
  bool MessageLoop(std::string* error);
  bool HandleFramebufferUpdate(std::string* error);
  bool ReadExact(void* buf, size_t len);
  bool Skip(size_t len);
  bool WriteAll(const void* buf, size_t len);
  void SendUpdateRequest(bool incremental);
  void ResizeFramebuffer(int width, int height);
  void EmitState(State state, const std::string& detail);

  Callbacks callbacks_;
  std::thread thread_;
  std::atomic<bool> stop_{false};
  std::atomic<int> fd_{-1};
  std::atomic<bool> connected_{false};
  std::atomic<bool> ext_key_{false};
  std::atomic<bool> updates_enabled_{true};
  bool swap_red_blue_ = false;
  std::mutex write_mutex_;

  std::mutex fb_mutex_;
  std::vector<uint8_t> framebuffer_;  // RGBA
  std::atomic<int> width_{0};
  std::atomic<int> height_{0};
  uint64_t frame_serial_ = 0;  // protegido por fb_mutex_
  std::vector<uint8_t> scratch_;
};

}  // namespace secada
