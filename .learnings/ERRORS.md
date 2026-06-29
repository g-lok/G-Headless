# ERRORS — LUKS2 SSH Boot Playbook

## 1. pacstrap pulls host repos

**Symptom:** Package conflicts during pacstrap, host-specific repos being used.

**Root cause:** `pacstrap -K` uses host's `/etc/pacman.conf`. Non-Arch hosts may have custom repos that conflict with vanilla Arch packages.

**Fix:** Generate clean pacman.conf + mirrorlist with only core/extra and official Arch mirror URLs. Pass via `pacstrap -C /tmp/pacstrap-pacman.conf`.

**Files:** `roles/bootstrap-arch/tasks/bootstrap.yml`

---

## 2. Stale LUKS mapper from partial runs

**Symptom:** `Cannot use device /dev/mapper/root, name already exists` or filesystem I/O errors on re-run.

**Root cause:** Previous failed run left mapper in dmsetup. `cryptsetup close` failed because device still busy (lingering subvolume mount).

**Fix:** (1) Lazy-unmount `-R /mnt/{{ bootstrap_mount }}` before anything. (2) Iterate dmsetup, close any LUKS mapped to target disk, fall back to `dmsetup remove -f`. (3) Check if mapper name is still taken after close; append random suffix if so.

**Files:** `roles/bootstrap-arch/tasks/partition.yml`

---

## 3. arch-chroot tmpfs shadows /tmp

**Symptom:** File copied to `/mnt/tmp/` visible on host but `arch-chroot /mnt` can't find it (`could not find or read package`).

**Root cause:** `arch-chroot` mounts a tmpfs on `/tmp` inside the chroot, hiding files on the filesystem.

**Fix:** Use `pacman --root=/mnt` directly instead of `arch-chroot` for pacman operations. Or copy files to a path not shadowed (e.g., `/mnt/root/`).

**Files:** `roles/bootstrap-arch/tasks/bootstrap.yml`

---

## 4. vendored_pkg.files[0] is a dict, not an object

**Symptom:** `object of type 'dict' has no attribute 'version'`

**Root cause:** Ansible `find` module returns dicts, not objects. `.version` attribute access fails.

**Fix:** Use `basename` filter on `.path`, store via `set_fact`, reference the fact variable.

**Files:** `roles/bootstrap-arch/tasks/bootstrap.yml`

---

## 5. /etc/resolv.conf is a mount point inside chroot

**Symptom:** `ln: failed to create symbolic link '/etc/resolv.conf': Device or resource busy`

**Root cause:** arch-chroot copies host's resolv.conf as a real file or bind-mount. `ln -sf` can't overwrite a mount point.

**Fix:** `umount /etc/resolv.conf 2>/dev/null` before `rm -f` + `ln -sf`.

**Files:** `roles/bootstrap-arch/tasks/network.yml`

---

## 6. Shell pipes in ansible.builtin.command

**Symptom:** `ls: cannot access '|': No such file or directory`

**Root cause:** `ansible.builtin.command` doesn't invoke a shell — it execs the binary directly. Pipes/redirects/globs don't work.

**Fix:** Use `ansible.builtin.shell` for commands needing pipes, or use `argv` with explicit args.

---

## 7. arch-chroot glob expansion runs on host, not chroot

**Symptom:** `error: '/tmp/mkinitcpio-systemd-extras-*.pkg.tar.zst': could not find or read package`

**Root cause:** The host shell expands the glob before `arch-chroot` runs. File is in the chroot, not on host.

**Fix:** Wrap in `arch-chroot /mnt sh -c '...'` so glob expands inside chroot. Or use exact filename with `ansible.builtin.command` + `argv`.

---

## 8. LUKS password via shell piping mangles special characters

**Symptom:** `cryptsetup luksFormat` or `cryptsetup open` fails with "No key available with this passphrase" even though password is correct.

**Root cause:** `echo "{{ password }}" | cryptsetup` and `printf '%s\n' "{{ password }}" | cryptsetup` break when password contains shell metacharacters:
- `printf` interprets `%` as format specifiers (e.g., `%s`, `%d`)
- `echo` mangles backslash escapes (`\n`, `\t`)
- Double quotes allow `$` variable expansion

**Fix:** Write password to temp keyfile (`/tmp/luks-keyfile` with `mode: 0600`), pass via `--key-file=/tmp/luks-keyfile` using `ansible.builtin.command` with `argv` (no shell interpretation). Remove keyfile after use.

**Files:** `roles/bootstrap-arch/tasks/partition.yml`, `roles/bootstrap-pi/tasks/pi-prepare.yml`

---

## 6. jj rebase drops files not in commit's own diff

**Symptom:** After `jj rebase -r X -d root()`, the new root commit has only files that were modified in X's diff. All other repo files from X's parent are lost.

**Root cause:** `jj rebase` only carries the commit's own diff (what X changed vs its parent), not X's full tree. If X's parent has files, they're dropped when rebasing onto root (which has nothing).

**Fix:** Use `jj new root()` → `jj restore --from PARENT --into @ .` to copy full tree first, then apply modifications on top.

**Files:** This file — it happened here.
