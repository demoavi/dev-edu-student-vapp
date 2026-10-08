#!/bin/bash
# Waits for each Avi controller, then runs the playbooks in ansible/ against it - once per site.
# Meant to be started on ubuntu-bootstrap after the Ansible install; safe to re-run by hand
# (as root: the vars file holds passwords): a playbook that already succeeded for a site is
# skipped, FORCE=1 runs it again.
#
# Variables come from /etc/avi-ansible/vars.json, written at first boot from the `ansible` block
# of the vApp-student-edu CR: for every site the shared variables overlaid by the site's own vars
# (which already include the derived `controller` and `avi_version`). They reach Ansible through a
# temporary 0600 extra-vars file, so the playbooks just use plain names (controller, avi_password...).
#   VARS_FILE         default /etc/avi-ansible/vars.json
#   AVI_PLAYBOOKS     overrides the playbook list of the vars file (space separated, relative to ansible/)
#   AVI_READY_PATH    API path that answers 200 once a controller is up (default /api/initial-data)
#   READY_RETRIES / READY_DELAY   readiness polling (default 90 x 10s)
#   LOG, STATE_DIR    log file and per-site success markers
: "${VARS_FILE:=/etc/avi-ansible/vars.json}"
: "${AVI_READY_PATH:=/api/initial-data}"
: "${READY_RETRIES:=90}"
: "${READY_DELAY:=10}"
: "${LOG:=/var/log/avi-playbooks.log}"
: "${STATE_DIR:=/var/lib/avi-playbooks}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${STATE_DIR}"
exec >> "${LOG}" 2>&1
log() { echo "$(date '+%F %T') avi-playbooks: $*"; }

[ -r "${VARS_FILE}" ] || { log "cannot read ${VARS_FILE}"; exit 1; }

# json_get <python expression on d (the parsed vars file)>
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${VARS_FILE}" "$1"; }

# site_vars <site> <out-file>: shared overlaid by the site's vars, plus the site key
site_vars() {
  python3 - "${VARS_FILE}" "$1" "$2" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1])); site = sys.argv[2]
merged = {**d.get("shared", {}), **d["sites"][site]["vars"], "site": site}
fd = os.open(sys.argv[3], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(merged, f)
PY
}

controller_ready() {
  [ "$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://${1}${AVI_READY_PATH}" 2>/dev/null)" = "200" ]
}

wait_ready() {
  local site=$1 controller=$2 n=1
  until controller_ready "${controller}"; do
    if [ "${n}" -ge "${READY_RETRIES}" ]; then log "${site}: ${controller} not ready after ${READY_RETRIES} checks"; return 1; fi
    log "${site}: ${controller} not ready yet (check ${n}/${READY_RETRIES})"
    n=$((n + 1))
    sleep "${READY_DELAY}"
  done
  log "${site}: ${controller} ready"
}

SITES="$(json_get '" ".join(d["sites"])')" || { log "bad vars file ${VARS_FILE}"; exit 1; }
PLAYBOOKS="${AVI_PLAYBOOKS:-$(json_get '" ".join(d.get("playbooks") or ["base.yaml"])')}"
failed=0
log "started: sites=[${SITES}] playbooks=[${PLAYBOOKS}]"
for site in ${SITES}; do
  extra="$(mktemp "${STATE_DIR}/vars.XXXXXX")"
  site_vars "${site}" "${extra}"
  controller="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("controller",""))' "${extra}")"
  if [ -z "${controller}" ]; then log "${site}: no controller address (no mgmt-ip on its VM and no controller var)"; failed=$((failed + 1)); rm -f "${extra}"; continue; fi
  if ! wait_ready "${site}" "${controller}"; then failed=$((failed + 1)); rm -f "${extra}"; continue; fi
  for playbook in ${PLAYBOOKS}; do
    marker="${STATE_DIR}/${site}.${playbook//\//_}.done"
    if [ -e "${marker}" ] && [ "${FORCE:-0}" != "1" ]; then log "${site}: ${playbook} already done, skipping"; continue; fi
    log "${site}: running ${playbook}"
    if (cd "${HERE}/ansible" && ansible-playbook -e "@${extra}" "${playbook}"); then
      touch "${marker}"; log "${site}: ${playbook} OK"
    else
      log "${site}: ${playbook} FAILED"; failed=$((failed + 1)); break
    fi
  done
  rm -f "${extra}"
done
log "finished, ${failed} failure(s)"
[ "${failed}" -eq 0 ]
