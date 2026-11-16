# nad-airplay

AirPlay for the **NAD C368 BluOS MDC card** (and probably other BluOS 4.x devices whose firmware ships without AirPlay).
It adds an AirPlay speaker that behaves like a native BluOS source:

- the amp switches to the MDC input by itself when you start casting
- title, artist, album, **album art** and progress appear on the amp and in the BluOS app
- amp remote / BluOS app **next, pause and play** control the iPhone/Mac (DACP)
- the phone's volume slider controls the amp (mapped and capped, see below)
- bit-perfect 44.1 kHz/16-bit into BluOS's own output engine (`dspout`), with its clock-drift correction

It's classic AirPlay (AirPlay 1, via [shairport-sync](https://github.com/mikebrady/shairport-sync)), so it shows up on
iOS/macOS as a normal speaker, but not in AirPlay 2 multi-room groups.

> **Unofficial and unsupported.** This modifies the device firmware (two small rootfs edits) and needs root SSH.
> Firmware updates may undo it or interact badly with it. Use at your own risk.

## How it works

BluOS 4.x on the MDC card still contains Bluesound's AirPlay *integration* (in `sovi-core`), but the AirPlay daemon
itself (`/usr/bin/sovi-airplay`) was left out of the firmware. This project provides a replacement daemon that speaks
the same internal protocol, so BluOS does everything else (source switching, display, app, remote, volume) itself.

```
 iPhone/Mac ──AirPlay──▶ shairport-sync ──PCM (stdout)──▶ sovi-airplay ──RTP──▶ dspout ──I²S──▶ amp DAC
                          │ metadata pipe                    │   ▲
                          └────────────────────────────────▶ │   │ unix sockets (BluOS plugin protocol)
                                                             ▼   │
 amp remote / BluOS app ◀──────────────────────────────────  sovi-core  (display, app, source switching, volume)
 iPhone/Mac ◀──DACP (next/pause/play)── sovi-airplay ◀── commands from sovi-core
```

- `sovi-core` launches `/usr/bin/sovi-airplay` (our Perl script) and restarts it if it dies.
- `sovi-airplay` runs shairport-sync as a child process with the `stdout` backend and the metadata pipe.
- Audio is chopped into 363-frame packets and sent as RTP to `dspout`'s socket `/var/data/pcm_rtp_socket01`.
  Roon (`raat_bluos`) uses exactly the same path. Each packet is stamped with the stream time at which it should play,
  and dspout's PID loop keeps the output locked to the sender.
- Track info goes to sovi-core as JSON. Album art is written to tmpfs and served by sovi-core's own image handler.

Full protocol details: [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Tested on

| | |
|---|---|
| Device | NAD C368 with MDC BluOS card (C390, i.MX53, 244 MB RAM) |
| BluOS | 4.12.11 |
| Senders | iPhone (Apple Music app), macOS Music app |
| shairport-sync | 5.6.3, classic AirPlay build |

## Install

You need **root SSH (key auth) to the card**. Getting that is out of scope here.

1. Build shairport-sync for the card (needs Docker with armv7 emulation, ~10 min):
   ```sh
   build/build.sh            # -> build/out/shairport-sync-armv7
   ```
2. Install (copies files, edits `/etc/sovi_info.xml`, links `/usr/bin/sovi-airplay`, sets the enable flag):
   ```sh
   ./install.sh 192.168.x.y "Living Room NAD"     # second argument = AirPlay name (optional)
   ```
3. **Power-cycle the amp** (mains off/on) on a first install, so sovi-core reads the new settings.
   ⚠️ Don't run `/sbin/reboot` on the MDC card: it **halts** and needs a mains power-cycle anyway.

The speaker then shows up in the AirPlay menu. The first launch takes about a minute after boot.

Uninstall: `./uninstall.sh 192.168.x.y`, then power-cycle.

## Settings

Files in `/var/data/airplay/` on the device. The plugin reads them at start unless noted otherwise.

| File | Default | Meaning |
|---|---|---|
| `name` | BluOS player name | AirPlay speaker name |
| `max_db` | `-20` | amp dB when the phone slider is at the top (cap) |
| `min_db` | `-70` | amp dB when the phone slider is at the bottom |
| `latency_ms` | `2000` | progress-bar offset (AirPlay plays ~2 s behind the sender's "current" position). Read live |
| `debug` | absent | create it to log every message (syslog, RAM only) |

**Volume behaviour:** connecting never changes the amp volume. Moving the phone slider sets the amp linearly between
`min_db` and `max_db`. Slider at zero (AirPlay "mute") sets BluOS volume to 0. The amp's own volume and remote work as usual.

Restart the plugin after changing settings: `kill $(pgrep -f "sovi-airplay -z")`. sovi-core relaunches it within about 60 s.

## Logs and troubleshooting

```sh
/sbin/logread | grep -E "sovi-airplay|airplay"     # plugin + sovi-core's AirPlay endpoint
/sbin/logread | grep dspout                        # output engine
```

- **Nothing in the AirPlay menu:** check `ps | grep shairport` and the log. Port 5000 must be free.
- **Plays but silent:** check BluOS volume/mute. If the phone slider was at zero when you connected, BluOS is at volume 0.
- **Timeline / glitch lines:** `re-anchor timeline` lines appear only on start, skip and seek. Repeated ones mean packets are
  arriving late (CPU starvation).
- Nothing is written to flash during playback: art, the metadata pipe, the generated config and logs all live in RAM.

## Limitations / TODO

- Classic AirPlay only (no AirPlay 2 / multi-room with Apple devices). BluOS grouping of the AirPlay source is untested.
- 44.1 kHz/16-bit only (that's what classic AirPlay carries).
- "Previous track" from the remote isn't mapped yet (the command code hasn't been captured).
- Runs as root. sovi-core passes `-U/-G` for privilege dropping, which is currently ignored.
- Planned: a [Sendspin](https://www.music-assistant.io/) (Music Assistant) front end on the same adapter.

## Repository layout

| Path | What |
|---|---|
| `plugin/sovi-airplay` | the plugin (Perl 5.14, core modules only, runs on the stock device) |
| `install.sh`, `uninstall.sh` | install/remove over SSH |
| `build/` | shairport-sync cross-build (armv7 Debian buster container, static libconfig/popt/openssl) |
| `docs/PROTOCOL.md` | BluOS plugin protocol, dspout RTP format, clocks, image path, amp UART protocol |
| `docs/REVERSE-ENGINEERING.md` | how it was worked out, and the tools |
| `tools/` | `rtp-tone.pl` (test tone through the AirPlay slot), logging stub, strace decoder, Go binary helpers |

## Credits

- [shairport-sync](https://github.com/mikebrady/shairport-sync) by Mike Brady does all the AirPlay work.
- NAD, Bluesound and BluOS are trademarks of Lenbrook. This project isn't affiliated with them. No Lenbrook code or
  binaries are included.
