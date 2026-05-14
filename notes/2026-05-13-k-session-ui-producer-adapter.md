# Session UI Producer Adapter

This slice adds the first Haskell-only UI producer adapter above
`MetaSonic.Session.FanIn`.

The adapter consumes already-decoded UI intents. It does not implement
a GUI toolkit binding, read or reload an authoring manifest, authorize
commands, define a live clock, or arbitrate against OSC/MIDI/Pattern
beyond the existing FIFO fan-in queue.

## Landed Scope

- `MetaSonic.Session.UIProducer` defines UI intents for voice start,
  voice stop, control write, and hot-swap.
- `decodeUISessionCommand` translates those intents into the shared
  `SessionCommand` vocabulary.
- Producer-local shape checks reject non-finite initial-control and
  control-write values before a command enters the fan-in queue.
- `UIProducerOptions` carries a diagnostic producer name.
- `enqueueUIProducerIntent` submits generated commands to a
  `SessionFanInHost` with `ProducerUI` identity.

## Still Out Of Scope

- GUI toolkit bindings or widget state.
- Manifest-driven session reload/import and resource allocation.
- Authorization or capability policy for UI commands.
- Producer-specific throttling, coalescing, or smoothing.
- Arbitration beyond FIFO producer order.
- Long-running supervision beyond the scoped fan-in service.

## Tests

The tests cover intent-to-command translation for voice on/off, control
write, and hot-swap; non-finite value rejection before enqueue;
successful `ProducerUI` enqueue attribution; rejection without enqueue;
queue-full surfacing; and composition through a scoped
`MetaSonic.Session.FanInService` drain worker.
