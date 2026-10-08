# dev-edu-student-vapp

Ansible playbooks that configure the Avi controllers of the student-avi-edu vApp, run from the
`ubuntu-bootstrap` VM. The VM clones this repo at boot (its bootstrap script, see the
vApp-student-edu CR in epc-vapp) and calls `run.sh`; to change the automation, push here and re-run
`run.sh` on the VM - no new VM needed.

## Layout

| Path | Purpose |
|---|---|
| `run.sh` | per site: waits until the controller's API answers, then runs the playbooks against it |
| `ansible/ansible.cfg` | Ansible settings (local inventory, no host key checking) |
| `ansible/*.yaml` | playbooks, run in the order given by the CR (default `base.yaml`) |

## Variables

They come from the CR, from the `ansible` block of the `ubuntu-bootstrap` VM. At first boot the
operator writes it to `/etc/avi-ansible/vars.json` (mode 0600, it holds passwords; run `run.sh` as root):

    ansible:
      repo: https://github.com/demoavi/dev-edu-student-vapp.git
      ref: main                    # optional
      playbooks: [base.yaml]       # optional, relative to ansible/
      shared:                      # given to every site
        avi_username: admin
        avi_password: ...
        avi_old_password: ...
      sites:                       # one per controller
        - name: dc1
          vm: dc1-avi-ctrl-1       # a VM of the same CR
          vars: {}                 # this site only, wins over shared and over the derived values
        - name: dc2
          vm: dc2-avi-ctrl-1

For each site `run.sh` hands Ansible one extra-vars file: `shared`, overlaid by the site's `vars`,
plus `site`. The operator adds two values to every site, derived from the VM it points at, unless
the site's `vars` set them:

| Variable | Derived from |
|---|---|
| `controller` | the VM's `mgmt-ip` ovfProperty |
| `avi_version` | the first `x.y.z` in the VM's template name (`controller-32.1.3-9105.ova` -> `32.1.3`) |

Playbooks use plain names (`controller`, `avi_version`, `avi_username`, `avi_password`, ...). Values
keep their JSON types, so lists and dictionaries are fine.

## Running by hand

    sudo ./run.sh
    tail -f /var/log/avi-playbooks.log

Other knobs (environment): `AVI_PLAYBOOKS` (override the list), `AVI_READY_PATH` (API path that
answers 200 once a controller is up, default `/api/initial-data`), `READY_RETRIES`/`READY_DELAY`
(default 90 x 10 s), `FORCE=1` (re-run what already succeeded), `VARS_FILE`, `LOG`, `STATE_DIR`.
A playbook that succeeded for a site leaves a marker in `/var/lib/avi-playbooks/` and is skipped
next time.

## Status

Skeleton: `base.yaml` only sets the admin password (derived from `dev-avi-edu`'s `sa.yaml`) and has
not been run against a controller yet.
