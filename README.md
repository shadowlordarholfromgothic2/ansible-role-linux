# `linux` role

Basic setup of Linux VMs: users, SSH server settings, timezone, packages (incl. extra repositories),
package upgrades, disk partitions / LVM / filesystems / mounts, sysctl settings
and ulimits.

Everything is opt-in — with the defaults the role changes nothing, so you can
enable one feature at a time per host or group.

## Requirements

* ansible-core ≥ 2.15 (tested on 2.21)
* Collections: `community.general`, `ansible.posix` — `ansible-galaxy install -r requirements.yml`
* Debian/Ubuntu or RedHat-family targets; the role asserts this up front.
  Repository management is implemented per family (deb822/one-line vs. yum).
* `become: true` — the role configures system state throughout.

## Usage

```yaml
- hosts: linux
  become: true
  roles:
    - role: linux
```

Tags: `timezone`, `repositories`, `upgrade`, `packages`, `users`, `ssh`, `storage`,
`sysctl`, `limits` — plus `linux` for all of them.

```bash
ansible-playbook linux.yml --tags users,packages
```

Every variable is described in [meta/argument_specs.yml](meta/argument_specs.yml)
(`ansible-doc -t role` shows them) and checked against it before the role runs:
a wrong type, an unknown key in a list entry (say, a typo in a `linux_users`
item) or a missing required key fails the play up front. The check templates
the variables before the role gathers facts, so in a play with
`gather_facts: false` they must not refer to `ansible_facts`.

## Users

```yaml
linux_groups:
  - {name: deploy, gid: 1500}

linux_users:
  - name: deploy
    comment: Deployment user
    groups: [deploy, docker]        # supplementary; `group:` sets the primary one
    shell: /bin/bash
    ssh_keys:
      - "ssh-ed25519 AAAA... kirgo@laptop"
    ssh_keys_exclusive: true        # prune keys that are not listed here
    sudo: true
    sudo_nopasswd: true

  - name: appsvc                    # service account, no login, no sudo
    system: true
    shell: /usr/sbin/nologin
    create_home: false

  - name: olduser
    state: absent
    remove: true                    # also delete the home directory
```

`sudo: true` writes `/etc/sudoers.d/60-ansible-<user>`, validated with `visudo -c`
before it is installed. Set `sudo_rules` to replace the default
`ALL=(ALL:ALL) NOPASSWD:ALL` with your own lines (it still needs `sudo: true`).
Turning `sudo` off again removes the drop-in.

### Passwords

Passwords are optional and live in their own variable so that `linux_users` can
stay in readable group_vars while the secrets are vaulted:

```yaml
# group_vars/linux/vault.yml  — ansible-vault encrypt this file
linux_user_passwords:
  deploy: "the-plaintext-password"
  backup: "$6$rounds=656000$somesalt$somehash..."   # already a crypt(3) hash
```

Values that already look like a crypt hash are used as they are; anything else
is hashed on the controller with `linux_user_password_algorithm` (`sha512`).
Plaintext is hashed with a salt derived from the user name and
`linux_user_password_salt`, so the resulting hash is stable — otherwise
`/etc/shadow` would be rewritten on every run. **Override
`linux_user_password_salt` per environment**, and treat it as part of the secret.

Users without an entry are left alone. `linux_user_update_password` (`always` by
default) decides whether an existing password is overwritten or only set at
creation time (`on_create`). The user task runs with `no_log` — set
`linux_users_no_log: false` when you need to debug it.

## SSH server

```yaml
linux_sshd_configure: true

# defaults
linux_sshd_pubkey_authentication: true              # PubkeyAuthentication
linux_sshd_password_authentication: false           # PasswordAuthentication
linux_sshd_kbd_interactive_authentication: false    # KbdInteractiveAuthentication
linux_sshd_permit_root_login: false                 # PermitRootLogin
linux_sshd_max_auth_tries: 3                        # MaxAuthTries
```

Booleans are written as `yes`/`no`; `linux_sshd_permit_root_login` also takes
`prohibit-password` or `forced-commands-only`.

The settings go to `/etc/ssh/sshd_config.d/00-ansible.conf`. sshd keeps the
first value it reads for a keyword, and Debian, Ubuntu and EL9 include that
directory at the top of `sshd_config`, so the `00-` prefix wins over drop-ins
like Ubuntu's `50-cloud-init.conf` (which may turn password logins back on).
The file is checked with `sshd -t` before it is installed, sshd is reloaded
afterwards, and the role then reads `sshd -T` to confirm every setting is in
effect — it fails if something earlier in the config overrides them.

`openssh-server` is installed if it is missing. With the defaults, password and
root logins stop working: make sure the account Ansible connects as has a key
(see `ssh_keys` under [Users](#users), which runs first) before enabling this.

## Timezone

```yaml
linux_timezone: Europe/Berlin
linux_hwclock: UTC            # optional
```

Cron is restarted afterwards because it only reads `/etc/localtime` at start-up.
On systemd hosts `timedatectl` does not touch Debian's `/etc/timezone`, so the
role keeps that file in sync itself.

## Packages and repositories

```yaml
linux_apt_keys:
  - {name: docker, url: "https://download.docker.com/linux/debian/gpg"}

linux_apt_repositories:            # ansible.builtin.deb822_repository
  - name: docker
    uris: https://download.docker.com/linux/debian
    suites: ["{{ ansible_facts.distribution_release }}"]
    components: [stable]
    signed_by: /etc/apt/keyrings/docker.asc

linux_packages: [htop, curl, containerd.io]
linux_packages_absent: [telnet]
linux_apt_install_recommends: false
```

Keys are fetched into `/etc/apt/keyrings/<name>.asc`; for a binary (dearmored)
key set `dest:` with a `.gpg` suffix. A key that is already present is left
alone, without contacting the server; set `force: true` on the entry to fetch it
again (e.g. after the vendor rotated it), and drop it once done. The apt cache
is refreshed immediately after a repository change, so packages from the new
repo can be installed in the same run. `python3-debian`, which
`deb822_repository` needs, is installed automatically.

In check mode a new repository is never really written, so its packages cannot
be found yet. When a repository changed in the same run, "No package … available"
is therefore only reported, not treated as a failure; otherwise it still fails.

For repos that are easier to write as a single line use
`linux_apt_repositories_legacy` (`filename` + `repo`); the role writes the
`.list` file directly, since `apt_repository` is deprecated as of core 2.21.
RedHat targets use `linux_yum_repositories`.

## Upgrades

```yaml
linux_upgrade: true
linux_upgrade_type: safe        # apt: safe | full | dist | yes
linux_reboot_if_required: false # reboot when the system asks for one
```

## Storage

Order of operations: partitions → volume groups → logical volumes →
filesystems → mounts.

```yaml
linux_partitions:
  - {device: /dev/sdb, number: 1, label: gpt, part_end: 100%, flags: [lvm]}

linux_lvm_volume_groups:
  - {name: vg_data, pvs: [/dev/sdb1]}

linux_lvm_volumes:
  - {name: lv_docker, vg: vg_data, size: 50G}

linux_filesystems:
  - {device: /dev/vg_data/lv_docker, fstype: ext4}

linux_mounts:
  - path: /var/lib/docker
    src: /dev/vg_data/lv_docker
    fstype: ext4
    opts: defaults,noatime
    owner: root
    mode: "0711"
```

Notes:

* The role fails with a clear message if a device in `linux_partitions` does not
  exist, rather than partitioning something unintended.
* After partitioning it waits for the new device nodes (`udevadm settle` +
  `wait_for`), which otherwise race with the next task.
* Creating a filesystem where a *different* one already exists needs an explicit
  `force: true` per entry. That reformats the device — check twice.
* Mount point ownership is applied after mounting, so it lands on the mounted
  filesystem and not on the directory underneath.
* `linux_mounts` entries with `state: present` only write the fstab line.
* In check mode nothing is really created, so a step that needs a partition,
  volume group or logical volume added in the same run — or a mount point owner
  or group from `linux_users`/`linux_groups` — cannot find it. Such a step is
  reported as changed and listed at the end instead of failing, but only when
  the step that adds it changed something; otherwise it still fails.

## sysctl

```yaml
linux_sysctl:
  net.ipv4.ip_forward: 1
  vm.swappiness: 10
linux_sysctl_absent: [net.ipv4.tcp_syncookies]
```

Written to `/etc/sysctl.d/99-ansible.conf` and applied at runtime.

## ulimits

```yaml
linux_limits:
  - {domain: "*", type: soft, item: nofile, value: 65535, comment: raise the fd limit}
  - {domain: "@deploy", type: hard, item: nproc, value: 4096}
```

Rendered as a single managed file (`/etc/security/limits.d/99-ansible.conf`), so
removing an entry from the list also removes it from the host.

`limits.conf` is enforced by `pam_limits`, i.e. for login sessions only. Daemons
started by systemd get their limits from systemd, so set those separately:

```yaml
linux_systemd_limits:
  DefaultLimitNOFILE: "65535:65535"
```

This writes drop-ins for `system.conf` and `user.conf` and runs
`systemctl daemon-reexec`. Already running services keep their old limits until
they are restarted.
