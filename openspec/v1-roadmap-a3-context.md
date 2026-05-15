# A3 `edge-vad-and-opener-prefetch` — propose-stage context

Hand-off from A2 `arch-cloud-edge-split` to A3 author. Not a spec; everything
here is "what's already in the repo by A2 ship" so A3's propose phase doesn't
have to re-derive it. **A3 propose still owns the design discussion**; this
note just lists the load-bearing pieces A2 leaves behind.

Source: arch-cloud-edge-split tasks.md § 13.4.

## 1. Cancel channel — already wired by A2

A3 needs a way for the **edge VAD** to interrupt an in-flight TTS chunk
without paying a WAN RTT. The A2 wire-up:

| Path | Mechanism | Where it lives |
|---|---|---|
| Edge → cloud "user spoke" | `Edge2Cloud.CallEvent.user_speaking_started` (proto field already reserved, tag 14) | `isales_common/proto/cloud_edge.proto` line ~244 |
| Cloud-side routing | `EngineSessionDispatcher._dispatch_call_event` → `entry.on_call_event(event)` | `isales_engine/transport/session_dispatcher.py` |
| Cloud → edge "cancel current playback" | `Cloud2Edge.CancelCommand{call_id, reason}` over the same bidi | `cloud_edge.proto` `CancelCommand` |
| Cloud → edge sender | `CloudEdgeGrpcServer.send_to_edge(edge_device_id, msg)` | `isales_engine/transport/grpc_server.py` |
| RtcTelephonyClient.hangup → CancelCommand | already issues `CancelCommand` (A2 PR #5) | `isales_engine/realtime/rtc_telephony.py` |

**Decision A2 already locked**: cancel is in-process within the cloud
instance, MUST NOT cross Redis Pub/Sub. A3 must keep that invariant — the
edge-VAD CallEvent arrives at `EngineSessionDispatcher`, the dispatcher
hands it to the engine session callback, the session cancels in-flight
LLM/TTS in **its own asyncio context**, no extra hop.

**Decision A3 still owns**: whether `user_speaking_started` is also
propagated *back* to the edge as a separate "stop your local playback"
command, or whether edge-VAD does its own local stop and the round-trip
only carries the "tell cloud" signal. PoC §8 (Day 2) measurements should
inform this. Today the proto has both directions reserved (edge sends
`CallEvent.user_speaking_started`, cloud can send `CancelCommand`) so
either choice is wire-compatible.

## 2. Opener pre-render — directory + sync strategy is still open

A2 has **not** decided where pre-rendered openers live or how they sync to
the edge. A3's design.md must close this. The pieces A2 makes available:

- **OSS bucket** is provisioned in Sprint 0 (RUNBOOK-cloud § "阿里云资源开通").
- **Edge SQLite + state dir** at `~/Library/Application Support/isales/`
  already exists for the cloud-edge gRPC buffer (telephony PR #3 / #4).
  A3 likely reuses `~/Library/Application Support/isales/openers/` for
  the pre-rendered PCM/Opus files.
- **`Cloud2Edge.ConfigUpdate`** in `cloud_edge.proto` is the only proto
  hook A2 leaves for "tell the edge to refresh something". If A3 needs
  a "new opener available" push, add a new oneof branch to `ConfigUpdate`
  rather than inventing a separate proto.

**Open questions A3 propose must answer**:

1. Opener key format — by `campaign_id`? `prompt_version_id`? Both
   (so prompt edits invalidate without losing per-campaign sharing)?
2. Sync trigger — pull on heartbeat? Push on campaign save? Lazy on
   dial?
3. Codec — raw 8 kHz PCM (modem-native, no edge resample) or 16 kHz
   PCM (RTC-native, audio-bridge picks)?
4. TTS provider lock-in — pre-render once per opener text, or
   regenerate when voice_model changes?

## 3. Where A3's spec deltas will most likely land

Based on the A3 problem statement in `v1-roadmap.md` L262-278:

- **`interruption-detection` delta**: move the barge-in decision point from
  engine's `realtime/interruption_detector.py` (current location, post-ASR
  partial) to edge-VAD; cancellation-token propagation flowchart.
- **`silence-activation` delta**: VAD physical location moves from
  `isales_engine/realtime/silence_detector.py` (cloud) to edge (where it
  exists in parallel for openers).
- **`deployment-topology` delta**: add `~/Library/Application Support/
  isales/openers/` directory + OSS bucket prefix + sync policy.

(All three already exist as spec capabilities; A3 only adds delta-style
sections.)

## 4. A2 deferred items A3 inherits unchanged

A2 ships these as no-op / placeholder; A3 is free to repurpose them
without coordinating:

- `UserSpeakingStarted` / `UserSpeakingStopped` payload schemas in the
  proto are intentionally empty stubs (cloud_edge.proto L283-289). A3
  fills them with VAD metadata (confidence, energy, timestamp).
- `Cloud2Edge.ConfigUpdate` has only `LogLevelUpdate` /
  `HeartbeatIntervalUpdate` today (proto L196-213). Adding an
  `OpenerCacheRefresh` branch is forward-compatible.

## 5. Things A3 should NOT touch (already final in A2)

- The bidi stream itself (one stream per edge, Bearer-token bound to
  `edge_device_id`).
- The 30 s heartbeat cadence (`Heartbeat` shape, watchdog 120 s
  threshold). If A3 needs faster cadence for VAD telemetry, use a
  separate `CallEvent` payload, not heartbeat.
- The RTC channel-per-call layout (`channel_id = call_id`, double
  participant `engine-{call_id}` / `edge-{call_id}`).
- The cancel = in-process invariant (Decision 5 of A2 design.md). Don't
  reintroduce a Redis Pub/Sub leg for cancel.
