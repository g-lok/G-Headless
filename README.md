# LUKS2 SSH Boot Playbook

Bootstrap full-disk-encrypted Linux systems with initramfs SSH unlock for headless remote access.

## Overview

This project provides Ansible playbooks to create LUKS-encrypted Linux installations with SSH-based unlock in the initramfs. Perfect for headless servers, NAS boxes, and remote systems where physical access isn't available for entering disk encryption passwords.

The bootstrap process runs on any x86_64 Linux workstation with the target drive connected via USB enclosure. The resulting disk can be installed in any x86_64 UEFI system.

**Features:**

- LUKS2 encryption with Argon2id key derivation
- **Isolated Mounts**: Uses temporary fstab to prevent workstation pollution
- **Reliable Cleanup**: Hardened mapper closure with device-path matching
- Multiple filesystem support: btrfs, ext4, xfs
- Initramfs SSH unlock (tinyssh for Arch, dropbear for Debian)
- Static or DHCP networking in initramfs
- Optional minimal disk imaging for deployment
- Post-restore expansion playbooks
- Swap disabled by default (k3s/docker compatible)

**Supported platforms:**

- **x86_64 systems** (ZimaBoard 2, NUCs, mini PCs, etc.): Arch Linux with systemd-boot UKI
- **Raspberry Pi 3/4/5**: Raspberry Pi OS Lite with extlinux

## Requirements

### Host system (workstation)

- Any x86_64 Linux (Arch, Debian/Ubuntu, Fedora, etc.)
- Python 3.10+
- Ansible 2.15+
- Required packages:
  - `arch-install-scripts` (pacstrap, genfstab, arch-chroot)
  - `cryptsetup`
  - `gdisk` (sgdisk)
  - `btrfs-progs` (for btrfs)
  - `qemu-user-static` + `binfmt-support` (Pi only)

### Target drive

- **x86_64**: Any SATA, NVMe drive, external HDD/SDD
- **Raspberry Pi**: microSD card or USB SSD

The resulting disk will boot on any x86_64 UEFI system (not limited to the workstation used for bootstrap).

## Quick Start

### 1. Clone and configure

```bash
git clone <this-repo>
cd LUKS2_SSH_BOOT_playbook

# Copy example config
cp config.yml.example config.yml

# Edit config.yml with your settings:
# - target_disk (find with: lsblk)
# - hostname, timezone, locale
# - network configuration (DHCP or static)
# - user name, shell, SSH public key
# - filesystem choice (btrfs/ext4/xfs)
```

### 2. Prepare secrets

All sensitive variables are consolidated in `vault.yml`. Edit this file with your values, then encrypt it:

```bash
# Edit vault.yml with your passwords and SSH key
vim vault.yml

# Encrypt it
ansible-vault encrypt vault.yml
```

**Required variables in `vault.yml`:**
- `bootstrap_luks_password`: Password for disk encryption
- `bootstrap_user_password`: Password for the default user
- `bootstrap_ssh_public_key`: Your public SSH key for both initramfs and post-boot access

### 3. Run bootstrap

```bash
# x86_64 systems (Arch Linux)
ansible-playbook bootstrap-arch.yml --ask-become-pass --ask-vault-pass

# Or with extra-vars (no vault file needed)
ansible-playbook bootstrap-arch.yml --ask-become-pass \
  -e bootstrap_luks_password=xxx \
  -e bootstrap_user_password=xxx

# Raspberry Pi 3/4/5
# Set bootstrap_pi_model in config.yml (3, 4, or 5)
ansible-playbook bootstrap-pi.yml --ask-become-pass --ask-vault-pass
```

### 4. Deploy and boot

**x86_64 systems:**

1. Disconnect drive from workstation
2. Install in target system (ZimaBoard, NUC, mini PC, etc.)
3. Connect power + Ethernet
4. SSH to initramfs: `ssh root@<IP>`
5. Enter LUKS passphrase when prompted
6. System boots, SSH as your user

**Raspberry Pi:**

1. Write image to SD/SSD: `dd if=files/pi-luks.img of=/dev/sdX bs=4M status=progress`
2. Insert in Pi, connect power + Ethernet
3. SSH to initramfs: `ssh root@<IP>`
4. Run `cryptroot-unlock`
5. System boots, SSH as your user

## Configuration

See `config.yml.example` for all available options. Key settings:

### Disk and partitioning

```yaml
bootstrap_target_disk: /dev/sdb
bootstrap_partition_size_gb: 0 # 0 = full disk, >0 = minimal for imaging
bootstrap_create_image: true
bootstrap_image_path: "{{ playbook_dir }}/files/bootstrap-image.img"
```

### Filesystem

```yaml
bootstrap_filesystem: btrfs # btrfs, ext4, or xfs
bootstrap_fs_label: rootfs

# btrfs options
bootstrap_btrfs_opts: "compress=zstd,noatime,ssd"
bootstrap_btrfs_subvolumes:
  - { path: /, name: "@" }
  - { path: /home, name: "@home" }
  - { path: /.snapshots, name: "@snapshots" }
  - { path: /var/log, name: "@var_log" }
  - { path: /var/cache, name: "@var_cache" }

# Container workloads (k3s/docker)
bootstrap_container_subvolumes: false
```

### Network

```yaml
bootstrap_net_method: dhcp # or static
bootstrap_net_address: "192.168.1.100/24" # static only
bootstrap_net_gateway: "192.168.1.1" # static only
bootstrap_net_iface: "en*" # x86_64; Pi uses eth0
```

### User

```yaml
bootstrap_user_name: admin
bootstrap_user_shell: /bin/bash
bootstrap_user_groups: [wheel] # or [sudo] for Debian
bootstrap_ssh_public_key: "ssh-ed25519 AAAA... your-key"
```

### Swap

```yaml
bootstrap_disable_swap: false # true for k3s/docker
```

### Pi Model (Raspberry Pi only)

```yaml
bootstrap_pi_model: 5 # 3, 4, or 5
```

This determines the correct initramfs name and kernel modules for your Pi model:

- Pi 3: Uses `initramfs_2710` with ARMv8 crypto modules
- Pi 4: Uses `initramfs_2711` with ARMv8 CE crypto modules
- Pi 5: Uses `initramfs_2712` with ARMv8 CE crypto modules (has hardware AES — no performance penalty)

> **Pi PBKDF memory note:** Cryptsetup auto-benchmarks Argon2 memory to ~1GB on the workstation. Pi initramfs has limited RAM and cannot allocate this much. The playbook caps PBKDF memory at 512MB. Do NOT override `--pbkdf-memory` unless you know what you're doing.

## Post-Bootstrap Tasks

### Resize after restoring minimal image

If you created a minimal image (`bootstrap_partition_size_gb > 0`) and restored it to a larger disk:

```bash
ansible-playbook playbooks/post-bootstrap/resize.yml \
  -e target_disk=/dev/nvme0n1 \
  --ask-become-pass
```

This expands the partition, LUKS container, and filesystem to fill the disk.

### btrfs snapshots (x86_64 only)

```bash
# Create snapshot before updates
sudo btrfs subvolume snapshot -r / /.snapshots/pre-update-$(date +%Y%m%d)

# Rollback if needed
sudo btrfs subvolume set-default <subvolid> /
sudo reboot
```

## Architecture

```
bootstrap-arch.yml (or bootstrap-pi.yml)
├── Phase 1: partition
│   ├── Cleanup stale mounts/LUKS from previous runs
│   ├── sgdisk (GPT: 1G EFI + rest for LUKS)
│   ├── cryptsetup luksFormat (LUKS2 + Argon2id)
│   ├── Create filesystem (btrfs/ext4/xfs)
│   └── Mount subvolumes (btrfs only)
│
├── Phase 2: bootstrap
│   ├── pacstrap / rsync base system
│   ├── Generate fstab
│   ├── Configure timezone, locale, hostname
│   ├── Create user + SSH keys
│   ├── Configure mkinitcpio + tinyssh/dropbear
│   ├── Configure initramfs networking
│   ├── Build UKI (x86_64) or update-initramfs (Pi)
│   └── Install bootloader
│
├── Phase 3: network
│   ├── Enable systemd-networkd + systemd-resolved
│   ├── Enable sshd + avahi-daemon
│   └── Configure mDNS (.local resolution)
│
└── Phase 4: cleanup
    ├── Unmount all filesystems
    ├── Close LUKS
    ├── Remove temp files
    └── Create disk image (if partition_size_gb > 0)
```

## Security Considerations

- **LUKS password**: Use a strong passphrase (20+ characters recommended)
- **SSH keys**: Only ed25519 keys are supported in initramfs
- **Initramfs SSH**: Uses separate keys from the main system
- **Swap**: Disabled by default to prevent password leakage
- **btrfs discard**: Enabled for SSD performance (minor security tradeoff)

## Troubleshooting

### LUKS password not working

- Verify vault.yml or extra-vars are correct
- Check `/tmp/luks-keyfile` content (if still present)
- Test manually: `cryptsetup --test-passphrase luksOpen /dev/sdX2`

### Boot hangs at initramfs

- Check initramfs networking config matches your network
- Verify SSH key is in `/etc/tinyssh/root_key` (x86_64) or `/etc/dropbear/initramfs/authorized_keys` (Pi)
- Check kernel cmdline has correct LUKS UUID

### Can't SSH to initramfs

- Verify IP address and network connectivity
- Check firewall isn't blocking port 22
- Try different SSH client (some don't support ed25519 in older versions)

## Development

This project was developed for personal use and migrated to a public-facing format. The original development version is integrated into the `gloco-ansible` project for multi-host provisioning.

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions welcome! Please open an issue or PR.

## Credits

Based on battle-tested guides and configurations from:

- Arch Wiki: dm-crypt, systemd-boot, mkinitcpio
- Raspberry Pi documentation
- K3s documentation (swap requirements)
- Community best practices for headless LUKS setups
