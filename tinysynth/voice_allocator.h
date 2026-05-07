// ================================================================
// voice_allocator.h
// Description : Producer-thread voice allocator over the realtime ABI
// ================================================================
//
// Phase 3.1: a minimal voice allocator that maps musical note events
// onto rt_graph_realtime_reserve / activate / release / remove. It
// owns a fixed set of voice records (= polyphony) and routes
// note_on / note_off through them under a stealing policy.
//
// Threading: producer-thread only — same single-producer contract as
// the realtime ABI in rt_graph.h. All entries below must be called
// from the *one* thread that drives note traffic (a MIDI thread, the
// test thread, etc.). Concurrent calls from multiple threads will
// corrupt internal state and the realtime queue.
//
// Lifecycle of a voice (allocator-side state machine):
//
//                 note_on(N)      tick + reserve+activate
//        Free  ──────────────►  PendingSteal  ──────────────►  Active
//          │                       │                            │
//          │ note_on(N) when     note_off(N): drop pending      │ note_off(N):
//          │ a Free voice                                       │ enqueue Release
//          │ exists                                             │
//          ▼                                                    ▼
//        Active                                              Releasing
//                                                                │
//                                          tick + auto-free      │
//                                  ◄─────────────────────────────┘
//
// The Reserved runtime state is hidden inside note_on / tick — the
// allocator never returns a record in that state.
//
// Generation policy: bumps once on every successful note_on assignment
// (Free → Active synchronously, or Active/Releasing → PendingSteal
// when stealing). Stale handles to a voice are detectable once the
// voice has been re-assigned. We do NOT bump on Active → Releasing
// (same logical owner) or PendingSteal → Active (same logical owner
// becoming live), so a handle stashed at note_on remains valid for
// the entire lifetime of that note.

#pragma once

#include "rt_graph.h"

#include <cstdint>
#include <vector>

namespace metasonic {

enum class VoiceState : int {
  Free          = 0,
  Active        = 1,
  Releasing     = 2,
  PendingSteal  = 3,
};

enum class VoiceResultStatus : int {
  // Voice reserved + per-note controls written + activate enqueued
  // synchronously. The slot will be live in the audio schedule at
  // the next process_graph block.
  Started      = 0,
  // No Free voice was available; we picked a steal victim, enqueued
  // Remove on its slot, and parked the new note in the same voice
  // record in PendingSteal state. The next tick() (after the audio
  // thread drains Remove) will reserve+activate.
  PendingSteal = 1,
  // The realtime queue refused an enqueue (full) or the runtime
  // refused a reserve (pool not pre-warmed). Caller may retry on a
  // later block.
  QueueFull    = 2,
  // The user-supplied control-mapping callback returned false; the
  // reservation was cancelled.
  MapFailed    = 3,
};

struct VoiceHandle {
  // Allocator-internal voice index (0..polyphony-1). Stable for the
  // life of the allocator.
  int      voice_index = -1;
  // Bumps on every successful note_on assignment to this voice.
  // Two handles to the same voice_index match only if generation
  // matches.
  std::uint32_t generation  = 0;
  // Runtime slot id once known. -1 in the PendingSteal result and
  // in any failure result.
  int      slot_id     = -1;
};

struct VoiceResult {
  VoiceResultStatus status = VoiceResultStatus::QueueFull;
  VoiceHandle       voice;
  // For PendingSteal: the runtime slot id of the voice we stole
  // from (where Remove was enqueued). For other statuses: -1.
  // Useful for debugging and for tests asserting which slot got
  // displaced.
  int               stolen_slot_id = -1;
};

// Per-note control-mapping callback. Called by the allocator on a
// freshly Reserved slot, before activate. Implementations should
// write per-note controls through rt_graph_instance_set_control on
// the given slot — that direct write is allowed on Reserved slots
// (see the [T:control] exception in rt_graph.h). Return true to
// proceed with activate; false to abort (the allocator will cancel
// the reservation and surface MapFailed to the caller).
//
// Producer-thread only — same contract as rt_graph_realtime_*.
using VoiceMapFn = bool (*)(RTGraph *graph, int slot_id, int note,
                            float velocity, void *user_data);

class VoiceAllocator {
public:
  // Construct an allocator over `template_id` in `graph` with the
  // given polyphony. polyphony is clamped to [1, ...]. The caller
  // must have set the template's rt_graph_template_set_polyphony to
  // at least `polyphony` and pre-warmed the runtime pool with that
  // many Available slots before issuing any note_on (typically by
  // spawning N instances via rt_graph_template_instance_add and
  // immediately removing each via rt_graph_instance_remove).
  //
  // `map` is invoked per note_on on a Reserved slot. Pass user_data
  // to thread per-allocator state into the callback. Both may be
  // null only if the template has no per-note control writes (rare
  // — typically there is at least pitch).
  VoiceAllocator(RTGraph *graph, int template_id, int polyphony,
                 VoiceMapFn map, void *user_data);

  // Note events.
  VoiceResult note_on(int note, float velocity);
  void        note_off(int note);

  // Per-block tick: retry pending steals (if their victim's Remove
  // has drained) and reap Releasing voices whose runtime slots
  // auto-freed via the §2.E silence window. Idempotent — safe to
  // call between every audio block, or less often.
  void        tick();

  // Hard panic: enqueue Remove on every Active or Releasing voice,
  // drop every PendingSteal. Returns the allocator to all-Free.
  void        all_notes_off();

  // Introspection. voice_count is constant for the life of the
  // allocator (= polyphony). voice_state / voice_handle / voice_note
  // return Free / default / -1 for out-of-range indices.
  int         voice_count() const noexcept;
  VoiceState  voice_state(int voice_index) const noexcept;
  VoiceHandle voice_handle(int voice_index) const noexcept;
  int         voice_note(int voice_index) const noexcept;

private:
  struct Voice {
    int           slot_id    = -1;   // runtime slot id; -1 when Free or PendingSteal
    std::uint32_t generation = 0;
    int           note       = -1;   // -1 when Free
    float         velocity   = 0.0f;
    std::uint64_t age        = 0;    // age_counter snapshot at last assignment
    VoiceState    state      = VoiceState::Free;
  };

  int  find_free_voice() const noexcept;
  int  pick_steal_victim() const noexcept;
  bool reserve_map_activate(Voice &v) noexcept;

  RTGraph           *graph_;
  int                template_id_;
  VoiceMapFn         map_;
  void              *user_data_;
  std::vector<Voice> voices_;
  std::uint64_t      age_counter_ = 0;
  // 128 = MIDI note range. -1 means unmapped.
  int                note_to_voice_[128];
};

} // namespace metasonic
