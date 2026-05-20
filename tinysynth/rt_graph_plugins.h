#pragma once

namespace metasonic {

// Upper bound on `PluginSpec::state_size_bytes` enforced by
// `register_plugin`. Pinned by Phase 6.E v2 §4.1 / §4.2
// (notes/2026-05-19-d-phase-6e4-second-static-plugin-contract.md):
// matches the v1 §6.E §2.1 design constant. The host owns this
// many bytes of per-instance plugin state inline on
// `StaticPluginState::storage` (rt_graph.cpp). Plugins declaring
// `state_size_bytes` outside `[0, kMaxPluginState]` are rejected
// at registration time (rt_graph_plugins.cpp `register_plugin`).
constexpr int kMaxPluginState = 4096;

struct PluginSpec {
  const char *name = nullptr;
  int state_size_bytes = 0;
  int audio_in_count = 0;
  int audio_out_count = 0;
  int latency_samples = 0;

  void (*init)(void *state, int sample_rate, int max_frames) noexcept = nullptr;
  void (*reset)(void *state) noexcept = nullptr;
  int (*process)(void *state, int nframes,
                 const float * const *inputs,
                 float * const *outputs) noexcept = nullptr;
};

int register_plugin(const PluginSpec *spec) noexcept;
int plugin_count() noexcept;
int plugin_find(const char *name) noexcept;
const PluginSpec *plugin_at(int id) noexcept;

} // namespace metasonic
