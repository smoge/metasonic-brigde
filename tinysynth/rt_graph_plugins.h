#pragma once

namespace metasonic {

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
