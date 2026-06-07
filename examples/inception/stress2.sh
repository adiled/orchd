#!/bin/sh
# Extended stress for the containerd runtime + orchdi supervisor:
#   TEST 1  fan-out: 6 containers up, clean teardown
#   TEST 2  oneshot: a container that exits is not restarted and is cleaned up
#   TEST 3  crash/restart: RESTART on-failure actually restarts, and fell stops it
# One VM boot; leak-checked against containerd's own state.
set -u
log(){ echo "[stress2] $*"; }
export PATH=/opt/tools/bin:$PATH
mkdir -p /etc/ssl/certs && cp /opt/tools/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
NS=orch
running(){ ctr -n $NS tasks ls 2>/dev/null | grep -c RUNNING; }
ctrs(){ ctr -n $NS containers ls -q 2>/dev/null | grep -c . ; }
sd(){ orchd --platform orchdi --state-dir /run/orchd "$@"; }
reset(){ rm -rf /run/orchd; mkdir -p /run/orchd; }

mkdir -p /run/containerd /var/lib/containerd
containerd >/var/log/containerd.log 2>&1 &
for i in $(seq 1 20); do ctr version >/dev/null 2>&1 && break; sleep 1; done
ctr version >/dev/null 2>&1 || { log "containerd FAILED"; exit 1; }
log "containerd up"
FAIL=0

log "===== TEST 1: fan-out (6 containers) ====="
reset
i=1; : > /run/fan.Orchfile
for n in a b c d e f; do
  printf 'SERVICE %s\nFROM docker.io/library/alpine:latest\nCMD sleep 600\n' "$n" >> /run/fan.Orchfile
done
sd --orchfile /run/fan.Orchfile --runtime containerd grow >/dev/null 2>&1
sleep 16
r=$(running); log "running=$r (expect 6)"; [ "$r" = "6" ] || FAIL=1
sd fell >/dev/null 2>&1; log "fell; settling 16s..."; sleep 16
r=$(running); c=$(ctrs); log "after fell running=$r containers=$c (expect 0/0)"; { [ "$r" = "0" ] && [ "$c" = "0" ]; } || FAIL=1

log "===== TEST 2: oneshot (exits, must NOT restart) ====="
reset
printf 'SERVICE once\nFROM docker.io/library/alpine:latest\nCMD true\nONESHOT true\n' > /run/once.Orchfile
sd --orchfile /run/once.Orchfile --runtime containerd grow >/dev/null 2>&1
sleep 10
r=$(running); c=$(ctrs); log "running=$r containers=$c (expect 0/0 — ran once and cleaned up)"; { [ "$r" = "0" ] && [ "$c" = "0" ]; } || FAIL=1
log "survey (oneshot should not be running):"; sd survey
sd fell >/dev/null 2>&1; sleep 3

log "===== TEST 3: crash/restart (RESTART on-failure) ====="
reset
printf 'SERVICE crash\nFROM docker.io/library/alpine:latest\nCMD false\nRESTART on-failure\nRESTART_DELAY 2s\n' > /run/crash.Orchfile
sd --orchfile /run/crash.Orchfile --runtime containerd grow >/dev/null 2>&1
sleep 20
restarts=$(grep -ch "restart #" /run/orchd/logs/*.log 2>/dev/null | head -1)
log "restarts observed in ~20s: ${restarts:-0} (expect >= 2)"; [ "${restarts:-0}" -ge 2 ] || FAIL=1
before=$(grep -ch "restart #" /run/orchd/logs/*.log 2>/dev/null | head -1)
sd fell >/dev/null 2>&1; log "fell; checking the restart loop stops..."; sleep 10
after=$(grep -ch "restart #" /run/orchd/logs/*.log 2>/dev/null | head -1)
c=$(ctrs); log "after fell: restarts froze (${before:-0} -> ${after:-0}), containers=$c (expect frozen, 0)"
{ [ "${before:-0}" = "${after:-0}" ] && [ "$c" = "0" ]; } || FAIL=1

log "===== TEST 4: spec alignment (volume + env + memory cgroup honored) ====="
reset
mkdir -p /run/vol; echo "VOLUME-OK" > /run/vol/marker
printf 'SERVICE sa\nFROM docker.io/library/alpine:latest\nCMD sleep 600\nMEMORY 64M\nENV FOO=bar\nVOLUME /run/vol:/mnt\n' > /run/sa.Orchfile
sd --orchfile /run/sa.Orchfile --runtime containerd grow >/dev/null 2>&1
sleep 8
r=$(running); log "running=$r (container with MEMORY+VOLUME+ENV; expect 1)"; [ "$r" = "1" ] || FAIL=1
vol=$(ctr -n $NS tasks exec --exec-id v orch-sa cat /mnt/marker 2>/dev/null | tr -d '\r')
log "volume /mnt/marker = '$vol' (expect VOLUME-OK)"; [ "$vol" = "VOLUME-OK" ] || FAIL=1
e=$(ctr -n $NS tasks exec --exec-id e orch-sa printenv FOO 2>/dev/null | tr -d '\r')
log "env FOO = '$e' (expect bar)"; [ "$e" = "bar" ] || FAIL=1
pid=$(ctr -n $NS tasks ls 2>/dev/null | grep orch-sa | awk '{print $2}')
cg=$(awk -F: '{print $3}' /proc/"$pid"/cgroup 2>/dev/null)
mem=$(cat /sys/fs/cgroup"$cg"/memory.max 2>/dev/null)
log "cgroup memory.max = '$mem' (expect 67108864 = 64M)"; [ "$mem" = "67108864" ] || FAIL=1
sd fell >/dev/null 2>&1; sleep 14

log "RESULT: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
sleep 3
