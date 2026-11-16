#!/bin/sh
# Remove the AirPlay plugin and restore the original BluOS files.
#   ./uninstall.sh <device-ip>
set -e
IP=${1:?usage: $0 <device-ip>}
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa "root@$IP" 'sh -s' <<'EOF'
set -e
rm -f /var/data/airplay_enable                      # flag first: sovi-core stops launching the plugin
for p in $(ps -o pid,args | grep -E "[s]ovi-airplay -z|[s]hairport-sync -c" | cut -c1-6); do kill $p; done
mount -o remount,rw /
trap 'mount -o remount,ro /' EXIT
if [ -f /var/data/airplay/orig/sovi_info.xml ]; then cp -p /var/data/airplay/orig/sovi_info.xml /etc/sovi_info.xml
else sed -i '/<airplay requireEnable=/d' /etc/sovi_info.xml; fi
[ -L /usr/bin/sovi-airplay ] && rm -f /usr/bin/sovi-airplay
sync
mount -o remount,ro /; trap - EXIT
rm -rf /var/data/airplay /tmp/sovi-airplay
echo "removed - power-cycle the device to finish (do not use /sbin/reboot on the NAD MDC card)"
EOF
