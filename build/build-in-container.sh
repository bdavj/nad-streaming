#!/bin/sh
# Runs inside the armv7 container started by build.sh. Builds into /out.
set -e
sed -i 's#deb.debian.org#archive.debian.org#; s#security.debian.org#archive.debian.org#; /buster-updates/d' /etc/apt/sources.list
apt-get -o Acquire::Check-Valid-Until=false update -qq
apt-get install -y -qq build-essential autoconf automake libtool pkg-config \
  libconfig-dev libpopt-dev libssl-dev libavahi-client-dev xxd file >/dev/null
# Force static linking of everything except glibc/avahi/dbus by hiding the .so dev symlinks
for l in libconfig libpopt libssl libcrypto; do rm -f /usr/lib/arm-linux-gnueabihf/$l.so; done
cd /tmp && tar xzf /src/shairport-sync-${SPS_VERSION:-5.6.3}.tar.gz && cd shairport-sync-${SPS_VERSION:-5.6.3}
autoreconf -fi >/dev/null 2>&1
./configure --sysconfdir=/var/data/airplay --with-stdout --with-pipe --with-metadata \
  --with-avahi --with-ssl=openssl --without-ffmpeg --with-hammerton LIBS="-ldl -lpthread" > /out/sps-configure.log 2>&1 || { tail -30 /out/sps-configure.log; exit 1; }
make -j$(nproc) > /out/sps-make.log 2>&1 || { tail -40 /out/sps-make.log; exit 1; }
strip shairport-sync
cp shairport-sync /out/shairport-sync-armv7
./shairport-sync -V || true
file /out/shairport-sync-armv7
echo "--- dynamic deps:"; readelf -d shairport-sync | grep NEEDED
echo "--- max glibc symbol version:"; objdump -T shairport-sync | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1
