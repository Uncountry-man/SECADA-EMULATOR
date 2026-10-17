// Display D-Bus do QEMU (-display dbus,p2p=yes,gl=on) com leitura pela GPU.
//
// Com VirGL, o caminho egl-headless + VNC do QEMU é limitado pelo timer de
// 30 ms do VNC (~26 quadros/s) e faz o Android esperar a cópia de cada
// quadro. Pelo display D-Bus, o QEMU entrega cada quadro do Android assim que
// ele termina (UpdateDMABUF) como um dmabuf da GPU: o SECADA Emulator importa o dmabuf
// num contexto EGL próprio, no mesmo nó de renderização do QEMU, lê só a
// região alterada e responde, liberando o próximo quadro (até 60 quadros/s).
//
// Conexão ponto a ponto: um socketpair é entregue ao QEMU por um QMP dedicado
// (getfd + add_client "@dbus-display"); depois um segundo socketpair vira o
// "Listener" (RegisterListener). Mouse e teclado também vão por D-Bus
// (interfaces Mouse/Keyboard do console), pois nesse modo o VNC deixa de
// injetar entrada.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace secada {

class DbusDisplay {
 public:
  // Chamados na thread do display.
  struct Callbacks {
    std::function<void()> on_frame;
    std::function<void(int width, int height)> on_resize;
    // |ok| = primeiro quadro recebido; !ok = falhou (|detail| explica).
    std::function<void(bool ok, const std::string& detail)> on_state;
  };

  explicit DbusDisplay(Callbacks callbacks);
  ~DbusDisplay();
  DbusDisplay(const DbusDisplay&) = delete;
  DbusDisplay& operator=(const DbusDisplay&) = delete;

  void Start(const std::string& qmp_socket, const std::string& render_node,
             int timeout_ms);
  void Stop();

  // Já entregou pelo menos um quadro (a partir daí é a fonte da imagem e da
  // entrada).
  bool active() const { return active_.load(); }

  // Copia o quadro atual (RGBA) se for mais novo que |*serial|.
  bool CopyFrameIfNewer(std::vector<uint8_t>* out, uint32_t* width,
                        uint32_t* height, uint64_t* serial);

  // Entrada (thread-safe). Botões no formato RFB (bit 0 esquerdo, 1 meio,
  // 2 direito, 3/4 roda).
  void SendPointer(int x, int y, uint8_t button_mask);
  // Keysym X11 -> scancode XT do layout en-us (o mesmo que o QEMU faz no VNC).
  void SendKeysym(uint32_t keysym, bool down);
  // Scancode XT (set 1; prefixo e0 = bit 0x80).
  void SendScancode(uint32_t scancode, bool down);

  struct Impl;  // Estado da thread (EGL, GDBus); público para os callbacks C.

 private:
  void Run(std::string qmp_socket, std::string render_node, int timeout_ms);
  void CallConsole(const char* iface, const char* method, void* params);

  Callbacks callbacks_;
  std::thread thread_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> active_{false};
  std::unique_ptr<Impl> impl_;

  std::mutex conn_mutex_;
  void* conn_ = nullptr;  // GDBusConnection* (QEMU); protegido por conn_mutex_
  void* context_ = nullptr;  // GMainContext* da thread
  void* loop_ = nullptr;     // GMainLoop*

  int last_x_ = -1, last_y_ = -1;
  uint8_t last_buttons_ = 0;
};

}  // namespace secada
