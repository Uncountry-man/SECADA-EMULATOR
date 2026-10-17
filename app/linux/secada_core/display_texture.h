// Textura Flutter alimentada pelo quadro mais recente do display da VM.
#pragma once

#include <flutter_linux/flutter_linux.h>

#include <cstdint>
#include <memory>
#include <vector>

namespace secada {

// Fonte de quadros RGBA (cliente RFB ou display D-Bus).
class FrameSource {
 public:
  virtual ~FrameSource() = default;
  // Copia o quadro para |out| se houver um mais novo que o último entregue.
  virtual bool CopyFrame(std::vector<uint8_t>* out, uint32_t* width,
                         uint32_t* height) = 0;
};

}  // namespace secada

G_BEGIN_DECLS

#define SECADA_TYPE_DISPLAY_TEXTURE (secada_display_texture_get_type())
G_DECLARE_FINAL_TYPE(SecadaDisplayTexture, secada_display_texture, SECADA,
                     DISPLAY_TEXTURE, FlPixelBufferTexture)

G_END_DECLS

SecadaDisplayTexture* secada_display_texture_new(
    std::shared_ptr<secada::FrameSource> source);
