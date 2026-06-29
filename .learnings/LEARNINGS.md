# LEARNINGS — LUKS2 SSH Boot Playbook

## category: correction

### pacstrap inherits host pacman config

`pacstrap` uses the host's `/etc/pacman.conf` by default. On non-Arch hosts (Debian, Ubuntu, Fedora), this may include custom repos. Always pass `-C` with a clean config when running on non-Arch hosts.

### arch-chroot shadows /tmp with tmpfs

`arch-chroot` mounts a tmpfs on `/tmp` inside the chroot. Any files placed in `/mnt/tmp/` before invoking `arch-chroot` are invisible to commands inside the chroot. Use `pacman --root=/mnt` for package operations, or copy to a path not shadowed (e.g., `/mnt/root/`).

### /etc/resolv.conf is bind-mounted in chroot

`arch-chroot` copies the host's `/etc/resolv.conf` into the chroot as a regular file or bind mount. Cannot `ln -sf` over it. Must `umount` first.

## category: best_practice

### ansible.builtin.command vs ansible.builtin.shell

- `ansible.builtin.command` — no shell expansion. Use with `argv` for safe arg passing. Pipes/redirects fail.
- `ansible.builtin.shell` — shell expansion, pipes, globs. Use when you need shell features.
- `arch-chroot /mnt sh -c '...'` — globs expand INSIDE the chroot.

### Ansible find returns dicts

`ansible.builtin.find` returns `files[0].path` as a dict key — no `.version` or other object-style access. Use `basename`, `dirname`, `regex_replace` filters.

### Clean EFI partition between runs

Always `rm -rf /mnt/boot/*` before pacstrap. Partial previous runs leave files on the vfat partition that cause file conflicts.

### Force-close stale LUKS mappings

`cryptsetup close` may fail if device is busy. Fall back to `dmsetup remove -f`. Always lazy-unmount before closing.

### Unique /mnt subdirectory per playbook

Never mount directly under `/mnt`. Each playbook owns a unique subdirectory (`/mnt/{{ bootstrap_mount }}`). Prevents cross-contamination when running multiple playbooks and avoids clobbering host mounts. Set via `bootstrap_mount` variable — override per playbook with `set_fact`.

### Cleanup must be aggressive

`umount -R` fails on busy mounts. Always `umount -l -R`. LUKS close can also fail — iterate `dmsetup ls`, match to target disk, try `cryptsetup close`, fall back to `dmsetup remove -f`. Remove mount directory after unmount.

### LUKS password via keyfile, not shell piping

`echo "{{ password }}" | cryptsetup` and `printf '%s\n' "{{ password }}" | cryptsetup` break if password contains shell metacharacters (`$`, `\`, `%`, `"`, etc). `printf` interprets `%` as format specifiers. `echo` mangles backslash escapes.

**Fix:** Write password to temp keyfile (`/tmp/luks-keyfile` with `mode: 0600`), pass via `--key-file=/tmp/luks-keyfile` using `ansible.builtin.command` with `argv` (no shell). Remove keyfile after use.

### noswap is not a valid kernel parameter

`noswap` does nothing. Swap control is via systemd (`systemctl mask swap.target`) and fstab. Don't create swap partitions/files in the first place.

### k3s swap strategy

k3s doesn't explicitly require swap disabled, but kubelet defaults to `failSwapOn: true`. Strategy:
1. Don't create swap (no swap partition, no swapfile)
2. `swapoff -a` — turn off any active swap
3. `systemctl mask swap.target` — prevent systemd activation
4. Remove swap entries from fstab
5. Pi: disable `dphys-swapfile` (RPi OS default swap manager)

Kubernetes 1.30+ supports swap via `NodeSwap` feature gate, but k3s still defaults to requiring no swap.

### btrfs subvolumes for container workloads

For k3s/docker/containerd, separate subvolumes keep container data out of root snapshots:
- `@var_lib_docker` → `/var/lib/docker`
- `@var_lib_containerd` → `/var/lib/containerd`
- `@var_lib_rancher` → `/var/lib/rancher` (k3s data)

Snapshotting `@` before updates stays lean — container images/layers aren't included.

### pi role needs resize.yml

Pi role was missing post-restore expansion. Added `tasks/resize.yml` matching arch pattern: expand partition → expand LUKS → `resize2fs` (ext4). Set `pi_resize_root: false` in defaults, enable per-host.

### Pi model support (3/4/5)

The Pi playbook now supports Pi 3, 4, and 5. Set `bootstrap_pi_model` in config.yml (3, 4, or 5). This determines:
- Initramfs name: `initramfs_2710` (Pi 3), `initramfs_2711` (Pi 4), `initramfs_2712` (Pi 5)
- Kernel modules: Pi 3 uses ARMv8 crypto (`aes_arm_bs`, `sha256_arm`), Pi 4/5 use ARMv8 CE crypto (`aes_ce_blk`, `sha2_ce`)

## category: knowledge_gap

### mkinitcpio -k flag in v41+

In mkinitcpio v41+, the `-k` flag in presets specifies the kernel image PATH. Missing vmlinuz file causes `must be readable` error. `pacman -S --noconfirm linux` reinstall fixes it.

### systemd-resolved creates /etc/resolv.conf

systemd package post-install creates `/etc/resolv.conf` in the chroot. It may be a regular file, symlink, or mount point depending on config.

### btrfs rootflags must include subvol=@ in kernel cmdline

Without `subvol=@` in `rootflags`, systemd in initramfs mounts btrfs top-level (shows empty subvolume dirs like `@`, `@home`). No init found → `switch_root` fails → emergency loop. Fix: `rootflags=subvol=@,x-systemd.device-timeout=0`. Only needed for btrfs — ext4/xfs don't use subvol.

### btrfs subvol=@ must not appear in ext4/xfs mount opts

`partition.yml` had `opts: "{{ bootstrap_btrfs_opts if ... else 'defaults' }},subvol=@"` — always appended `subvol=@` even for ext4/xfs. That option is invalid for non-btrfs filesystems. **Fix:** Split into two mount tasks with `when:` guards — btrfs uses `subvol=@`, ext4/xfs use `defaults`.

Similarly `bootstrap.yml` had unconditional `MODULES=(igc btrfs)` — `btrfs` module is pointless for ext4/xfs. Made conditional with Jinja.

### Stale mapper cleanup: match ^root not ^root-

The host has no `root` LUKS mapper — all `root*` mappers on the host belong to the playbook's target disk. Grep pattern should match `^{{ luks_mapper_name }}` (catches `root` and `root-*`) not `^{{ luks_mapper_name }}-` (misses `root`). This applies when using a unique per-playbook mapper name prefix like `root`.
