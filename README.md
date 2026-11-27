# `linux` role

Basic setup of Linux VMs: users, SSH server settings, the UFW firewall (Ubuntu), timezone,
`/etc/hosts` entries, trusted CA certificates, packages (incl. extra repositories), package
upgrades, disk partitions / LVM / filesystems / mounts, sysctl settings and ulimits.

Everything is opt-in — with the defaults the role changes nothing, so you can
enable one feature at a time per host or group.

## Requirements

* ansible-core ≥ 2.15 (tested on 2.21)
* Collections: `community.general`, `ansible.posix` — `ansible-galaxy install -r requirements.yml`
* Debian/Ubuntu or RedHat-family targets; the role asserts this up front.
  Repository management is implemented per family (deb822/one-line vs. yum).
  The firewall is Ubuntu only.
* `become: true` — the role configures system state throughout.

## Usage

```yaml
- hosts: linux
  become: true
  roles:
    - role: linux
```

Tags: `timezone`, `hosts`, `ca_certificates`, `repositories`, `upgrade`, `packages`, `users`,
`ssh`, `ufw`, `storage`, `sysctl`, `limits` — plus `linux` for all of them.

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

## Firewall (UFW)

Ubuntu only: with `linux_ufw_enabled: true` the role fails on any other
distribution, before it changes anything. With the default `false` it leaves
UFW alone — it does not disable a firewall that is already running.

```yaml
# host_vars/nas01.yml
linux_ufw_enabled: true
linux_ufw_rules:
  - {port: 22,   proto: tcp, from: 192.168.1.0/24, comment: SSH from LAN}
  - {port: 9100, proto: tcp, from: 192.168.1.10,   comment: node_exporter for Prometheus}
  - {port: 443,  proto: tcp, comment: HTTPS from anywhere}
  - {port: 8080, proto: tcp, from: 192.168.1.50, remove: true}  # drop an old rule

# defaults
linux_ufw_default_incoming: deny    # allow | deny | reject
linux_ufw_default_outgoing: allow
linux_ufw_default_routed: deny
```

A rule entry also takes `to`, `rule` (`allow`, `deny`, `reject` or `limit`),
`direction` and `interface`; see [meta/argument_specs.yml](meta/argument_specs.yml).
`port` may be a range (`"8000:8100"`) or a list (`"80,443"`), which then need
`proto`. Without `from` a rule covers IPv4 and IPv6.

The role does not prune rules it is not told about: dropping an entry from the
list leaves its rule in UFW, so set `remove: true` instead. The comment is not passed along when a rule
is removed, since UFW would only delete a rule with exactly that comment.

The rules and policies are applied first, then UFW is enabled, which keeps open
connections alive. Before that the role checks that a rule allows the tcp port
Ansible connects to (`ansible_port`, 22 by default), as UFW would otherwise lock
the next run out. It only checks the port, not that `from` covers the
controller. Set `linux_ufw_check_ssh_rule: false` when Ansible gets in some
other way.

UFW applies `/etc/ufw/sysctl.conf` whenever it starts, which wins over
[sysctl](#sysctl) settings for the same keys (`accept_redirects`,
`log_martians`, …).

### Docker and the DOCKER-USER chain

Docker publishes container ports through the `FORWARD` chain, ahead of UFW, so
UFW rules do not apply to them. The chain Docker evaluates first is
`DOCKER-USER`; its rules go to a managed block in `/etc/ufw/after.rules` and
are loaded together with UFW:

```yaml
linux_ufw_docker_user_rules:
  - rule: -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    comment: replies to connections the containers opened
  - rule: -s 192.168.1.0/24 -j RETURN
    comment: the LAN reaches every published port
  - rule: -p tcp -m conntrack --ctorigdstport 443 --ctdir ORIGINAL -j RETURN
    comment: HTTPS from anywhere
  - rule: -i eth0 -j DROP
    comment: nothing else from outside
```

Each `rule` is an iptables rule spec, appended to `DOCKER-USER` in the order of
the list (the role writes the `-A DOCKER-USER`). `RETURN` hands the packet back
to Docker, which accepts it; anything that falls through the list goes back to
Docker as well, so finish with a `DROP` for the traffic you want to keep out. The
connections the containers open themselves come back through this chain too,
hence the first rule. Docker translates the destination before the chain, so
`--dport` matches the port inside the container — match the published port
with `-m conntrack --ctorigdstport`, as above.

The block declares the chain, which empties it whenever UFW starts or reloads:
the chain holds exactly these rules, also after Docker restarts. Before the
file is installed it is checked with `iptables-restore --test` — a file that
does not load makes `ufw reload` stop half-way and mark UFW disabled. The test
cannot see whether a chain a rule jumps to exists; such a rule fails at the
reload. UFW is reloaded whenever the block changes.

`linux_ufw_docker_user_rules_ipv6` does the same for IPv6, in
`/etc/ufw/after6.rules`. An empty list removes its block and flushes the chain.
Docker's nftables firewall backend has no `DOCKER-USER` chain; this needs the
default iptables one.

## Timezone

```yaml
linux_timezone: Europe/Berlin
linux_hwclock: UTC            # optional
```

Cron is restarted afterwards because it only reads `/etc/localtime` at start-up.
On systemd hosts `timedatectl` does not touch Debian's `/etc/timezone`, so the
role keeps that file in sync itself.

## /etc/hosts

```yaml
linux_hosts:
  - {name: nas.lan, ip: 192.168.1.10}
  - {name: nas, ip: 192.168.1.10}       # one name per entry
  - {name: printer.lan, ip: "fd00::20"}
```

The entries go into a block of their own at the end of `/etc/hosts`:

```
# BEGIN ANSIBLE MANAGED BLOCK: linux_hosts
192.168.1.10    nas.lan
192.168.1.10    nas
fd00::20        printer.lan
# END ANSIBLE MANAGED BLOCK: linux_hosts
```

The block holds exactly what is listed: dropping an entry removes its line, and
an empty list — the default — removes the block. That is why this step runs
even when `linux_hosts` is empty; where the role never added a block, it leaves
the file as it is. Lines outside the block are not touched, so a name that also
appears in one of them (Debian's `127.0.1.1 <hostname>`, say) ends up with two
addresses, and which one a program gets depends on how it resolves names —
remove the other line if that is not what you want.

Every entry is checked before the file is written: the resolver silently skips
a line whose address it cannot parse. It runs before the
[repositories](#packages-and-repositories) are configured, so their servers may
be named here.

cloud-init with `manage_etc_hosts: true` writes `/etc/hosts` from its template
at every boot and drops the block until the role runs again; set it to `false`
(or put the entries into `/etc/cloud/templates/hosts.*.tmpl`) on such hosts.

## CA certificates

```yaml
linux_ca_certificates:
  - name: homelab-root              # installed as homelab-root.crt
    src: certs/homelab-root.crt     # a PEM file on the controller ...
  - name: homelab-issuing
    content: |                      # ... or the certificate itself
      -----BEGIN CERTIFICATE-----
      MIIBkzCCATmgAwIBAgIU...
      -----END CERTIFICATE-----
  - name: old-root
    remove: true                    # take it out of the trust store again
```

The certificates go to the directory each family reads local CAs from —
`/usr/local/share/ca-certificates/` on Debian/Ubuntu,
`/etc/pki/ca-trust/source/anchors/` on RedHat. Whenever one was added, changed
or removed, the trust store is rebuilt with `update-ca-certificates --fresh`
(`--fresh` also drops the `/etc/ssl/certs` links of a removed certificate) or
`update-ca-trust extract`. That happens right away rather than at the end of the
play, so the [repositories](#packages-and-repositories) configured next may
already be served with a certificate from one of these CAs.

`src` is looked up like `copy`'s: a relative path is searched in the `files/`
directory next to the playbook. Every entry must hold a PEM certificate; the
role checks that on the controller before changing anything, since
`update-ca-certificates` would only warn about anything else and leave it out.
Keep one certificate per entry: Debian adds a file with several of them to the
bundle, but skips it for the hashed lookup in `/etc/ssl/certs`.

Dropping an entry from the list leaves its file on the host — set
`remove: true` instead.

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
