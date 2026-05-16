
1. Run the manual MIDI smoke with real hardware and capture friction.
   Use it as an operator validation pass, not a new architecture slice:
   ```sh
   stack exec metasonic-bridge -- --authoring-manifest named-control > /tmp/metasonic-named-control-manifest.json
   stack exec metasonic-bridge -- --manifest-reload-plan-file /tmp/metasonic-named-control-manifest.json named-control
   stack exec metasonic-bridge -- --midi-list
   stack exec metasonic-bridge -- --manifest-midi-reload-smoke /tmp/metasonic-named-control-manifest.json named-control --midi-device N --manifest-midi-smoke-seconds 30
   ```
   `named-control` currently binds `vol` to CC 10. Send CC 10 and one
   unbound CC. Do not edit only the JSON to remap the control; the manifest
   reload planner validates it against the compiled demo catalog. If the
   controller can only send another CC, change the demo source binding and
   regenerate the manifest. If the output is confusing, do a tiny UX polish
   pass. A fast controller sweep should produce accepted writes plus drain
   lines, not sustained `SeiQueueFull 128` spam.

2. If the smoke feels usable, commit the current milestone and move to a different roadmap lane.

3. Do not start resource/allocation recovery events yet. The closeout note is right: that needs a real subscriber, such as a UI surface, supervisor telemetry consumer, or CI failure reporter.

---

Yes, but I’d frame it as an experimental audible manifest reload demo, not as changing the normal demo path yet.

It is a good next integration slice because it would be the first real consumer that forces the full stack to work together under audio:

manifest plan -> SessionFanInService with audio -> ingress target -> reloadManifestHostWithStrategy -> close/open ingress -> audible owner continues or falls back

I’d keep the first version very narrow:

New explicit CLI mode, not default:
--manifest-live-reload-demo STRATEGY MANIFEST.json OLD_DEMO NEW_DEMO
Start audio from OLD_DEMO through the manifest/session path.
Open one ingress type first, probably OSC, because it is deterministic and already has real UDP coverage.
Wait for Enter or a simple command trigger.
Run reloadManifestHostWithStrategy STRATEGY to NEW_DEMO.
Print which strategy ran: preserving, stopped-audio, or explicit fallback.
Keep MIDI optional for a later pass.
I would not start with MIDI here. OSC gives you audible, operator-visible reload friction without device discovery and controller noise.

The key constraint: don’t call it the default live demo path yet. It should be an opt-in “first audible pipeline consumer.” That lets us break the non-goal deliberately while preserving the current guarantee that ordinary metasonic-bridge DEMO still uses the established path.
--
Added ManifestLiveReloadDemo.hs (line 1).
Added CLI mode in Main.hs (line 206):
--manifest-live-reload-demo STRATEGY MANIFEST.json OLD NEW
Wired it in package.yaml (line 140).
