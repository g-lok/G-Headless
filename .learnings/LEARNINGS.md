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

### LUKS password via ansible.builtin.shell stdin, not temp keyfile

`echo "{{ password }}" | cryptsetup` breaks on shell metacharacters. The old fix (temp keyfile via `ansible.builtin.copy`) works but adds complexity — write + cleanup tasks, `no_log` on all three.

**Better fix:** Use `ansible.builtin.shell` with `stdin:` parameter and `--key-file=-`. Ansible passes input directly, bypassing shell expansion. No temp file. One task instead of three.

```yaml
- name: LUKS2 format root partition
  ansible.builtin.shell:
    cmd: "cryptsetup luksFormat --type=luks2 --key-file=- '{{ bootstrap_luks_part }}'"
    stdin: "{{ bootstrap_luks_password }}"
  no_log: true
```

`--key-file=-` tells cryptsetup to read key from stdin. `stdin:` in `ansible.builtin.shell` avoids shell metacharacters the same way `argv` in `ansible.builtin.command` does — but allows pipes/redirects.

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

### chpasswd via stdin (simpler than temp file)

Same fix as LUKS: use `ansible.builtin.shell` with `stdin:` parameter. Replaces 3 tasks (write → chpasswd → cleanup) with 1.

```yaml
- name: Set user password via chpasswd
  ansible.builtin.shell:
    cmd: "arch-chroot /mnt/{{ bootstrap_mount }} chpasswd"
    stdin: "{{ bootstrap_user_name }}:{{ bootstrap_user_password }}"
  no_log: true
```

The old temp-file pattern (`copy` → `chroot chpasswd < /root/.pw_user` → `file: state=absent`) is now superseded.

### initramfs predictable naming needs udev rules in FILES

With `sd-network` hook, `.network` files use predictable names (`enp1s0`). But initramfs udev doesn't ship naming rules by default — all interfaces show as `eth0/eth1`. Match by `Name=enp1s0` fails → interface gets no config → no network in initramfs.

**Fix:** Add to mkinitcpio `FILES`:
- `/usr/lib/udev/rules.d/75-net-description.rules` — PCI vendor/device → interface name
- `/usr/lib/udev/rules.d/80-net-setup-link.rules` — apply naming policy
- `/usr/lib/systemd/network/99-default.link` — default link policy (needed by 80-*)

Only needed for `sd-network` initramfs. Pi (initramfs-tools/dropbear) uses `eth0` legacy naming — not affected.

### sd-network obviates ip= kernel parameter

`sd-network` hook in mkinitcpio handles networking entirely via `.network` files in the initramfs. The `ip=` kernel parameter is redundant (and confusing — it requires exact interface name with no glob support). Remove `ip=` when using `sd-network` + `sd-tinyssh`.

**Pi does NOT remove ip=:** Pi uses initramfs-tools + dropbear, which reads `ip=` from cmdline.txt directly. No `.network` file support.

### sshd port in hardening config

Added `bootstrap_sshd_port` variable (default 22) to both Arch and Pi defaults. Written to `/etc/ssh/sshd_config.d/10-hardening.conf` as `Port {{ bootstrap_sshd_port }}`. Useful when initramfs SSH and post-boot sshd both need port 22 during unlock, then post-boot moves to a non-standard port.

### Root password should not be set

Arch and Debian/RPi OS both default to locked root (no password). Don't set a root password — user logs in as themselves and `sudo -i` to become root. Locked root prevents console/SSH brute-force on the `root` account. Remove root password setup entirely from playbooks.

### Pi PBKDF memory must be capped

Workstation auto-benchmarks Argon2 to ~1GB. Pi initramfs has limited RAM — embedding 1GB memory cost in the LUKS header causes failures on Pi 3/4 and wastes RAM on Pi 5.

**Fix:** `--pbkdf-memory=512000 --pbkdf-parallel=1` in `cryptsetup luksFormat`.

### Pi 5 has hardware AES acceleration

Unlike Pi 3/4, Pi 5 has dedicated AES hardware. `aes-xts-plain64` runs at ~1800 MiB/s — same cipher as x86_64. No need for `xchacha20,aes-adiantum-plain64` fallback.
