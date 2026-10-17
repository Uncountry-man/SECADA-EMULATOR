#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "secada_core/secada_plugin.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // Instância única: se a janela já existe (outro processo foi iniciado, por
  // exemplo ao abrir um APK pelo gerenciador de arquivos), só a traz à frente.
  GList* existing = gtk_application_get_windows(GTK_APPLICATION(application));
  if (existing != nullptr) {
    GtkWindow* w = GTK_WINDOW(existing->data);
    gtk_window_deiconify(w);
    gtk_window_present(w);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // A barra de título é desenhada pelo Flutter (nome, estado da VM e botões
  // de janela), por isso a janela não usa decoração do gerenciador.
  gtk_window_set_title(window, "SECADA Emulator");
  gtk_window_set_decorated(window, FALSE);
  // Janela transparente (visual RGBA): os cantos arredondados são recortados
  // pelo Flutter. Sem compositor, o visual cai no padrão e os cantos ficam retos.
  {
    GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window));
    GdkVisual* rgba = gdk_screen_get_rgba_visual(screen);
    if (rgba != nullptr && gdk_screen_is_composited(screen)) {
      gtk_widget_set_visual(GTK_WIDGET(window), rgba);
      gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
    }
  }
  {
    // Ícone embarcado no pacote: <dir do executável>/share/secada.png
    g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
    if (exe != nullptr) {
      g_autofree gchar* dir = g_path_get_dirname(exe);
      g_autofree gchar* icon =
          g_build_filename(dir, "share", "secada.png", nullptr);
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }

  // Conteúdo 1280x720 + barra de título (40) + barra lateral (56).
  gtk_window_set_default_size(window, 1336, 760);
  GdkGeometry hints;
  hints.min_width = 640;
  hints.min_height = 420;
  gtk_window_set_geometry_hints(window, nullptr, &hints, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // Os arquivos a abrir chegam pelo canal nativo (ver command_line), não
  // como argumentos do Dart.
  (void)self;

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlPluginRegistrar) secada_registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "SecadaCorePlugin");
  secada_core_plugin_register_with_registrar(secada_registrar);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::command_line. Roda na instância principal, também
// para as linhas de comando de outros processos (o GApplication as encaminha
// pelo D-Bus e o segundo processo encerra). Os argumentos que não são opções
// são arquivos (APK/XAPK) a instalar: caminhos, ou URIs file:// quando o
// gerenciador de arquivos usa %U.
static int my_application_command_line(GApplication* application,
                                       GApplicationCommandLine* cmdline) {
  g_application_activate(application);

  gint argc = 0;
  gchar** argv = g_application_command_line_get_arguments(cmdline, &argc);
  const gchar* cwd = g_application_command_line_get_cwd(cmdline);
  g_autofree gchar* fallback_cwd = cwd ? nullptr : g_get_current_dir();
  if (!cwd) cwd = fallback_cwd;

  GPtrArray* paths = g_ptr_array_new_with_free_func(g_free);
  for (gint i = 1; i < argc; ++i) {
    const gchar* arg = argv[i];
    if (arg == nullptr || arg[0] == '\0' || arg[0] == '-') continue;
    gchar* path = nullptr;
    if (g_str_has_prefix(arg, "file://")) {
      path = g_filename_from_uri(arg, nullptr, nullptr);
    } else if (g_path_is_absolute(arg)) {
      path = g_strdup(arg);
    } else {
      path = g_build_filename(cwd, arg, nullptr);
    }
    if (path) g_ptr_array_add(paths, path);
  }
  if (paths->len > 0) {
    secada_core_plugin_open_files(
        reinterpret_cast<const char* const*>(paths->pdata), int(paths->len));
  }
  g_ptr_array_unref(paths);
  g_strfreev(argv);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
