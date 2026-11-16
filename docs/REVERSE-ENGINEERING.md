# How this was worked out

Notes for anyone porting this to another BluOS device or firmware version.

## Device survey (read-only)

- i.MX53 (Cortex-A8, ARMv7 hard-float), 244 MB RAM, glibc 2.30, BusyBox, Perl 5.14. No strace, Python or package manager.
- rootfs (`mmcblk0p2`, ext4) is mounted read-only. `/var/data` (`mmcblk0p3`) is the only persistent writable storage, and `/tmp` is tmpfs.
- `dspout` permanently owns the only ALSA PCM. Everything else feeds it through unix sockets, so "take over the sound
  card" isn't an option, but "be another BluOS source" is.
- The firmware has AirPlay leftovers: `AirPlay.pm`/`AirPlayCodec.pm` (encrypted), a settings page, icons, and a full Go
  AirPlay endpoint in `sovi-core`, but no `sovi-airplay` binary.

**Back up first:** `dd` every partition off the card (`/dev/mmcblk0p1..4`, `mmcblk0boot0/1`) and hash the images on both
ends. A mistake in `sovi_info.xml` makes sovi-core crash-loop.

## Captures

A static ARMv7 strace (build: debian:buster armv7 container, `LDFLAGS=-static LIBS="-lrt -lpthread"`) copied to `/tmp`:
```sh
/tmp/strace -f -tt -xx -s 400 -e trace=sendto,sendmsg,recvfrom,recvmsg,write,read,connect,accept,accept4 -o /tmp/x.st -p <pid>
```
- Spotify Connect session (`sovi-spotify`): plugin socket protocol, metadata JSON, volume, `H`/`G`.
- `sovi-hal-qt`: amp UART protocol (display text, remote keys).
- **Roon** (`raat_bluos`): the RTP format into dspout, the `N` clock, and the stream-start sequence. Roon was the key: it's the
  only stock source that delivers audio as RTP, which is what the AirPlay endpoint expects. raat also logs its IPC in
  plain text (`bluos_ipc tellPlayer: …`).
- `tools/stdecode.py` decodes `-xx` traces per file descriptor.

## Static analysis of sovi-core (stripped Go, ARM)

- `tools/gofunc.py <elf> <regex>`: function names and addresses from `.gopclntab` (works on stripped Go 1.20+ binaries).
- `tools/goasm.py <elf> <funcs> <regex>`: disassembles a function (Apple/LLVM objdump, `--triple=armv7`) and annotates
  calls with Go names and literal-pool loads with the strings they point at.
- `tools/gotype.py`: dumps Go struct layouts from reflect metadata (found the `sovi.AirPlay` settings struct and its XML tags).

Useful functions: `cp.startSoviAirplay` (launch, and the nil deref), `airplay.(*AirPlayCodec).SetMetadataJSON.func1`
(metadata → status, `%s/airplay/%s` cover path), `ms.Run` (`images.AddPathHandler` for `/airplay/images`).

## Probing

- `tools/sovi-airplay-logging-stub`: put it in place of the plugin to log how sovi-core launches it and what it sends.
- `tools/rtp-tone.pl`: the smallest working sender. Announces a stream, follows `N`, sends a sine as PT-96 RTP.

## Pitfalls hit along the way

- `F` sent while core is still stopping another source is silently dropped (`Play while PLAYING`).
- `N` has a pre-roll phase. Anchoring on it and then re-anchoring produced glitches, and so did jittery send pacing.
- The DACP client address is often IPv6 link-local: connect with an explicit scope id (the `eth0` index).
- `/Volume?db=` is relative, not absolute.
- macOS sends a DMAP field called `mdst` inside the track metadata. Don't mistake it for shairport's `ssnc/mdst`.
- Perl's JSON encoder emits strings for numbers that were used in string context. Force `0 + $x`.
- iOS caches a receiver's Bonjour TXT record (`md=0,1,2` = supports artwork). After turning art on, the phone needed
  rediscovery before it sent images.
