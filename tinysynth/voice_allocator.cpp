// ================================================================
// voice_allocator.cpp
// Description : Implementation of the producer-thread voice allocator
// ================================================================

#include "voice_allocator.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <iterator>
#include <limits>

namespace metasonic {

VoiceAllocator::VoiceAllocator(RTGraph *graph, int template_id, int polyphony,
                               VoiceMapFn map, void *user_data)
    : graph_(graph),
      template_id_(template_id),
      map_(map),
      user_data_(user_data) {
  if (polyphony < 1) polyphony = 1;
  voices_.resize(static_cast<std::size_t>(polyphony));
  std::fill(std::begin(note_to_voice_), std::end(note_to_voice_), -1);
}

int VoiceAllocator::find_free_voice() const noexcept {
  for (std::size_t i = 0; i < voices_.size(); ++i) {
    if (voices_[i].state == VoiceState::Free) return static_cast<int>(i);
  }
  return -1;
}

int VoiceAllocator::pick_steal_victim() const noexcept {
  // Two-pass scan: oldest Releasing first (logically already done),
  // then oldest Active. Skip PendingSteal — those are mid-allocation
  // and stealing them would create a chain.
  int            best_idx = -1;
  std::uint64_t  best_age = std::numeric_limits<std::uint64_t>::max();

  for (std::size_t i = 0; i < voices_.size(); ++i) {
    if (voices_[i].state == VoiceState::Releasing && voices_[i].age < best_age) {
      best_age = voices_[i].age;
      best_idx = static_cast<int>(i);
    }
  }
  if (best_idx >= 0) return best_idx;

  best_age = std::numeric_limits<std::uint64_t>::max();
  for (std::size_t i = 0; i < voices_.size(); ++i) {
    if (voices_[i].state == VoiceState::Active && voices_[i].age < best_age) {
      best_age = voices_[i].age;
      best_idx = static_cast<int>(i);
    }
  }
  return best_idx;
}

// Synchronous reserve → map → activate sequence on a voice record
// already populated with note / velocity. Returns true on full
// success (slot reserved, controls written, Activate enqueued); on
// failure rolls back any partial reservation and returns false. The
// voice's state and slot_id are updated only on success — caller
// reverts the voice to Free or leaves it PendingSteal as appropriate.
bool VoiceAllocator::reserve_map_activate(Voice &v) noexcept {
  int slot = rt_graph_realtime_reserve(graph_, template_id_);
  if (slot < 0) return false;  // pool not pre-warmed or cap hit

  if (map_ && !map_(graph_, slot, v.note, v.velocity, user_data_)) {
    rt_graph_realtime_cancel(graph_, slot);
    return false;
  }

  if (rt_graph_realtime_activate(graph_, slot) == 0) {
    // Queue full. Roll back the reservation so the slot returns to
    // Available; the caller can retry next tick.
    rt_graph_realtime_cancel(graph_, slot);
    return false;
  }

  v.slot_id = slot;
  v.state   = VoiceState::Active;
  return true;
}

VoiceResult VoiceAllocator::note_on(int note, float velocity) {
  if (note < 0 || note >= 128) {
    return {VoiceResultStatus::MapFailed, {}, -1};
  }

  // Find a Free voice first — synchronous fast path.
  int vi = find_free_voice();
  if (vi >= 0) {
    Voice &v   = voices_[static_cast<std::size_t>(vi)];
    v.note     = note;
    v.velocity = velocity;
    v.age      = ++age_counter_;

    int slot = rt_graph_realtime_reserve(graph_, template_id_);
    if (slot < 0) {
      v.note = -1;
      return {VoiceResultStatus::QueueFull, {vi, v.generation, -1}, -1};
    }
    if (map_ && !map_(graph_, slot, note, velocity, user_data_)) {
      rt_graph_realtime_cancel(graph_, slot);
      v.note = -1;
      return {VoiceResultStatus::MapFailed, {vi, v.generation, -1}, -1};
    }
    if (rt_graph_realtime_activate(graph_, slot) == 0) {
      rt_graph_realtime_cancel(graph_, slot);
      v.note = -1;
      return {VoiceResultStatus::QueueFull, {vi, v.generation, -1}, -1};
    }

    ++v.generation;
    v.slot_id = slot;
    v.state   = VoiceState::Active;
    note_to_voice_[note] = vi;
    return {VoiceResultStatus::Started, {vi, v.generation, slot}, -1};
  }

  // No Free voice — pick a steal victim. Releasing first, then Active.
  int victim_vi = pick_steal_victim();
  if (victim_vi < 0) {
    // Polyphony >= 1 plus all voices in use means at least one
    // Active or Releasing voice exists, so this is unreachable in
    // practice. Defensive fall-through.
    return {VoiceResultStatus::QueueFull, {}, -1};
  }
  Voice &victim         = voices_[static_cast<std::size_t>(victim_vi)];
  const int stolen_slot = victim.slot_id;

  // Enqueue Remove on the victim's slot. If the queue is full, the
  // steal can't proceed and the new note is rejected — the caller
  // can retry next block.
  if (rt_graph_realtime_remove(graph_, stolen_slot) == 0) {
    return {VoiceResultStatus::QueueFull, {}, -1};
  }

  // Forget the victim's note before bumping the voice's identity.
  if (victim.note >= 0 && note_to_voice_[victim.note] == victim_vi) {
    note_to_voice_[victim.note] = -1;
  }
  ++victim.generation;
  victim.note     = note;
  victim.velocity = velocity;
  victim.age      = ++age_counter_;
  victim.slot_id  = -1;  // unknown until tick reserves
  victim.state    = VoiceState::PendingSteal;
  note_to_voice_[note] = victim_vi;

  return {VoiceResultStatus::PendingSteal,
          {victim_vi, victim.generation, -1},
          stolen_slot};
}

void VoiceAllocator::note_off(int note) {
  if (note < 0 || note >= 128) return;
  const int vi = note_to_voice_[note];
  if (vi < 0) return;
  Voice &v = voices_[static_cast<std::size_t>(vi)];

  switch (v.state) {
    case VoiceState::Active: {
      // Enqueue Release. On queue-full, leave the voice Active —
      // caller can retry by sending note_off again next block.
      if (rt_graph_realtime_release(graph_, v.slot_id) == 0) return;
      v.state = VoiceState::Releasing;
      // Leave note_to_voice[note] in place so a duplicate note_off
      // hits the same voice (and is a no-op in Releasing). tick()
      // clears the mapping when the slot auto-frees.
      break;
    }
    case VoiceState::Releasing:
      // Already releasing; no-op.
      break;
    case VoiceState::PendingSteal: {
      // The pending note never activated. Drop it: the victim's
      // queued Remove still fires, freeing the runtime slot, and
      // this voice record returns to Free without ever publishing.
      ++v.generation;
      v.note   = -1;
      v.state  = VoiceState::Free;
      v.slot_id = -1;
      note_to_voice_[note] = -1;
      break;
    }
    case VoiceState::Free:
      // Stale note_off — voice already cleaned up. Defensive clear.
      note_to_voice_[note] = -1;
      break;
  }
}

void VoiceAllocator::tick() {
  // Pass 1: reap Releasing voices whose runtime slots auto-freed
  // via the §2.E silence window.
  for (auto &v : voices_) {
    if (v.state != VoiceState::Releasing) continue;
    if (rt_graph_instance_status(graph_, v.slot_id) != -1) continue;

    if (v.note >= 0 && note_to_voice_[v.note] >= 0) {
      const int mapped = note_to_voice_[v.note];
      if (mapped >= 0 && voices_[static_cast<std::size_t>(mapped)].generation == v.generation) {
        note_to_voice_[v.note] = -1;
      }
    }
    v.note   = -1;
    v.state  = VoiceState::Free;
    v.slot_id = -1;
  }

  // Pass 2: retry pending steals. The victim's Remove may not yet
  // have drained on the audio thread, in which case reserve fails
  // (no Available slot of this template's shape) and we just leave
  // the voice pending for the next tick.
  for (auto &v : voices_) {
    if (v.state != VoiceState::PendingSteal) continue;
    (void) reserve_map_activate(v);
    // On success v.state is now Active. On failure (queue full, map
    // failed, or no Available slot yet), v stays PendingSteal. We
    // do NOT bump generation here — the voice's logical owner did
    // not change.
  }
}

void VoiceAllocator::all_notes_off() {
  for (auto &v : voices_) {
    switch (v.state) {
      case VoiceState::Active:
      case VoiceState::Releasing:
        // Hard remove. Queue full here means the panic is best-
        // effort; the voice record still resets locally so the
        // allocator's accounting stays consistent.
        (void) rt_graph_realtime_remove(graph_, v.slot_id);
        v.note   = -1;
        v.state  = VoiceState::Free;
        v.slot_id = -1;
        break;
      case VoiceState::PendingSteal:
        v.note   = -1;
        v.state  = VoiceState::Free;
        v.slot_id = -1;
        break;
      case VoiceState::Free:
        break;
    }
  }
  std::fill(std::begin(note_to_voice_), std::end(note_to_voice_), -1);
}

int VoiceAllocator::voice_count() const noexcept {
  return static_cast<int>(voices_.size());
}

VoiceState VoiceAllocator::voice_state(int voice_index) const noexcept {
  if (voice_index < 0 || voice_index >= static_cast<int>(voices_.size())) {
    return VoiceState::Free;
  }
  return voices_[static_cast<std::size_t>(voice_index)].state;
}

VoiceHandle VoiceAllocator::voice_handle(int voice_index) const noexcept {
  if (voice_index < 0 || voice_index >= static_cast<int>(voices_.size())) {
    return {};
  }
  const Voice &v = voices_[static_cast<std::size_t>(voice_index)];
  return {voice_index, v.generation, v.slot_id};
}

int VoiceAllocator::voice_note(int voice_index) const noexcept {
  if (voice_index < 0 || voice_index >= static_cast<int>(voices_.size())) {
    return -1;
  }
  return voices_[static_cast<std::size_t>(voice_index)].note;
}

} // namespace metasonic
