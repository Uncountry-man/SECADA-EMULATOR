#include "display_texture.h"

#include <vector>

struct _SecadaDisplayTexture {
  FlPixelBufferTexture parent_instance;
  std::shared_ptr<secada::FrameSource>* source;
  std::vector<uint8_t>* pixels;
  uint32_t width;
  uint32_t height;
};

G_DEFINE_TYPE(SecadaDisplayTexture, secada_display_texture,
              fl_pixel_buffer_texture_get_type())

// Chamado na thread de rasterização do Flutter.
static gboolean secada_display_texture_copy_pixels(FlPixelBufferTexture* texture,
                                                 const uint8_t** out_buffer,
                                                 uint32_t* width,
                                                 uint32_t* height,
                                                 GError** error) {
  SecadaDisplayTexture* self = SECADA_DISPLAY_TEXTURE(texture);
  (*self->source)->CopyFrame(self->pixels, &self->width, &self->height);
  if (self->pixels->empty()) {
    // Ainda sem quadro: 1x1 preto.
    self->pixels->assign({0, 0, 0, 0xff});
    self->width = self->height = 1;
  }
  *out_buffer = self->pixels->data();
  *width = self->width;
  *height = self->height;
  return TRUE;
}

static void secada_display_texture_dispose(GObject* object) {
  SecadaDisplayTexture* self = SECADA_DISPLAY_TEXTURE(object);
  delete self->source;
  self->source = nullptr;
  delete self->pixels;
  self->pixels = nullptr;
  G_OBJECT_CLASS(secada_display_texture_parent_class)->dispose(object);
}

static void secada_display_texture_class_init(SecadaDisplayTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      secada_display_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = secada_display_texture_dispose;
}

static void secada_display_texture_init(SecadaDisplayTexture* self) {
  self->source = nullptr;
  self->pixels = new std::vector<uint8_t>();
  self->width = self->height = 0;
}

SecadaDisplayTexture* secada_display_texture_new(
    std::shared_ptr<secada::FrameSource> source) {
  auto* self = SECADA_DISPLAY_TEXTURE(
      g_object_new(secada_display_texture_get_type(), nullptr));
  self->source = new std::shared_ptr<secada::FrameSource>(std::move(source));
  return self;
}
