#include "rt_graph_plugins.h"

#include <cstddef>

namespace {

// Phase 6.E v2 second static plugin
// (notes/2026-05-19-d-phase-6e4-second-static-plugin-contract.md).
// Two-input one-sample-delayed sum:
//
//   out[i] = prev_sum (carried from previous sample)
//   prev_sum := in0[i] + in1[i]
//
// Initial state is zero, which v2 obtains for free from the host's
// value-initialized StaticPluginState::storage blob — see §4.1a's
// implicit-lifetime / trivially-copyable / zero-valid contract.
// `init` and `reset` are spec-declared for forward compatibility
// with the v1 hosting contract, but v2 does not call either
// callback from anywhere (§4 opening).
struct OneTapDelayState {
  float prev_sum = 0.0f;
};

void one_tap_delay_init(void *, int, int) noexcept {}

void one_tap_delay_reset(void *state) noexcept {
  if (state == nullptr) return;
  auto *s = static_cast<OneTapDelayState *>(state);
  s->prev_sum = 0.0f;
}

int one_tap_delay_process(void *state, int nframes,
                          const float * const *inputs,
                          float * const *outputs) noexcept {
  if (nframes < 0 || inputs == nullptr || outputs == nullptr
      || outputs[0] == nullptr || state == nullptr) {
    return 1;
  }

  auto *s = static_cast<OneTapDelayState *>(state);
  const float *a = inputs[0];
  const float *b = inputs[1];
  float *out = outputs[0];
  float prev = s->prev_sum;
  for (int i = 0; i < nframes; ++i) {
    // Null-as-zero, mirroring identity.cpp: a `Param 0.0` input
    // lowers to RConst on the Haskell side and the FFI loader does
    // not wire a buffer for it, so process_static_plugin passes
    // nullptr for that channel. Without this guard, an unwired
    // input would dereference nullptr.
    const float av = a == nullptr ? 0.0f : a[i];
    const float bv = b == nullptr ? 0.0f : b[i];
    const float sum = av + bv;
    out[i] = prev;
    prev = sum;
  }
  s->prev_sum = prev;
  return 0;
}

const metasonic::PluginSpec kOneTapDelaySpec{
    "one-tap-delay",
    static_cast<int>(sizeof(OneTapDelayState)),
    2,
    1,
    1,
    one_tap_delay_init,
    one_tap_delay_reset,
    one_tap_delay_process,
};

} // namespace

namespace metasonic {

const PluginSpec *one_tap_delay_plugin_spec() noexcept {
  return &kOneTapDelaySpec;
}

} // namespace metasonic
