#include "rt_graph_plugins.h"

#include <array>
#include <cstddef>
#include <cstring>

namespace metasonic {

const PluginSpec *identity_plugin_spec() noexcept;
const PluginSpec *one_tap_delay_plugin_spec() noexcept;

namespace {

constexpr int kMaxPlugins = 16;

std::array<const PluginSpec *, kMaxPlugins> g_plugins{};
int g_plugin_count = 0;
bool g_builtin_plugins_registered = false;

void ensure_builtin_plugins_registered() noexcept {
  if (g_builtin_plugins_registered) return;
  g_builtin_plugins_registered = true;
  (void)register_plugin(identity_plugin_spec());
  (void)register_plugin(one_tap_delay_plugin_spec());
}

} // namespace

int register_plugin(const PluginSpec *spec) noexcept {
  if (spec == nullptr || spec->name == nullptr) return -1;
  // Phase 6.E v2 §4.2 bounds check: reject metadata that would
  // either silently take the zero-state-pass-nullptr branch in
  // process_static_plugin (negative state_size_bytes) or overflow
  // StaticPluginState::storage[kMaxPluginState] (oversized state).
  if (spec->state_size_bytes < 0 || spec->state_size_bytes > kMaxPluginState) {
    return -1;
  }
  if (g_plugin_count >= kMaxPlugins) return -1;
  if (plugin_find(spec->name) >= 0) return -1;

  const int id = g_plugin_count;
  g_plugins[static_cast<std::size_t>(id)] = spec;
  ++g_plugin_count;
  return id;
}

int plugin_count() noexcept {
  ensure_builtin_plugins_registered();
  return g_plugin_count;
}

int plugin_find(const char *name) noexcept {
  ensure_builtin_plugins_registered();
  if (name == nullptr) return -1;
  for (int i = 0; i < g_plugin_count; ++i) {
    const auto *spec = g_plugins[static_cast<std::size_t>(i)];
    if (spec != nullptr && spec->name != nullptr
        && std::strcmp(spec->name, name) == 0) {
      return i;
    }
  }
  return -1;
}

const PluginSpec *plugin_at(int id) noexcept {
  ensure_builtin_plugins_registered();
  if (id < 0 || id >= g_plugin_count) return nullptr;
  return g_plugins[static_cast<std::size_t>(id)];
}

} // namespace metasonic
