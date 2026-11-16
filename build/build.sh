#!/bin/sh
# Cross-build shairport-sync (classic AirPlay, stdout + metadata) for the BluOS MDC card (i.MX53, ARMv7 hard-float,
# glibc 2.30). Uses an armv7 Debian buster container (glibc 2.28 <= 2.30, so the binary runs on the card).
# libconfig/libpopt/openssl are linked statically; glibc, libavahi-client and libdbus come from the card.
# Requires Docker with armv7 emulation (Docker Desktop has it; on Linux install qemu-user-static/binfmt).
# Output: build/out/shairport-sync-armv7
set -e
cd "$(dirname "$0")"
SPS_VERSION=${SPS_VERSION:-5.6.3}
TARBALL=shairport-sync-$SPS_VERSION.tar.gz
mkdir -p out src
if [ ! -f "src/$TARBALL" ]; then
  curl -fL -o "src/$TARBALL" "https://github.com/mikebrady/shairport-sync/archive/refs/tags/$SPS_VERSION.tar.gz"
fi
docker run --rm --platform linux/arm/v7 \
  -v "$PWD/src:/src:ro" -v "$PWD/out:/out" -v "$PWD/build-in-container.sh:/build.sh:ro" \
  -e SPS_VERSION="$SPS_VERSION" \
  debian:buster-slim sh /build.sh
ls -la out/shairport-sync-armv7
