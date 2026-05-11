#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RTGraph RTGraph;

// Phase 5.1.B: opaque handle to a "next world" prepared off-audio.
// A prepared swap owns the RTGraphState that the audio thread will
// install at the next block boundary, then owns the retired previous
// state until the producer disposes the collected swap.
// See notes/2026-05-10-phase-5-rcu-hot-swap-design.md.
typedef struct RTGraphSwap RTGraphSwap;

// ----------------------------------------------------------------
// Thread safety: every entry below carries a "[T:CATEGORY]" tag in
// its comment. Categories and the contract they participate in are
// enumerated in Note [Thread safety contract] in rt_graph.cpp:
//
// Rule of thumb:
//   * Build and reconfigure graphs before audio starts.
//   * While audio is running, use rt_graph_realtime_* from one
//     producer thread for note/control changes.
//   * Read-only helpers are diagnostic; they may be stale during
//     concurrent mutation.
//
//   construction       — mutates shared structure; safe only when
//                        the audio callback is not running
//   control            — mutates per-instance state; safe only when
//                        audio is stopped (one narrow exception:
//                        rt_graph_instance_set_control may write to
//                        a Reserved slot owned by the producer
//                        between _realtime_reserve and _realtime_-
//                        activate)
//   realtime-producer  — A.2 additions; safe to call from a SINGLE
//                        producer thread while audio is running.
//                        Mutation is mediated by the SPSC command
//                        queue drained at the top of process_graph
//   read-only          — reads scalar / atomic fields; may return
//                        stale values during concurrent mutation
//                        but cannot crash
//   bus-read           — copies bus samples; tearable but not racy
//                        on container shape
//   audio-life         — open/close/poll the realtime stream
//   render             — runs process_graph; offline-only when the
//                        audio callback is also running
//   alloc-reset        — cooperate with the audio lifecycle (stop
//                        the stream before mutating state)
// ----------------------------------------------------------------

// ----------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------

// [T:alloc-reset] Allocate a fresh runtime graph handle. Initialises
// template 0 (an empty MetaDef) and instance 0 (an empty GraphInstance
// belonging to template 0) so legacy single-template callers can issue
// add_node / set_control / connect without an explicit rt_graph_template_add
// call. New multi-template callers can either keep the auto-created
// template 0 and add more via rt_graph_template_add, or remove
// instance 0 and start fresh. The caller does not yet hold the handle,
// so concurrency does not arise.
RTGraph *rt_graph_create(int capacity, int max_frames);

// [T:alloc-reset] Stop audio (joining the audio thread) and free the
// graph. Caller must ensure no other thread holds g.
void rt_graph_destroy(RTGraph *g);

// [T:alloc-reset] Reset the graph to the initial state: stops audio
// (joining the callback), clears all templates and instances, and
// reinstates template 0 + instance 0. The handle is preserved.
void rt_graph_clear(RTGraph *g);

// ----------------------------------------------------------------
// Multi-template construction (§2.D.3)
// ----------------------------------------------------------------
//
// An RTGraph holds a vector of MetaDefs (templates), one per registered
// template, plus a flat vector of GraphInstances each carrying its
// template_id. The execution order at process time is the registration
// order of templates: process_graph iterates g.defs from 0 to N-1 and
// for each template_id processes every live instance with that
// template_id.
//
// The Haskell side (compileTemplateGraph) chooses registration order
// to match a topological sort over the inter-template precedence DAG.
// As of §6.C.4 the rule unions buses and buffers — T_a precedes T_b
// iff
//
//   (bfWrites(T_a) ∩ bfReads(T_b))                ≠ ∅   // bus
//   ∨ (bfBufWrites(T_a) ∩ bfBufReads(T_b))         ≠ ∅   // buffer
//
// 'BusInDelayed' / 'BufReadDelayed' reads do not contribute on
// either side, exactly as within a single graph. Cycles in that DAG
// are rejected at compile time, as is a same-buffer 'BufWrite' from
// two different templates (§6.C.4) or from two nodes in one graph
// (§6.C.5). The runtime is a dumb executor — it never inspects the
// precedence relation or reorders.
//
// §6.C.5 also clamps any template carrying a non-empty bfBufWrites
// to polyphony=1 so the same-buffer-writer uniqueness invariant
// survives runtime instance spawning. The clamp is enforced at two
// independent layers: declaratively in the Haskell loaders
// (loadRuntimeGraph / loadRuntimeGraphFused / loadTemplateGraph /
// loadTemplateGraphFused), and as a runtime backstop on the public
// C ABI in rt_graph_template_add_node / rt_graph_template_set_-
// polyphony. Either layer alone is enough; both together cover
// every construction path including direct-C-ABI callers that
// never reach the Haskell loaders. Lifting the single-writer-
// single-instance constraint is reserved for §6.C.5+ once a real
// ordering / mixdown primitive lands.
//
// Cross-template signal flow goes through the shared Server bus pool
// (BusOut/Out -> BusIn/BusInDelayed). The bus pool is single-buffered
// for live reads and double-buffered for delayed reads, with a swap +
// clear at the Server level once per block (see Note [Bus pool
// double-buffering] in rt_graph.cpp). There is no cross-template
// direct port wiring; rt_graph_template_connect's src and dst nodes
// must both belong to the named template.

// [T:construction] Add a fresh, empty MetaDef and return its dense
// template_id. New templates execute strictly *after* every previously
// registered template within each block. Returns -1 on failure (g is
// null).
int rt_graph_template_add(RTGraph *g);

// [T:read-only] Number of templates currently registered. Iterate
// 0..count-1 to enumerate template_ids.
int rt_graph_template_count(RTGraph *g);

// [T:construction] Set the polyphony cap for a template — the maximum
// number of simultaneously-live (Active or Releasing) instances of
// that template. rt_graph_template_instance_add returns -1 once the
// cap is reached; the runtime does not steal voices automatically.
// Caller-side policy such as VoiceAllocator owns stealing/retry
// decisions.
//
// Default: 8 per template (covers existing tests). Callers that need
// more declare it explicitly during construction. Values <= 0 are
// clamped to 1. Silent no-op on invalid template_id.
//
// §6.C.5 backstop: if the template currently carries any buffer-
// writer node (today: NodeKind::RecordBufMono), the cap is silently
// clamped to 1 regardless of the requested value. Pairs with the
// matching clamp in rt_graph_template_add_node so the runtime
// honors the single-writer-single-instance invariant on every
// public-ABI construction path. See Note [§6.C.5 single-writer-
// single-instance invariant] in rt_graph.cpp.
//
// See Note [Pool model] in rt_graph.cpp for how the cap interacts
// with the pre-allocated GraphInstance pool, and Note [Thread safety
// contract] for why this is construction-only.
void rt_graph_template_set_polyphony(RTGraph *g, int template_id, int polyphony);

// [T:construction] Add or reconfigure one node at its dense runtime
// index in the named template. Walks every live instance of that
// template and installs freshly-initialized state at the same index,
// so adding a node early or late produces the same final layout
// per-template. Instances of other templates are not touched (each
// template has its own dense node space). Silent no-op if template_id
// is invalid.
//
// §6.C.5 backstop: dropping a buffer-writer kind (today:
// NodeKind::RecordBufMono) into a template with polyphony > 1
// silently clamps the cap to 1 in place. See Note [§6.C.5 single-
// writer-single-instance invariant] in rt_graph.cpp.
void rt_graph_template_add_node(RTGraph *g, int template_id,
                                int node_index, int node_kind);

// [T:construction] Attach a Phase 5.2 migration identity key to one
// node in a template. Keys are optional, scoped per template, and used
// by rt_graph_prepare_swap_from_graph to build a controls/state
// migration plan. key_len must be in 1..16; bytes are opaque but may
// not include NUL. Returns 1 on success, 0 on invalid args, duplicate
// key in the same template, or overlong key.
int rt_graph_template_set_node_migration_key(
    RTGraph *g, int template_id, int node_index,
    const char *key, int key_len);

// [T:construction] Attach a Phase 5.4.B template identity token. Used
// only by rt_graph_prepare_swap_from_graph as a precondition: if any
// live (Active or Releasing) old slot's template_id has identities set
// on both old and new defs[template_id] and the tokens differ, prepare
// returns nullptr. Identities are optional; templates without one opt
// out of the precondition. key_len must be in 1..16; bytes are opaque
// but may not include NUL. Returns 1 on success, 0 on invalid args.
int rt_graph_template_set_identity(
    RTGraph *g, int template_id,
    const char *key, int key_len);

// [T:construction] Set one entry of a template's spec.default_controls.
// New instances created later via rt_graph_template_instance_add inherit
// the value; existing instances are *not* mutated. Use
// rt_graph_instance_set_control to update a specific live instance.
void rt_graph_template_set_default(RTGraph *g, int template_id,
                                   int node_index, int control_index,
                                   double value);

// [T:construction] Connect one source output port to one destination
// input port within the named template. Wiring lives on the spec side
// and is shared by every instance of the template. Both src and dst
// must belong to the same template — cross-template signal flow goes
// through the bus pool, not direct wiring.
void rt_graph_template_connect(RTGraph *g, int template_id,
                               int src_index, int src_port,
                               int dst_index, int dst_port);

// [T:construction] Mark a node in the named template as elided. An
// elided node remains in the spec — its NodeIndex is preserved,
// its controls remain addressable via rt_graph_template_set_default,
// rt_graph_instance_set_control, and the realtime control queue —
// but process_instance skips its kernel. The Step C single-edge
// fusion pass uses this to keep a Gain node addressable while
// absorbing its per-block work into the consumer's input read.
//
// Silent no-op on invalid template_id or node_index. Idempotent:
// marking the same node elided twice is harmless.
void rt_graph_template_set_node_elided(RTGraph *g, int template_id,
                                       int node_index);

// [T:construction] Wire one input port of a destination node so it
// reads through a fused scaled-source form rather than from a
// producer's output buffer. At runtime the input resolver
// materializes the value as
//
//   scratch[i] = src[i] * static_cast<float>(scale_node.controls[scale_control])
//
// into a per-instance scratch buffer (allocated here, never grown
// in the audio callback) and returns a span over it. Mirrors the
// scalar branch of process_gain so fused vs. unfused outputs are
// bit-identical.
//
// The scale control is read live: rt_graph_instance_set_control
// (or the realtime queue) targeting (scale_node, scale_control)
// continues to drive the fused output, exactly as it did the
// dispatched Gain.
//
// Allocates one fresh scratch slot per call. Walks every live
// instance of the named template to grow its scratch storage
// in lockstep, mirroring rt_graph_template_add_node's parallel-
// growth contract. Construction-only: must run before audio
// starts.
//
// Silent no-op on any invalid index (template_id, dst_node /
// dst_port out of range, src_node / src_port likewise, or
// scale_node / scale_control likewise). Multiple fused-input
// wires (any of the fused-* connect entries) to the same
// (dst_node, dst_port) overwrite the previous; the older scratch
// slot becomes unused but is not reclaimed.
void rt_graph_template_connect_fused_scale_input(
    RTGraph *g, int template_id,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int scale_node, int scale_control_index);

// [T:construction] Wire one input port of a destination node so it
// reads through a chained fused scaled-source form: a single source
// buffer multiplied by a sequence of scalar gains, applied in
// source-to-sink order.
//
// Operationally equivalent to making N consecutive single-edge fused
// inputs, except (a) it claims one scratch slot regardless of chain
// length, and (b) the resolver applies all scales in a single
// per-block pass, preserving float multiplication order so the fused
// output is bit-identical to the unfused chain of process_gain
// kernels:
//
//   scratch[i] = src[i]
//   for k in 0 .. scale_count-1:
//     k_f = sanitize_finite(static_cast<float>(scale_nodes[k]
//                            .controls[scale_controls[k]]), 1.0f)
//     for i in 0 .. nframes-1: scratch[i] *= k_f
//
// scale_count must be ≥ 1. Each (scale_nodes[k], scale_controls[k])
// pair is a live read on every block — the elided Gain nodes remain
// addressable and rt_graph_instance_set_control on any of them
// continues to drive the consumer's input.
//
// Validation: every scale_node / scale_control pair is checked
// before the scratch slot is claimed. On any invalid index (or null
// arrays / zero count), this is a silent no-op and no slot is
// allocated. Multiple fused-input wires (any of the fused-* connect
// entries) to the same (dst_node, dst_port) overwrite the previous;
// the older scratch slot becomes unused but is not reclaimed.
//
// Construction-only: must run before audio starts. Walks every live
// instance of the named template to grow its scratch storage in
// lockstep with the new slot, mirroring the parallel-growth contract
// of rt_graph_template_add_node.
void rt_graph_template_connect_fused_scale_chain_input(
    RTGraph *g, int template_id,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int scale_count,
    const int *scale_nodes,
    const int *scale_controls);

// [T:construction] Phase 4.C.2: wire one input port through an
// affine chain — a run of scalar Gain (multiply) and scalar Add
// (bias) operations applied in source-to-sink order. Generalises
// rt_graph_template_connect_fused_scale_input and the chain entry:
// every fused input that contains at least one bias step takes
// this entry; pure-scale chains stay on the older entries to keep
// existing callers and tests bit-identical.
//
//   step_kinds[k]:    0 = Scale (multiply), 1 = Bias (add)
//   step_nodes[k]:    NodeIndex of the elided producer (kept
//                     addressable for set_control / realtime
//                     control writes)
//   step_controls[k]: control slot on that node — 0 for Gain;
//                     0 or 1 for Add, depending on which port
//                     held the bias literal.
//
// Per-block resolver materializes:
//
//   scratch[i] = src[i]
//   for k in 0 .. step_count-1:
//     v = sanitize_finite(static_cast<float>(step_nodes[k]
//                          .controls[step_controls[k]]),
//                         step_kinds[k] == 0 ? 1.0f : 0.0f)
//     if step_kinds[k] == 0: for i in 0..nframes-1: scratch[i] *= v
//     if step_kinds[k] == 1: for i in 0..nframes-1: scratch[i] += v
//
// Float arithmetic is non-associative so step order is preserved;
// scales are *not* pre-multiplied and biases are *not* pre-summed.
// Each control is read live every block, so set_control on any
// elided Gain or Add still drives the consumer's input.
//
// Validation: every step (kind ∈ {0,1}, node + control range) is
// checked before the scratch slot is claimed. Any failure or null
// arrays / zero count is a silent no-op. step_count must be ≥ 1.
// One scratch slot per fused input regardless of chain length.
// Construction-only; walks every live instance to grow scratch in
// lockstep, mirroring the parallel-growth contract.
void rt_graph_template_connect_fused_affine_input(
    RTGraph *g, int template_id,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int step_count,
    const int *step_kinds,
    const int *step_nodes,
    const int *step_controls);

// [T:construction] Add one region to the named template's MetaDef.
// Regions are an execution-order overlay on the template's node array;
// process_instance iterates them as the unit of dispatch when the
// template has at least one region registered, and falls back to a
// flat per-node loop when the regions vector is empty.
//
//   rate         : raw int matching the Haskell 'Rate' lattice ordering
//                  (0=CompileRate, 1=InitRate, 2=BlockRate, 3=SampleRate).
//                  Stored verbatim for diagnostics and future
//                  rate-aware executor decisions. The runtime does not
//                  currently make decisions based on rate.
//   first_node   : dense index of the region's first node within the
//                  template's node array.
//   node_count   : number of contiguous nodes in this region.
//
// Regions are expected to cover every node in the template exactly
// once with no overlap (the Haskell greedy region pass guarantees
// this). The C ABI does not currently validate that contract — it is
// a precondition. Silent no-op if template_id is invalid or if
// first_node/node_count would step outside the template's node array.
//
// NodeIndex remains the addressable identity for every control-write
// ABI ('rt_graph_template_set_default', 'rt_graph_realtime_set_control',
// etc.). Future fusion passes that elide nodes must preserve or
// redirect their control-slot identities.
void rt_graph_template_add_region(RTGraph *g, int template_id,
                                  int rate, int first_node, int node_count);

// [T:construction] Phase 4.B: add one region to the named template,
// tagged with a region kernel selector. Generalises
// rt_graph_template_add_region: the older entry registers a region
// with kernel = 0 (NodeLoop); this entry lets the Haskell loader
// also register fused-kernel regions of various shapes and
// arities.
//
//   kernel_kind: integer matching the Haskell RegionKernel encoding.
//                The full set of accepted tags is the source of
//                truth on the Haskell side ('kernelTag' in
//                MetaSonic.Bridge.Compile); current tags are
//                  0 = NodeLoop        (per-node dispatch, any arity)
//                  1 = SawLpfGain      (3-node buffer-terminal:
//                                       SawOsc -> LPF -> Gain)
//                  2 = SinGainOut      (3-node sink-terminal:
//                                       SinOsc -> Gain -> Out)
//                  3 = SawLpfGainOut   (4-node sink-terminal:
//                                       SawOsc -> LPF -> Gain -> Out)
//                  4 = SawGainOut      (3-node sink-terminal:
//                                       SawOsc -> Gain -> Out)
//                  5 = NoiseGainOut    (3-node sink-terminal:
//                                       NoiseGen -> Gain -> Out)
//                  6 = BusInLpfGainOut (4-node sink-terminal:
//                                       BusIn -> LPF -> Gain -> Out)
//                The Haskell side machine-checks tag agreement in a
//                property test (mirroring the kindTag pattern in
//                §0.5.1) so this set cannot drift between aligned
//                sender and resolver builds.
//
//   Caller responsibility on version skew. The implementation is
//   /not/ self-healing on an unknown kernel_kind: when the tag is
//   not recognized the call returns without pushing a RegionSpec.
//   That looks innocuous in isolation, but if the template already
//   carries other regions, 'process_instance' takes the
//   region-iterating dispatch path (regions list is non-empty),
//   and the unregistered range silently goes unprocessed — the
//   would-be region's nodes never run. There is no implicit
//   NodeLoop fallback today.
//
//   To safely target a kernel that may not exist in the resolver:
//     * Query 'rt_graph_region_kernel_supported(tag)' first and
//       fall back to 'rt_graph_template_add_region' (NodeLoop)
//       when it returns 0.
//     * Or register every kernel range as NodeLoop first via
//       'rt_graph_template_add_region', then upgrade tags
//       opportunistically — same effect, costs one extra entry.
//   Either approach guarantees every node lives in /some/ region.
//   If a future revision wants the stronger "rejected tag still
//   produces a valid NodeLoop region" guarantee, that has to be
//   an explicit fallback inside the implementation, not a comment.
//
// The remaining arguments mirror rt_graph_template_add_region:
// rate is stored verbatim, first_node + node_count flatten the
// region's contiguous member list. For a fused-kernel region the
// caller is responsible for ensuring 'node_count' matches the
// kernel's expected arity and that the contiguous kind sequence
// matches the kernel's expected shape — for example:
//   * SawLpfGain    needs node_count == 3 and kinds
//                   [SawOsc, LPF, Gain].
//   * SinGainOut    needs node_count == 3 and kinds
//                   [SinOsc, Gain, /sink/] where /sink/ is
//                   either Out or BusOut. Both are operationally
//                   identical sinks (see Note [Bus model]); the
//                   kernel body absorbs them the same way.
//   * SawLpfGainOut needs node_count == 4 and kinds
//                   [SawOsc, LPF, Gain, /sink/] with the same
//                   Out/BusOut rule as SinGainOut.
//   * SawGainOut    needs node_count == 3 and kinds
//                   [SawOsc, Gain, /sink/] (the saw counterpart
//                   of SinGainOut; same Out/BusOut rule).
//   * NoiseGainOut  needs node_count == 3 and kinds
//                   [NoiseGen, Gain, /sink/]. NoiseGen is a
//                   different state class (xorshift PRNG, no
//                   audio inputs, no controls), so the kernel
//                   body is unlike the oscillator sink kernels —
//                   one PRNG read per sample × scalar gain →
//                   bus accumulation. Same Out/BusOut rule on
//                   the terminal slot.
//   * BusInLpfGainOut needs node_count == 4 and kinds
//                   [BusIn, LPF, Gain, /sink/]. The first non-
//                   oscillator producer kernel: the source is a
//                   bus reader, not a generator with phase or
//                   PRNG state. The kernel reads
//                   output_buses[busin_bus][i] inline (same
//                   value process_busin would have copied) and
//                   feeds it through the same LPF + scalar gain
//                   + sink-accumulate pipeline as
//                   SawLpfGainOut. Same Out/BusOut rule on the
//                   terminal slot. An out-of-range BusIn bus
//                   silent-no-ops the block, mirroring
//                   process_busin's invalid-bus contract.
// The runtime validates the kind sequence at dispatch time and
// falls back to per-node iteration on any mismatch.
//
// NodeIndex remains the addressable identity for every control-
// write ABI; the fused kernel reads its members' state and controls
// rather than introducing anonymous state. Silent no-op on invalid
// template_id, range, or kernel_kind.
void rt_graph_template_add_region_kernel(
    RTGraph *g, int template_id,
    int kernel_kind,
    int rate, int first_node, int node_count);

// [T:introspection] Returns 1 if @kernel_kind@ corresponds to a
// region kernel the runtime knows how to dispatch (including
// 0 = NodeLoop), 0 otherwise. Pinned by the Haskell-side
// 'kernelTag' agreement test; mirrors rt_graph_kind_supported for
// node kinds.
int rt_graph_region_kernel_supported(int kernel_kind);

// [T:construction] Phase §4.E.2.C0a: append one descriptive
// schedule step to the named template, layering an interpretation
// on top of the regions appended via rt_graph_template_add_region.
//
//   kind             : ScheduleStepKind tag matching the Haskell
//                      ScheduleStep encoding:
//                        0 = Barrier
//                        1 = FreeLayer
//   item_count       : number of regions covered by this step.
//   region_ordinals  : pointer to item_count ints, each one an
//                      ordinal into the template's region vector
//                      (the same vector rt_graph_template_add_region
//                      appends to, in registered = scheduled order).
//
// The indirect (per-item) shape — rather than a contiguous
// [first_region, first_region + region_count) range — is required
// because Haskell's 'segmentLayers' / 'goLayers' can produce a free
// layer whose members are non-contiguous in regionSchedule order.
// Concretely: a free segment with rrIndex 0, rrIndex 1 (depends on
// 0), rrIndex 2 (independent) yields regionSchedule = [0, 1, 2] but
// layeredRegionSchedule = [FreeLayer {0, 2}, FreeLayer {1}]. A
// contiguous-range encoding would silently rewrite layer {0, 2} to
// {0, 1}, miscategorising rrIndex 1 once C0c consumes the metadata.
//
// Silent no-op on invalid template_id, unknown kind tag, an ordinal
// outside [0, region_count), null region_ordinals on a positive
// item_count, or a non-positive item_count. The validation pass
// runs before any push so a malformed step cannot partially extend
// schedule_step_regions before being rejected. The default executor
// does not consume schedule_steps; the C0c/C1a test executor consumes
// the global-schedule bands derived from them only when
// rt_graph_test_set_global_schedule_execution is on.
//
// The canonical writer-slot key continues to be
//   (template_id, instance_slot, scheduled_region_ordinal,
//    sink_ordinal_within_region)
// so step ordinals are execution metadata rather than part of the
// per-writer-slot identity.
void rt_graph_template_add_schedule_step(
    RTGraph *g, int template_id,
    int kind,
    int item_count,
    const int *region_ordinals);

// [T:control] Spawn an instance of the named template. Returns
// globally-unique instance_id (>= 0) or -1 on failure. Slot reuse: a
// dead slot is reused before appending. The instance carries its
// template_id and is processed by every subsequent rt_graph_process
// call until removed.
int rt_graph_template_instance_add(RTGraph *g, int template_id);

// ----------------------------------------------------------------
// Legacy single-template construction (template 0 shim)
// ----------------------------------------------------------------
//
// These entries operate on template 0 (auto-created by
// rt_graph_create / rt_graph_clear). They are kept unchanged for
// callers that don't need multi-template support; new callers should
// prefer the explicit rt_graph_template_* variants above.

// [T:construction] Template-0 shim for rt_graph_template_add_node.
void rt_graph_add_node(RTGraph *g, int node_index, int node_kind);

// [T:control] Template-0 shim for rt_graph_instance_set_control on
// instance 0. Note: this entry can also grow the bus pool as a side
// effect (when control 0 of an Out / BusOut / BusIn / BusInDelayed
// node is set), which makes it a [T:construction] step in practice
// during graph build. Existing callers always use it during graph
// build, before audio starts; do not call after rt_graph_start_audio.
void rt_graph_set_control(RTGraph *g, int node_index, int control_index,
                          double value);

// [T:construction] Template-0 shim for rt_graph_template_connect.
void rt_graph_connect(RTGraph *g, int src_index, int src_port, int dst_index,
                      int dst_port);

// [T:construction] Template-0 shim for rt_graph_template_add_region.
void rt_graph_add_region(RTGraph *g, int rate, int first_node, int node_count);

// [T:construction] Template-0 shim for rt_graph_template_set_node_elided.
void rt_graph_set_node_elided(RTGraph *g, int node_index);

// [T:construction] Template-0 shim for
// rt_graph_template_connect_fused_scale_input.
void rt_graph_connect_fused_scale_input(
    RTGraph *g,
    int dst_node, int dst_port,
    int src_node, int src_port,
    int scale_node, int scale_control_index);

// [T:render] Offline block rendering. Processes every live instance of
// every template, in template registration (= execution) order.
// nframes must be between 0 and max_frames inclusive. While realtime
// audio is running the audio callback also calls process_graph from
// its own thread; concurrent calls from any other thread are UB.
void rt_graph_process(RTGraph *g, int nframes);

// [T:construction] Grow the shared Server bus pool to cover bus_index.
// No-op if the pool already covers that bus. This is the only
// caller-facing way to size the pool — rt_graph_template_set_default
// and rt_graph_instance_set_control never resize as a side effect of
// writing a control. Construction-only: must run before
// rt_graph_start_audio.
//
// See Note [Explicit bus-pool sizing] in rt_graph.cpp for why the
// implicit-growth path was removed and how the audio thread depends
// on this contract.
void rt_graph_ensure_bus(RTGraph *g, int bus_index);

// [T:bus-read] Copy nframes samples from one server bus into out.
// Returns the number of samples written, or 0 on bad arguments. Reads
// directly from the shared Server bus pool — under §2.C+§2.D.3 the
// pool is shared across all instances of all templates, so there is
// no per-instance / per-template scope for bus reads. Intended for
// offline rendering and tests; calling while audio is running may
// return torn samples (no resize race; the pool is not grown after
// construction).
int rt_graph_read_bus(RTGraph *g, int bus_index, int nframes, float *out);

// [T:audio-life] Realtime audio via q_io/PortAudio.
// output_channels <= 0 means: infer from configured Out buses, minimum 1.
// device_id < 0 means: use the PortAudio default output device if possible,
// otherwise the first device with enough output channels.
// Returns 0 on success, negative values on failure.
int rt_graph_start_audio(RTGraph *g, int output_channels, int device_id);

// [T:audio-life] Wait until the realtime callback has executed at
// least once. Polls an std::atomic<bool>; safe to call concurrently
// with the callback. timeout_ms < 0 waits indefinitely.
// Returns 0 when started, negative values on error/timeout.
int rt_graph_wait_started(RTGraph *g, int timeout_ms);

// [T:audio-life] Stop realtime audio if it is running. Joins the
// audio thread before returning.
void rt_graph_stop_audio(RTGraph *g);

// [T:construction] Phase §6.C.3a: allocate a mono float32 buffer of
// `frames` samples. Returns the assigned 0-based buffer ID on
// success, or -1 if the pool is full (>= 64 allocated). The
// underlying storage is zero-initialised; load samples in with
// rt_graph_buffer_load_f32. `frames` must be >= 0; negative values
// are rejected with -1. Construction-only: must run before
// rt_graph_start_audio.
int rt_graph_buffer_alloc(RTGraph *g, int frames);

// [T:construction] Phase §6.C.3a: copy `frame_count` float32 samples
// from `samples` into buffer `buffer_id`, starting at frame 0.
// Returns the number of frames written, or:
//   -1 if buffer_id is out of range or unallocated,
//   -2 if frame_count > the buffer's allocated frame count,
//   -1 if samples is null and frame_count > 0.
// Construction-only: must run before rt_graph_start_audio.
int rt_graph_buffer_load_f32(
    RTGraph *g,
    int buffer_id,
    const float *samples,
    int frame_count);

// [T:construction] Phase §6.C.3a: stopped-audio fast path. Flip
// `buffer_id` from Allocated back to Unallocated. The underlying
// storage capacity is preserved for reuse. UNSAFE to call while
// audio is running — the audio thread may still be reading from
// this slot. For the live-safe path, use rt_graph_buffer_retire
// + rt_graph_buffer_collect_retired instead. Returns 0 on
// success, -1 if buffer_id is out of range or the slot is not
// currently Allocated (callers must collect a Retired slot
// before they can clear or reuse it).
int rt_graph_buffer_clear(RTGraph *g, int buffer_id);

// [T:realtime-producer] Phase §6.C.3b slice 2: live-safe drop of a
// buffer reference. Flips the slot from Allocated to Retired,
// without touching its samples storage. Every subsequent
// PlayBufMono kernel call sees state == Retired through an
// acquire-load and takes the invalid-read path (emits zero +
// ticks rt_graph_test_buffer_invalid_read_count). The audio
// thread may still hold a samples.data() pointer captured at
// the top of the current block — that pointer remains valid
// because retire never resizes or frees samples. Single-producer
// (SPSC contract with collect_retired). Returns 0 on success,
// -1 if buffer_id is out of range or the slot is not currently
// Allocated.
int rt_graph_buffer_retire(RTGraph *g, int buffer_id);

// [T:realtime-producer] Phase §6.C.3b slice 2: live-safe reap of a
// retired buffer slot. If the audio thread has crossed at least
// one block boundary since the matching retire (i.e. the
// internal buffer-retire-generation counter has advanced past
// the snapshot stamped by retire), no pre-retire pointer can
// survive — every kernel call since the retire has seen state
// == Retired and taken the invalid-read path. Transitions the
// slot back to Unallocated; storage capacity is preserved for
// the next rt_graph_buffer_alloc. Returns 0 on success, -1 if
// buffer_id is out of range or the slot is not currently
// Retired, -2 if a pre-retire pointer might still be in flight
// (the producer should call rt_graph_process at least once more
// and retry).
int rt_graph_buffer_collect_retired(RTGraph *g, int buffer_id);

// [T:read-only] Phase §6.C.3a test surface: total number of
// successful sample reads performed by KPlayBufMono kernels since
// g was created. Counts one tick per kernel-per-sample (not
// per-block). Returns 0 if no block has run yet, or if g is null.
long long rt_graph_test_buffer_read_count(const RTGraph *g);

// [T:read-only] Phase §6.C.3a test surface: total number of reads
// against an invalid buffer_id (out of range or unallocated) by
// KPlayBufMono kernels since g was created. These reads emit
// zeros; the counter is the only way to distinguish "kernel
// emitted zeros because no buffer" from "kernel didn't run at
// all." Returns 0 if no block has run yet, or if g is null.
long long rt_graph_test_buffer_invalid_read_count(const RTGraph *g);

// [T:read-only] Phase §6.C.4 follow-up test surface: total number of
// successful sample writes performed by KRecordBufMono kernels
// since g was created. Counts one tick per kernel-per-sample.
// Returns 0 if no block has run yet, or if g is null.
long long rt_graph_test_buffer_write_count(const RTGraph *g);

// [T:read-only] Phase §6.C.4 follow-up test surface: total number of
// write attempts against an invalid buffer_id (out of range,
// unallocated, retired, or past the end in one-shot mode) by
// KRecordBufMono kernels since g was created. These writes
// emit no mutation; the counter is the only way to
// distinguish "kernel skipped a write because no buffer" from
// "kernel didn't run at all." Returns 0 if no block has run
// yet, or if g is null.
long long rt_graph_test_buffer_invalid_write_count(const RTGraph *g);

// [T:read-only] Phase §6.D slice 2 test surface: number of
// analysis FFT calls performed by KSpectralFreeze kernels
// since g was created. Each tick corresponds to exactly one
// FFT pass at an analysis-hop boundary; counter-confirmed
// tests can derive expected counts from
// floor((samples_in_so_far) / hop). Returns 0 if no
// spectral kernel has run, or if g is null.
long long rt_graph_test_spectral_analysis_count(const RTGraph *g);

// [T:read-only] Phase §6.D slice 2 test surface: number of
// resynthesis IFFT calls performed by KSpectralFreeze
// kernels since g was created. Mirrors the analysis
// counter: one tick per IFFT call. In pass-through mode the
// analysis and resynthesis counts advance in lockstep; in
// freeze mode (slice 3) the analysis counter stops while
// the resynthesis counter keeps ticking. Returns 0 if no
// spectral kernel has run, or if g is null.
long long rt_graph_test_spectral_resynthesis_count(const RTGraph *g);

// [T:read-only] Pure introspection: returns 1 if node_kind names a kind
// this runtime knows how to construct (i.e. it has a case in
// rt_graph_add_node), 0 otherwise. Intended for contract tests that
// verify Haskell's NodeKind tags agree with this file's enum.
int rt_graph_kind_supported(int node_kind);

// [T:read-only] Phase §4.E.2.B0 test surface: the count of canonical
// writer slots reserved during the most recent rt_graph_process call.
// Equals the total of:
//
//   - For each Active or Releasing instance of every template:
//       - One slot per Out / BusOut NodeSpec dispatched through
//         dispatch_node (flat-fallback path or NodeLoop region).
//       - One slot per sink-terminal fused region (SinGainOut,
//         SawGainOut, NoiseGainOut, SawLpfGainOut, BusInLpfGainOut,
//         NoiseLpfGainOut).
//
// Buffer-terminal regions and non-sink nodes contribute zero. Returns
// 0 if no block has run yet, or if g is null. Used by offline tests
// to assert canonical-order reservation across flat-fallback,
// NodeLoop, fused-sink, and cross-instance / cross-template
// scenarios — the count is what Phase B2 will use to size the
// active portion of the contribution table.
int rt_graph_test_last_writer_slot_count(const RTGraph *g);

// [T:read-only] Phase §4.E.2.B1 test surface: writer-slot capacity
// the contribution storage is currently sized for. Equals
// Σ_t max(def[t].polyphony, occupied_t) × sink_writer_count[t]
// at the high-water mark, where occupied_t counts {Active,
// Releasing, Reserved} instances. Updated by every construction
// mutation that can affect the bound (rt_graph_template_add,
// rt_graph_template_set_polyphony, rt_graph_template_add_node,
// rt_graph_clear). Grow-only — see Note [Contribution storage —
// Phase §4.E.2.B1]. Returns 0 on null g.
int rt_graph_test_contribution_slot_capacity(const RTGraph *g);

// [T:read-only] Phase §4.E.2.B1 test surface: total sample count
// in the contribution storage's per-slot frame buffers. Equals
// rt_graph_test_contribution_slot_capacity * max_frames at every
// point construction is observable from outside. Used by tests
// as a cross-check that samples sizing tracks slot capacity.
// Returns 0 on null g.
int rt_graph_test_contribution_sample_count(const RTGraph *g);

// [T:read-only] Phase §4.E.2.B1 test surface: contribution
// target-vector size. Equals rt_graph_test_contribution_slot_capacity
// for any well-formed storage state, since target is one int per
// writer slot. Returns 0 on null g.
int rt_graph_test_contribution_target_count(const RTGraph *g);

// [T:read-only] Phase §4.E.2.B1 test surface: contribution
// used-bitset word count. Equals
// (rt_graph_test_contribution_slot_capacity + 63) / 64 for any
// well-formed storage state — one 64-bit word covers up to 64
// slots. Together with the sample and target accessors, this is
// the third leg that makes "all parallel storage vectors stay in
// lockstep" testable. Returns 0 on null g.
int rt_graph_test_contribution_used_word_count(const RTGraph *g);

// [T:test-only] Phase §4.E.2.B2 reduction-capture switch. When
// non-zero, the next rt_graph_process call routes every sink
// write into the per-writer-slot contribution buffer instead of
// server.output_buses, and records target / used metadata for
// each slot. The serial reduction fold then accumulates used slots
// back into server.output_buses at deterministic join points so
// later live BusIn reads see canonically earlier writes. Default
// off; tests opt in to inspect the capture and assert direct-vs-
// reduction equivalence. No-op on null g.
void rt_graph_test_set_reduction_capture(RTGraph *g, int on);

// [T:test-only] Phase §4.E.2.C0c/C1a schedule-executor switch. When
// non-zero, metadata-bearing graphs execute serially by walking the
// per-block global-schedule bands instead of the legacy nested
// template/instance loop. If any live instance's template has no
// schedule metadata, the runtime falls back to the legacy loop for
// the whole block so C++-only construction paths keep rendering.
// Default off; no-op on null g.
void rt_graph_test_set_global_schedule_execution(RTGraph *g, int on);

// [T:test-only] Phase §4.E.2.C1b worker-pool scaffold. Sets the
// logical worker lane count on the RTGraph-owned pool. Values <= 1
// create no background worker threads and keep execution purely
// serial. Values > 1 create (worker_count - 1) idle background
// workers. With global-schedule execution enabled, C1c can use those
// workers for conservative Free-band dispatch. This is construction /
// test-only: call while audio is stopped. No-op on null g.
void rt_graph_test_set_worker_pool_size(RTGraph *g, int worker_count);

// [T:read-only] Current logical worker lane count configured via
// rt_graph_test_set_worker_pool_size. Returns 0 on null g.
int rt_graph_test_worker_pool_size(const RTGraph *g);

// [T:read-only] Number of background worker threads currently owned by
// the graph. Returns 0 on null g. For logical sizes 0 and 1 this is 0;
// for logical size N > 1 this is N - 1.
int rt_graph_test_worker_thread_count(const RTGraph *g);

// [T:read-only] Phase §4.E.2.C1c-b test counters from the most recent
// process block. `parallel_band_count` is the number of Free bands
// dispatched through the worker pool; `parallel_entry_count` is the
// total entries claimed by that path; `serialized_free_band_count` is
// the number of multi-entry Free bands explicitly kept on the audio
// thread because they contained sink writers while reduction mode was
// off. All return 0 on null g.
int rt_graph_test_last_parallel_band_count(const RTGraph *g);
int rt_graph_test_last_parallel_entry_count(const RTGraph *g);
int rt_graph_test_last_serialized_free_band_count(const RTGraph *g);

// [T:read-only] Phase §4.E.2.B2 test surface: per-slot resolved
// bus index for the most recent reduction-capture block.
// Returns target[ws] for ws in [0, slot_capacity); -1 means
// either the slot wasn't opened this block, or it was opened
// with an invalid bus control. Returns -1 on null g or
// out-of-range ws.
int rt_graph_test_contribution_slot_target(const RTGraph *g, int ws);

// [T:read-only] Phase §4.E.2.B2 test surface: per-slot used bit
// for the most recent reduction-capture block. Returns 1 if the
// slot was opened with a valid bus this block, 0 otherwise
// (early exit, invalid bus, or slot not reserved). Returns 0 on
// null g or out-of-range ws.
int rt_graph_test_contribution_slot_used(const RTGraph *g, int ws);

// [T:read-only] Phase §4.E.2.B2 test surface: copy a slot's
// per-frame buffer into 'out' for inspection. Writes the first
// 'nframes' frames of contribution_storage's slot ws into
// out[0..nframes). Returns 0 on success, -1 on null g, null out,
// out-of-range ws, or nframes exceeding the slot capacity. The
// destination is left untouched on error.
int rt_graph_test_read_contribution_slot(const RTGraph *g, int ws,
                                         int nframes, float *out);

// [T:read-only] Phase §4.E.2.C0a test surface: number of schedule
// steps registered for the named template via
// rt_graph_template_add_schedule_step. Returns 0 if g is null or
// template_id is out of range. Loaders are expected to ship one
// step per Haskell ScheduleStep, so this should equal
// length (layeredRegionSchedule rg) for any well-formed template.
int rt_graph_test_template_schedule_step_count(
    const RTGraph *g, int template_id);

// [T:read-only] Phase §4.E.2.C0a test surface: ScheduleStepKind
// tag of the @step_index@-th step on the named template. Returns
//   0 = Barrier
//   1 = FreeLayer
// or -1 if g is null, template_id is out of range, or step_index
// is out of range. Pinned by Haskell-side metadata-equivalence
// tests against layeredRegionSchedule.
int rt_graph_test_template_schedule_step_kind(
    const RTGraph *g, int template_id, int step_index);

// [T:read-only] Phase §4.E.2.C0a test surface: number of regions
// covered by the @step_index@-th step. Returns -1 on null g or
// out-of-range indices.
int rt_graph_test_template_schedule_step_item_count(
    const RTGraph *g, int template_id, int step_index);

// [T:read-only] Phase §4.E.2.C0a test surface: the scheduled-
// region ordinal at @item_index@ within the @step_index@-th step,
// resolved through MetaDef::schedule_step_regions. Returns -1 on
// null g, out-of-range template_id / step_index / item_index, or
// a backing-vector underrun (the slice points past the end of
// schedule_step_regions — only possible if a future change
// corrupts the storage; the C ABI's add entry validates step
// shapes up-front).
int rt_graph_test_template_schedule_step_region(
    const RTGraph *g, int template_id, int step_index, int item_index);

// [T:read-only] Phase §4.E.2.C0b test surfaces. The runtime
// rebuilds a per-block "global schedule" at the top of every
// rt_graph_process call: a flat list of (template_id,
// instance_slot, step_index) entries in canonical
//   template ascending → instance slot ascending → step ascending
// order, filtered to instances whose state is Active or
// Releasing. By default this is observational; when the C0c/C1a
// test switch is enabled, metadata-bearing graphs execute serially
// by walking the bands derived from this schedule. After rt_graph_clear
// (or before any block has run), the vector is empty. Templates with
// no schedule_steps emit no
// entries even when they have live instances; that's the "no
// metadata, no schedule" fallback for the legacy single-template
// build path.

// Number of entries built for the most recent block.
int rt_graph_test_global_schedule_entry_count(const RTGraph *g);

// Per-entry accessors. Return -1 on null g or out-of-range
// entry_index (i.e. >= rt_graph_test_global_schedule_entry_count).
int rt_graph_test_global_schedule_entry_template(
    const RTGraph *g, int entry_index);
int rt_graph_test_global_schedule_entry_instance(
    const RTGraph *g, int entry_index);
int rt_graph_test_global_schedule_entry_step(
    const RTGraph *g, int entry_index);

// [T:read-only] Phase §4.E.2.C0d test surfaces. The runtime derives a
// second per-block vector of contiguous "bands" over the C0b global
// schedule:
//   0 = Barrier  (one serial GlobalScheduleEntry)
//   1 = Free     (one or more FreeLayer entries that the conservative
//                 v1 rule would be allowed to dispatch together)
// The C1a executor walks these bands serially; Phase C can replace the
// Free-band loop with worker dispatch. Return -1 on
// null g or out-of-range band_index for per-band accessors.

int rt_graph_test_global_schedule_band_count(const RTGraph *g);
int rt_graph_test_global_schedule_band_kind(
    const RTGraph *g, int band_index);
int rt_graph_test_global_schedule_band_first_entry(
    const RTGraph *g, int band_index);
int rt_graph_test_global_schedule_band_entry_count(
    const RTGraph *g, int band_index);

// [T:read-only] Phase §4.E.2.C1d-a test surfaces. The runtime expands
// each GlobalScheduleEntry into one RegionLayerWorkItem per scheduled
// region item at the top of every rt_graph_process call. This vector is
// observational in C1d-a: execution still consumes global schedule
// bands exactly as before. Per-item accessors return -1 on null g or
// out-of-range item_index. Capacity returns the currently reserved
// vector capacity so tests can pin the no-allocation audio-path bound.
int rt_graph_test_region_layer_work_item_count(const RTGraph *g);
int rt_graph_test_region_layer_work_item_capacity(const RTGraph *g);
int rt_graph_test_region_layer_work_item_entry(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_template(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_instance(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_step(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_item(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_region(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_first_writer_slot(
    const RTGraph *g, int item_index);
int rt_graph_test_region_layer_work_item_writer_slot_count(
    const RTGraph *g, int item_index);

// [T:read-only] Phase §4.E.2.C1d-a counters from the most recent
// process block. Candidate entries are multi-region FreeLayer steps
// whose regions are all sink-free and therefore are potential C1d
// region-level worker-dispatch groups. Serialized sink entries are
// multi-region FreeLayer steps containing at least one sink writer.
// All return 0 on null g.
int rt_graph_test_last_c1d_candidate_entry_count(const RTGraph *g);
int rt_graph_test_last_c1d_candidate_item_count(const RTGraph *g);
int rt_graph_test_last_c1d_serialized_sink_entry_count(const RTGraph *g);

// [T:read-only] Phase §4.E.2.C1d-b counter from the most recent process
// block. Counts scheduled region items dispatched through the C1d-b
// serial region-item executor in process_schedule_band_serial. The
// legacy executor (no rt_graph_test_set_global_schedule_execution) and
// the C1c worker pool both bypass this path; tests assert non-zero
// only when the C1d-b path actually consumed RegionLayerWorkItem
// entries. Returns 0 on null g.
int rt_graph_test_last_c1d_serial_region_item_execution_count(
    const RTGraph *g);

// [T:read-only] Phase §4.E.2.C1d-c counters from the most recent
// process block. `parallel_entry_count` increments once per multi-
// region sink-free FreeLayer entry dispatched through the worker pool
// at region-item granularity inside process_schedule_band_serial.
// `parallel_region_item_count` totals the region items handed to the
// pool. The C1c band-level worker path and the C1d-b serial path both
// bypass these counters, so non-zero values prove region-item dispatch
// was the path actually exercised this block. All return 0 on null g.
int rt_graph_test_last_c1d_parallel_entry_count(const RTGraph *g);
int rt_graph_test_last_c1d_parallel_region_item_count(const RTGraph *g);

// ----------------------------------------------------------------
// Phase 5.1.B: RCU hot-swap protocol substrate + world payload
// ----------------------------------------------------------------
//
// The swap protocol installs a prepared RTGraphState at a block
// boundary. The previous active world is moved into the same
// RTGraphSwap as retired payload; deleting the collected swap frees
// that old world off-audio.
//
// Lifecycle:
//
//   1. Off-audio thread calls rt_graph_prepare_swap(g) -> swap for a
//      default empty world, or builds a separate offline RTGraph and
//      calls rt_graph_prepare_swap_from_graph(target, builder) to move
//      that builder's world into the swap.
//   2. Off-audio calls rt_graph_publish_swap(g, swap). Returns 1 on
//      success, 0 if args are invalid or any previous swap is still
//      pending, installing, or retired-but-not-collected. On success,
//      the runtime owns `swap` from this point.
//   3. The next rt_graph_process call's audio thread acquires the
//      pending swap at the top of the block, advances
//      swap_generation, replaces the active world, and moves the
//      consumed swap to a one-deep retire slot.
//   4. Off-audio polls rt_graph_collect_retired_swap(g) and frees
//      the returned swap. Producer is contractually required to reap
//      until the call returns the retired swap after each publish.
//      A new publish is rejected while any previous swap is pending,
//      installing, or retired-but-not-collected.
//
// rt_graph_cancel_swap is the rollback path for a prepared but not
// yet published swap; once publish has succeeded the runtime owns the
// swap and only the audio thread can move it to the retire slot.
//
// See notes/2026-05-10-phase-5-rcu-hot-swap-design.md for the full
// protocol, world boundary, and migration deferral rationale.

// [T:construction] Allocate a default next-world handle off-audio. The
// next world is equivalent to a freshly-cleared graph: template 0 plus
// active instance 0, no nodes, no buses, no schedule metadata. The
// returned pointer is owned by the caller until either
// rt_graph_cancel_swap or a successful rt_graph_publish_swap. Returns
// null if g is null.
RTGraphSwap *rt_graph_prepare_swap(RTGraph *g);

// [T:construction] Move the swappable world from an offline builder
// graph into a next-world handle for `target`. target and source must
// be non-null, distinct handles with the same max_frames. On success,
// source is reset to the same default state as rt_graph_clear and the
// caller owns the returned swap until cancel or successful publish.
// This lets producers reuse the existing RTGraph construction ABI to
// build a future world without duplicating every construction call for
// RTGraphSwap. Returns null on invalid args or if source itself has a
// swap in flight.
RTGraphSwap *rt_graph_prepare_swap_from_graph(RTGraph *target,
                                              RTGraph *source);

// [T:construction] Free an unpublished swap. Silent no-op on null. Do
// not call after rt_graph_publish_swap has succeeded for this swap;
// once the runtime owns the swap, only the audio thread + the retire
// reap path may move it.
void rt_graph_cancel_swap(RTGraph *g, RTGraphSwap *swap);

// [T:realtime-producer] Atomically publish `swap` as the pending next
// world. Returns 1 on success, 0 if a swap is already pending or args
// are null. Returns 0 as well while a previous swap has installed but
// not yet been collected. On success, the audio thread acquires `swap`
// at the top of the next process_graph block and the runtime owns it
// from publish time forward.
//
// Single-producer contract. Only one off-audio thread may publish.
// Concurrent publish from multiple threads is undefined behavior.
int rt_graph_publish_swap(RTGraph *g, RTGraphSwap *swap);

// [T:realtime-producer] Pop the most recently retired swap, if any.
// Returns null if no swap is waiting. The caller owns the returned
// pointer and must free it via rt_graph_cancel_swap (the same
// destructor — cancel and reap-then-free share the off-audio dispose
// path).
//
// Producer responsibility: collect and dispose the retired swap after
// each successful publish. Until collection happens, the next publish
// fails so the one-deep retire slot cannot be overwritten.
RTGraphSwap *rt_graph_collect_retired_swap(RTGraph *g);

// [T:read-only] Phase 5.1.A test surface: atomic count of swaps the
// audio thread has installed since graph construction (or
// rt_graph_clear). Pinned by tests to assert "the install actually
// happened at a block boundary." Returns 0 on null g, or 0 immediately
// after rt_graph_clear. Producers may poll it after publish to know
// when new-world commands are allowed.
int rt_graph_test_swap_generation(const RTGraph *g);

// [T:read-only] Phase 5.1.A test surface: returns 1 if a swap is
// currently pending publication (published but not yet installed by
// the audio thread), 0 otherwise. Lets tests assert pending state
// without racing the install. Returns 0 on null g.
int rt_graph_test_swap_pending(const RTGraph *g);

// [T:read-only] Phase 5.1.A test surface: returns 1 if a swap is
// currently in the retire slot (installed by the audio thread but not
// yet collected by the producer), 0 otherwise. Returns 0 on null g.
int rt_graph_test_swap_retired_pending(const RTGraph *g);

// [T:read-only] Phase 5.1.B test surface: inspect one control value
// from the retired world stored inside a collected swap. Returns 1 and
// writes *out_value on success, 0 on null args or out-of-range ids.
// This is only meaningful after rt_graph_collect_retired_swap returns
// a non-null swap and before rt_graph_cancel_swap disposes it.
int rt_graph_test_retired_swap_control_value(
    const RTGraphSwap *swap,
    int instance_id,
    int node_index,
    int control_index,
    double *out_value);

// [T:read-only] Phase 5.2.A/B/C migration-plan counters on a prepared or
// collected swap. `committed_count` counts node matches committed into
// the off-audio plan. `skipped_count` counts nodes that could not
// participate in the selected migration slice. `instance_copy_count`
// is written by the audio thread during install and counts per-instance
// control-vector copies actually performed. `state_copy_count` counts
// allocation-free DSP-state copies for supported stateful kinds.
// `lifecycle_copy_count` counts slot lifecycle snapshots copied for
// slot-index/template-matched Active or Releasing instances. All return
// 0 on null swap.
int rt_graph_swap_migration_committed_count(const RTGraphSwap *swap);
int rt_graph_swap_migration_skipped_count(const RTGraphSwap *swap);
int rt_graph_swap_migration_instance_copy_count(const RTGraphSwap *swap);
int rt_graph_swap_migration_state_copy_count(const RTGraphSwap *swap);
int rt_graph_swap_migration_lifecycle_copy_count(const RTGraphSwap *swap);

// [T:read-only] Phase 5.2.A/B/C test surface: reason code for a skipped
// migration-plan entry. Returns -1 on null swap or out-of-range index.
// Values:
//   1 = MissingTag
//   2 = KeyNotFound
//   3 = DuplicateKey
//   4 = KindMismatch
//   5 = ArityMismatch
//   6 = StateUnsupported
int rt_graph_swap_migration_skipped_reason(
    const RTGraphSwap *swap, int skip_index);

// ----------------------------------------------------------------
// Multi-instance support
// ----------------------------------------------------------------
//
// Instances are independent running copies of a template's MetaDef:
// each has its own control values, kernel state (oscillator phase,
// filter memory, delay buffers, envelope position) but shares the
// Server bus pool with every other instance of every template. The
// instance_id returned here is globally unique and stable for the
// life of the instance; it does not encode the template_id.
//
// rt_graph_instance_add (legacy, no template argument) spawns an
// instance of template 0. For instances of other templates use
// rt_graph_template_instance_add above.
//
// rt_graph_process processes every live instance; the realtime audio
// callback sums their bus contributions onto hardware channels via
// the shared Server pool.

// [T:control] Spawn an instance of template 0. Returns the new
// instance_id (>= 0) or -1 on failure (e.g. g is null). Equivalent
// to rt_graph_template_instance_add(g, 0).
int rt_graph_instance_add(RTGraph *g);

// [T:control] Remove the instance; subsequent operations on
// instance_id are silent no-ops. Slots are reused by future
// rt_graph_instance_add / rt_graph_template_instance_add calls.
// Removing instance 0 is allowed and disables the back-compatibility
// single-instance functions until a new instance is added at slot 0.
//
// This is the *hard-free* path: the slot is cleared at the next
// block boundary regardless of whether the instance still has audio
// in flight, so it clicks if applied to a sustaining voice. Use
// rt_graph_instance_release for graceful tear-down (envelope tail
// completes, then slot is reclaimed automatically).
void rt_graph_instance_remove(RTGraph *g, int instance_id);

// [T:control] Request graceful tear-down of an instance. Sets the
// gate control of every Env node in the instance to 0 so envelopes
// start their release ramp, marks the instance as "Releasing", and
// lets it keep processing every block. Once the instance contributes
// silence (per-block peak below an internal threshold) for a small
// number of consecutive blocks, the slot is reclaimed and the
// instance_id may be reused by future rt_graph_instance_add /
// _template_instance_add calls. If the instance has no Env node (no
// envelope to release), the call is equivalent to
// rt_graph_instance_remove. Silent no-op on dead/invalid instance_id.
//
// Pair this with rt_graph_instance_status to observe the lifecycle
// transition (Live -> Releasing -> dead). Hard-free remains
// available via rt_graph_instance_remove for panic stops and voice
// stealing under pressure.
void rt_graph_instance_release(RTGraph *g, int instance_id);

// [T:read-only] Returns the lifecycle status of an instance:
//   0  = Live (Active; the steady-state of a sounding voice)
//   1  = Releasing (release requested, awaiting silence)
//  -1  = no such instance (free slot, slot reserved by a producer
//        but not yet activated, out of range, or null graph)
//
// Both freed and Reserved slots return -1: a freed slot is
// observationally identical to a slot that never existed, and a
// Reserved slot is the producer's private claim (under the Phase-3
// realtime queue) that has not yet been published to the audio
// schedule via Activate. Use rt_graph_instance_alive when the
// distinction the caller cares about is liveness rather than status.
int rt_graph_instance_status(RTGraph *g, int instance_id);

// [T:read-only] Number of instance slots (live + dead). Iterate
// 0..count-1 to enumerate; check liveness with rt_graph_instance_alive.
int rt_graph_instance_count(RTGraph *g);

// [T:read-only] 1 if the slot is part of the audio schedule (Active
// or Releasing), 0 otherwise (free, reserved-but-not-activated, out
// of range, or null graph). May race with the §2.E auto-free path
// and the Phase-3 realtime queue; treat the result as a hint, not a
// synchronization barrier.
int rt_graph_instance_alive(RTGraph *g, int instance_id);

// [T:control] Per-instance variant of rt_graph_set_control.
// instance_id must reference a live or Reserved instance; an
// Available slot is a silent no-op. Mutates the *instance's*
// controls — to set a template's spec defaults, use
// rt_graph_template_set_default.
//
// Direct write on a Reserved slot is permitted as an explicit
// exception to "[T:control] is audio-stopped only" — the slot is
// the producer's private claim before Activate, and the audio
// thread skips Reserved slots in process_graph. The exception
// applies *only* to the producer that owns the reservation; no
// other thread should write to a Reserved slot. Once the producer
// has enqueued Activate, all subsequent control changes must go
// through rt_graph_realtime_set_control (queued).
void rt_graph_instance_set_control(RTGraph *g, int instance_id,
                                   int node_index, int control_index,
                                   double value);

// (rt_graph_instance_read_bus was removed in the post-§2.E ABI
// cleanup. Under §2.C the bus pool is server-global, so an
// instance-keyed bus read added nothing beyond rt_graph_read_bus
// except a liveness gate the caller can do explicitly via
// rt_graph_instance_alive / _status. Use rt_graph_read_bus.)

// ----------------------------------------------------------------
// A.2: realtime ABI — single-producer entries safe to call from a
// non-audio thread while the audio callback is running
// ----------------------------------------------------------------
//
// Mutation that must happen while audio is live (note-on, note-off,
// CC streams, panic stops) goes through these entries, not the
// [T:control] direct entries above. The work is mediated by an
// SPSC lock-free command queue drained at the top of every
// process_graph block. See Note [A.2: realtime control queue] in
// rt_graph.cpp for the design and memory model.
//
// Single-producer contract: only ONE thread may call this group of
// entries. UI / OSC / MIDI ingress should feed a single producer
// thread (typically the voice allocator's input handler), which is
// the only thread that calls these entries. Concurrent calls from
// multiple threads will corrupt the queue. The C ABI cannot enforce
// this — it is the caller's responsibility.
//
// Lifecycle of a realtime spawn:
//
//   1. rt_graph_realtime_reserve(g, template_id) -> slot_id
//      synchronously CAS-claims an Available slot, prepares it
//      (resize nodes, init kernel state, set defaults), and
//      returns it in Reserved state. -1 on failure.
//
//   2. (Optional) rt_graph_instance_set_control on the Reserved
//      slot to override per-note controls. Direct call — see the
//      [T:control] exception above.
//
//   3. rt_graph_realtime_activate(g, slot_id) enqueues Activate.
//      The audio drain CAS-flips Reserved -> Active at the next
//      block boundary, publishing the slot into the schedule.
//      If enqueue fails (queue full), call rt_graph_realtime_cancel
//      to roll back the reservation.

// [T:realtime-producer] Reserve and prepare a slot of the named
// template. Returns slot_id (>= 0) on success, -1 on any failure
// (null graph, invalid template_id, polyphony cap reached, no
// Available slot in the pool to recycle). Realtime reserve never
// grows the slot pool — callers must pre-warm the pool during
// construction (the standard pattern: spawn N instances via
// rt_graph_template_instance_add, then immediately remove them via
// rt_graph_instance_remove; the slots stay Available with their
// vector capacity preserved).
int rt_graph_realtime_reserve(RTGraph *g, int template_id);

// [T:realtime-producer] Cancel a reservation, returning the slot
// to Available without ever publishing it. Used to roll back when
// rt_graph_realtime_activate's enqueue fails. Silent no-op if the
// slot's state is anything other than Reserved (caller bug or
// already activated).
void rt_graph_realtime_cancel(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue Activate(slot_id). Returns 1 on
// success, 0 if the queue is full. The audio drain applies it at
// the next block boundary via a CAS Reserved -> Active. On failure
// the producer should rt_graph_realtime_cancel.
int rt_graph_realtime_activate(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue Release(slot_id) — graceful tear-
// down via §2.E silence-window. The audio drain gates to Active
// only (Reserved is producer-private; Releasing is already in
// flight). Returns 1 on success, 0 if the queue is full.
int rt_graph_realtime_release(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue Remove(slot_id) — hard-free at the
// next block boundary. The audio drain gates to Active or
// Releasing; Reserved slots are producer-private and should be
// canceled via rt_graph_realtime_cancel instead. Returns 1 on
// success, 0 if the queue is full.
int rt_graph_realtime_remove(RTGraph *g, int slot_id);

// [T:realtime-producer] Enqueue SetControl. The audio drain
// applies it only to Active or Releasing slots — Reserved slots
// receive their initial controls from the producer's pre-enqueue
// path (direct rt_graph_instance_set_control on the Reserved
// slot). Returns 1 on success, 0 if the queue is full.
int rt_graph_realtime_set_control(RTGraph *g, int slot_id,
                                  int node_index, int control_index,
                                  double value);

#ifdef __cplusplus
}
#endif
