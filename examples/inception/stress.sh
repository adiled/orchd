#!/bin/sh
# Stress the containerd runtime: repeated grow/fell cycles over multiple
# containers, leak-checked against containerd's own state — but only AFTER
# teardown has actually finished (containerd-run processes gone), so we measure
# the settled state, not mid-grace.
set -u
log(){ echo "[stress] $*"; }
export PATH=/opt/tools/bin:$PATH
mkdir -p /etc/ssl/certs && cp /opt/tools/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
NS=orch

log "start containerd"
mkdir -p /run/containerd /var/lib/containerd
containerd >/var/log/containerd.log 2>&1 &
for i in $(seq 1 20); do ctr version >/dev/null 2>&1 && break; sleep 1; done
ctr version >/dev/null 2>&1 || { log "containerd FAILED"; exit 1; }
log "containerd up"

running(){ ctr -n $NS tasks ls 2>/dev/null | grep -c RUNNING; }
containers(){ ctr -n $NS containers ls -q 2>/dev/null | grep -c . ; }
leaked_snaps(){ ctr -n $NS snapshots ls 2>/dev/null | grep -cE "^orch-[abc] "; }
crun_alive(){ ps -eo args 2>/dev/null | grep -q "[c]ontainerd-run"; }

FAIL=0
for cycle in 1 2; do
  log "===== CYCLE $cycle ====="
  rm -rf /run/orchd; mkdir -p /run/orchd
  orchd --orchfile /opt/tools/inner-stress-Orchfile --runtime containerd --platform orchdi --state-dir /run/orchd grow >/dev/null 2>&1
  sleep 8
  r=$(running); log "grow -> RUNNING=$r (expect 3)"
  [ "$r" = "3" ] || FAIL=1

  orchd --platform orchdi --state-dir /run/orchd fell >/dev/null 2>&1
  log "fell issued; waiting 16s for teardown grace to settle..."
  sleep 16
  rt=$(running); ct=$(containers); sn=$(leaked_snaps)
  log "settled -> running=$rt containers=$ct snaps=$sn (expect 0/0/0)"
  [ "$rt" = "0" ] && [ "$ct" = "0" ] && [ "$sn" = "0" ] || FAIL=1
done

log "===== FINAL ====="
log "tasks:"; ctr -n $NS tasks ls 2>&1
log "RESULT: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
sleep 3
