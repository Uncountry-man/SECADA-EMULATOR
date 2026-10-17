#include "dbus_display.h"

#include <dlfcn.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

namespace secada {

namespace {

constexpr char kConsolePath[] = "/org/qemu/Display1/Console_0";
constexpr char kListenerPath[] = "/org/qemu/Display1/Listener";

constexpr char kListenerXml[] = R"(
<node>
  <interface name="org.qemu.Display1.Listener">
    <method name="Scanout">
      <arg type="u" name="width" direction="in"/>
      <arg type="u" name="height" direction="in"/>
      <arg type="u" name="stride" direction="in"/>
      <arg type="u" name="pixman_format" direction="in"/>
      <arg type="ay" name="data" direction="in"/>
    </method>
    <method name="Update">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
      <arg type="u" name="stride" direction="in"/>
      <arg type="u" name="pixman_format" direction="in"/>
      <arg type="ay" name="data" direction="in"/>
    </method>
    <method name="ScanoutDMABUF">
      <arg type="h" name="dmabuf" direction="in"/>
      <arg type="u" name="width" direction="in"/>
      <arg type="u" name="height" direction="in"/>
      <arg type="u" name="stride" direction="in"/>
      <arg type="u" name="fourcc" direction="in"/>
      <arg type="t" name="modifier" direction="in"/>
      <arg type="b" name="y0_top" direction="in"/>
    </method>
    <method name="UpdateDMABUF">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
    </method>
    <method name="Disable"/>
    <method name="MouseSet">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="on" direction="in"/>
    </method>
    <method name="CursorDefine">
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
      <arg type="i" name="hot_x" direction="in"/>
      <arg type="i" name="hot_y" direction="in"/>
      <arg type="ay" name="data" direction="in"/>
    </method>
    <property name="Interfaces" type="as" access="read"/>
  </interface>
</node>)";

constexpr uint64_t kModInvalid = 0x00ffffffffffffffULL;

#ifndef EGL_DRM_RENDER_NODE_FILE_EXT
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3377
#endif

// Formatos pixman de 32 bits usados pelo QEMU.
constexpr uint32_t kPixmanX8R8G8B8 = 0x20020888;
constexpr uint32_t kPixmanA8R8G8B8 = 0x20028888;
constexpr uint32_t kPixmanX8B8G8R8 = 0x20030888;
constexpr uint32_t kPixmanA8B8G8R8 = 0x20038888;

// ------------------------------------------------------------- QMP (fd pass)

bool WriteAllFd(int fd, const std::string& s) {
  size_t off = 0;
  while (off < s.size()) {
    ssize_t n = send(fd, s.data() + off, s.size() - off, MSG_NOSIGNAL);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    off += size_t(n);
  }
  return true;
}

// Lê respostas QMP até uma com "return" ou "error" (eventos são ignorados).
bool QmpReply(int fd, std::string* reply) {
  std::string buf;
  char c;
  for (;;) {
    ssize_t n = recv(fd, &c, 1, 0);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    if (c != '\n') {
      buf.push_back(c);
      continue;
    }
    if (buf.find("\"return\"") != std::string::npos ||
        buf.find("\"error\"") != std::string::npos) {
      *reply = buf;
      return buf.find("\"error\"") == std::string::npos;
    }
    buf.clear();
  }
}

bool QmpCommand(int fd, const std::string& json, int pass_fd,
                std::string* error) {
  std::string line = json + "\n";
  if (pass_fd >= 0) {
    struct msghdr msg = {};
    struct iovec iov = {const_cast<char*>(line.data()), line.size()};
    char ctrl[CMSG_SPACE(sizeof(int))] = {};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl;
    msg.msg_controllen = sizeof(ctrl);
    struct cmsghdr* cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &pass_fd, sizeof(int));
    if (sendmsg(fd, &msg, MSG_NOSIGNAL) != ssize_t(line.size())) {
      *error = "QMP: falha ao enviar o descritor";
      return false;
    }
  } else if (!WriteAllFd(fd, line)) {
    *error = "QMP: falha de escrita";
    return false;
  }
  std::string reply;
  if (!QmpReply(fd, &reply)) {
    *error = "QMP: " + (reply.empty() ? std::string("conexão encerrada") : reply);
    return false;
  }
  return true;
}

int ConnectUnix(const std::string& path, int timeout_ms,
                const std::atomic<bool>& stop) {
  auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (!stop && std::chrono::steady_clock::now() < deadline) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0)
      return fd;
    close(fd);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  return -1;
}

// ---------------------------------------------------- keysym -> scancode XT

uint32_t KeysymToScancode(uint32_t ks) {
  if (ks >= 'A' && ks <= 'Z') ks += 'a' - 'A';
  static const char kLetters[] = "abcdefghijklmnopqrstuvwxyz";
  static const uint8_t kLetterCodes[] = {
      0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26,
      0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d,
      0x15, 0x2c};
  if (ks >= 'a' && ks <= 'z') return kLetterCodes[strchr(kLetters, int(ks)) - kLetters];
  if (ks >= '1' && ks <= '9') return 0x02 + (ks - '1');
  if (ks >= 0xffbe && ks <= 0xffc7) return 0x3b + (ks - 0xffbe);  // F1..F10
  switch (ks) {
    case '0': case ')': return 0x0b;
    case '!': return 0x02;
    case '@': return 0x03;
    case '#': return 0x04;
    case '$': return 0x05;
    case '%': return 0x06;
    case '^': return 0x07;
    case '&': return 0x08;
    case '*': return 0x09;
    case '(': return 0x0a;
    case '-': case '_': return 0x0c;
    case '=': case '+': return 0x0d;
    case '[': case '{': return 0x1a;
    case ']': case '}': return 0x1b;
    case '\\': case '|': return 0x2b;
    case ';': case ':': return 0x27;
    case '\'': case '"': return 0x28;
    case '`': case '~': return 0x29;
    case ',': case '<': return 0x33;
    case '.': case '>': return 0x34;
    case '/': case '?': return 0x35;
    case ' ': return 0x39;
    case 0xff08: return 0x0e;  // BackSpace
    case 0xff09: return 0x0f;  // Tab
    case 0xff0d: return 0x1c;  // Return
    case 0xff8d: return 0x9c;  // KP_Enter
    case 0xff1b: return 0x01;  // Escape
    case 0xffff: return 0xd3;  // Delete
    case 0xff63: return 0xd2;  // Insert
    case 0xff50: return 0xc7;  // Home
    case 0xff57: return 0xcf;  // End
    case 0xff55: return 0xc9;  // Page_Up
    case 0xff56: return 0xd1;  // Page_Down
    case 0xff51: return 0xcb;  // Left
    case 0xff52: return 0xc8;  // Up
    case 0xff53: return 0xcd;  // Right
    case 0xff54: return 0xd0;  // Down
    case 0xffe1: return 0x2a;  // Shift_L
    case 0xffe2: return 0x36;  // Shift_R
    case 0xffe3: return 0x1d;  // Control_L
    case 0xffe4: return 0x9d;  // Control_R
    case 0xffe5: return 0x3a;  // Caps_Lock
    case 0xffe7: case 0xffeb: return 0xdb;  // Meta_L / Super_L
    case 0xffe8: case 0xffec: return 0xdc;  // Meta_R / Super_R
    case 0xffe9: return 0x38;  // Alt_L
    case 0xffea: case 0xfe03: return 0xb8;  // Alt_R / AltGr
    case 0xff7f: return 0x45;  // Num_Lock
    case 0xff14: return 0x46;  // Scroll_Lock
    case 0xff61: return 0xb7;  // Print
    case 0xff13: return 0xc6;  // Pause
    case 0xff67: return 0xdd;  // Menu
    case 0xffc8: return 0x57;  // F11
    case 0xffc9: return 0x58;  // F12
    case 0xffb0: return 0x52;  // KP_0
    case 0xffb1: return 0x4f;
    case 0xffb2: return 0x50;
    case 0xffb3: return 0x51;
    case 0xffb4: return 0x4b;
    case 0xffb5: return 0x4c;
    case 0xffb6: return 0x4d;
    case 0xffb7: return 0x47;
    case 0xffb8: return 0x48;
    case 0xffb9: return 0x49;  // KP_9
    case 0xffae: return 0x53;  // KP_Decimal
    case 0xffab: return 0x4e;  // KP_Add
    case 0xffad: return 0x4a;  // KP_Subtract
    case 0xffaa: return 0x37;  // KP_Multiply
    case 0xffaf: return 0xb5;  // KP_Divide
  }
  return 0;
}

}  // namespace

// --------------------------------------------------------------- estado EGL

struct DbusDisplay::Impl {
  DbusDisplay* owner = nullptr;

  // EGL/GLES (só na thread do display).
  int render_fd = -1;
  void* gbm_lib = nullptr;
  void* gbm_device = nullptr;
  void (*gbm_destroy)(void*) = nullptr;
  EGLDisplay dpy = EGL_NO_DISPLAY;
  EGLContext ctx = EGL_NO_CONTEXT;
  GLuint blit_program = 0;
  GLuint blit_fbo = 0;
  GLuint blit_tex = 0;
  int blit_w = 0, blit_h = 0;

  struct Image {
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint tex = 0;
    GLuint fbo = 0;  // 0 = não renderizável; usa a cópia por shader
    int width = 0, height = 0;
    uint64_t last_use = 0;
  };
  std::map<ino_t, Image> images;  // por inode do dmabuf (cache dos buffers)
  Image* current = nullptr;
  bool y0_top = true;
  uint64_t use_counter = 0;

  // Quadro (protegido por fb_mutex).
  std::mutex fb_mutex;
  std::vector<uint8_t> framebuffer;  // RGBA
  int width = 0, height = 0;
  uint64_t serial = 0;
  std::vector<uint8_t> scratch;

  // Cursor definido pelo QEMU (ARGB), quando houver.
  std::vector<uint32_t> cursor;
  int cursor_w = 0, cursor_h = 0, hot_x = 0, hot_y = 0;
  int cursor_x = 0, cursor_y = 0;
  bool cursor_on = false;

  GDBusConnection* listener_conn = nullptr;
  guint listener_reg = 0;
  bool registered = false;
  std::string error;

  bool InitEgl(const std::string& node);
  void DestroyEgl();
  void DropImage(Image& img);
  bool Import(int fd, int w, int h, int stride, uint32_t fourcc,
              uint64_t modifier, Image* out);
  bool ReadRegion(int x, int y, int w, int h);
  void Resize(int w, int h);
  void Commit();
  bool failed = false;
  void Fail(const std::string& why) {
    if (failed) return;
    failed = true;
    error = why;
    if (owner->callbacks_.on_state && !owner->active())
      owner->callbacks_.on_state(false, why);
  }
};

bool DbusDisplay::Impl::InitEgl(const std::string& node) {
  // Sem libEGL/libGLESv2 o libepoxy abortaria o processo na primeira chamada.
  for (const char* lib : {"libEGL.so.1", "libGLESv2.so.2"}) {
    void* h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
      error = std::string(lib) + " ausente";
      return false;
    }
    dlclose(h);
  }
  render_fd = open(node.c_str(), O_RDWR | O_CLOEXEC);
  if (render_fd < 0) {
    error = "não foi possível abrir " + node;
    return false;
  }
  // GBM no mesmo nó do QEMU (carregado em tempo de execução: não é
  // dependência de compilação).
  gbm_lib = dlopen("libgbm.so.1", RTLD_NOW | RTLD_LOCAL);
  if (gbm_lib) {
    auto create = reinterpret_cast<void* (*)(int)>(dlsym(gbm_lib, "gbm_create_device"));
    gbm_destroy = reinterpret_cast<void (*)(void*)>(dlsym(gbm_lib, "gbm_device_destroy"));
    if (create) gbm_device = create(render_fd);
  }
  if (gbm_device && epoxy_has_egl_extension(EGL_NO_DISPLAY, "EGL_KHR_platform_gbm")) {
    dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR, gbm_device, nullptr);
  }
  if (dpy == EGL_NO_DISPLAY &&
      epoxy_has_egl_extension(EGL_NO_DISPLAY, "EGL_EXT_platform_device")) {
    // Alternativa: dispositivo EGL cujo nó de renderização é o do QEMU.
    EGLDeviceEXT devices[16];
    EGLint n = 0;
    if (eglQueryDevicesEXT(16, devices, &n)) {
      for (EGLint i = 0; i < n && dpy == EGL_NO_DISPLAY; ++i) {
        const char* f = eglQueryDeviceStringEXT(devices[i], EGL_DRM_RENDER_NODE_FILE_EXT);
        if (f && node == f)
          dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, devices[i], nullptr);
      }
    }
  }
  if (dpy == EGL_NO_DISPLAY) {
    error = "EGL indisponível para " + node;
    return false;
  }
  if (!eglInitialize(dpy, nullptr, nullptr)) {
    error = "eglInitialize falhou";
    return false;
  }
  if (!epoxy_has_egl_extension(dpy, "EGL_EXT_image_dma_buf_import") ||
      !epoxy_has_egl_extension(dpy, "EGL_KHR_surfaceless_context")) {
    error = "o driver EGL não importa dmabuf";
    return false;
  }
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLConfig config = EGL_NO_CONFIG_KHR;
  if (!epoxy_has_egl_extension(dpy, "EGL_KHR_no_config_context") &&
      !epoxy_has_egl_extension(dpy, "EGL_MESA_configless_context")) {
    const EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                EGL_SURFACE_TYPE, 0, EGL_NONE};
    EGLint n = 0;
    eglChooseConfig(dpy, cfg_attrs, &config, 1, &n);
  }
  ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, attrs);
  if (ctx == EGL_NO_CONTEXT ||
      !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
    error = "não foi possível criar o contexto EGL";
    return false;
  }
  if (!epoxy_has_gl_extension("GL_OES_EGL_image")) {
    error = "GL_OES_EGL_image indisponível";
    return false;
  }
  glPixelStorei(GL_PACK_ALIGNMENT, 4);
  return true;
}

void DbusDisplay::Impl::DropImage(Image& img) {
  if (img.fbo) glDeleteFramebuffers(1, &img.fbo);
  if (img.tex) glDeleteTextures(1, &img.tex);
  if (img.image != EGL_NO_IMAGE_KHR) eglDestroyImageKHR(dpy, img.image);
  img = Image();
}

void DbusDisplay::Impl::DestroyEgl() {
  if (dpy != EGL_NO_DISPLAY && ctx != EGL_NO_CONTEXT) {
    for (auto& [ino, img] : images) DropImage(img);
    images.clear();
    current = nullptr;
    if (blit_fbo) glDeleteFramebuffers(1, &blit_fbo);
    if (blit_tex) glDeleteTextures(1, &blit_tex);
    if (blit_program) glDeleteProgram(blit_program);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
  }
  if (dpy != EGL_NO_DISPLAY) eglTerminate(dpy);
  if (gbm_device && gbm_destroy) gbm_destroy(gbm_device);
  if (gbm_lib) dlclose(gbm_lib);
  if (render_fd >= 0) close(render_fd);
  dpy = EGL_NO_DISPLAY;
  ctx = EGL_NO_CONTEXT;
  gbm_device = gbm_lib = nullptr;
  render_fd = -1;
}

bool DbusDisplay::Impl::Import(int fd, int w, int h, int stride,
                               uint32_t fourcc, uint64_t modifier,
                               Image* out) {
  EGLint attrs[32];
  int i = 0;
  attrs[i++] = EGL_WIDTH;
  attrs[i++] = w;
  attrs[i++] = EGL_HEIGHT;
  attrs[i++] = h;
  attrs[i++] = EGL_LINUX_DRM_FOURCC_EXT;
  attrs[i++] = EGLint(fourcc);
  attrs[i++] = EGL_DMA_BUF_PLANE0_FD_EXT;
  attrs[i++] = fd;
  attrs[i++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT;
  attrs[i++] = 0;
  attrs[i++] = EGL_DMA_BUF_PLANE0_PITCH_EXT;
  attrs[i++] = stride;
  if (modifier != kModInvalid &&
      epoxy_has_egl_extension(dpy, "EGL_EXT_image_dma_buf_import_modifiers")) {
    attrs[i++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
    attrs[i++] = EGLint(modifier & 0xffffffff);
    attrs[i++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
    attrs[i++] = EGLint(modifier >> 32);
  }
  attrs[i++] = EGL_NONE;
  out->image = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
                                 nullptr, attrs);
  if (out->image == EGL_NO_IMAGE_KHR) return false;
  glGenTextures(1, &out->tex);
  glBindTexture(GL_TEXTURE_2D, out->tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, out->image);
  glGenFramebuffers(1, &out->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, out->fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         out->tex, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    // Formato não renderizável neste driver: lê por uma cópia em shader.
    glDeleteFramebuffers(1, &out->fbo);
    out->fbo = 0;
  }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  out->width = w;
  out->height = h;
  return true;
}

namespace {

GLuint CompileBlitProgram() {
  static const char* vs =
      "attribute vec2 p; varying vec2 t;"
      "void main(){ t = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }";
  static const char* fs =
      "precision mediump float; varying vec2 t; uniform sampler2D s;"
      "void main(){ gl_FragColor = vec4(texture2D(s, t).rgb, 1.0); }";
  auto compile = [](GLenum type, const char* src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    return sh;
  };
  GLuint prog = glCreateProgram();
  GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
  glAttachShader(prog, v);
  glAttachShader(prog, f);
  glBindAttribLocation(prog, 0, "p");
  glLinkProgram(prog);
  glDeleteShader(v);
  glDeleteShader(f);
  GLint ok = 0;
  glGetProgramiv(prog, GL_LINK_STATUS, &ok);
  if (!ok) {
    glDeleteProgram(prog);
    return 0;
  }
  return prog;
}

}  // namespace

// Lê a região (x, y, w, h) — coordenadas da tela, origem no topo — do buffer
// atual para o framebuffer RGBA.
bool DbusDisplay::Impl::ReadRegion(int x, int y, int w, int h) {
  Image* img = current;
  if (!img) return false;
  const int W = img->width, H = img->height;
  x = std::clamp(x, 0, W);
  y = std::clamp(y, 0, H);
  w = std::clamp(w, 0, W - x);
  h = std::clamp(h, 0, H - y);
  if (w == 0 || h == 0) return true;
  GLuint fbo = img->fbo;
  if (!fbo) {
    // Copia o buffer inteiro para uma textura RGBA renderizável.
    if (!blit_program && !(blit_program = CompileBlitProgram())) return false;
    if (!blit_tex || blit_w != W || blit_h != H) {
      if (!blit_tex) glGenTextures(1, &blit_tex);
      glBindTexture(GL_TEXTURE_2D, blit_tex);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, nullptr);
      if (!blit_fbo) glGenFramebuffers(1, &blit_fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, blit_fbo);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_TEXTURE_2D, blit_tex, 0);
      blit_w = W;
      blit_h = H;
    }
    static const GLfloat quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    glBindFramebuffer(GL_FRAMEBUFFER, blit_fbo);
    glViewport(0, 0, W, H);
    glUseProgram(blit_program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, img->tex);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
    glEnableVertexAttribArray(0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    fbo = blit_fbo;
  }
  // Convenção do QEMU (ver o gtk-egl dele, que inverte quando !y0_top):
  // y0_top=false => a linha 0 da memória do dmabuf é o topo da tela;
  // y0_top=true => a imagem está de baixo para cima.
  const bool top_first = !y0_top;
  const int ry = top_first ? y : H - y - h;
  scratch.resize(size_t(w) * h * 4);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glReadPixels(x, ry, w, h, GL_RGBA, GL_UNSIGNED_BYTE, scratch.data());
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  std::lock_guard<std::mutex> lock(fb_mutex);
  if (width != W || height != H) return true;
  const size_t row = size_t(w) * 4;
  for (int r = 0; r < h; ++r) {
    const uint8_t* src = &scratch[size_t(top_first ? r : h - 1 - r) * row];
    uint8_t* dst = &framebuffer[(size_t(y + r) * W + x) * 4];
    memcpy(dst, src, row);
    for (size_t a = 3; a < row; a += 4) dst[a] = 0xff;
  }
  return true;
}

void DbusDisplay::Impl::Resize(int w, int h) {
  {
    std::lock_guard<std::mutex> lock(fb_mutex);
    if (w == width && h == height) return;
    framebuffer.assign(size_t(w) * h * 4, 0);
    for (size_t i = 3; i < framebuffer.size(); i += 4) framebuffer[i] = 0xff;
    width = w;
    height = h;
    serial++;
  }
  if (owner->callbacks_.on_resize) owner->callbacks_.on_resize(w, h);
}

void DbusDisplay::Impl::Commit() {
  {
    std::lock_guard<std::mutex> lock(fb_mutex);
    serial++;
  }
  // Diagnóstico: SECADA_DISPLAY_STATS=1 imprime quadros/s a cada 5 s.
  static const bool stats = getenv("SECADA_DISPLAY_STATS") != nullptr;
  if (stats) {
    static int frames = 0;
    static auto since = std::chrono::steady_clock::now();
    ++frames;
    auto now = std::chrono::steady_clock::now();
    double secs = std::chrono::duration<double>(now - since).count();
    if (secs >= 5) {
      fprintf(stderr, "secada: display D-Bus %.1f quadros/s\n", frames / secs);
      frames = 0;
      since = now;
    }
  }
  if (!owner->active_.exchange(true) && owner->callbacks_.on_state)
    owner->callbacks_.on_state(true, "");
  if (owner->callbacks_.on_frame) owner->callbacks_.on_frame();
}

// ------------------------------------------------------- métodos do Listener

namespace {

void CopyPixman(const uint8_t* src, int stride, uint32_t format, int w, int h,
                uint8_t* dst, int dst_stride) {
  const bool bgr = format == kPixmanX8R8G8B8 || format == kPixmanA8R8G8B8;
  for (int r = 0; r < h; ++r) {
    const uint8_t* s = src + size_t(r) * stride;
    uint8_t* d = dst + size_t(r) * dst_stride;
    for (int c = 0; c < w; ++c, s += 4, d += 4) {
      d[0] = bgr ? s[2] : s[0];
      d[1] = s[1];
      d[2] = bgr ? s[0] : s[2];
      d[3] = 0xff;
    }
  }
}

void ListenerMethod(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                    const gchar* method, GVariant* params,
                    GDBusMethodInvocation* invocation, gpointer user_data) {
  auto* d = static_cast<DbusDisplay::Impl*>(user_data);
  if (g_str_equal(method, "ScanoutDMABUF")) {
    gint32 handle;
    guint32 w, h, stride, fourcc;
    guint64 modifier;
    gboolean y0_top;
    g_variant_get(params, "(huuuutb)", &handle, &w, &h, &stride, &fourcc,
                  &modifier, &y0_top);
    GDBusMessage* msg = g_dbus_method_invocation_get_message(invocation);
    GUnixFDList* fds = g_dbus_message_get_unix_fd_list(msg);
    int fd = fds ? g_unix_fd_list_get(fds, handle, nullptr) : -1;
    if (fd >= 0) {
      struct stat st;
      ino_t ino = fstat(fd, &st) == 0 ? st.st_ino : 0;
      auto it = d->images.find(ino);
      if (it != d->images.end() &&
          (it->second.width != int(w) || it->second.height != int(h))) {
        if (d->current == &it->second) d->current = nullptr;
        d->DropImage(it->second);
        d->images.erase(it);
        it = d->images.end();
      }
      if (it == d->images.end()) {
        DbusDisplay::Impl::Image img;
        if (d->Import(fd, int(w), int(h), int(stride), fourcc, modifier, &img)) {
          // Mantém poucos buffers (o Android alterna entre 2 ou 3).
          if (d->images.size() >= 6) {
            auto oldest = std::min_element(
                d->images.begin(), d->images.end(), [](auto& a, auto& b) {
                  return a.second.last_use < b.second.last_use;
                });
            if (d->current == &oldest->second) d->current = nullptr;
            d->DropImage(oldest->second);
            d->images.erase(oldest);
          }
          it = d->images.emplace(ino, img).first;
        } else {
          d->Fail("falha ao importar o dmabuf (eglCreateImage)");
        }
      }
      close(fd);
      if (it != d->images.end()) {
        it->second.last_use = ++d->use_counter;
        d->current = &it->second;
        d->y0_top = y0_top;
        d->Resize(int(w), int(h));
      }
    }
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_str_equal(method, "UpdateDMABUF")) {
    gint32 x, y, w, h;
    g_variant_get(params, "(iiii)", &x, &y, &w, &h);
    if (d->ReadRegion(x, y, w, h)) d->Commit();
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_str_equal(method, "Scanout") || g_str_equal(method, "Update")) {
    const bool full = g_str_equal(method, "Scanout");
    gint32 x = 0, y = 0, w, h;
    guint32 stride, format;
    GVariant* data = nullptr;
    if (full) {
      guint32 uw, uh;
      g_variant_get(params, "(uuuu@ay)", &uw, &uh, &stride, &format, &data);
      w = gint32(uw);
      h = gint32(uh);
      d->current = nullptr;
      d->Resize(w, h);
    } else {
      g_variant_get(params, "(iiiiuu@ay)", &x, &y, &w, &h, &stride, &format, &data);
    }
    gsize len = 0;
    const auto* bytes = static_cast<const uint8_t*>(
        g_variant_get_fixed_array(data, &len, 1));
    const bool known = format == kPixmanX8R8G8B8 || format == kPixmanA8R8G8B8 ||
                       format == kPixmanX8B8G8R8 || format == kPixmanA8B8G8R8;
    {
      std::lock_guard<std::mutex> lock(d->fb_mutex);
      if (known && x >= 0 && y >= 0 && x + w <= d->width && y + h <= d->height &&
          len >= size_t(stride) * (h > 0 ? h - 1 : 0) + size_t(w) * 4) {
        CopyPixman(bytes, int(stride), format, w, h,
                   &d->framebuffer[(size_t(y) * d->width + x) * 4], d->width * 4);
      }
    }
    g_variant_unref(data);
    d->Commit();
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_str_equal(method, "Disable")) {
    d->current = nullptr;
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_str_equal(method, "MouseSet")) {
    gint32 x, y, on;
    g_variant_get(params, "(iii)", &x, &y, &on);
    {
      std::lock_guard<std::mutex> lock(d->fb_mutex);
      d->cursor_x = x;
      d->cursor_y = y;
      d->cursor_on = on != 0;
    }
    if (!d->cursor.empty()) d->Commit();
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else if (g_str_equal(method, "CursorDefine")) {
    gint32 w, h, hx, hy;
    GVariant* data = nullptr;
    g_variant_get(params, "(iiii@ay)", &w, &h, &hx, &hy, &data);
    gsize len = 0;
    const void* bytes = g_variant_get_fixed_array(data, &len, 1);
    {
      std::lock_guard<std::mutex> lock(d->fb_mutex);
      if (w > 0 && h > 0 && w <= 256 && h <= 256 && len >= size_t(w) * h * 4) {
        d->cursor.assign(size_t(w) * h, 0);
        memcpy(d->cursor.data(), bytes, size_t(w) * h * 4);
        d->cursor_w = w;
        d->cursor_h = h;
        d->hot_x = hx;
        d->hot_y = hy;
      } else {
        d->cursor.clear();
      }
    }
    g_variant_unref(data);
    g_dbus_method_invocation_return_value(invocation, nullptr);
  } else {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "método desconhecido");
  }
}

GVariant* ListenerProperty(GDBusConnection*, const gchar*, const gchar*,
                           const gchar*, const gchar* name, GError** error,
                           gpointer) {
  if (g_str_equal(name, "Interfaces")) return g_variant_new_strv(nullptr, 0);
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "%s", name);
  return nullptr;
}

const GDBusInterfaceVTable kListenerVTable = {ListenerMethod, ListenerProperty,
                                              nullptr, {}};

GDBusConnection* ConnectionOnFd(int fd, GDBusConnectionFlags flags,
                                GError** err) {
  GSocket* sock = g_socket_new_from_fd(fd, err);
  if (!sock) return nullptr;
  GSocketConnection* sc = g_socket_connection_factory_create_connection(sock);
  g_object_unref(sock);
  GDBusConnection* conn = g_dbus_connection_new_sync(
      G_IO_STREAM(sc), nullptr,
      GDBusConnectionFlags(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | flags),
      nullptr, nullptr, err);
  g_object_unref(sc);
  return conn;
}

}  // namespace

// ------------------------------------------------------------------ DbusDisplay

DbusDisplay::DbusDisplay(Callbacks callbacks)
    : callbacks_(std::move(callbacks)), impl_(std::make_unique<Impl>()) {
  impl_->owner = this;
}

DbusDisplay::~DbusDisplay() { Stop(); }

void DbusDisplay::Start(const std::string& qmp_socket,
                        const std::string& render_node, int timeout_ms) {
  Stop();
  stop_ = false;
  thread_ = std::thread(&DbusDisplay::Run, this, qmp_socket, render_node,
                        timeout_ms);
}

void DbusDisplay::Stop() {
  stop_ = true;
  {
    std::lock_guard<std::mutex> lock(conn_mutex_);
    if (loop_) g_main_loop_quit(static_cast<GMainLoop*>(loop_));
  }
  if (thread_.joinable()) thread_.join();
}

void DbusDisplay::Run(std::string qmp_socket, std::string render_node,
                      int timeout_ms) {
  Impl* d = impl_.get();
  auto fail = [d](const std::string& why) { d->Fail(why); };

  if (!d->InitEgl(render_node)) {
    fail(d->error);
    d->DestroyEgl();
    return;
  }

  // 1. Conexão D-Bus ponto a ponto entregue ao QEMU pelo QMP dedicado.
  int qmp = ConnectUnix(qmp_socket, timeout_ms, stop_);
  int pair[2] = {-1, -1};
  std::string err;
  if (qmp < 0) {
    fail("QMP do display indisponível");
  } else if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) {
    fail("socketpair falhou");
  } else {
    std::string greeting;
    char c;
    while (recv(qmp, &c, 1, 0) == 1 && c != '\n') greeting.push_back(c);
    if (!QmpCommand(qmp, R"({"execute":"qmp_capabilities"})", -1, &err) ||
        !QmpCommand(qmp, R"({"execute":"getfd","arguments":{"fdname":"secadadbus"}})",
                    pair[1], &err) ||
        !QmpCommand(qmp,
                    R"({"execute":"add_client","arguments":{"protocol":"@dbus-display","fdname":"secadadbus"}})",
                    -1, &err)) {
      fail(err);
    }
  }
  if (qmp >= 0) close(qmp);
  if (pair[1] >= 0) close(pair[1]);
  if (d->failed) {
    if (pair[0] >= 0) close(pair[0]);
    d->DestroyEgl();
    return;
  }

  GMainContext* ctx = g_main_context_new();
  g_main_context_push_thread_default(ctx);
  GMainLoop* loop = g_main_loop_new(ctx, FALSE);
  GError* gerr = nullptr;
  GDBusConnection* conn = ConnectionOnFd(pair[0], G_DBUS_CONNECTION_FLAGS_NONE, &gerr);

  // 2. Listener: o QEMU recebe a outra ponta em RegisterListener e chama os
  // métodos de /org/qemu/Display1/Listener nesta thread.
  int lpair[2] = {-1, -1};
  GDBusNodeInfo* info = g_dbus_node_info_new_for_xml(kListenerXml, nullptr);
  if (conn && socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, lpair) == 0) {
    GUnixFDList* fdl = g_unix_fd_list_new();
    g_unix_fd_list_append(fdl, lpair[1], nullptr);
    close(lpair[1]);
    g_dbus_connection_call_with_unix_fd_list(
        conn, nullptr, kConsolePath, "org.qemu.Display1.Console",
        "RegisterListener", g_variant_new("(h)", 0), nullptr,
        G_DBUS_CALL_FLAGS_NONE, -1, fdl, nullptr,
        [](GObject* src, GAsyncResult* res, gpointer data) {
          auto* impl = static_cast<Impl*>(data);
          GError* e = nullptr;
          GVariant* r = g_dbus_connection_call_with_unix_fd_list_finish(
              G_DBUS_CONNECTION(src), nullptr, res, &e);
          if (r) {
            impl->registered = true;
            g_variant_unref(r);
          } else {
            impl->Fail(std::string("RegisterListener: ") + e->message);
            g_error_free(e);
          }
        },
        d);
    g_object_unref(fdl);
    d->listener_conn = ConnectionOnFd(
        lpair[0], G_DBUS_CONNECTION_FLAGS_DELAY_MESSAGE_PROCESSING, &gerr);
    if (d->listener_conn) {
      d->listener_reg = g_dbus_connection_register_object(
          d->listener_conn, kListenerPath, info->interfaces[0],
          &kListenerVTable, d, nullptr, &gerr);
      g_dbus_connection_start_message_processing(d->listener_conn);
    }
  }
  if (!conn || !d->listener_conn || !d->listener_reg) {
    fail(std::string("D-Bus: ") + (gerr ? gerr->message : "conexão falhou"));
  } else {
    {
      std::lock_guard<std::mutex> lock(conn_mutex_);
      conn_ = conn;
      context_ = ctx;
      loop_ = loop;
    }
    // Verifica |stop_| periodicamente: um g_main_loop_quit() chamado antes
    // de o laço começar seria perdido.
    GSource* tick = g_timeout_source_new(100);
    g_source_set_callback(
        tick,
        [](gpointer data) -> gboolean {
          auto* self = static_cast<DbusDisplay*>(data);
          if (self->stop_) g_main_loop_quit(static_cast<GMainLoop*>(self->loop_));
          return G_SOURCE_CONTINUE;
        },
        this, nullptr);
    g_source_attach(tick, ctx);
    g_source_unref(tick);
    if (!stop_) g_main_loop_run(loop);
    std::lock_guard<std::mutex> lock(conn_mutex_);
    conn_ = nullptr;
    context_ = nullptr;
    loop_ = nullptr;
  }
  if (gerr) g_error_free(gerr);

  if (d->listener_conn) {
    if (d->listener_reg)
      g_dbus_connection_unregister_object(d->listener_conn, d->listener_reg);
    g_dbus_connection_close_sync(d->listener_conn, nullptr, nullptr);
    g_object_unref(d->listener_conn);
    d->listener_conn = nullptr;
  }
  if (conn) {
    g_dbus_connection_close_sync(conn, nullptr, nullptr);
    g_object_unref(conn);
  }
  g_dbus_node_info_unref(info);
  while (g_main_context_iteration(ctx, FALSE)) {
  }
  g_main_loop_unref(loop);
  g_main_context_pop_thread_default(ctx);
  g_main_context_unref(ctx);
  d->DestroyEgl();
}

bool DbusDisplay::CopyFrameIfNewer(std::vector<uint8_t>* out, uint32_t* width,
                                   uint32_t* height, uint64_t* serial) {
  Impl* d = impl_.get();
  std::lock_guard<std::mutex> lock(d->fb_mutex);
  if (d->serial == *serial || d->framebuffer.empty()) return false;
  *out = d->framebuffer;
  *width = uint32_t(d->width);
  *height = uint32_t(d->height);
  *serial = d->serial;
  // Cursor definido pelo QEMU (quando o convidado usa plano de cursor).
  if (d->cursor_on && !d->cursor.empty()) {
    for (int cy = 0; cy < d->cursor_h; ++cy) {
      int py = d->cursor_y - d->hot_y + cy;
      if (py < 0 || py >= d->height) continue;
      for (int cx = 0; cx < d->cursor_w; ++cx) {
        int px = d->cursor_x - d->hot_x + cx;
        if (px < 0 || px >= d->width) continue;
        uint32_t argb = d->cursor[size_t(cy) * d->cursor_w + cx];
        uint32_t a = argb >> 24;
        if (!a) continue;
        uint8_t* o = &(*out)[(size_t(py) * d->width + px) * 4];
        const uint32_t rgb[3] = {(argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff};
        for (int k = 0; k < 3; ++k) o[k] = uint8_t((rgb[k] * a + o[k] * (255 - a)) / 255);
      }
    }
  }
  return true;
}

// -------------------------------------------------------------------- entrada

void DbusDisplay::CallConsole(const char* iface, const char* method,
                              void* params) {
  std::lock_guard<std::mutex> lock(conn_mutex_);
  auto* v = static_cast<GVariant*>(params);
  if (!conn_) {
    g_variant_unref(g_variant_ref_sink(v));
    return;
  }
  // Assíncrono e na ordem de envio (mesma conexão).
  g_dbus_connection_call(static_cast<GDBusConnection*>(conn_), nullptr,
                         kConsolePath, iface, method, v, nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
}

void DbusDisplay::SendPointer(int x, int y, uint8_t button_mask) {
  x = std::max(0, x);
  y = std::max(0, y);
  if (x != last_x_ || y != last_y_) {
    CallConsole("org.qemu.Display1.Mouse", "SetAbsPosition",
                g_variant_new("(uu)", guint32(x), guint32(y)));
    last_x_ = x;
    last_y_ = y;
  }
  // Bits RFB -> botões do QEMU (0 esquerdo, 1 meio, 2 direito, 3/4 roda).
  uint8_t changed = button_mask ^ last_buttons_;
  for (int b = 0; b < 5; ++b) {
    if (!(changed & (1 << b))) continue;
    CallConsole("org.qemu.Display1.Mouse",
                (button_mask & (1 << b)) ? "Press" : "Release",
                g_variant_new("(u)", guint32(b)));
  }
  last_buttons_ = button_mask;
}

void DbusDisplay::SendKeysym(uint32_t keysym, bool down) {
  uint32_t sc = KeysymToScancode(keysym);
  if (sc) SendScancode(sc, down);
}

void DbusDisplay::SendScancode(uint32_t scancode, bool down) {
  CallConsole("org.qemu.Display1.Keyboard", down ? "Press" : "Release",
              g_variant_new("(u)", scancode));
}

}  // namespace secada
