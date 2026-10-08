#!/bin/bash
# Waits for the Avi controllers, then runs the playbooks in ansible/ against each of them.
# Meant to be started on ubuntu-bootstrap after the Ansible install; safe to re-run by hand:
# a playbook that already succeeded for a controller is skipped (FORCE=1 runs it again).
# Settings come from the environment (the VM's envVars end up in /etc/profile.d/edu-env.sh).
#   AVI_CONTROLLERS   required, space separated, e.g. "dc1-avi-ctrl-1.avi.lab dc2-avi-ctrl-1.avi.lab"
#   AVI_PLAYBOOKS     playbooks to run in order, relative to ansible/ (default: base.yaml)
#   AVI_READY_PATH    API path that answers 200 once a controller is up (default: /api/initial-data)
#   READY_RETRIES / READY_DELAY   readiness polling (default: 90 x 10s)
#   LOG, STATE_DIR    log file and per-playbook success markers
[ -r /etc/profile.d/edu-env.sh ] && . /etc/profile.d/edu-env.sh
: "${AVI_CONTROLLERS:?AVI_CONTROLLERS is not set}"
: "${AVI_PLAYBOOKS:=base.yaml}"
: "${AVI_READY_PATH:=/api/initial-data}"
: "${READY_RETRIES:=90}"
: "${READY_DELAY:=10}"
: "${LOG:=/var/log/avi-playbooks.log}"
: "${STATE_DIR:=/var/lib/avi-playbooks}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${STATE_DIR}"
exec >> "${LOG}" 2>&1
log() { echo "$(date '+%F %T') avi-playbooks: $*"; }

controller_ready() {
  [ "$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://${1}${AVI_READY_PATH}" 2>/dev/null)" = "200" ]
}

wait_ready() {
  local c=$1 n=1
  until controller_ready "${c}"; do
    if [ "${n}" -ge "${READY_RETRIES}" ]; then log "${c}: not ready after ${READY_RETRIES} checks"; return 1; fi
    log "${c}: not ready yet (check ${n}/${READY_RETRIES})"
    n=$((n + 1))
    sleep "${READY_DELAY}"
  done
  log "${c}: ready"
}

failed=0
log "started: controllers=[${AVI_CONTROLLERS}] playbooks=[${AVI_PLAYBOOKS}]"
for controller in ${AVI_CONTROLLERS}; do
  if ! wait_ready "${controller}"; then failed=$((failed + 1)); continue; fi
  for playbook in ${AVI_PLAYBOOKS}; do
    marker="${STATE_DIR}/${controller}.${playbook//\//_}.done"
    if [ -e "${marker}" ] && [ "${FORCE:-0}" != "1" ]; then log "${controller}: ${playbook} already done, skipping"; continue; fi
    log "${controller}: running ${playbook}"
    if (cd "${HERE}/ansible" && AVI_CONTROLLER="${controller}" ansible-playbook "${playbook}"); then
      touch "${marker}"; log "${controller}: ${playbook} OK"
    else
      log "${controller}: ${playbook} FAILED"; failed=$((failed + 1)); break
    fi
  done
done
log "finished, ${failed} failure(s)"
[ "${failed}" -eq 0 ]
