# Sendspin for the NAD C368 BluOS MDC card — design

Date: 2026-11-20. Status: approved 2026-11-20.

## Intent

Make the NAD C368 (BluOS MDC card, BluOS 4.12.11) a **Sendspin player**, so Music Assistant can play to it
in sync with the other Sendspin speakers in the house. It joins the existing `nad-airplay` plugin as a second
front end behind the same BluOS adapter: BluOS still sees one "AirPlay" source, which gives us input
switching, display, app, remote and volume for free (decided 16 Nov; see `nad-recon/SUMMARY.md`).

Why now: AirPlay works, the BluOS plugin protocol and dspout's RTP path are understood and documented in
`docs/PROTOCOL.md`, and Sendspin is Music Assistant's native multi-room protocol. The 16 Nov decision named a
Rust crate as the client; that crate turned out to be a work in progress with no audio output, so this design
replaces it with the official C++ library.

## Goals

1. The amp appears in Music Assistant as a Sendspin player and plays **in sync** with other Sendspin players
   (spec target: steady-state error within ±1 ms of the time filter's prediction; we accept whatever
   dspout's clock allows, and provide a delay setting to trim the rest).
2. Starting playback in Music Assistant switches the amp to the MDC input and shows title, artist, album, art
   and progress on the amp and in the BluOS app, exactly as AirPlay does today.
3. Amp remote / BluOS app next, pause and play control Music Assistant (controller role).
4. Music Assistant's volume slider controls the amp (mapped and capped like AirPlay); mute works; the amp's own
   volume changes are reported back so MA's slider follows.
5. Pairing with Music Assistant works for a device with no display: a pairing token the user can read from the
   device, plus optional unpaired access.
6. Survives reboots (identity, pairings, settings persist under `/var/data`), is restarted by the plugin if it
   crashes, and never endangers the BluOS watchdog.
7. AirPlay keeps working. When both want the amp, **the newest sender wins** (my call, see Decisions).

## Non-goals

- Sendspin **source** role (streaming the amp's inputs into MA), visualizer and color roles.
- Opus (patent-encumbered, optional in the spec; FLAC and PCM are mandatory and enough on a LAN).
- Sample rates other than 44.1 kHz in the first version (see Decisions).
- Showing a separate "Sendspin" source in BluOS. It shows as AirPlay; a proper BluOS source would need
  rootfs UI edits and sovi-core changes we don't have.
- Running when the AirPlay endpoint is disabled in BluOS: Sendspin rides on the same `sovi-airplay` process.
- Code-based pairing (6- or 8-digit codes). The token flow covers a display-less device.

## Anti-goals

- Anything that can kill `dspout`, `sovi-core` or the other watchdog-protected processes (a halt needs a
  mains power-cycle).
- Additional rootfs edits. The two from the AirPlay install are the only ones.
- A second copy of the BluOS plugin protocol in C++. One implementation (Perl) owns it.
- Audible sync corrections (warble, clicks). Let the library do frame-level correction; keep dspout's RTP
  timeline continuous.

## Constraints

- Target: i.MX53 Cortex-A8 (ARMv7-A, NEON, VFPv3), single core ~800 MHz, 244 MB RAM (188 MB available),
  glibc 2.30, perl 5.14 with JSON::PP, no compiler, no package manager, only `/var/data` persistent
  (2.7 GB). `/var/avahi/services` is a writable tmpfs that avahi-daemon watches.
- Audio goes to dspout as RTP over `/var/data/pcm_rtp_socket01` (20-byte header, S16LE, 363-frame packets);
  packets stamped in the past are dropped; timestamps must be continuous. dspout tells us its clock through
  sovi-core's `N` message (stream position in ms at a CLOCK_REALTIME time), every ~5 s.
- Sendspin spec v1 (RC1): Noise KKpsk2 encryption is mandatory; the player advertises `_sendspin._tcp` and
  the server connects to it on ws://<ip>:8928/sendspin; a Kalman time filter and NTP-style bursts are
  required; PCM and FLAC are the mandatory codecs.
- `sendspin-cpp` (Apache-2.0, C++20, host build via CMake + FetchContent: ArduinoJson, IXWebSocket without
  TLS, noise-c reference backend, micro-flac). Its sync engine does **not** expose per-chunk timestamps.
  It expects an ALSA-like sink: `on_audio_output(pcm, format, timeout_ms)` writes PCM at real-time rate, and
  the sink calls `notify_audio_played(frames, finish_time_us)` with the client-clock time at which those
  frames will finish playing. The library inserts/drops frames so that what the sink plays lines up with
  the server timestamps. Its clock is `CLOCK_MONOTONIC_RAW` (`SendspinClient::now_us()`).
- Music Assistant (2.10, Sendspin in "technical preview"): discovers via mDNS, offers "Pair device" (token
  for devices without a code) and "Connect unpaired" when the device allows it, picks codec/rate from the
  player's advertised formats, sends metadata and artwork, accepts play/pause/skip from players.

## Approaches considered

### Client implementation

1. **C++ bridge on `sendspin-cpp` — chosen.** Official, maintained daily, built for embedded, does Noise,
   pairing, time filter, FLAC and buffering. We write a thin program around it. Cost: a C++20 cross-build
   with a newer GCC than our current buster container, linked statically because the card's glibc is 2.30.
2. Go from scratch. Easy static cross-compile and good crypto libraries, but we'd own ~1500 lines of
   protocol code (handshake, filter, pairing, fragmentation, artwork reassembly) and track spec changes alone.
3. Perl on the card. Rejected: no X25519/ChaCha20-Poly1305 without CPAN modules, and the sync loop is too
   tight for the existing 50 ms select loop.
4. The ready-made `sendspin-cpp-cli` player. Rejected: outputs to ALSA/PortAudio, which dspout holds, and it
   needs libdns_sd. Useful as a reference only.

### Where the audio sink lives

1. **The C++ bridge writes RTP to dspout itself — chosen.** The library's sync loop needs a prompt
   `notify_audio_played()` per write; doing that through Perl's event loop would add tens of ms of jitter
   to every report. The bridge needs only the `N` clock, which Perl forwards as it arrives (a slow-moving
   mapping, so forwarding latency doesn't matter).
2. The bridge pipes PCM to Perl, Perl stamps RTP (reusing the AirPlay pump). Rejected for the reason above,
   and because the AirPlay pump stamps "now + 250 ms", which would discard Sendspin's timing entirely.
3. The bridge speaks the BluOS plugin protocol directly. Rejected: two implementations of that protocol.

### Arbitration between AirPlay and Sendspin

1. **Newest sender wins — chosen** (my call; the user hasn't said). Matches how BluOS itself behaves when a
   new source starts, and how AirPlay behaves today with `allow_session_interruption`.
2. First come first served: the second sender is refused until the first stops. Simpler, but a stuck AirPlay
   session would block MA until someone finds the phone.

When the amp leaves Sendspin for another BluOS input, `client.leave()` (this amp alone drops out) was chosen
over a controller `pause` (whole group stops); when AirPlay takes over, `set_available(false)` was chosen over
`leave()` because the amp must not be re-taken by MA mid-AirPlay-session.

## Design

### Processes

```
 Music Assistant ──ws+Noise──▶ sendspin-bridge (C++) ──RTP──▶ dspout ──▶ amp
                                  │  ▲ stdin/stdout, JSON lines
                                  ▼  │
 iPhone ──AirPlay──▶ shairport-sync ──PCM──▶ sovi-airplay (Perl) ──RTP──▶ dspout
                                                  │ ▲ unix sockets
                                                  ▼ │
                                             sovi-core (display, app, remote, volume)
```

- `sovi-airplay` (Perl, existing) stays the only process that talks to sovi-core. It now manages **two**
  children: `shairport-sync` (as today) and `sendspin-bridge`. Either may be absent (binary missing or
  disabled by a settings file); the plugin keeps working with the other.
- `sendspin-bridge` (new, C++20, static ARMv7 binary at `/var/data/airplay/bin/sendspin-bridge`): runs
  `sendspin::SendspinClient` with the player, metadata, artwork and controller roles; owns the Sendspin
  identity and pairing store; writes RTP to dspout; talks to the plugin over stdin/stdout.
- Perl restarts a dead child after 3 s, as it does for shairport-sync today.

### Bridge ⇄ plugin protocol (stdin/stdout, one JSON object per line)

Bridge → plugin (stdout):

| event | fields | plugin action |
|---|---|---|
| `ready` | `client_id`, `pairing_token`, `port`, `unpaired` | write avahi service file; log token once |
| `connected` / `disconnected` | `server_id`, `paired` | log; on disconnect end any open stream |
| `stream_start` | `rate`, `channels`, `bits` | `announce()` → `F` to core (open BluOS stream), as for AirPlay |
| `stream_end` | | `end_stream()` → `G` to core |
| `metadata` | `title`, `artist`, `album`, `duration_ms`, `elapsed_ms`, `playing` | `send_meta()` JSON to core |
| `artwork` | `file` (path in tmpfs) or `null` | `save_cover()` equivalent: set `cover`, re-send metadata |
| `volume` | `volume` 0–100, `muted` | map to amp dB (`min_db`..`max_db`) via `/Volume`; mute via `/Volume?mute=` |
| `paired` / `pairing_attempt` / `pairing_aborted` | `server_id`, `reason` | log |
| `log` | `level`, `msg` | syslog |

Plugin → bridge (stdin):

| command | fields | bridge action |
|---|---|---|
| `clock` | `pos_us`, `real_us` | update the dspout clock mapping (only *live* `N` reports, after the pre-roll switch) |
| `live` | | BluOS stream is open and clocked: start writing RTP |
| `stop` | | stop writing RTP, drop the timeline (source changed, AirPlay took over) |
| `available` | `true`/`false` | `client.set_available()` (AirPlay took over / released the amp) |
| `control` | `next` / `pause` / `play` | controller `send_command()` |
| `amp_volume` | `db` | report to MA as volume % via `player.update_volume()` (when it changes by ≥ 1 %) |
| `quit` | | `client.stop()`, exit |

Bridge stderr → syslog via the plugin, like shairport-sync's.

### Audio path and sync (the heart of it)

The sink is dspout's RTP timeline. Rules:

1. **Timeline.** While `live`, the bridge keeps a continuous RTP timestamp `ts` (µs of dspout stream
   position), advancing by `frames × 1e6 / rate` per packet, exactly as the AirPlay pump does. Packets are
   363 frames, header per `docs/PROTOCOL.md` §4.
2. **Clock mapping.** From the latest `clock` (`pos_us` at CLOCK_REALTIME `real_us`) and a simultaneous
   sample of CLOCK_REALTIME and CLOCK_MONOTONIC_RAW, the bridge converts any `ts` to the library clock:
   `mono(ts) = mono_now + (ts − (pos_us + (real_now − real_us)))`. Only live `N` reports are forwarded;
   Perl keeps its existing pre-roll/stale filtering. The mapping is **slewed, not snapped**: the first
   live report after an anchor is taken as is; each later report moves the mapping toward its value at a
   bounded rate (≤ 1 ms per second of stream time, i.e. ≤ 1000 ppm) with a log line for any implied step
   over 5 ms. This keeps `N` jitter (unknown today; measured in milestone 1) from turning into library
   hard syncs, whose threshold is 5 ms, while still following real dspout-vs-CPU drift.
3. **Anchor.** On `live`, and whenever the timeline has gone stale (last packet's play time is already in
   the past), re-anchor `ts = current_pos + LEAD` (LEAD = 250 ms as today).
4. **Write.** `on_audio_output(pcm, fmt, timeout_ms)`: wait until the write's first frame would play within
   `LEAD_MAX` (≈ 400 ms) of now (bounded by `timeout_ms`; return 0 if it can't start in time), then send
   the frames as RTP packets, advance `ts`, and call `notify_audio_played(frames, mono(ts_end))` where
   `ts_end` is the stream position at which the last written frame plays. Because the report is immediate,
   the library's "next write plays at" estimate is simply the end of the previous write, which is exact.
5. **Not live.** Before `live` and after `stop`, writes are discarded (return `pcm.size()`, no report). The
   library then treats the sink as running dry and hard-syncs when audio resumes. To keep the first
   half-second of a track from being lost while BluOS opens the stream, the bridge advertises
   `required_lead_time_ms` ≈ 1000 (setting `sendspin/lead_ms`); the spec says servers SHOULD extend the
   startup lead toward it for buffered sources. Whether MA 2.10 does, and how long the card takes from `F`
   to a live `N` (the Perl code suggests ~0.5 s typical, longer if core is still stopping another source),
   is **measured in milestone 1**. If MA gives only its default ~500 ms, a cold start may lose a few hundred
   ms of the first track while the other players play it; the 3 s grace on stream end (below) means this
   happens only on a cold start, not on pause/resume or track changes. Accepted for v1; the fallback, if it
   turns out to matter, is to keep the BluOS stream open while the MA group is stopped but this player is
   still its active source (amp stays on the MDC input showing "paused"), which is a product change to
   raise then.
6. **Correction.** The library does hard sync (insert silence / drop) at start and after seeks, and soft sync
   (±1 frame per chunk) in steady state. dspout's own PID loop follows our continuous timestamps. We never
   bend `ts`; drift between dspout's clock and the server shows up as soft-sync frames, inaudible.
7. **Offset.** dspout's reported position may not be the exact moment samples hit the DAC (the `N` mode
   field says 150 ms capture latency). A fixed offset in `PlayerRoleConfig::fixed_delay_us`, read from
   `sendspin/delay_us`, lets the user trim the amp against another Sendspin player by ear. MA's
   "Static playback delay" (`output_delay_ms`) also works and persists.
8. **Formats offered**, in priority order: FLAC 2ch/44100/16, PCM 2ch/44100/16. One sample rate only, so
   the server resamples and never switches format mid-stream (a format switch would mean reopening the
   BluOS stream with a gap). 48 kHz can be tried later by a settings file once the RTP path is proven at
   that rate. `audio_buffer_capacity` 1 MB (default), `min_buffer_ms` 500 (default).

### Stream lifecycle mapping

| Sendspin | BluOS (via Perl) |
|---|---|
| `on_stream_start` | `announce()`: `P1 S0 L1`, then `F airplay_pcm01:pcm/44100/16/2/<sid>` with retries; wait for live `N` → `live` to bridge |
| `on_stream_end` (pause, stop, role removed) | metadata `isPlaying:false` at once; `end_stream()` (`G` to core) only after a **3 s grace** with no new stream (same as AirPlay's `GAP_S`), so a short pause or a stop/play in MA doesn't pay the ~0.5 s BluOS re-open. Track changes and seeks never close the stream (gapless / `stream/clear`) |
| `stream/clear` (seek) | nothing; the library re-aligns. Up to LEAD_MAX of old audio may still play |
| group stopped / disconnected | `end_stream()` if open |
| core `S` (someone chose another BluOS input) | `stop` to the bridge and `client.leave()`: this amp drops out of its MA group and the rest of the house keeps playing (my call, see arbitration) |
| core `H` / `G` / bare `F` | `control next` / `pause` / `play` → controller commands (if in `supported_commands`) |
| core `K` (amp volume) | `amp_volume` → MA volume % |

### Arbitration (newest sender wins)

- **Sendspin starts while AirPlay is live:** Perl sends DACP `pause` to the AirPlay sender, sets
  `$suppress` for AirPlay, closes the AirPlay stream, and opens the Sendspin stream. AirPlay comes back
  when the phone presses play (as today after a core `S`).
- **AirPlay starts (shairport `pbeg`) while Sendspin is live:** Perl sends `available:false` to the bridge
  (MA moves this player into its own stopped group and stops streaming to it), closes the Sendspin stream,
  and opens the AirPlay one. When the AirPlay session ends (`pend`), Perl sends `available:true`. The user
  re-adds the amp to an MA group if they want it back; that is the spec's intended semantics for "taken
  by an external source".
- **Core `S` (someone chose another BluOS input)** while Sendspin is live: `stop` to the bridge and
  `client.leave()` (spec: "a device that plays a local source it can be interrupted out of stays available
  and leaves its group"). MA parks this amp alone in a stopped group and the other speakers play on; the
  player stays available so MA can take it again later. A controller `pause` would have stopped the whole
  group because someone picked CD on one amp, so it is **not** used here (my call).

### Metadata, artwork, volume

- Metadata role → the same JSON the AirPlay path sends (`title`, `artist`, `album`, `duration_ms`,
  `elapsed_ms`, `isPlaying`), with progress interpolated by the library (`get_track_progress_ms()`), pushed
  on every `on_track_metadata` and every 5 s while playing (so the progress bar stays honest). No AirPlay
  2-second latency offset applies.
- Artwork role: one slot, album art, JPEG 600×600, `max_image_bytes` 256 KiB (BluOS serves the file to the
  app; the amp display shows a thumbnail). The bridge writes the JPEG to `/tmp/sovi-airplay/images/` and
  reports the file; Perl rotates files as `save_cover()` does today. `on_image_clear` → `artwork null`.
- Volume: MA 0–100 → amp dB linear between `min_db` and `max_db` (same files as AirPlay), applied through
  the existing rate-limited `/Volume` child-job path; `muted` → `/Volume?mute=1|0`. On connect, MA may push
  its stored volume; we apply it (unlike AirPlay's "ignore the first report"), because we also report the
  amp's volume back and MA's state then converges. Amp dB → % is the inverse mapping, clamped.
- Amp → MA volume source: core's `K` message is AirPlay dB (amp dB / 2, clamped to −30..0, so anything below
  −60 dB reads as 0 %). Its cadence is unverified: milestone 1 checks (with `debug` on) whether `K` arrives
  on every knob/remote change while a Sendspin stream is live. If it does, use it. If not, Perl polls
  `/Volume` on :11000 every 2 s **only while a Sendspin stream is live**, through the existing child-job
  path, and reports changes ≥ 1 %. Either way the mapping uses `min_db`..`max_db` and clamps.

### Discovery, identity, pairing

- Perl writes `/var/avahi/services/sendspin.service` when the bridge reports `ready`:
  `<name>` = the AirPlay/BluOS name, `<type>_sendspin._tcp</type>`, port 8928, `txt-record path=/sendspin`,
  `txt-record name=<name>`. Removed when the bridge exits. avahi-daemon picks the file up by itself.
- `SendspinClientConfig`: `name` from `/var/data/airplay/name` (or the BluOS player name), `product_name`
  "C368", `manufacturer` "NAD", `software_version` = our version, `mac_address` from the `-i` argument
  sovi-core passes, `server_port` 8928.
- Persistence: `FilePersistenceProvider` (vendored from the library's examples) at
  `/var/data/airplay/sendspin/state.json` (mode 0600): keypair, pairing PSK, long-term records.
- Pairing token: logged once at startup (syslog is RAM-only) and written to
  `/var/data/airplay/sendspin/pairing-token` (0600). `install.sh` prints it at the end. In MA: player →
  "Pair device" → paste token.
- Unpaired access: **enabled by default** (setting file `sendspin/no_unpaired` disables it), so MA's
  "Connect unpaired" works out of the box on a home LAN. Documented as unverified/MITM-able per spec.

### Settings (files in `/var/data/airplay/sendspin/`, read at bridge start)

| File | Default | Meaning |
|---|---|---|
| `disabled` | absent | don't start the bridge |
| `lead_ms` | 1000 | `required_lead_time_ms` advertised to the server |
| `delay_us` | 0 | fixed output offset to align with other players (may be negative) |
| `no_unpaired` | absent | refuse unpaired servers |
| `debug` | absent | verbose bridge logging |
| `pairing-token` | written by bridge | the `SP:…` token to paste into MA |
| `state.json` | written by bridge | identity and pairings; delete to reset |

### Build and install

- `build/build-sendspin.sh`: Docker `--platform linux/arm/v7`, `debian:bookworm-slim` (GCC 12 for C++20),
  cmake + git; `sendspin-cpp` pinned to a tag (v0.10.0, what the CLI pins) and fetched by FetchContent;
  roles: player, metadata, artwork, controller; `SENDSPIN_ENABLE_OPUS=OFF`, visualizer/color/source off;
  `-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2`, `-static` (card glibc is 2.30, bookworm's is 2.36, so
  nothing may be linked dynamically); strip. Output `build/out/sendspin-bridge-armv7`. The script asserts
  `file` says "statically linked" and that the binary runs `--version` under emulation.
- `bridge/` directory in the repo: `CMakeLists.txt`, `main.cpp`, `rtp_sink.{h,cpp}`, `plugin_io.{h,cpp}`,
  vendored `file_persistence_provider.{h,cpp}`. It must also build natively on macOS/Linux for tests.
- `install.sh` additionally copies the bridge binary and creates `/var/data/airplay/sendspin/`; it skips
  Sendspin with a note if the binary isn't built. `uninstall.sh` removes the avahi file and the directory.
- The plugin learns the bridge's absence gracefully: no binary → AirPlay-only, as today.

### Testing

- C++ unit tests (native, GoogleTest or plain asserts) for the sink: RTP header packing, timeline anchoring
  and re-anchoring, clock mapping from `N` reports, pacing/`timeout_ms` behaviour, `notify_audio_played`
  values. The sink is written against a small interface (a fake dgram socket, injectable clocks).
- Plugin-level test: a Perl script that fakes sovi-core's sockets and a fake bridge (any process printing
  the JSON lines) to check the event→message mapping and arbitration without hardware.
- Optional: the Sendspin conformance suite (`Sendspin/conformance`, Python) against a native build of the
  bridge with a "discard" sink.
- On the card: play from MA, check `logread` for sync (the library logs hard syncs / loss of sync), compare
  against another Sendspin player by ear, tune `delay_us`.
- Environment assumptions: root SSH to the card works now (192.168.1.219); a Music Assistant 2.10 instance is
  on the LAN; a second Sendspin player for by-ear comparison is desirable but optional (`sendspin-cpp-cli` on
  a laptop will do, and the plan builds the bridge natively on macOS first so MA interop is proven before
  anything touches the card).

### Verify early (milestone 1, before the Perl integration)

These are the unknowns the design rests on; each gets a measurement task in the plan:

1. MA 2.10 pairs with and plays to a native build of the bridge with a discard sink (protocol interop).
2. The startup lead MA actually gives us with `required_lead_time_ms` = 1000 (log `stream/start`
   `server_transmitted` vs first chunk timestamp).
3. Time from `F` to the first live `N` on the card, cold and after a 3 s grace close (from `logread`).
4. Jitter of the `N`-implied clock mapping across consecutive reports (log deltas for a few minutes).
5. Whether `K` arrives on amp volume changes while a stream is live.

## Left to the builder

- Exact split of the bridge into files/classes; whether the sink runs its pacing wait with a condition
  variable or a plain sleep loop.
- How much of the Perl plugin to refactor into a generic "front end" abstraction vs. adding a second
  child alongside the first. Keep it readable; don't over-abstract for two children.
- Choice of GoogleTest vs. a minimal test main for the C++ tests.
- Whether to vendor the dependency sources into `build/src` for reproducible offline builds or let
  FetchContent fetch at build time (the AirPlay build caches tarballs in `build/src`; follow that pattern if
  it's cheap).
- Log wording and rate limits.
