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

### LUKS password via keyfile, not shell piping

`echo "{{ password }}" | cryptsetup` and `printf '%s\n' "{{ password }}" | cryptsetup` break if password contains shell metacharacters (`$`, `\`, `%`, `"`, etc). `printf` interprets `%` as format specifiers. `echo` mangles backslash escapes.

**Pattern:** Write password to temp keyfile (`/tmp/luks-keyfile` with `mode: 0600`), pass via `--key-file=/tmp/luks-keyfile` using `ansible.builtin.command` with `argv` (no shell). Remove keyfile after use.

```yaml
- name: Write LUKS password to temp keyfile
  ansible.builtin.copy:
    content: "{{ bootstrap_luks_password }}"
    dest: /tmp/luks-keyfile
    mode: '0600'
  no_log: true

- name: LUKS2 format root partition
  ansible.builtin.command:
    argv:
      - cryptsetup
      - luksFormat
      - --type=luks2
      - --key-file=/tmp/luks-keyfile
      - "{{ bootstrap_luks_part }}"
```

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

Secrets can be in `vault.yml` encrypted with Ansible Vault, or passed via `--extra-vars`. Variables: `bootstrap_luks_password`, `bootstrap_root_password`, `bootstrap_user_password`.

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
