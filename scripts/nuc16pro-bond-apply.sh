#!/bin/bash
# nuc16pro LACP (802.3ad) bond: enp86s0 + enp87s0 -> upstream 2.5G managed switch LAG.
# Mirrors netplan/99-nuc16pro-bond.yaml. MANUAL one-time setup, NOT run by the daily updater.
#
# RUN FROM THE PHYSICAL CONSOLE. Applying briefly drops SSH while 192.168.8.13 moves to bond0.
# SELF-REVERTING: if the box cannot reach its gateway within ~180s it auto-restores the old
# network config, so it is SAFE to run even before the switch LAG exists (it just reverts).
# PREREQ: the switch (e.g. Grandstream GWN7721) must have an 802.3ad LAG on the two NIC ports.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0"; exit 1; }

GW=192.168.8.1
WANT_IP=192.168.8.13
REVERT_AFTER=180
BK=/root/netplan-bak-$(date +%s)

echo "== backup /etc/netplan -> $BK =="
mkdir -p "$BK"; cp -a /etc/netplan/. "$BK"/

echo "== write revert helper =="
cat > /usr/local/sbin/nuc16pro-bond-revert.sh <<REV
#!/bin/bash
rm -f /etc/netplan/99-nuc16pro-bond.yaml
cp -a "$BK"/. /etc/netplan/
chmod 600 /etc/netplan/*.yaml 2>/dev/null
netplan apply
logger -t nuc16pro-bond "network ROLLED BACK to pre-bond config"
REV
chmod +x /usr/local/sbin/nuc16pro-bond-revert.sh

echo "== arm independent auto-revert in ${REVERT_AFTER}s (survives SSH drop, owned by PID1) =="
systemctl stop nuc16pro-bond-revert.timer 2>/dev/null
systemd-run --on-active=${REVERT_AFTER} --unit=nuc16pro-bond-revert \
  --timer-property=AccuracySec=1s /usr/local/sbin/nuc16pro-bond-revert.sh >/dev/null 2>&1 \
  && echo "  armed (cancel with: systemctl stop nuc16pro-bond-revert.timer)" \
  || echo "  WARN: could not arm auto-revert timer"

echo "== remove conflicting standalone stanzas (already backed up) =="
rm -f /etc/netplan/00-installer-config.yaml
rm -f /etc/netplan/90-NM-bdd2e424-1c2f-31a7-972f-d2c114c66171.yaml

echo "== write bond config =="
cat > /etc/netplan/99-nuc16pro-bond.yaml <<'YAML'
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    enp86s0:
      match: {macaddress: "48:21:0b:7e:24:2c"}
      set-name: enp86s0
    enp87s0:
      match: {macaddress: "48:21:0b:7e:24:2b"}
      set-name: enp87s0
  bonds:
    bond0:
      interfaces: [enp86s0, enp87s0]
      macaddress: "48:21:0b:7e:24:2b"
      dhcp4: true
      dhcp6: true
      parameters:
        mode: 802.3ad
        lacp-rate: fast
        mii-monitor-interval: 100
        transmit-hash-policy: layer3+4
YAML
chmod 600 /etc/netplan/99-nuc16pro-bond.yaml

echo "== validate config =="
if ! netplan generate 2>/tmp/np.err; then
  echo "!! netplan generate FAILED; restoring now:"; cat /tmp/np.err
  systemctl stop nuc16pro-bond-revert.timer 2>/dev/null
  /usr/local/sbin/nuc16pro-bond-revert.sh
  exit 1
fi

echo "== apply (SSH may drop here) =="
netplan apply
sleep 20

IP_OK=0; ip -4 addr show bond0 2>/dev/null | grep -qw "$WANT_IP" && IP_OK=1
PING_OK=0; ping -c3 -W2 "$GW" >/dev/null 2>&1 && PING_OK=1
echo "== result: bond0_has_${WANT_IP}=${IP_OK}  gateway_ping=${PING_OK} =="
grep -iE "Bonding Mode|Partner Mac|MII Status|Aggregator ID|Slave Interface" /proc/net/bonding/bond0 2>/dev/null | head -20

if [ "$IP_OK" = 1 ] && [ "$PING_OK" = 1 ]; then
  systemctl stop nuc16pro-bond-revert.timer 2>/dev/null
  echo
  echo "== BOND LIVE. rollback cancelled. =="
  echo "   Check aggregation: cat /proc/net/bonding/bond0   (want 'Partner Mac' = switch, both slaves MII up)"
else
  echo
  echo "!! NO connectivity -> auto-revert fires within ${REVERT_AFTER}s and restores the old config."
  echo "   Most likely the switch 802.3ad LAG is not set on those two ports yet. Set it, then re-run."
fi
