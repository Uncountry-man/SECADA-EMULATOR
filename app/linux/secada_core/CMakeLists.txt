# Backend nativo do SECADA Emulator: processo QEMU, displays RFB e D-Bus, diagnóstico
# do host e controle de janela.
add_library(secada_core STATIC
  "secada_plugin.cc"
  "dbus_display.cc"
  "display_texture.cc"
  "host_probe.cc"
  "rfb_client.cc"
  "vm_process.cc"
)
apply_standard_settings(secada_core)
target_compile_features(secada_core PUBLIC cxx_std_17)
find_package(Threads REQUIRED)
# EGL/GLES pelo libepoxy (já usado pelo GTK) e GUnixFDList para o display
# D-Bus; o libgbm é carregado com dlopen.
pkg_check_modules(EPOXY REQUIRED IMPORTED_TARGET epoxy)
pkg_check_modules(GIOUNIX REQUIRED IMPORTED_TARGET gio-unix-2.0)
target_link_libraries(secada_core PUBLIC flutter PkgConfig::GTK PkgConfig::EPOXY
  PkgConfig::GIOUNIX Threads::Threads ${CMAKE_DL_LIBS})
target_include_directories(secada_core PUBLIC "${CMAKE_SOURCE_DIR}")
