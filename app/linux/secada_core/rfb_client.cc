#include "rfb_client.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>

namespace secada {
namespace {

constexpr int32_t kEncodingRaw = 0;
constexpr int32_t kEncodingCopyRect = 1;
constexpr int32_t kEncodingDesktopSize = -223;
constexpr int32_t kEncodingQemuExtendedKey = -258;

inline uint16_t ReadU16(const uint8_t* p) { return (p[0] << 8) | p[1]; }
inline uint32_t ReadU32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | p[3];
}
inline void PutU16(uint8_t* p, uint16_t v) {
  p[0] = v >> 8;
  p[1] = v & 0xff;
}
inline void PutU32(uint8_t* p, uint32_t v) {
  p[0] = v >> 24;
  p[1] = (v >> 16) & 0xff;
  p[2] = (v >> 8) & 0xff;
  p[3] = v & 0xff;
}

void SleepMs(int ms) {
  struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&ts, nullptr);
}

}  // namespace

RfbClient::RfbClient(Callbacks callbacks) : callbacks_(std::move(callbacks)) {}

RfbClient::~RfbClient() { Stop(); }

void RfbClient::Start(const std::string& socket_path, int connect_timeout_ms,
                      bool swap_red_blue) {
  Stop();
  stop_ = false;
  swap_red_blue_ = swap_red_blue;
  thread_ = std::thread(&RfbClient::Run, this, socket_path, connect_timeout_ms);
}

void RfbClient::Stop() {
  stop_ = true;
  int fd = fd_.load();
  if (fd >= 0) shutdown(fd, SHUT_RDWR);  // Acorda a thread bloqueada em recv.
  if (thread_.joinable()) thread_.join();
  fd = fd_.exchange(-1);
  if (fd >= 0) close(fd);
  connected_ = false;
  ext_key_ = false;
}

void RfbClient::EmitState(State state, const std::string& detail) {
  if (callbacks_.on_state) callbacks_.on_state(state, detail);
}

void RfbClient::Run(std::string socket_path, int connect_timeout_ms) {
  EmitState(State::kConnecting, socket_path);
  if (!ConnectSocket(socket_path, connect_timeout_ms)) {
    if (!stop_) {
      EmitState(State::kFailed,
                "Não foi possível conectar ao display da VM em " + socket_path);
    }
    return;
  }
  std::string error;
  if (!Handshake(&error)) {
    if (!stop_) EmitState(State::kFailed, "Handshake VNC falhou: " + error);
    return;
  }
  connected_ = true;
  EmitState(State::kConnected, "");
  bool ok = MessageLoop(&error);
  connected_ = false;
  if (stop_) {
    EmitState(State::kDisconnected, "");
  } else {
    EmitState(ok ? State::kDisconnected : State::kFailed, error);
  }
}

bool RfbClient::ConnectSocket(const std::string& path, int timeout_ms) {
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (path.size() >= sizeof(addr.sun_path)) return false;
  memcpy(addr.sun_path, path.c_str(), path.size());

  auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (!stop_) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    if (connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) ==
        0) {
      fd_ = fd;
      if (stop_) return false;
      return true;
    }
    close(fd);
    if (std::chrono::steady_clock::now() > deadline) return false;
    SleepMs(100);
  }
  return false;
}

bool RfbClient::ReadExact(void* buf, size_t len) {
  auto* p = static_cast<uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = recv(fd_.load(), p, len, 0);
    if (n == 0) return false;
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += n;
    len -= n;
  }
  return true;
}

bool RfbClient::Skip(size_t len) {
  uint8_t tmp[4096];
  while (len > 0) {
    size_t chunk = std::min(len, sizeof(tmp));
    if (!ReadExact(tmp, chunk)) return false;
    len -= chunk;
  }
  return true;
}

bool RfbClient::WriteAll(const void* buf, size_t len) {
  std::lock_guard<std::mutex> lock(write_mutex_);
  int fd = fd_.load();
  if (fd < 0) return false;
  auto* p = static_cast<const uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += n;
    len -= n;
  }
  return true;
}

bool RfbClient::Handshake(std::string* error) {
  char version[12];
  if (!ReadExact(version, 12)) {
    *error = "sem versão do protocolo";
    return false;
  }
  if (memcmp(version, "RFB 003.", 8) != 0) {
    *error = "servidor não é RFB";
    return false;
  }
  const char kVersion[] = "RFB 003.008\n";
  if (!WriteAll(kVersion, 12)) {
    *error = "falha ao enviar versão";
    return false;
  }
  uint8_t count = 0;
  if (!ReadExact(&count, 1)) {
    *error = "falha ao ler tipos de segurança";
    return false;
  }
  if (count == 0) {
    uint8_t len_buf[4];
    std::string reason;
    if (ReadExact(len_buf, 4)) {
      reason.resize(ReadU32(len_buf));
      ReadExact(reason.data(), reason.size());
    }
    *error = "servidor recusou: " + reason;
    return false;
  }
  std::vector<uint8_t> types(count);
  if (!ReadExact(types.data(), count)) return false;
  // O socket é local e protegido por permissões do sistema de arquivos, por
  // isso usamos o tipo "None" (1).
  if (std::find(types.begin(), types.end(), 1) == types.end()) {
    *error = "servidor exige autenticação não suportada";
    return false;
  }
  uint8_t choice = 1;
  if (!WriteAll(&choice, 1)) return false;
  uint8_t result_buf[4];
  if (!ReadExact(result_buf, 4)) return false;
  if (ReadU32(result_buf) != 0) {
    *error = "autenticação falhou";
    return false;
  }

  uint8_t shared = 1;
  if (!WriteAll(&shared, 1)) return false;

  uint8_t init[24];
  if (!ReadExact(init, 24)) {
    *error = "ServerInit incompleto";
    return false;
  }
  int w = ReadU16(init);
  int h = ReadU16(init + 2);
  uint32_t name_len = ReadU32(init + 20);
  if (!Skip(name_len)) return false;
  ResizeFramebuffer(w, h);

  // SetPixelFormat: 32bpp, little-endian, R no byte 0, G no 1, B no 2 => RGBX.
  uint8_t spf[20] = {0};
  spf[0] = 0;
  spf[4] = 32;   // bits-per-pixel
  spf[5] = 24;   // depth
  spf[6] = 0;    // big-endian-flag
  spf[7] = 1;    // true-colour-flag
  PutU16(spf + 8, 255);
  PutU16(spf + 10, 255);
  PutU16(spf + 12, 255);
  spf[14] = swap_red_blue_ ? 16 : 0;  // red-shift
  spf[15] = 8;                         // green-shift
  spf[16] = swap_red_blue_ ? 0 : 16;   // blue-shift
  if (!WriteAll(spf, sizeof(spf))) return false;

  const int32_t encodings[] = {kEncodingCopyRect, kEncodingRaw,
                               kEncodingDesktopSize, kEncodingQemuExtendedKey};
  const int n = sizeof(encodings) / sizeof(encodings[0]);
  uint8_t se[4 + 4 * n];
  se[0] = 2;
  se[1] = 0;
  PutU16(se + 2, n);
  for (int i = 0; i < n; ++i) PutU32(se + 4 + 4 * i, uint32_t(encodings[i]));
  if (!WriteAll(se, sizeof(se))) return false;

  SendUpdateRequest(false);
  return true;
}

void RfbClient::ResizeFramebuffer(int width, int height) {
  {
    std::lock_guard<std::mutex> lock(fb_mutex_);
    framebuffer_.assign(size_t(width) * height * 4, 0);
    for (size_t i = 3; i < framebuffer_.size(); i += 4) framebuffer_[i] = 0xff;
    width_ = width;
    height_ = height;
    frame_serial_++;
  }
  if (callbacks_.on_resize) callbacks_.on_resize(width, height);
}

void RfbClient::SendUpdateRequest(bool incremental) {
  uint8_t req[10];
  req[0] = 3;
  req[1] = incremental ? 1 : 0;
  PutU16(req + 2, 0);
  PutU16(req + 4, 0);
  PutU16(req + 6, width_.load());
  PutU16(req + 8, height_.load());
  WriteAll(req, sizeof(req));
}

void RfbClient::RequestFullUpdate() {
  if (connected_ && updates_enabled_) SendUpdateRequest(false);
}

void RfbClient::SetUpdatesEnabled(bool enabled) {
  bool was = updates_enabled_.exchange(enabled);
  if (enabled && !was && connected_) SendUpdateRequest(false);
}

bool RfbClient::MessageLoop(std::string* error) {
  while (!stop_) {
    uint8_t type;
    if (!ReadExact(&type, 1)) {
      *error = "conexão com o display encerrada";
      return true;
    }
    switch (type) {
      case 0:
        if (!HandleFramebufferUpdate(error)) return false;
        break;
      case 1: {  // SetColourMapEntries (não usado em true-colour)
        uint8_t hdr[5];
        if (!ReadExact(hdr, 5)) return false;
        if (!Skip(size_t(ReadU16(hdr + 3)) * 6)) return false;
        break;
      }
      case 2:  // Bell
        break;
      case 3: {  // ServerCutText
        uint8_t hdr[7];
        if (!ReadExact(hdr, 7)) return false;
        if (!Skip(ReadU32(hdr + 3))) return false;
        break;
      }
      default:
        *error = "mensagem RFB desconhecida: " + std::to_string(type);
        return false;
    }
  }
  return true;
}

bool RfbClient::HandleFramebufferUpdate(std::string* error) {
  uint8_t hdr[3];
  if (!ReadExact(hdr, 3)) return false;
  int rects = ReadU16(hdr + 1);
  bool resized = false;
  for (int i = 0; i < rects; ++i) {
    uint8_t rh[12];
    if (!ReadExact(rh, 12)) return false;
    int x = ReadU16(rh), y = ReadU16(rh + 2);
    int w = ReadU16(rh + 4), h = ReadU16(rh + 6);
    int32_t enc = int32_t(ReadU32(rh + 8));
    if (enc == kEncodingRaw) {
      size_t row_bytes = size_t(w) * 4;
      scratch_.resize(row_bytes * h);
      if (!ReadExact(scratch_.data(), scratch_.size())) return false;
      std::lock_guard<std::mutex> lock(fb_mutex_);
      int fw = width_.load(), fh = height_.load();
      if (x + w > fw || y + h > fh) continue;  // Ignora retângulo inválido.
      for (int row = 0; row < h; ++row) {
        uint8_t* dst = &framebuffer_[(size_t(y + row) * fw + x) * 4];
        const uint8_t* src = &scratch_[row * row_bytes];
        memcpy(dst, src, row_bytes);
        for (size_t a = 3; a < row_bytes; a += 4) dst[a] = 0xff;
      }
    } else if (enc == kEncodingCopyRect) {
      uint8_t src_pos[4];
      if (!ReadExact(src_pos, 4)) return false;
      int sx = ReadU16(src_pos), sy = ReadU16(src_pos + 2);
      std::lock_guard<std::mutex> lock(fb_mutex_);
      int fw = width_.load(), fh = height_.load();
      if (x + w > fw || y + h > fh || sx + w > fw || sy + h > fh) continue;
      size_t row_bytes = size_t(w) * 4;
      scratch_.resize(row_bytes * h);
      for (int row = 0; row < h; ++row) {
        memcpy(&scratch_[row * row_bytes],
               &framebuffer_[(size_t(sy + row) * fw + sx) * 4], row_bytes);
      }
      for (int row = 0; row < h; ++row) {
        memcpy(&framebuffer_[(size_t(y + row) * fw + x) * 4],
               &scratch_[row * row_bytes], row_bytes);
      }
    } else if (enc == kEncodingDesktopSize) {
      ResizeFramebuffer(w, h);
      resized = true;
    } else if (enc == kEncodingQemuExtendedKey) {
      ext_key_ = true;  // Confirmação do servidor; sem dados.
    } else {
      *error = "codificação RFB não suportada: " + std::to_string(enc);
      return false;
    }
  }
  {
    std::lock_guard<std::mutex> lock(fb_mutex_);
    frame_serial_++;
  }
  if (callbacks_.on_frame) callbacks_.on_frame();
  if (updates_enabled_) SendUpdateRequest(!resized);
  return true;
}

bool RfbClient::CopyFrameIfNewer(std::vector<uint8_t>* out, uint32_t* width,
                                 uint32_t* height, uint64_t* serial) {
  std::lock_guard<std::mutex> lock(fb_mutex_);
  if (frame_serial_ == *serial || framebuffer_.empty()) return false;
  *out = framebuffer_;
  *width = width_.load();
  *height = height_.load();
  *serial = frame_serial_;
  return true;
}

void RfbClient::SendPointer(int x, int y, uint8_t button_mask) {
  if (!connected_) return;
  int w = width_.load(), h = height_.load();
  x = std::clamp(x, 0, std::max(0, w - 1));
  y = std::clamp(y, 0, std::max(0, h - 1));
  uint8_t msg[6];
  msg[0] = 5;
  msg[1] = button_mask;
  PutU16(msg + 2, x);
  PutU16(msg + 4, y);
  WriteAll(msg, sizeof(msg));
}

void RfbClient::SendKey(uint32_t keysym, bool down) {
  if (!connected_) return;
  uint8_t msg[8] = {0};
  msg[0] = 4;
  msg[1] = down ? 1 : 0;
  PutU32(msg + 4, keysym);
  WriteAll(msg, sizeof(msg));
}

bool RfbClient::SendScancode(uint32_t scancode, uint32_t keysym, bool down) {
  if (!connected_ || !ext_key_) return false;
  uint8_t msg[12];
  msg[0] = 255;  // mensagem QEMU
  msg[1] = 0;    // sub-tipo: extended key event
  PutU16(msg + 2, down ? 1 : 0);
  PutU32(msg + 4, keysym);
  PutU32(msg + 8, scancode);
  return WriteAll(msg, sizeof(msg));
}

}  // namespace secada
