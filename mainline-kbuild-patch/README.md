# Kbuild Silent Failure: How One Missing Exit Code Can Crash Your System

> **A mainline Linux kernel patch story** — from a real kernel panic on an NVMe system, traced through 3 days of silent failures, all the way to a patch submitted to the linux-kbuild mailing list.

---

## The Short Version

A kernel upgrade ran. Everything appeared successful. On the next reboot — kernel panic. The system was completely unbootable.

The root cause: a single line in the Linux kernel's own build script (`scripts/package/builddeb`) that unconditionally exits with code `0` — even when the post-installation hooks fail silently.

This is the story of finding that bug, tracing it to mainline, and submitting a fix upstream.

---

## Patch Status

```
[PATCH] kbuild: deb-pkg: propagate hook script failures in builddeb

Submitted to: linux-kbuild@vger.kernel.org
Maintainer:   Masahiro Yamada <masahiroy@kernel.org>
Reviewer:     Nathan Chancellor <nathan@kernel.org>
Status:       v3 — under review
Lore:         https://lore.kernel.org/linux-kbuild/?q=jillravaliya
Bug:          https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2141741
```

---

## Background — The Kernel Panic

**February 13, 2026 — Morning**

System powered on. Instead of the login screen:

```
KERNEL PANIC!
VFS: Unable to mount root fs on unknown-block(0,0)
```

This was the host machine. The one that was never experimented on directly.

### Decoding the Error

```
VFS: Unable to mount root fs on unknown-block(0,0)

VFS    = Virtual File System — kernel's abstraction over all storage
root fs = the very first filesystem the kernel mounts (/everything/)
(0,0)  = major:minor device number — (0,0) means NO DEVICE EXISTS AT ALL
```

The kernel didn't fail to read the disk. It couldn't see any disk at all. That distinction points directly at a missing driver — not corrupted data.

### Why NVMe Systems Are Affected

```
CONFIG_BLK_DEV_NVME=m   ← MODULE (not built into kernel)
CONFIG_ATA=y             ← BUILT IN (SATA always present)
```

`=m` means the NVMe driver lives as a separate `.ko` file inside the initramfs. Without initramfs, the NVMe driver never loads. Without the NVMe driver, the SSD is completely invisible.

```
NORMAL BOOT:
GRUB → loads kernel + initrd → NVMe driver loads from initrd
→ /dev/nvme0n1 appears → kernel mounts / → system starts

WHAT HAPPENED:
GRUB → loads kernel (no initrd — never created)
→ no NVMe driver → SSD invisible → unknown-block(0,0) → PANIC
```

SATA users would never notice this failure. The NVMe driver requires initramfs. SATA is built in.

---

## Three Days of Silent Failure

The panic didn't happen immediately after the broken kernel was installed. It happened **three days later** — because the failure was completely silent.

```
Feb 11 09:09  apt upgrade → kernel 6.17.0-14 installed
              initrd NEVER CREATED (silent failure)
              grub.cfg NOT updated (silent failure)

Feb 11-12     Reboots worked fine — GRUB still defaulted to old kernel

Feb 13 08:41  apt removed old kernel 6.14.0-36 (routine cleanup)
              postrm.d/zz-update-grub ran → grub.cfg regenerated
              6.17.0-14 = newest kernel → became default
              initrd for 6.17.0-14 = still missing

Feb 13        First reboot → KERNEL PANIC
```

Three days. Same failure. Zero user-visible output. The system never warned anything was wrong.

### Reading the Logs

```bash
# The 3-day pattern in dpkg log:
Feb 11 09:09:25  status half-configured  linux-image-6.17.0-14-generic
Feb 12 09:36:03  status half-configured  linux-image-6.17.0-14-generic
Feb 13 08:41:13  status half-configured  linux-image-6.17.0-14-generic

# What failed (from apt term.log):
* dkms: autoinstall for kernel 6.17.0-14-generic
   ...fail!
run-parts: /etc/kernel/postinst.d/dkms exited with return code 11

dpkg: error processing package linux-image-6.17.0-14-generic (--configure):
 installed post-installation script returned error exit status 11
```

---

## The Failure Chain

### System 1 — The Alphabetical Trap

```
/etc/kernel/postinst.d/ runs in ALPHABETICAL order via run-parts:

[d] dkms              → FAILED (exit 11)
                         VirtualBox DKMS couldn't compile
                         VBox/cdefs.h missing (DFSG compliance)

run-parts STOPS on first non-zero exit code

[i] initramfs-tools   → NEVER RAN  ← initrd never created
[zz] zz-update-grub   → NEVER RAN  ← grub.cfg never updated
```

### System 2 — The Silent Lie

While System 1 was stopped, `kernel-install` ran independently and reached the critical file:

```bash
# /usr/lib/kernel/install.d/55-initrd.install

if [ -e "$INITRD_SRC" ]; then
    ln -fs "$INITRD_SRC" "$KERNEL_INSTALL_STAGING_AREA"
else
    echo "$INITRD_SRC does not exist, not installing an initrd"
fi

exit 0   ← THE BUG — always returns success
         #  Whether initrd exists or not.
         #  GRUB creates a boot entry.
         #  System appears fully updated.
         #  User reboots into kernel panic.
```

Exit code 0 is a contract — "everything I was responsible for succeeded." This script broke that contract.

---

## Tracing to Mainline

The Ubuntu bug (#2141741) was filed and confirmed. But the investigation didn't stop there.

Nick Rosbrook (Ubuntu systemd maintainer) said:

> *"I really think the kernel packaging should handle all of this. If any of the run-parts scripts in /etc/kernel/postinst.d/ fail, the package installation should probably fail/stop."*

That was the signal to look upstream.

### The Mainline Bug

```bash
# scripts/package/builddeb
# In the Linux kernel source tree — torvalds/linux.git

install_maint_scripts () {
    for script in postinst postrm preinst prerm; do
        cat <<-EOF > "${pdir}/DEBIAN/${script}"
        ...
        hookdirs="\${hookdirs# }"
        test -n "\$hookdirs" && run-parts --arg="${KERNELRELEASE}" \
            --arg="/${installed_image_path}" \$hookdirs
        exit 0        ← SAME BUG IN MAINLINE
        EOF
    done
}
```

The kernel's own packaging script generates the `postinst` installer that runs on user machines. It calls `run-parts` to execute the hook scripts — but never checks if they succeed. It always exits with code 0.

This means:
- DKMS fails → `run-parts` returns non-zero → ignored → `exit 0`
- initramfs never generated → no warning → GRUB creates broken boot entry
- User reboots → kernel panic

The same silent failure, in the mainline kernel source, affecting every Debian-based distribution that builds kernels from source.

---

## The Patch

### What Changed

```diff
--- a/scripts/package/builddeb
+++ b/scripts/package/builddeb
@@ -98,7 +98,12 @@ install_maint_scripts () {
        hookdirs="\$hookdirs \$dir/${script}.d"
        done
        hookdirs="\${hookdirs# }"
-       test -n "\$hookdirs" && run-parts --arg="${KERNELRELEASE}" \
-           --arg="/${installed_image_path}" \$hookdirs
+       if [ -n "\$hookdirs" ]; then
+           if ! run-parts --arg="${KERNELRELEASE}" \
+               --arg="/${installed_image_path}" \$hookdirs; then
+               echo "E: Post-install hooks failed." >&2
+               exit 1
+           fi
+       fi
        exit 0
        EOF
```

### Why This Fix

**Before:** `run-parts` runs all hooks. If any fail, the exit code is silently discarded. The installer returns 0 regardless.

**After:** If `run-parts` returns non-zero, the installer prints a clear error and exits 1. `dpkg` marks the package as `half-configured`. `apt` reports the failure. The user is warned before rebooting.

### What This Prevents

```
With the fix:

DKMS fails → run-parts exits non-zero
→ postinst exits 1
→ dpkg: "package half-configured"
→ apt shows error to user
→ GRUB does NOT create boot entry for broken kernel
→ User cannot accidentally reboot into panic
→ User fixes DKMS issue → re-runs configuration → boots normally
```

---

## The Review Process

### v1 — April 22, 2026

First submission. Sent via Gmail web interface instead of `git send-email`. Malformed — could not be applied to the tree.

**Nathan Chancellor (ClangBuiltLinux maintainer):**
> *"Unfortunately, this patch is malformed so it cannot be applied. The premise seems reasonable and I would be happy to test it properly once it can be correctly applied."*

### v2 — April 30, 2026

Resent via `git send-email` with correct SMTP configuration. Properly formatted and arrived on lore.kernel.org.

**Nathan Chancellor:**
> *"Thanks for the quick v2! A few issues to address:*
> *1. Signed-off-by name formatting*
> *2. Variable escaping in run-parts invocation*
> *3. Indentation should use tabs, not spaces"*

### v3 — May 1, 2026

All three issues addressed:
- `Signed-off-by: Jill Ravaliya` — proper name formatting
- `${KERNELRELEASE}` without backslash — expands at script generation time
- Tab indentation throughout — consistent with surrounding code

**Current status: Under review by Masahiro Yamada and Nathan Chancellor**

---

## The Complete Picture

```
Ubuntu ships VirtualBox with DFSG compliance
  VBox/cdefs.h removed → DKMS cannot compile
    ↓
apt upgrade installs kernel 6.17.0-14
    ↓
run-parts starts /etc/kernel/postinst.d/ alphabetically:
  [d] dkms → exit 11 → STOPS
  [i] initramfs-tools → NEVER RAN → initrd never created
  [zz] zz-update-grub → NEVER RAN
    ↓
kernel-install runs independently:
  55-initrd.install detects missing initrd → exit 0 (THE LIE)
    ↓
3 days pass. Everything seems normal.
    ↓
Feb 13: old kernel removed → grub.cfg regenerated
  → 6.17.0-14 becomes default → points to missing initrd
    ↓
Reboot → no NVMe driver → SSD invisible
  → VFS: Unable to mount root fs on unknown-block(0,0)
    ↓
KERNEL PANIC
    ↓
Investigation → 3 days of logs → root cause found
    ↓
Ubuntu Bug #2141741 filed → confirmed within 2 hours
    ↓
Traced to mainline: scripts/package/builddeb
    ↓
Patch submitted to linux-kbuild@vger.kernel.org
Nathan Chancellor: "premise seems reasonable"
v3 under review
```

---

## Key Concepts

| Term | Meaning |
|------|---------|
| `initramfs` | Compressed archive GRUB loads into RAM — contains drivers needed before disk is visible |
| `CONFIG_BLK_DEV_NVME=m` | NVMe driver is a module — must come from initramfs |
| `run-parts` | Runs all scripts in a directory — stops on first failure |
| `exit 0` | Contract meaning "success" — breaking it causes silent failures downstream |
| `half-configured` | dpkg state meaning configuration started but failed |
| `recordfail` | GRUB mechanism that shows menu after failed boot |
| `Kbuild` | Linux kernel build system — `scripts/package/builddeb` lives here |

---

## Related

- **Ubuntu Bug #2141741** — `55-initrd.install` silently exits 0 when initrd missing
  https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2141741

- **Ubuntu Bug #2136499** — VirtualBox DKMS fails to build for Linux 6.17 (trigger, fixed March 2026)
  https://bugs.launchpad.net/ubuntu/+source/virtualbox/+bug/2136499

- **Patch on lore.kernel.org**
  https://lore.kernel.org/linux-kbuild/?q=jillravaliya

- **Original investigation writeup**
  https://github.com/jillravaliya/kernel-panic-study

---

## Author

**Jill Ravaliya**

Systems programming and Linux kernel development.

- Email: jillravaliya@gmail.com
- GitHub: [github.com/jillravaliya](https://github.com/jillravaliya)
- LinkedIn: [linkedin.com/in/jill-ravaliya-684a98264](https://linkedin.com/in/jill-ravaliya-684a98264)
- Patch: [lore.kernel.org/linux-kbuild](https://lore.kernel.org/linux-kbuild/?q=jillravaliya)

---

> *One exit code. Three days of silence. One kernel panic. The system never warned me — so I traced every log until it did. Then I sent a patch.*
