#!/bin/bash
# Waits for each Avi controller, then runs the playbooks in ansible/ against it - once per site.
# Meant to be started on ubuntu-bootstrap after the Ansible install; safe to re-run by hand
# (as root: the vars file holds passwords): a playbook that already succeeded for a site is
# skipped, FORCE=1 runs it again.
#
# Variables come from /etc/avi-ansible/vars.json, written at first boot from the `ansible` block
# of the vApp-student-edu CR: for every site the shared variables overlaid by the site's own vars
# (which already include the derived `controller`, `avi_version` and `lsc_hosts`). They reach Ansible
# through a temporary 0600 extra-vars file, so the playbooks just use plain names.
# The site's `hosts` become an inventory (group selsc, with one child group selsc_<site>) for the
# playbooks that target the hosts: Ansible logs in as ${lsc_ssh_user:-ubuntu} with `lsc_private_key`
# (written to a temporary 0600 file).
#
# What to wait for: each playbook says what it needs in a comment line, `# needs: controller`,
# `# needs: hosts` or `# needs: controller hosts` (no line = controller). run.sh waits for the
# controller's API and/or SSH on the site's hosts only before the first playbook that needs it, so a
# playbook that needs only the hosts (docker.yaml) can run while the controller is still booting.
#   VARS_FILE         default /etc/avi-ansible/vars.json
#   AVI_PLAYBOOKS     overrides the playbook list of the vars file (space separated, relative to ansible/)
#   AVI_READY_PATH    API path that answers 200 once a controller is up (default /api/initial-data)
#   READY_RETRIES / READY_DELAY   readiness polling for controllers and hosts (default 90 x 10s)
#   HOST_SSH_PORT     default 22
#   LOG, STATE_DIR    log file and per-site success markers
: "${VARS_FILE:=/etc/avi-ansible/vars.json}"
: "${AVI_READY_PATH:=/api/initial-data}"
: "${READY_RETRIES:=90}"
: "${READY_DELAY:=10}"
: "${HOST_SSH_PORT:=22}"
: "${LOG:=/var/log/avi-playbooks.log}"
: "${STATE_DIR:=/var/lib/avi-playbooks}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${STATE_DIR}"
exec >> "${LOG}" 2>&1
log() { echo "$(date '+%F %T') avi-playbooks: $*"; }

[ -r "${VARS_FILE}" ] || { log "cannot read ${VARS_FILE}"; exit 1; }

# playbook_needs <playbook>: the words after "# needs:" in the playbook (default: controller)
playbook_needs() {
  local needs
  needs="$(sed -n 's/^# needs: *//p' "${HERE}/ansible/$1" 2>/dev/null | head -1)"
  echo "${needs:-controller}"
}

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

# site_inventory <site> <extra-vars-file> <inventory-out> <key-out>
# Writes the Ansible inventory (JSON) for the site's hosts and, if lsc_private_key is set, the key file.
site_inventory() {
  python3 - "${VARS_FILE}" "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1])); site = sys.argv[2]
extra = json.load(open(sys.argv[3])); inventory_path, key_path = sys.argv[4], sys.argv[5]
common = {"ansible_user": extra.get("lsc_ssh_user", "ubuntu"),
          "ansible_ssh_common_args": "-o UserKnownHostsFile=/dev/null"}
if extra.get("lsc_private_key"):
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(extra["lsc_private_key"].rstrip("\n") + "\n")
    common["ansible_ssh_private_key_file"] = key_path
hosts = {name: {"ansible_host": address} for name, address in d["sites"][site].get("hosts", {}).items()}
inventory = {"all": {"children": {"selsc": {"vars": common, "children": {f"selsc_{site}": {"hosts": hosts}}}}}}
fd = os.open(inventory_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(inventory, f)
PY
}

# site_host_addresses <site>: one "name address" line per host
site_host_addresses() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(n, a) for n, a in d["sites"][sys.argv[2]].get("hosts", {}).items()]' "${VARS_FILE}" "$1"
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

host_ssh_ready() { timeout 5 bash -c "exec 3<>/dev/tcp/${1}/${HOST_SSH_PORT}" 2>/dev/null; }

# wait_hosts <site>: SSH port of every host of the site answers
wait_hosts() {
  local site=$1 name address n
  while read -r name address; do
    [ -n "${name}" ] || continue
    n=1
    until host_ssh_ready "${address}"; do
      if [ "${n}" -ge "${READY_RETRIES}" ]; then log "${site}: host ${name} (${address}) not reachable on port ${HOST_SSH_PORT} after ${READY_RETRIES} checks"; return 1; fi
      log "${site}: host ${name} (${address}) not reachable yet (check ${n}/${READY_RETRIES})"
      n=$((n + 1))
      sleep "${READY_DELAY}"
    done
    log "${site}: host ${name} (${address}) reachable"
  done < <(site_host_addresses "${site}")
}

SITES="$(json_get '" ".join(d["sites"])')" || { log "bad vars file ${VARS_FILE}"; exit 1; }
PLAYBOOKS="${AVI_PLAYBOOKS:-$(json_get '" ".join(d.get("playbooks") or ["base.yaml"])')}"
failed=0
log "started: sites=[${SITES}] playbooks=[${PLAYBOOKS}]"
for site in ${SITES}; do
  extra="$(mktemp "${STATE_DIR}/vars.XXXXXX")"
  inventory="$(mktemp "${STATE_DIR}/inventory.XXXXXX")"
  key="$(mktemp "${STATE_DIR}/key.XXXXXX")"
  cleanup() { rm -f "${extra}" "${inventory}" "${key}"; }
  site_vars "${site}" "${extra}"
  site_inventory "${site}" "${extra}" "${inventory}" "${key}"
  controller="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("controller",""))' "${extra}")"
  controller_ready_flag=0
  hosts_ready_flag=0
  for playbook in ${PLAYBOOKS}; do
    marker="${STATE_DIR}/${site}.${playbook//\//_}.done"
    if [ -e "${marker}" ] && [ "${FORCE:-0}" != "1" ]; then log "${site}: ${playbook} already done, skipping"; continue; fi
    needs="$(playbook_needs "${playbook}")"
    if [[ " ${needs} " == *" controller "* ]] && [ "${controller_ready_flag}" = "0" ]; then
      if [ -z "${controller}" ]; then log "${site}: ${playbook} needs a controller but there is no address (no mgmt-ip on its VM and no controller var)"; failed=$((failed + 1)); break; fi
      if ! wait_ready "${site}" "${controller}"; then log "${site}: ${playbook} FAILED (controller not ready)"; failed=$((failed + 1)); break; fi
      controller_ready_flag=1
    fi
    if [[ " ${needs} " == *" hosts "* ]] && [ "${hosts_ready_flag}" = "0" ]; then
      if ! wait_hosts "${site}"; then log "${site}: ${playbook} FAILED (hosts not reachable)"; failed=$((failed + 1)); break; fi
      hosts_ready_flag=1
    fi
    log "${site}: running ${playbook} (needs: ${needs})"
    if (cd "${HERE}/ansible" && ansible-playbook -i "${inventory}" -e "@${extra}" "${playbook}"); then
      touch "${marker}"; log "${site}: ${playbook} OK"
    else
      log "${site}: ${playbook} FAILED"; failed=$((failed + 1)); break
    fi
  done
  cleanup
done
log "finished, ${failed} failure(s)"
[ "${failed}" -eq 0 ]
