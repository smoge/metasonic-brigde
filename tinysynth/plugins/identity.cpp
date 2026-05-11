#include "rt_graph_plugins.h"

namespace {

void identity_init(void *, int, int) noexcept {}

void identity_reset(void *) noexcept {}

int identity_process(void *, int nframes,
                     const float * const *inputs,
                     float * const *outputs) noexcept {
  if (nframes < 0 || inputs == nullptr || outputs == nullptr
      || outputs[0] == nullptr) {
    return 1;
  }

  const float *a = inputs[0];
  const float *b = inputs[1];
  float *out = outputs[0];
  for (int i = 0; i < nframes; ++i) {
    const float av = a == nullptr ? 0.0f : a[i];
    const float bv = b == nullptr ? 0.0f : b[i];
    out[i] = av + bv;
  }
  return 0;
}

const metasonic::PluginSpec kIdentitySpec{
    "identity",
    0,
    2,
    1,
    0,
    identity_init,
    identity_reset,
    identity_process,
};

} // namespace

namespace metasonic {

const PluginSpec *identity_plugin_spec() noexcept {
  return &kIdentitySpec;
}

} // namespace metasonic
