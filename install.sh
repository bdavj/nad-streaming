#!/bin/sh
# Install the AirPlay plugin on a BluOS device over SSH.
#   ./install.sh <device-ip> [airplay name]
# Needs: root SSH to the device (key auth), build/out/shairport-sync-armv7 (run build/build.sh first).
#
# What it changes on the device:
#   /var/data/airplay/                persistent: plugin, shairport-sync, backups of the files below (orig/)
#   /etc/sovi_info.xml   (rootfs)     adds <airplay requireEnable="true" uid="107" gid="107">yes</airplay> to <settings>
#   /usr/bin/sovi-airplay (rootfs)    symlink -> /var/data/airplay/sovi-airplay
#   /var/data/airplay_enable          BluOS's own on/off flag for the AirPlay source
# The rootfs is remounted read-write only for the two edits, then back to read-only.
# ORDER MATTERS: the XML element must exist before the enable flag, or sovi-core crashes on start (nil pointer),
# the BluOS watchdog restarts it, and it crash-loops. uninstall.sh removes the flag first.
set -e
IP=${1:?usage: $0 <device-ip> [airplay name]}
NAME=$2
cd "$(dirname "$0")"
SPS=build/out/shairport-sync-armv7
[ -f "$SPS" ] || { echo "missing $SPS - run build/build.sh first"; exit 1; }

SSH="ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@$IP"
echo ">> copying files"
$SSH 'mkdir -p /var/data/airplay/bin /var/data/airplay/orig'
$SSH 'cat > /var/data/airplay/sovi-airplay.new && chmod 755 /var/data/airplay/sovi-airplay.new && mv /var/data/airplay/sovi-airplay.new /var/data/airplay/sovi-airplay' < plugin/sovi-airplay
$SSH 'cat > /var/data/airplay/bin/shairport-sync.new && chmod 755 /var/data/airplay/bin/shairport-sync.new && mv /var/data/airplay/bin/shairport-sync.new /var/data/airplay/bin/shairport-sync' < "$SPS"
[ -n "$NAME" ] && printf '%s\n' "$NAME" | $SSH 'cat > /var/data/airplay/name'

echo ">> configuring BluOS"
$SSH 'sh -s' <<'EOF'
set -e
grep -q "sovi-airplay\|startSoviAirplay" /usr/bin/sovi-core 2>/dev/null || grep -q "sovi-airplay" /usr/bin/cp-go 2>/dev/null \
  || { echo "this BluOS build has no AirPlay endpoint - not supported"; exit 1; }
/var/data/airplay/bin/shairport-sync -V >/dev/null || { echo "shairport-sync does not run on this device"; exit 1; }
[ -f /var/data/airplay/orig/sovi_info.xml ] || cp -p /etc/sovi_info.xml /var/data/airplay/orig/sovi_info.xml
need_xml=1; grep -q "<airplay " /etc/sovi_info.xml && need_xml=0
need_link=1; [ "$(readlink /usr/bin/sovi-airplay)" = /var/data/airplay/sovi-airplay ] && need_link=0
if [ $need_xml = 1 ] || [ $need_link = 1 ]; then
  mount -o remount,rw /
  trap 'mount -o remount,ro /' EXIT
  if [ $need_xml = 1 ]; then
    sed -i 's#^\([[:space:]]*\)<settings>#&\n\1\t<airplay requireEnable="true" uid="107" gid="107">yes</airplay>#' /etc/sovi_info.xml
    grep -q "<airplay " /etc/sovi_info.xml || { echo "failed to edit sovi_info.xml"; cp -p /var/data/airplay/orig/sovi_info.xml /etc/sovi_info.xml; exit 1; }
    xmllint --noout /etc/sovi_info.xml 2>/dev/null || { echo "sovi_info.xml no longer parses - restoring"; cp -p /var/data/airplay/orig/sovi_info.xml /etc/sovi_info.xml; exit 1; }
    echo "   added <airplay> to /etc/sovi_info.xml"
  fi
  if [ $need_link = 1 ]; then ln -sfn /var/data/airplay/sovi-airplay /usr/bin/sovi-airplay; echo "   linked /usr/bin/sovi-airplay"; fi
  sync
fi
touch /var/data/airplay_enable
echo "   enabled (/var/data/airplay_enable)"
if pgrep -f "sovi-airplay -z" >/dev/null 2>&1 || ps | grep -q "[s]ovi-airplay -z"; then
  for p in $(ps -o pid,args | grep -E "[s]ovi-airplay -z|[s]hairport-sync -c" | cut -c1-6); do kill $p; done
  echo "   restarted running plugin (sovi-core relaunches it within ~60 s)"
  echo "DONE"
else
  echo "DONE - now POWER-CYCLE the device (mains off/on) so sovi-core picks up the new settings."
  echo "       Do NOT use /sbin/reboot on the NAD MDC card: it halts instead of rebooting."
fi
EOF
