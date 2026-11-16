# BluOS internals used by nad-airplay

Worked out on BluOS 4.12.11 (NAD C368 MDC card) from strace captures of the stock Spotify and Roon plugins,
probing, and reading `sovi-core` (Go) and `dspout` (C) disassembly. Field meanings marked *(inferred)* are from timing,
not from code.

## 1. Enabling BluOS's AirPlay source

`sovi-core` contains a complete AirPlay endpoint (`ms/internal/sources/endpoints/airplay`), but the daemon it launches,
`/usr/bin/sovi-airplay`, isn't in the firmware. The endpoint starts when **both** of these are true:

1. `/etc/sovi_info.xml` has an `<airplay>` element inside `<settings>`. Without it, `startSoviAirplay()` dereferences a
   nil `Settings.AirPlay` and sovi-core panics, the watchdog restarts it, and it crash-loops.
   ```xml
   <airplay requireEnable="true" uid="107" gid="107">yes</airplay>
   ```
   Struct `sovi.AirPlay`: chardata, `requireEnable` (bool), `uid`, `gid`, `maxVolumeRange`, `<model maxVolumeRange="">`
   children. With `uid == gid == 0` it looks up a user called `airplay`, which doesn't exist.
2. `requireEnable="true"` makes `/var/data/airplay_enable` the on/off switch (`/enable?airplay` reports it).

sovi-core then runs (cwd `/root`, as root, `chrt -r 1`):
```
sovi-airplay -z 1 -i <mac> -d /var/data/airplay -b NAD -M C368 -v 4.12.11 -e -C -U 107 -G 107 -N "1 <player name>"
```
and relaunches it about 60 s after it exits.

## 2. Plugin sockets

All in the plugin directory (`-d`, here `/var/data/airplay/`). The same pattern is used by Spotify, Tidal, Qobuz and Roon.

| Socket | Type | Direction |
|---|---|---|
| `airplay_req01` | unix DGRAM, bound by sovi-core | plugin → core |
| `airplay_cmd01` | unix DGRAM, **bound by the plugin** | core → plugin |
| `airplay_pcm01` | (announced in `F`, but the AirPlay endpoint never connects to it; audio goes to dspout as RTP) | |

### plugin → core

| Message | Bytes | Meaning |
|---|---|---|
| `P` u8 | `50 01` / `50 00` | session present / gone |
| `S` u8 | `53 00` | state *(inferred)* |
| `L` u8 | `4c 01` | ready *(inferred)* |
| `F` ascii | `Fairplay_pcm01:pcm/44100/16/2/<id>` | **open a stream** (`pcm/<rate>/<bits>/<ch>/<streamId>`). Dropped if core is still stopping the previous source (`Play while PLAYING`), so retry if no reply |
| JSON | see below | metadata |
| `G` | `47` | paused / stream ended. Core answers `G` then `S` |

Metadata JSON (AirPlay endpoint, `SetMetadataJSON`). All numbers **must** be JSON numbers, or core logs
`cannot unmarshal string into Go struct field metadata.rate of type int` and drops the whole message:
```json
{"isPlaying":true,"isStream":false,"title":"…","album":"…","artist":"…","cover":"images/cover-3.png",
 "rate":44100,"duration_ms":284000,"elapsed_ms":61000,"ts":0}
```
`cover` is a file name relative to the plugin dir: core builds `Sprintf("%s/airplay/%s", dataDir, cover)`. Image files are
served by core's image handler, which `ms.Run` registers for `/var/data/airplay/images/` (and `/var/data/raat/images/`)
via `images.AddPathHandler`, so covers must live in `/var/data/airplay/images/` (a symlink to tmpfs works). The extension
is checked. Anything else (URLs, other paths) gets 404.

### core → plugin

| Message | Bytes | Meaning |
|---|---|---|
| `K` u32 u8 str\0… | `K .... "-30.000000\0"` | current AirPlay volume in AirPlay dB (`amp dB / 2`, clamped −30..0) |
| `R` u8 str\0 | `52 01 "Living Room\0"` | player name |
| `F` u32be | `46 00 00 00 00` | stream accepted |
| `F` (1 byte) | `46` | **resume** (play pressed on remote/app) |
| `O` u32be id, u32be latency | `4f 00000007 00000000` | output opened (`L0` → latency 0; Roon gets 150) |
| `O` | `4f` | output running |
| `N` 01 u32be u32be u32be | see §3 | stream clock |
| `H` | `48` | next track |
| `G` | `47` | pause (also echoed back after the plugin sends `G`, so ignore it for ~2 s) |
| `S` u8 | `53 01` | stop (source changed or after `G`) |

Roon's plugin (`raat_bluos`) gets the same messages, except that `N` is ASCII:
`N 01 "<pos_ns>\0<realtime_ns>\0" u32be id`.

## 3. Stream clock (`N`)

```
4e 01 | 00 00 18 4f | 33 55 d8 c0 | 00 02 49 f0
 'N'  | pos_ms=6223 | realtime_ms % 10^9 = 861264064 | mode = 150000
```
- `pos_ms`: dspout's stream position in ms, at wall-clock time `realtime_ms` (CLOCK_REALTIME, ms modulo 10⁹)
- `mode`: `0` or `50` = **pre-roll** (estimated). Once the hardware clock runs it changes to the capture latency in µs (`150000`)
  and the position **jumps back** by 200–300 ms. Ignore pre-roll reports that arrive after the switch, and stale
  out-of-order ones (core re-sends old values).
- Interval: about 100 ms after start (`I100`), then 5 s (`I5000`).

## 4. Audio: RTP to dspout

dspout listens on **`/var/data/pcm_rtp_socket01`** (unix DGRAM, `srw-rw-rw-`, hard-linked as `/var/data/raat/pcm_rtp_socket01`)
and UDP 11000. Datagram = 20-byte **little-endian** header + interleaved S16LE PCM:

| Offset | Size | Value |
|---|---|---|
| 0 | u8 | `0x80` (RTP v2) |
| 1 | u8 | `0xe0` = marker + payload type **96** (raw PCM) |
| 2 | u16 LE | sequence number |
| 4 | u32 LE | **timestamp: stream position in µs at which this packet should play** (the `N` clock) |
| 8 | u16 LE | sample rate / 50 (`882` = 44100) |
| 10 | u16 LE | frames in packet (raat uses 363 → 1452 bytes of PCM, 1472-byte datagram) |
| 12 | u8 | bits per sample (`& 0x3f`) |
| 13 | u8 | 0 |
| 14 | u16 LE | channels |
| 16 | u32 | 0 |

dspout also handles PT 97/98 (fixed sizes 0x1814/0x4814) and PT 99/100 (control), which aren't needed here.

Timing rules that matter:
- Lead: stamp packets about **250 ms** ahead of the current stream position (as raat does). Packets that would play in
  the past are dropped (`pkt late`), so keep the lead stable.
- Keep timestamps **continuous** (`ts += frames * 1e6 / rate`). dspout runs a PID loop (`Sync(RTP)`) that resamples to
  follow the timestamps, so jittery timestamps are audible as warble. Correct drift slowly (we use ≤250 ppm) and only
  re-anchor on real discontinuities (start, flush, packets about to be late).

What core sends dspout for an AirPlay stream (`/tmp/pcmcontrol` text commands, `/tmp/pcmsock` header):
`S` (stop previous), `I100`, `L0\0150\0 0\0`, stream header `10 ad 00 00 06 02 00 00` + `03 00 00 00 44 ac 00 00 10 00 00 00 02 00 …`
(type 3; Roon's is type 7 with `L150`). dspout then logs `Stream: id=N 44100/16/2 … version:0x206`.

## 5. Volume

- BluOS HTTP API on :11000: `/Volume` (read), `/Volume?level=0..100`, `/Volume?db=<delta>` (**relative** change),
  `/Volume?mute=0|1`. `abs_db=` isn't supported on this build.
- Level ↔ dB on the C368 is roughly `dB ≈ −70 + 0.7 × level`.
- sovi-hal-qt forwards BluOS volume to the amp over the UART (`Main.Volume`), and the amp's own volume comes back the same way.

## 6. Amp link (for reference)

`/dev/ttymxc1`, 115200 8N1, owned by `sovi-hal-qt`. Plain NAD ASCII protocol, `\r<Key>=<Value>\r`, also bridged to TCP 23.
- card → amp: `Main.Power=On`, `Main.Source=9` (MDC slot), `UI.Artist=`, `UI.Title=`, `UI.Album=`, `UI.PlayState=`,
  `UI.PlayTime=`, `UI.TotalTime=`
- amp → card: `Main.Volume=<dB>`, `Main.Mute=On|Off`, `Media.Action=SkipForward` (remote "next"). sovi-core turns that
  into `H` for the active plugin.

## 7. Misc

- `/sbin/reboot` **halts** the MDC card, so a mains power-cycle is needed.
- The `rc.sovi` watchdog calls `reboot` (i.e. halts the MDC card) if dspout, sovi-core, sovi-hal-qt, avahi, dbus, sovi-discover, sovi-bt, sovi-broker
  or rc.stage0 die. It doesn't watch `sovi-airplay`.
- Syslog is in RAM: read it with `/sbin/logread`.
