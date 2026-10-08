# dev-edu-student-vapp

Ansible playbooks that configure the Avi controllers of the student-avi-edu vApp, run from the
`ubuntu-bootstrap` VM. The VM clones this repo at boot (see the vApp-student-edu CR in epc-vapp)
and calls `run.sh`; to change the automation, push here and re-run `run.sh` on the VM (it does not
need a new VM).

## Layout

| Path | Purpose |
|---|---|
| `run.sh` | waits until each controller's API answers, then runs the playbooks against it |
| `ansible/ansible.cfg` | Ansible settings (local inventory, no host key checking) |
| `ansible/*.yaml` | playbooks, run in the order of `AVI_PLAYBOOKS` |

## Environment contract

Everything comes from the environment. On the VM these are the CR's `envVars`, which end up in
`/etc/profile.d/edu-env.sh` (`run.sh` sources it).

| Variable | Required | Meaning |
|---|---|---|
| `AVI_CONTROLLERS` | yes | space separated controller names/IPs, e.g. `dc1-avi-ctrl-1.avi.lab dc2-avi-ctrl-1.avi.lab` |
| `AVI_VERSION` | yes | Avi API version passed to the modules |
| `AVI_PASSWORD` | yes | admin password the controllers should end up with |
| `AVI_OLD_PASSWORD` | yes | admin password they start with (the OVF `default-password`, or Avi's default) |
| `AVI_USERNAME` | no | default `admin` |
| `AVI_PLAYBOOKS` | no | playbooks to run in order, relative to `ansible/` (default `base.yaml`) |
| `AVI_READY_PATH` | no | API path that answers 200 once a controller is up (default `/api/initial-data`) |
| `READY_RETRIES`, `READY_DELAY` | no | readiness polling, default 90 x 10 s |
| `FORCE` | no | `1` re-runs playbooks that already succeeded |

`run.sh` exports `AVI_CONTROLLER` (singular) for each playbook run.

## Running by hand

    cd /path/to/this/repo && ./run.sh
    tail -f /var/log/avi-playbooks.log

A playbook that succeeded for a controller leaves a marker in `/var/lib/avi-playbooks/` and is
skipped next time.

## Status

Skeleton: `base.yaml` only sets the admin password (derived from `dev-avi-edu`'s `sa.yaml`) and has
not been run against a controller yet.
