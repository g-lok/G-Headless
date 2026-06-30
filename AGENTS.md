# AGENTS.md — LUKS2 SSH Boot Playbook

## Project

Public-facing Ansible playbooks that bootstrap full-disk-encrypted Linux systems with initramfs SSH unlock. Two playbooks:

- **`bootstrap-arch.yml`** — Arch Linux + LUKS2 + btrfs/ext4/xfs + tinyssh on x86_64 systems
- **`bootstrap-pi.yml`** — Raspberry Pi OS + LUKS + ext4 + dropbear on Pi 3/4/5 (image builder)

## Critical Patterns

### Unique /mnt subdirectory per playbook

ALWAYS mount under `/mnt/{{ bootstrap_mount }}` — never bare `/mnt`. Each playbook owns a unique subdirectory:
- **Arch**: `bootstrap_mount_subdir: bootstrap_work` (from role defaults)
- **Pi**: `bootstrap_mount_subdir: pi_bootstrap` (from role defaults)

This prevents cross-contamination between playbooks and avoids clobbering host mounts.

### pacstrap on non-Arch hosts

Host may be Debian/Ubuntu/Fedora. `pacstrap` needs clean pacman.conf + mirrorlist. ALWAYS generate clean config and pass `-C`:

```
pacstrap -C /tmp/pacstrap-pacman.conf -K /mnt/{{ bootstrap_mount }} base ...
```

Clean config must inline `Server =` lines — don't `Include = /etc/pacman.d/mirrorlist` (that's the host's mirrorlist).

### arch-chroot tmpfs shadow

`arch-chroot` mounts tmpfs over `/tmp`. Files in `/mnt/{{ bootstrap_mount }}/tmp/` are INVISIBLE inside chroot. For pacman operations: use `pacman --root=/mnt/{{ bootstrap_mount }} --cachedir=... --config=...` directly. For shell commands: use `arch-chroot /mnt/{{ bootstrap_mount }} sh -c '...'` (expands inside chroot).

### chroot /etc/resolv.conf

`arch-chroot` creates `/etc/resolv.conf` inside chroot as file or bind mount. Before replacing with symlink: `umount /etc/resolv.conf 2>/dev/null; rm -f /etc/resolv.conf; ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf`

### LUKS mapper cleanup between runs

1. `umount -l -R /mnt/{{ bootstrap_mount }}` (lazy, succeeds despite busy)
2. Iterate dmsetup, close LUKS mapped to target disk, fallback `dmsetup remove -f`
3. Check if mapper name still taken; append random suffix if so
4. Remove mount dir: `file: path=/mnt/{{ bootstrap_mount }} state=absent`

### Ansible find module

Returns dicts with `.path` key. No `.version` attribute. Use `basename` filter and `set_fact`.

### vendored AUR package install

```
# Copy (use /mnt/{{ bootstrap_mount }}/tmp/ but avoid arch-chroot for pacman)
dest: "/mnt/{{ bootstrap_mount }}/tmp/{{ vendored_pkg_basename }}"

# Install
ansible.builtin.command:
  argv:
    - pacman
    - --root=/mnt/{{ bootstrap_mount }}
    - --cachedir=/mnt/{{ bootstrap_mount }}/var/cache/pacman/pkg
    - --config=/mnt/{{ bootstrap_mount }}/etc/pacman.conf
    - -U
    - --noconfirm
    - "/mnt/{{ bootstrap_mount }}/tmp/{{ vendored_pkg_basename }}"
```

### EFI partition residue

Partial runs leave files on vfat EFI partition. Clean before pacstrap: `rm -rf /mnt/{{ bootstrap_mount }}/boot/*`

### Kernel reinstall before mkinitcpio

After pacstrap, `vmlinuz-linux` may be missing from `/boot/`. Defensive reinstall: `arch-chroot /mnt/{{ bootstrap_mount }} pacman -S --noconfirm linux` before `mkinitcpio -P`.

### Cleanup must be aggressive

`umount -R` fails on busy mounts. Always `umount -l -R`. LUKS close can also fail — iterate `dmsetup ls`, match to target disk, try `cryptsetup close`, fall back to `dmsetup remove -f`. Remove mount directory after unmount. Both Arch (`roles/bootstrap-arch/tasks/cleanup.yml`) and Pi (`roles/bootstrap-pi/tasks/cleanup.yml`) use this pattern.

### LUKS password via ansible.builtin.command + argv + | trim (preferred)

`echo "{{ password }}" | cryptsetup` and `printf '%s\n' "{{ password }}" | cryptsetup` break if password contains shell metacharacters (`$`, `\`, `%`, `"`, etc). **Same bug applies to `echo user:password | chpasswd`**.

**Fix:** Use `ansible.builtin.command` with `argv:` list (bypasses shell entirely) + `stdin: "{{ password | trim }}"` to strip trailing whitespace. `ansible.builtin.shell` always appends `\n` to stdin — cryptsetup treats newline as literal password data. No temp files, no cleanup.

```yaml
- name: LUKS2 format root partition
  ansible.builtin.command:
    argv:
      - cryptsetup
      - luksFormat
      - --type=luks2
      - --key-file=-
      - "{{ bootstrap_luks_part }}"
    stdin: "{{ bootstrap_luks_password | trim }}"
  no_log: true

- name: Open LUKS container
  ansible.builtin.command:
    argv:
      - cryptsetup
      - open
      - --key-file=-
      - "{{ bootstrap_luks_part }}"
      - "{{ bootstrap_luks_mapper_name }}"
    stdin: "{{ bootstrap_luks_password | trim }}"
  no_log: true

- name: Set user password via chpasswd
  ansible.builtin.shell:
    cmd: "arch-chroot /mnt/{{ bootstrap_mount }} chpasswd"
    stdin: "{{ bootstrap_user_name }}:{{ bootstrap_user_password }}"
  no_log: true
```

The `--key-file=-` flag reads the password from stdin. `ansible.builtin.command` with `argv:` bypasses shell metacharacter issues entirely. `| trim` strips trailing whitespace/newlines that shell module would append. No temp file to write or clean up.

**chpasswd still uses `ansible.builtin.shell` with stdin** — chpasswd expects newline-terminated input, so the shell's automatic `\n` append is correct behavior.

**chpasswd with `< /path` redirect (old pattern):** The redirect runs on the HOST shell, so path must include host mount prefix (`/mnt/{{ bootstrap_mount }}/root/.pw_user`). arch-chroot shadows `/tmp` with tmpfs — use `/root/` paths. This pattern is now superseded by the stdin approach above.

### Swap disabled for k3s/docker

k3s kubelet defaults to `failSwapOn: true`. Strategy:
1. Don't create swap (no swap partition, no swapfile)
2. `swapoff -a` — turn off any active swap
3. `systemctl mask swap.target` — prevent systemd activation
4. Remove swap entries from fstab
5. Pi: disable `dphys-swapfile` (RPi OS default swap manager)

`noswap` is NOT a valid kernel parameter — don't use it.

### btrfs subvolumes for container workloads

For k3s/docker/containerd, separate subvolumes keep container data out of root snapshots:
- `@var_lib_docker` → `/var/lib/docker`
- `@var_lib_containerd` → `/var/lib/containerd`
- `@var_lib_rancher` → `/var/lib/rancher` (k3s data)

Snapshotting `@` before updates stays lean — container images/layers aren't included.

### Pi model detection

The Pi playbook supports Pi 3, 4, and 5. Set `bootstrap_pi_model` in config.yml (3, 4, or 5). This determines:
- Initramfs name: `initramfs_2710` (Pi 3), `initramfs_2711` (Pi 4), `initramfs_2712` (Pi 5)
- Kernel modules: ARMv8 crypto for Pi 3, ARMv8 CE crypto for Pi 4/5

### Pi PBKDF memory cap

**Critical:** The workstation auto-benchmarks Argon2 memory to ~1GB. Pi initramfs has limited RAM — it must allocate that much memory just to verify the LUKS password. On 8GB Pi 5 it works, but it's wasteful. On Pi 3/4 it can outright fail.

**Fix:** Always pass `--pbkdf-memory=512000 --pbkdf-parallel=1` to `cryptsetup luksFormat` for Pi targets:

```yaml
cryptsetup luksFormat --disable-locks --type=luks2
  --pbkdf-memory=512000 --pbkdf-parallel=1 --batch-mode
  --key-file=- "{{ tgt_root }}"
```

The `roles/bootstrap-pi/tasks/pi-prepare.yml` already includes this. Do not remove it.

### Pi 5 has hardware AES

Unlike Pi 3/4, Pi 5 has dedicated AES hardware acceleration. `aes-xts-plain64` runs at ~1800 MiB/s — same cipher as x86_64, no performance penalty. No need for the `xchacha20,aes-adiantum-plain64` fallback (needed on Pi 3/4 without crypto extensions).

### LUKS mapper cleanup — dual approach

Both cleanup and emergency-cleanup use two methods:
1. **Device-path matching** — iterate all dmsetup, `cryptsetup status` to get device, grep for `bootstrap_target_disk`
2. **Mapper-name matching** — `dmsetup ls | grep "^{{ bootstrap_luks_mapper_name }}"` catches `root` and `root-*`

Use both for defense in depth.

### btrfs subvol=@ in kernel cmdline

For btrfs: `rootflags=subvol=@,x-systemd.device-timeout=0`. Without `subvol=@`, systemd mounts top-level btrfs (empty subvolume dirs) → no init → switch_root fails → emergency loop. **Must be conditional** — ext4/xfs don't use subvol.

Similarly `MODULES=(igc btrfs)` in mkinitcpio.conf must be conditional — only include `btrfs` module when `bootstrap_filesystem == 'btrfs'`.

### initramfs predictable naming requires udev rules in FILES

`sd-network` in initramfs relies on udev for interface naming (predictable names like `enp1s0`). Without udev rules in the initramfs, all interfaces appear as `eth0`/`eth1` — matching a `.network` file by `Name=enp1s0` fails, and the interface gets no config.

**Fix:** Add these udev rules to `FILES=` in mkinitcpio.conf:

```
FILES=(... /usr/lib/udev/rules.d/75-net-description.rules /usr/lib/udev/rules.d/80-net-setup-link.rules /usr/lib/systemd/network/99-default.link)
```

Only needed when using `sd-network` with predictable naming. The Pi playbook uses `initramfs-tools` + dropbear with legacy `eth0` naming — not affected.

### ip= kernel parameter redundant with sd-network

When using `sd-network` + `sd-tinyssh` mkinitcpio hooks, the `ip=` kernel parameter is **not needed** — the `.network` file in the initramfs (via `FILES`) handles all networking. Remove `ip=` from kernel cmdline to avoid confusion.

**Pi (initramfs-tools):** Still needs `ip=` in `cmdline.txt` — initramfs-tools dropbear uses `ip=` directly, not `.network` files. Do NOT remove it for Pi.

### sd-tinyssh hook reads authorized keys from SD_TINYSSH_AUTHORIZED_KEYS

The `sd-tinyssh` mkinitcpio hook (from `mkinitcpio-systemd-extras`) reads authorized keys from `$SD_TINYSSH_AUTHORIZED_KEYS`, defaulting to `/root/.ssh/authorized_keys`. It does NOT read `/etc/tinyssh/root_key` unless explicitly configured.

**Fix:** Set in mkinitcpio.conf:
```
SD_TINYSSH_AUTHORIZED_KEYS=/etc/tinyssh/root_key
```

The playbook writes the SSH public key to `/etc/tinyssh/root_key` before running mkinitcpio. Without this variable, the hook looks for `/root/.ssh/authorized_keys` (which doesn't exist) and the initramfs has no authorized keys → all SSH connections are rejected.

### sshd port configurable via bootstrap_sshd_port

Set `bootstrap_sshd_port` in config.yml (default: 22). The value is written to `/etc/ssh/sshd_config.d/10-hardening.conf` as `Port {{ bootstrap_sshd_port }}`. Works for both Arch and Pi. Set to non-standard (e.g., 4455) to reduce scan noise — initramfs SSH runs on 22 during unlock.

### Shell must be in pacstrap package list

If `bootstrap_user_shell` is set to `zsh` (or any non-default shell), it must be included in the pacstrap packages list BEFORE `useradd`/`chpasswd` runs. Otherwise setting the shell fails because the binary doesn't exist in the chroot yet. Add to `bootstrap_pacstrap_packages`.

### Root mount opts must be filesystem-aware

Split root mount task into two with `when:` guards:
- btrfs: `opts: "{{ bootstrap_btrfs_opts }},subvol=@"` 
- ext4/xfs: `opts: defaults`
Never append `,subvol=@` for non-btrfs filesystems — mount fails.

## Commands

```bash
# ArchBoard bootstrap (workstation, NVMe in USB)
ansible-playbook bootstrap-arch.yml --ask-become-pass --ask-vault-pass

# Pi image builder
ansible-playbook bootstrap-pi.yml --ask-become-pass --ask-vault-pass

# Post-restore resize
ansible-playbook playbooks/post-bootstrap/resize.yml -e target_disk=/dev/nvme0n1 --ask-become-pass
```

## Vault

Secrets can be in `vault.yml` encrypted with Ansible Vault, or passed via `--extra-vars`. Convention: `vault.yml` defines `bootstrap_luks_password` and `bootstrap_user_password` directly (no indirection). Stub `vault.yml` is committed to the repo — users fill in values and encrypt. Root password is not managed — locked by default (sudo-based access).

## Config

Copy `config.yml.example` to `config.yml` and customize. Key settings:
- `bootstrap_target_disk` — target block device
- `bootstrap_partition_size_gb` — 0 for full disk, >0 for minimal image
- `bootstrap_filesystem` — btrfs, ext4, or xfs
- `bootstrap_hostname`, `bootstrap_user_name`, `bootstrap_ssh_public_key`
- `bootstrap_net_method` — dhcp or static
- `bootstrap_disable_swap` — true for k3s/docker
- `bootstrap_pi_model` — 3, 4, or 5 (Pi playbook only)

## Roles

- `roles/bootstrap-arch/` — Arch Linux bootstrap tasks
- `roles/bootstrap-pi/` — Raspberry Pi OS bootstrap tasks

## Post-Bootstrap

- `playbooks/post-bootstrap/resize.yml` — Expand partition/LUKS/filesystem after restoring minimal image
