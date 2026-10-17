// Ponte entre o backend nativo (C++) e a interface Flutter.
//
// Canal de métodos "dev.secada/core":
//   host.probe                       -> informações de KVM/CPU/memória
//   vm.start {argv, env, logPath}    -> pid
//   vm.signal {signal}               -> bool
//   vm.isRunning                     -> bool
//   display.connect {socketPath, timeoutMs, swapRedBlue, dbusQmpSocket,
//                    renderNode} -> textureId
//   display.disconnect / display.refresh
//   input.pointer {x, y, buttons} / input.key {keysym, down}
//   input.warpPointer {x, y} -> bool (mover o cursor, mira com o mouse)
//   app.ready -> [paths]  (a interface está pronta; devolve os arquivos em
//                         espera; depois chegam como evento openFiles)
//   window.* (minimize, toggleMaximize, startDrag, startResize, setFullscreen,
//             close, setTitle)
// Eventos nativos -> Dart: método "onEvent" com um mapa {type: ...}.
#pragma once

#include <flutter_linux/flutter_linux.h>

void secada_core_plugin_register_with_registrar(FlPluginRegistrar* registrar);

// Arquivos (APK/XAPK) recebidos pela linha de comando ou por outra instância.
// Ficam na fila até a interface Dart avisar que está pronta (app.ready).
void secada_core_plugin_open_files(const char* const* paths, int count);
