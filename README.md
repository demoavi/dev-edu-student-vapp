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
      playbooks: [base.yaml, lsc-hosts.yaml]   # optional, relative to ansible/
      shared:                      # given to every site
        avi_username: admin
        avi_password: ...
        avi_old_password: ...
        lsc_private_key: |         # SSH private key (PEM) for the LSC cloud connector user
          -----BEGIN RSA PRIVATE KEY-----
          ...
      sites:                       # one per controller
        - name: dc1
          vm: dc1-avi-ctrl-1       # a VM of the same CR
          hosts: [dc1-ubuntu-01, dc1-ubuntu-02]   # optional: VMs of the same CR that belong to this site
          vars: {}                 # this site only, wins over shared and over the derived values
        - name: dc2
          vm: dc2-avi-ctrl-1
          hosts: [dc2-ubuntu-01, dc2-ubuntu-02]

For each site `run.sh` hands Ansible one extra-vars file: `shared`, overlaid by the site's `vars`,
plus `site`. The operator adds two values to every site, derived from the VM it points at, unless
the site's `vars` set them:

| Variable | Derived from |
|---|---|
| `controller` | the VM's `mgmt-ip` ovfProperty |
| `avi_version` | the first `x.y.z` in the VM's template name (`controller-32.1.3-9105.ova` -> `32.1.3`) |
| `lsc_hosts` | the site's `hosts`: a list of `{name, address}`; each address is the first address of the netplan interface that carries the default route in that VM's `userData` |

## Inventory for the hosts

`run.sh` turns each site's `hosts` into an inventory: group `selsc`, child group `selsc_<site>`, one
entry per VM with `ansible_host` set to its derived address. Ansible logs in as `ubuntu`
(`lsc_ssh_user` to change it) with `lsc_private_key`, which `run.sh` writes to a temporary 0600 file
whose path goes into the inventory. A playbook that targets the hosts uses `hosts: "selsc_{{ site }}"`;
when a playbook file mentions `selsc`, `run.sh` first waits for SSH (port 22) on the site's hosts.

Other variables used by `base.yaml`: `lsc_private_key` (the task that creates the cloud connector
user is skipped when it is empty) and the optional `lsc_user_name` (default `credsLsc`). The matching
public key is put on the Ubuntu VMs through the CR's per-VM `sshAuthorizedKeys`.

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

- `base.yaml` (derived from `dev-avi-edu`'s `sa.yaml`) sets the admin password, then creates the SSH
  cloud connector user (`credsLsc`) the Linux Server Cloud will use to reach the Ubuntu hosts.
- `lsc-hosts.yaml` runs per site against that site's hosts and runs the controller's
  `linux_host_install` script on each (guarded by a marker file). The private key is not copied to the
  hosts: the controller's cloud connector user holds it, and `run.sh` uses it to log in.

Neither has been run against real controllers/hosts yet.
