#include "secada_plugin.h"

#include <glib-unix.h>
#include <gtk/gtk.h>
#include <signal.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "dbus_display.h"
#include "display_texture.h"
#include "host_probe.h"
#include "rfb_client.h"
#include "vm_process.h"

namespace {

constexpr char kChannelName[] = "dev.secada/core";

struct Plugin {
  FlPluginRegistrar* registrar = nullptr;
  FlTextureRegistrar* texture_registrar = nullptr;
  FlMethodChannel* channel = nullptr;
  GtkWindow* window = nullptr;
  secada::VmProcess vm;

  std::shared_ptr<secada::RfbClient> rfb;
  // Display D-Bus (VirGL): quando ativo, fornece a imagem e recebe a entrada;
  // o RFB fica de reserva.
  std::shared_ptr<secada::DbusDisplay> dbus;
  SecadaDisplayTexture* texture = nullptr;
  // Incrementado a cada conexão de display; eventos de clientes antigos que
  // chegarem atrasados à thread principal são descartados.
  std::atomic<uint64_t> display_generation{0};
  std::atomic<bool> frame_pending{false};

  // Arquivos a instalar recebidos antes de a interface Dart estar pronta.
  std::vector<std::string> pending_open;
  bool dart_ready = false;

  bool allow_close = false;
  bool fullscreen = false;
  bool maximized = false;
};

Plugin* g_plugin = nullptr;  // Vive durante todo o processo.

// Fonte da textura: o display D-Bus quando ativo; senão, o RFB.
class DisplaySources : public secada::FrameSource {
 public:
  DisplaySources(std::shared_ptr<secada::RfbClient> rfb,
                 std::shared_ptr<secada::DbusDisplay> dbus)
      : rfb_(std::move(rfb)), dbus_(std::move(dbus)) {}

  bool CopyFrame(std::vector<uint8_t>* out, uint32_t* width,
                 uint32_t* height) override {
    if (dbus_ && dbus_->active())
      return dbus_->CopyFrameIfNewer(out, width, height, &dbus_serial_);
    return rfb_ && rfb_->CopyFrameIfNewer(out, width, height, &rfb_serial_);
  }

 private:
  std::shared_ptr<secada::RfbClient> rfb_;
  std::shared_ptr<secada::DbusDisplay> dbus_;
  uint64_t rfb_serial_ = 0;
  uint64_t dbus_serial_ = 0;
};

bool DbusActive(Plugin* p) { return p->dbus && p->dbus->active(); }

void SendEvent(Plugin* p, FlValue* event) {
  fl_method_channel_invoke_method(p->channel, "onEvent", event, nullptr,
                                  nullptr, nullptr);
  fl_value_unref(event);
}

FlValue* MakeEvent(const char* type) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "type", fl_value_new_string(type));
  return map;
}

// ---------------------------------------------------------------- utilidades

const char* GetString(FlValue* args, const char* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(v);
}

int64_t GetInt(FlValue* args, const char* key, int64_t fallback) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
    return int64_t(fl_value_get_float(v));
  return fallback;
}

bool GetBool(FlValue* args, const char* key, bool fallback) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_BOOL) return fallback;
  return fl_value_get_bool(v);
}

FlMethodResponse* Error(const char* code, const std::string& message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message.c_str(), nullptr));
}

FlMethodResponse* Success(FlValue* value) {
  FlMethodResponse* r =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  if (value) fl_value_unref(value);
  return r;
}

// ------------------------------------------------------------ abrir arquivos

FlValue* TakePendingOpen(Plugin* p) {
  FlValue* list = fl_value_new_list();
  for (const std::string& path : p->pending_open) {
    fl_value_append_take(list, fl_value_new_string(path.c_str()));
  }
  p->pending_open.clear();
  return list;
}

void FlushOpenFiles(Plugin* p) {
  if (p->pending_open.empty()) return;
  FlValue* e = MakeEvent("openFiles");
  fl_value_set_string_take(e, "paths", TakePendingOpen(p));
  SendEvent(p, e);
}

// ------------------------------------------------------------------- host/vm

FlMethodResponse* HandleProbeHost() {
  secada::HostInfo h = secada::ProbeHost();
  FlValue* m = fl_value_new_map();
  fl_value_set_string_take(m, "kvmPresent", fl_value_new_bool(h.kvm_present));
  fl_value_set_string_take(m, "kvmAccessible",
                           fl_value_new_bool(h.kvm_accessible));
  fl_value_set_string_take(m, "kvmApiVersion",
                           fl_value_new_int(h.kvm_api_version));
  fl_value_set_string_take(m, "kvmError",
                           fl_value_new_string(h.kvm_error.c_str()));
  fl_value_set_string_take(m, "cpuModel",
                           fl_value_new_string(h.cpu_model.c_str()));
  fl_value_set_string_take(m, "cpuVendor",
                           fl_value_new_string(h.cpu_vendor.c_str()));
  fl_value_set_string_take(m, "cpuVirtFlag", fl_value_new_bool(h.cpu_virt_flag));
  fl_value_set_string_take(m, "logicalCpus", fl_value_new_int(h.logical_cpus));
  fl_value_set_string_take(m, "memTotalMb", fl_value_new_int(h.mem_total_mb));
  fl_value_set_string_take(m, "memAvailableMb",
                           fl_value_new_int(h.mem_available_mb));
  return Success(m);
}

FlMethodResponse* HandleVmStart(Plugin* p, FlValue* args) {
  FlValue* argv_v = fl_value_lookup_string(args, "argv");
  const char* log_path = GetString(args, "logPath");
  if (!argv_v || fl_value_get_type(argv_v) != FL_VALUE_TYPE_LIST || !log_path) {
    return Error("bad_args", "argv/logPath ausentes");
  }
  std::vector<std::string> argv;
  for (size_t i = 0; i < fl_value_get_length(argv_v); ++i) {
    FlValue* item = fl_value_get_list_value(argv_v, i);
    if (fl_value_get_type(item) != FL_VALUE_TYPE_STRING)
      return Error("bad_args", "argv deve conter strings");
    argv.emplace_back(fl_value_get_string(item));
  }
  std::vector<std::pair<std::string, std::string>> env;
  FlValue* env_v = fl_value_lookup_string(args, "env");
  if (env_v && fl_value_get_type(env_v) == FL_VALUE_TYPE_MAP) {
    for (size_t i = 0; i < fl_value_get_length(env_v); ++i) {
      FlValue* k = fl_value_get_map_key(env_v, i);
      FlValue* v = fl_value_get_map_value(env_v, i);
      if (fl_value_get_type(k) == FL_VALUE_TYPE_STRING &&
          fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
        env.emplace_back(fl_value_get_string(k), fl_value_get_string(v));
      }
    }
  }
  std::string error;
  if (!p->vm.Start(argv, env, log_path, &error)) {
    return Error("vm_start_failed", error);
  }
  return Success(fl_value_new_int(p->vm.pid()));
}

void OnVmExit(int code, bool signaled, int signal_number) {
  Plugin* p = g_plugin;
  if (!p) return;
  FlValue* e = MakeEvent("vmExit");
  fl_value_set_string_take(e, "code", fl_value_new_int(code));
  fl_value_set_string_take(e, "signaled", fl_value_new_bool(signaled));
  fl_value_set_string_take(e, "signal", fl_value_new_int(signal_number));
  SendEvent(p, e);
}

// ------------------------------------------------------------------- display

struct DisplayMsg {
  uint64_t generation;
  std::string kind;  // "state" | "size" | "backend"
  std::string state;
  std::string detail;
  int width = 0;
  int height = 0;
  bool from_dbus = false;
};

gboolean DeliverDisplayMsg(gpointer data) {
  std::unique_ptr<DisplayMsg> msg(static_cast<DisplayMsg*>(data));
  Plugin* p = g_plugin;
  if (!p || msg->generation != p->display_generation.load())
    return G_SOURCE_REMOVE;
  if (msg->kind == "size") {
    // Com o display D-Bus ativo, o tamanho vem dele (o do VNC é reserva).
    if (!msg->from_dbus && DbusActive(p)) return G_SOURCE_REMOVE;
    FlValue* e = MakeEvent("displaySize");
    fl_value_set_string_take(e, "width", fl_value_new_int(msg->width));
    fl_value_set_string_take(e, "height", fl_value_new_int(msg->height));
    SendEvent(p, e);
  } else if (msg->kind == "backend") {
    FlValue* e = MakeEvent("displayBackend");
    fl_value_set_string_take(e, "state",
                             fl_value_new_string(msg->state.c_str()));
    fl_value_set_string_take(e, "detail",
                             fl_value_new_string(msg->detail.c_str()));
    SendEvent(p, e);
  } else {
    FlValue* e = MakeEvent("display");
    fl_value_set_string_take(e, "state",
                             fl_value_new_string(msg->state.c_str()));
    fl_value_set_string_take(e, "detail",
                             fl_value_new_string(msg->detail.c_str()));
    SendEvent(p, e);
  }
  return G_SOURCE_REMOVE;
}

gboolean DeliverFrame(gpointer data) {
  Plugin* p = g_plugin;
  if (!p) return G_SOURCE_REMOVE;
  p->frame_pending = false;
  if (p->texture) {
    fl_texture_registrar_mark_texture_frame_available(
        p->texture_registrar, FL_TEXTURE(p->texture));
  }
  return G_SOURCE_REMOVE;
}

void PostDisplayMsg(DisplayMsg* msg) {
  g_main_context_invoke_full(nullptr, G_PRIORITY_DEFAULT, DeliverDisplayMsg,
                             msg, nullptr);
}

void DisconnectDisplay(Plugin* p) {
  p->display_generation++;
  if (p->dbus) {
    p->dbus->Stop();
    p->dbus.reset();
  }
  if (p->rfb) {
    p->rfb->Stop();
    p->rfb.reset();
  }
  if (p->texture) {
    fl_texture_registrar_unregister_texture(p->texture_registrar,
                                            FL_TEXTURE(p->texture));
    g_object_unref(p->texture);
    p->texture = nullptr;
  }
}

FlMethodResponse* HandleDisplayConnect(Plugin* p, FlValue* args) {
  const char* path = GetString(args, "socketPath");
  if (!path) return Error("bad_args", "socketPath ausente");
  int timeout_ms = int(GetInt(args, "timeoutMs", 20000));
  DisconnectDisplay(p);
  const uint64_t gen = p->display_generation.load();

  secada::RfbClient::Callbacks cb;
  cb.on_frame = []() {
    Plugin* pl = g_plugin;
    if (!pl || pl->frame_pending.exchange(true)) return;
    g_main_context_invoke_full(nullptr, G_PRIORITY_HIGH_IDLE, DeliverFrame,
                               nullptr, nullptr);
  };
  cb.on_resize = [gen](int w, int h) {
    auto* m = new DisplayMsg{gen, "size", "", "", w, h};
    PostDisplayMsg(m);
  };
  cb.on_state = [gen](secada::RfbClient::State s, const std::string& detail) {
    const char* name = "disconnected";
    switch (s) {
      case secada::RfbClient::State::kConnecting:
        name = "connecting";
        break;
      case secada::RfbClient::State::kConnected:
        name = "connected";
        break;
      case secada::RfbClient::State::kDisconnected:
        name = "disconnected";
        break;
      case secada::RfbClient::State::kFailed:
        name = "failed";
        break;
    }
    auto* m = new DisplayMsg{gen, "state", name, detail, 0, 0};
    PostDisplayMsg(m);
  };

  p->rfb = std::make_shared<secada::RfbClient>(std::move(cb));

  // Display D-Bus (VirGL): QMP dedicado + nó de renderização do QEMU.
  const char* dbus_qmp = GetString(args, "dbusQmpSocket");
  const char* render_node = GetString(args, "renderNode");
  if (dbus_qmp && *dbus_qmp && render_node && *render_node) {
    secada::DbusDisplay::Callbacks dcb;
    dcb.on_frame = []() {
      Plugin* pl = g_plugin;
      if (!pl || pl->frame_pending.exchange(true)) return;
      g_main_context_invoke_full(nullptr, G_PRIORITY_HIGH_IDLE, DeliverFrame,
                                 nullptr, nullptr);
    };
    dcb.on_resize = [gen](int w, int h) {
      auto* m = new DisplayMsg{gen, "size", "", "", w, h, true};
      PostDisplayMsg(m);
    };
    std::weak_ptr<secada::RfbClient> weak_rfb = p->rfb;
    dcb.on_state = [gen, weak_rfb](bool ok, const std::string& detail) {
      // Ativo: o VNC para de pedir quadros (só reserva).
      if (ok) {
        if (auto r = weak_rfb.lock()) r->SetUpdatesEnabled(false);
      }
      auto* m = new DisplayMsg{gen, "backend", ok ? "dbus" : "failed", detail};
      PostDisplayMsg(m);
    };
    p->dbus = std::make_shared<secada::DbusDisplay>(std::move(dcb));
  }

  p->texture = secada_display_texture_new(
      std::make_shared<DisplaySources>(p->rfb, p->dbus));
  fl_texture_registrar_register_texture(p->texture_registrar,
                                        FL_TEXTURE(p->texture));
  p->rfb->Start(path, timeout_ms, GetBool(args, "swapRedBlue", false));
  if (p->dbus) p->dbus->Start(dbus_qmp, render_node, timeout_ms);
  return Success(fl_value_new_int(fl_texture_get_id(FL_TEXTURE(p->texture))));
}

// -------------------------------------------------------------------- janela

void EmitWindowState(Plugin* p) {
  FlValue* e = MakeEvent("window");
  fl_value_set_string_take(e, "maximized", fl_value_new_bool(p->maximized));
  fl_value_set_string_take(e, "fullscreen", fl_value_new_bool(p->fullscreen));
  SendEvent(p, e);
}

gboolean OnWindowState(GtkWidget*, GdkEventWindowState* event, gpointer) {
  Plugin* p = g_plugin;
  if (!p) return FALSE;
  p->maximized = event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED;
  p->fullscreen = event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN;
  EmitWindowState(p);
  return FALSE;
}

gboolean OnDeleteEvent(GtkWidget*, GdkEvent*, gpointer) {
  Plugin* p = g_plugin;
  if (!p || p->allow_close) return FALSE;
  // Delega ao Dart: ele desliga a VM com segurança e então chama window.close.
  SendEvent(p, MakeEvent("closeRequested"));
  return TRUE;
}

gboolean OnUnixSignal(gpointer) {
  static int count = 0;
  Plugin* p = g_plugin;
  if (!p) return G_SOURCE_CONTINUE;
  if (++count > 1) {
    // Segundo sinal: encerramento imediato (QEMU recebe SIGTERM e grava os
    // discos antes de sair).
    DisconnectDisplay(p);
    p->vm.TerminateBlocking(10000);
    exit(130);
  }
  FlValue* e = MakeEvent("closeRequested");
  fl_value_set_string_take(e, "fromSignal", fl_value_new_bool(true));
  SendEvent(p, e);
  return G_SOURCE_CONTINUE;
}

bool PointerRoot(Plugin* p, gint* x, gint* y) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(p->window));
  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  if (!pointer) return false;
  gdk_device_get_position(pointer, nullptr, x, y);
  return true;
}

FlMethodResponse* HandleWindow(Plugin* p, const gchar* method, FlValue* args) {
  GtkWindow* w = p->window;
  if (!w) return Error("no_window", "janela indisponível");
  if (g_str_equal(method, "window.minimize")) {
    gtk_window_iconify(w);
  } else if (g_str_equal(method, "window.toggleMaximize")) {
    if (p->maximized)
      gtk_window_unmaximize(w);
    else
      gtk_window_maximize(w);
  } else if (g_str_equal(method, "window.setFullscreen")) {
    if (GetBool(args, "value", false))
      gtk_window_fullscreen(w);
    else
      gtk_window_unfullscreen(w);
  } else if (g_str_equal(method, "window.startDrag")) {
    gint x, y;
    if (PointerRoot(p, &x, &y))
      gtk_window_begin_move_drag(w, 1, x, y, GDK_CURRENT_TIME);
  } else if (g_str_equal(method, "window.startResize")) {
    gint x, y;
    int edge = int(GetInt(args, "edge", GDK_WINDOW_EDGE_SOUTH_EAST));
    if (PointerRoot(p, &x, &y))
      gtk_window_begin_resize_drag(w, GdkWindowEdge(edge), 1, x, y,
                                   GDK_CURRENT_TIME);
  } else if (g_str_equal(method, "window.close")) {
    p->allow_close = true;
    gtk_window_close(w);
  } else if (g_str_equal(method, "window.setTitle")) {
    const char* t = GetString(args, "title");
    if (t) gtk_window_set_title(w, t);
  } else if (g_str_equal(method, "window.setContentAspect")) {
    // Define o tamanho mínimo e, opcionalmente, ajusta a janela para que a
    // área do Android tenha exatamente |aspect|. (Não usamos dicas de
    // proporção do ICCCM: o Muffin/Cinnamon ignora o "base size" e aplicaria
    // a proporção à janela inteira; o encaixe fino é feito pelo Dart ao fim
    // de cada redimensionamento.)
    double aspect = 16.0 / 9.0;
    FlValue* av = fl_value_lookup_string(args, "aspect");
    if (av && fl_value_get_type(av) == FL_VALUE_TYPE_FLOAT)
      aspect = fl_value_get_float(av);
    int chrome_w = int(GetInt(args, "chromeWidth", 0));
    int chrome_h = int(GetInt(args, "chromeHeight", 0));
    int pref_w = int(GetInt(args, "preferredWidth", 1280));
    GdkGeometry hints = {};
    hints.min_width = chrome_w + 480;
    hints.min_height = chrome_h + int(480 / aspect);
    if (aspect < 1) {  // retrato (rotação rápida)
      hints.min_width = chrome_w + 320;
      hints.min_height = chrome_h + int(320 / aspect);
    }
    gtk_window_set_geometry_hints(
        w, nullptr, &hints,
        GDK_HINT_MIN_SIZE);
    if (GetBool(args, "resize", false) && !p->maximized && !p->fullscreen) {
      // Maior tamanho que cabe em ~88% da área útil do monitor.
      GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(w));
      GdkWindow* gw = gtk_widget_get_window(GTK_WIDGET(w));
      GdkMonitor* mon = gw ? gdk_display_get_monitor_at_window(display, gw)
                           : gdk_display_get_primary_monitor(display);
      GdkRectangle wa = {0, 0, 1366, 728};
      if (mon) gdk_monitor_get_workarea(mon, &wa);
      double cw = pref_w, ch = pref_w / aspect;
      if (aspect < 1) {  // retrato: mantém a altura atual do conteúdo
        gint cur_w, cur_h;
        gtk_window_get_size(w, &cur_w, &cur_h);
        ch = cur_h - chrome_h;
        cw = ch * aspect;
      }
      const double max_w = wa.width * 0.88 - chrome_w;
      const double max_h = wa.height * 0.88 - chrome_h;
      const double k = std::min({1.0, max_w / cw, max_h / ch});
      cw *= k;
      ch *= k;
      gtk_window_resize(w, int(cw + 0.5) + chrome_w, int(ch + 0.5) + chrome_h);
    }
  } else if (g_str_equal(method, "window.resize")) {
    if (!p->maximized && !p->fullscreen) {
      gtk_window_resize(w, int(GetInt(args, "width", 1336)),
                        int(GetInt(args, "height", 760)));
    }
  } else if (g_str_equal(method, "window.state")) {
    FlValue* m = fl_value_new_map();
    fl_value_set_string_take(m, "maximized", fl_value_new_bool(p->maximized));
    fl_value_set_string_take(m, "fullscreen", fl_value_new_bool(p->fullscreen));
    return Success(m);
  } else {
    return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  return Success(nullptr);
}

// ------------------------------------------------------- arrastar e soltar

// Aceita somente text/uri-list com ação COPY: o arquivo de origem nunca é
// movido. Os caminhos são resolvidos aqui (file:// -> caminho local).
gboolean OnDragMotion(GtkWidget* widget, GdkDragContext* context, gint x,
                      gint y, guint time, gpointer) {
  Plugin* p = g_plugin;
  if (p) {
    FlValue* e = MakeEvent("dragOver");
    fl_value_set_string_take(e, "x", fl_value_new_float(x));
    fl_value_set_string_take(e, "y", fl_value_new_float(y));
    SendEvent(p, e);
  }
  gdk_drag_status(context, GDK_ACTION_COPY, time);
  return TRUE;
}

void OnDragLeave(GtkWidget*, GdkDragContext*, guint, gpointer) {
  if (g_plugin) SendEvent(g_plugin, MakeEvent("dragLeave"));
}

gboolean OnDragDrop(GtkWidget* widget, GdkDragContext* context, gint, gint,
                    guint time, gpointer) {
  GdkAtom target = gtk_drag_dest_find_target(widget, context, nullptr);
  if (target == GDK_NONE) return FALSE;
  gtk_drag_get_data(widget, context, target, time);
  return TRUE;
}

void OnDragDataReceived(GtkWidget*, GdkDragContext* context, gint, gint,
                        GtkSelectionData* data, guint, guint time, gpointer) {
  Plugin* p = g_plugin;
  g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
  FlValue* paths = fl_value_new_list();
  for (gchar** u = uris; u && *u; ++u) {
    g_autofree gchar* path = g_filename_from_uri(*u, nullptr, nullptr);
    if (path) fl_value_append_take(paths, fl_value_new_string(path));
  }
  const bool ok = fl_value_get_length(paths) > 0;
  gtk_drag_finish(context, ok, FALSE /* nunca apagar a origem */, time);
  if (!p) {
    fl_value_unref(paths);
    return;
  }
  FlValue* e = MakeEvent("dragDrop");
  fl_value_set_string_take(e, "paths", paths);
  SendEvent(p, e);
}

void SetupDragAndDrop(GtkWidget* view) {
  gtk_drag_dest_set(view, GtkDestDefaults(0), nullptr, 0, GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(view);
  g_signal_connect(view, "drag-motion", G_CALLBACK(OnDragMotion), nullptr);
  g_signal_connect(view, "drag-leave", G_CALLBACK(OnDragLeave), nullptr);
  g_signal_connect(view, "drag-drop", G_CALLBACK(OnDragDrop), nullptr);
  g_signal_connect(view, "drag-data-received", G_CALLBACK(OnDragDataReceived),
                   nullptr);
}

// ------------------------------------------------------------------ dispatch

void OnMethodCall(FlMethodChannel* channel, FlMethodCall* call,
                  gpointer user_data) {
  Plugin* p = static_cast<Plugin*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  FlMethodResponse* response = nullptr;

  // Entrada: pelo display D-Bus quando ativo (nesse modo o VNC do QEMU não
  // injeta eventos); senão, pelo RFB.
  if (g_str_equal(method, "input.pointer")) {
    const int x = int(GetInt(args, "x", 0)), y = int(GetInt(args, "y", 0));
    const auto buttons = uint8_t(GetInt(args, "buttons", 0));
    if (DbusActive(p))
      p->dbus->SendPointer(x, y, buttons);
    else if (p->rfb)
      p->rfb->SendPointer(x, y, buttons);
    response = Success(nullptr);
  } else if (g_str_equal(method, "input.key")) {
    const auto keysym = uint32_t(GetInt(args, "keysym", 0));
    const bool down = GetBool(args, "down", false);
    if (DbusActive(p))
      p->dbus->SendKeysym(keysym, down);
    else if (p->rfb)
      p->rfb->SendKey(keysym, down);
    response = Success(nullptr);
  } else if (g_str_equal(method, "input.scancode")) {
    const auto scancode = uint32_t(GetInt(args, "scancode", 0));
    const bool down = GetBool(args, "down", false);
    bool sent = false;
    if (DbusActive(p)) {
      p->dbus->SendScancode(scancode, down);
      sent = true;
    } else if (p->rfb) {
      sent = p->rfb->SendScancode(scancode, uint32_t(GetInt(args, "keysym", 0)),
                                  down);
    }
    response = Success(fl_value_new_bool(sent));
  } else if (g_str_equal(method, "input.warpPointer")) {
    // Move o cursor do sistema para (x, y) em coordenadas da janela (usado
    // pela mira com o mouse). Funciona em X11; em Wayland o servidor ignora.
    bool ok = false;
    if (p->window) {
      GdkWindow* gw = gtk_widget_get_window(GTK_WIDGET(p->window));
      GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(p->window));
      GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
      if (gw && pointer) {
        gint ox = 0, oy = 0;
        gdk_window_get_origin(gw, &ox, &oy);
        gdk_device_warp(pointer, gdk_window_get_screen(gw),
                        ox + gint(GetInt(args, "x", 0)),
                        oy + gint(GetInt(args, "y", 0)));
        ok = true;
      }
    }
    response = Success(fl_value_new_bool(ok));
  } else if (g_str_equal(method, "app.ready")) {
    p->dart_ready = true;
    response = Success(TakePendingOpen(p));
  } else if (g_str_equal(method, "host.probe")) {
    response = HandleProbeHost();
  } else if (g_str_equal(method, "vm.start")) {
    response = HandleVmStart(p, args);
  } else if (g_str_equal(method, "vm.signal")) {
    response = Success(
        fl_value_new_bool(p->vm.Signal(int(GetInt(args, "signal", SIGTERM)))));
  } else if (g_str_equal(method, "vm.isRunning")) {
    response = Success(fl_value_new_bool(p->vm.IsRunning()));
  } else if (g_str_equal(method, "display.connect")) {
    response = HandleDisplayConnect(p, args);
  } else if (g_str_equal(method, "display.disconnect")) {
    DisconnectDisplay(p);
    response = Success(nullptr);
  } else if (g_str_equal(method, "display.refresh")) {
    if (p->rfb) p->rfb->RequestFullUpdate();
    response = Success(nullptr);
  } else if (g_str_has_prefix(method, "window.")) {
    response = HandleWindow(p, method, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("secada: falha ao responder %s: %s", method, error->message);
  }
  g_object_unref(response);
}

void OnViewDestroyed(gpointer data, GObject*) {
  Plugin* p = static_cast<Plugin*>(data);
  DisconnectDisplay(p);
  // Rede de segurança: se a interface não desligou a VM, encerramos aqui.
  p->vm.TerminateBlocking(15000);
}

}  // namespace

void secada_core_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* p = new Plugin();
  g_plugin = p;
  p->registrar = registrar;
  p->texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  p->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(p->channel, OnMethodCall, p,
                                            nullptr);

  p->vm.set_exit_callback(OnVmExit);

  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view) {
    GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
    if (GTK_IS_WINDOW(toplevel)) {
      p->window = GTK_WINDOW(toplevel);
      g_signal_connect(toplevel, "window-state-event",
                       G_CALLBACK(OnWindowState), nullptr);
      g_signal_connect(toplevel, "delete-event", G_CALLBACK(OnDeleteEvent),
                       nullptr);
    }
    g_object_weak_ref(G_OBJECT(view), OnViewDestroyed, p);
    SetupDragAndDrop(GTK_WIDGET(view));
  }
  g_unix_signal_add(SIGINT, OnUnixSignal, nullptr);
  g_unix_signal_add(SIGTERM, OnUnixSignal, nullptr);
  g_unix_signal_add(SIGHUP, OnUnixSignal, nullptr);
}

void secada_core_plugin_open_files(const char* const* paths, int count) {
  Plugin* p = g_plugin;
  if (!p) return;
  for (int i = 0; i < count; ++i) {
    if (paths[i] && paths[i][0]) p->pending_open.emplace_back(paths[i]);
  }
  if (p->window) {
    gtk_window_deiconify(p->window);
    gtk_window_present(p->window);
  }
  if (p->dart_ready) FlushOpenFiles(p);
}
