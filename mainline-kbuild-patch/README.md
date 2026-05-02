# kbuild: deb-pkg — Silent Hook Failures and the Missing Exit Code

> A deep investigation into how the Linux kernel packages itself for Debian-based systems, why a single missing error check can silently produce an unbootable system, and the mainline patch that fixes it.

---

### During that investigation, a question emerged

> The Ubuntu-specific script `55-initrd.install` exits 0 when initrd is missing. But what about the upstream source? Does the mainline Linux kernel have the same gap?

This repository answers that question. The answer is yes — and the fix is a patch to `scripts/package/builddeb` in the mainline kernel tree.

---

## Understanding Kbuild First

Before the patch makes sense, Kbuild needs to make sense.

### What Kbuild Is

Kbuild is the Linux kernel's build system — the collection of Makefiles, shell scripts, and tools that turn 30 million lines of C source code into a bootable kernel image. It lives inside the kernel source tree itself.

```
linux/
├── Makefile          ← top-level orchestrator
├── scripts/
│   ├── Makefile.build
│   ├── checkpatch.pl
│   └── package/
│       ├── builddeb  ← THIS FILE
│       ├── buildrpm
│       └── ...
├── arch/
├── mm/
├── drivers/
└── ...
```

When a developer wants to distribute a kernel as a Debian package — the format Ubuntu, Debian, Kali, Raspberry Pi OS, and hundreds of other distributions use — they run:

```bash
make deb-pkg
```

Kbuild handles everything: compiling the kernel, packaging the modules, and generating the installer scripts that will run on the user's machine when they install the `.deb` file.

### What `scripts/package/builddeb` Does

`builddeb` is the shell script Kbuild uses to build that `.deb` package. It does several things:

```
builddeb responsibilities:

1. Compile and collect the kernel binary (vmlinuz)
2. Install kernel modules into the package directory
3. Copy System.map and .config into /boot
4. Generate maintainer scripts (postinst, postrm, preinst, prerm)
5. Set correct permissions
6. Assemble the final .deb package
```

Step 4 is where the bug lives.

### What Maintainer Scripts Are

When you install any `.deb` package on Ubuntu or Debian, the package contains four special shell scripts:

```
package.deb
└── DEBIAN/
    ├── postinst   ← runs AFTER installation
    ├── postrm     ← runs AFTER removal
    ├── preinst    ← runs BEFORE installation
    └── prerm      ← runs BEFORE removal
```

These scripts handle everything the file copy itself cannot — registering the kernel with the bootloader, building the initramfs, updating GRUB, and running any distribution-specific setup.

For kernel packages specifically, the `postinst` script is the most critical. It is responsible for:

```
postinst responsibilities after kernel install:

1. Tell initramfs-tools to build the initrd for this kernel
2. Tell GRUB to add a boot entry for this kernel
3. Run any other distribution hooks in /etc/kernel/postinst.d/
```

If postinst fails silently, the user has a kernel installed with no initrd and no GRUB entry — or worse, a GRUB entry that points to a missing initrd.

---

## How `builddeb` Generates `postinst`

Here is the actual mechanism. Inside `builddeb`, there is a function called `install_maint_scripts`. It uses a heredoc — a shell construct that writes a script file inline — to generate the `postinst` script that will later run on the user's machine:

```bash
install_maint_scripts () {
    debhookdir=${KDEB_HOOKDIR:-/etc/kernel /usr/share/kernel}
    for script in postinst postrm preinst prerm; do
        mkdir -p "${pdir}/DEBIAN"
        cat <<-EOF > "${pdir}/DEBIAN/${script}"
        #!/bin/sh

        set -e

        # Pass maintainer script parameters to hook scripts
        export DEB_MAINT_PARAMS="\$*"

        # Tell initramfs builder whether it's wanted
        export INITRD=$(if_enabled_echo CONFIG_BLK_DEV_INITRD Yes No)

        # run-parts will error out if one of its directory arguments does not
        # exist, so filter the list of hook directories accordingly.
        hookdirs=
        for dir in ${debhookdir}; do
            test -d "\$dir/${script}.d" || continue
            hookdirs="\$hookdirs \$dir/${script}.d"
        done
        hookdirs="\${hookdirs# }"
        test -n "\$hookdirs" && run-parts --arg="${KERNELRELEASE}" \
            --arg="/${installed_image_path}" \$hookdirs
        exit 0
        EOF
        chmod 755 "${pdir}/DEBIAN/${script}"
    done
}
```

Reading this carefully, several things are happening at once:

**The heredoc (`cat <<-EOF`)** writes a shell script into the file `DEBIAN/postinst`. Everything between `EOF` markers becomes the content of that generated script.

**Variable expansion** happens in two phases. Variables like `${KERNELRELEASE}` and `${installed_image_path}` expand *now*, at package build time — they get their values baked into the generated script. Variables prefixed with `\$` like `\$hookdirs` expand *later*, when the generated script actually runs on the user's machine.

**`run-parts`** is the command that runs all hook scripts in the given directories — things like `initramfs-tools`, `update-grub`, and any DKMS modules. On Ubuntu, these live in `/etc/kernel/postinst.d/`. Each one handles a specific part of the kernel installation.

**The problem:** After calling `run-parts`, the generated script reaches `exit 0`. Always. Unconditionally. No matter what `run-parts` returned.

---

## The Design Gap

### What `run-parts` Actually Returns

`run-parts` runs every executable file in a directory, in order. If any of those scripts exits with a non-zero code, `run-parts` itself returns non-zero.

This is the mechanism the system has for communicating failure. A hook script that fails returns 1. `run-parts` propagates that to 1. The caller of `run-parts` is supposed to check that return code and decide what to do.

The generated `postinst` does not check it.

```bash
# What the generated postinst currently does:
test -n "$hookdirs" && run-parts --arg="..." $hookdirs
exit 0   ← ignores whatever run-parts returned
```

This is equivalent to:

```bash
# In any other language:
result = run_hooks()
return SUCCESS   # regardless of result
```

### Why This Is a Kbuild Problem, Not Just an Ubuntu Problem

The Ubuntu-specific script `55-initrd.install` also exits 0 when initrd is missing. That was filed as Ubuntu Bug #2141741. During that discussion, Nick Rosbrook (Ubuntu systemd maintainer) pushed back on fixing it there — his reasoning was that an initrd is not strictly required in all environments where `kernel-install` is used, so a blanket `exit 1` from `55-initrd.install` could break embedded or container setups that legitimately have no initrd.

His pushback was technically valid — but it also pointed directly at where the real fix belongs:

> *"I really think the kernel packaging should handle all of this. If any of the run-parts scripts in /etc/kernel/postinst.d/ fail, the package installation should probably fail/stop."*

He is describing `scripts/package/builddeb`. The generated `postinst` — written by the mainline kernel's own Kbuild system — is where the exit code from `run-parts` should be checked. If it is not checked here, then no matter how individual hook scripts behave, the installation can always complete with a broken result. Nick's pushback on the Ubuntu layer became the justification for fixing the mainline layer.

### The Consequence on NVMe Systems

This matters most on systems where the storage driver is compiled as a module (`=m`) rather than built into the kernel (`=y`).

```
CONFIG_BLK_DEV_NVME=m   ← driver must come from initramfs
CONFIG_ATA=y             ← SATA driver is always present
```

If initramfs is never built (because the initramfs-tools hook failed and its exit code was ignored), the NVMe driver never loads. The kernel sees no storage device at all.

```
kernel reads /etc/fstab:
  "mount UUID=... as /"

scans all block devices for that UUID:
  zero block devices found (no NVMe driver = no /dev/nvme*)

VFS: Unable to mount root fs on unknown-block(0,0)
KERNEL PANIC
```

SATA systems are unaffected — their driver is always present. The same silent failure produces completely different results depending on storage hardware. This is why the bug can go undetected: most developers testing kernel packaging use SATA systems.

---

## The Fix

### What Needs to Change

The generated `postinst` script needs to propagate the exit code from `run-parts`. If a hook script fails, the installation should fail visibly — not silently succeed.

### The Original Code

```bash
hookdirs="\${hookdirs# }"
test -n "\$hookdirs" && run-parts --arg="${KERNELRELEASE}" \
    --arg="/${installed_image_path}" \$hookdirs
exit 0
```

**What this does:**
- If `hookdirs` is non-empty, run `run-parts` with the hook directories
- The `&&` means: only run `run-parts` if there are directories to process
- Then unconditionally exit 0 — regardless of whether `run-parts` succeeded

The `&&` operator returns the exit code of the last command it runs. But that exit code is immediately discarded by `exit 0` on the next line.

### The Fixed Code

```bash
hookdirs="\${hookdirs# }"
if [ -n "\$hookdirs" ]; then
    if ! run-parts --arg="${KERNELRELEASE}" \
        --arg="/${installed_image_path}" \$hookdirs; then
        echo "E: Post-install hooks failed." >&2
        exit 1
    fi
fi
exit 0
```

**What this does differently:**

The `if [ -n "$hookdirs" ]` check replaces the `test -n ... &&` pattern. Functionally equivalent, but now the result of the inner command matters.

The `if ! run-parts ...` construct runs `run-parts` and negates its exit code for the condition. If `run-parts` returns non-zero (failure), the `!` makes that condition true, and the error branch executes.

The error branch prints a message to stderr (`>&2` ensures it goes to the error stream, not stdout) and exits 1.

The final `exit 0` is only reached when `run-parts` succeeded — or when there were no hook directories to run. It is no longer unconditional.

### Variable Escaping — Why It Matters

Inside the heredoc, variable escaping determines *when* a variable gets its value:

```bash
# Expands NOW at package build time (correct):
run-parts --arg="${KERNELRELEASE}" --arg="/${installed_image_path}"

# Would expand LATER when script runs (incorrect):
run-parts --arg="\${KERNELRELEASE}" --arg="/\${installed_image_path}"
```

`KERNELRELEASE` and `installed_image_path` are known at build time — they are the kernel version and install path for *this specific kernel*. They must be baked into the generated script, not left as variables to resolve at install time (where they would be undefined).

`$hookdirs` uses `\$` because it *should* expand at runtime — it is computed dynamically when the generated script runs on the user's machine.

Getting this distinction wrong produces a script that either fails immediately (undefined variable) or passes wrong arguments to `run-parts`.

### Indentation — Why Tabs

The `builddeb` script uses tabs for indentation throughout. Shell scripts inside heredocs inherit this convention. Using spaces breaks the visual consistency and, in some heredoc configurations, can cause parsing issues.

This is enforced by `checkpatch.pl` — the kernel's style checker — which warns on mixed indentation.

---

## The Patch

```diff
--- a/scripts/package/builddeb
+++ b/scripts/package/builddeb
@@ -98,7 +98,12 @@ install_maint_scripts () {
 		hookdirs="\$hookdirs \$dir/${script}.d"
 		done
 		hookdirs="\${hookdirs# }"
-		test -n "\$hookdirs" && run-parts --arg="${KERNELRELEASE}" --arg="/${installed_image_path}" \$hookdirs
+		if [ -n "\$hookdirs" ]; then
+			if ! run-parts --arg="${KERNELRELEASE}" --arg="/${installed_image_path}" \$hookdirs; then
+				echo "E: Post-install hooks failed." >&2
+				exit 1
+			fi
+		fi
 		exit 0
 		EOF
 		chmod 755 "${pdir}/DEBIAN/${script}"
```

**6 lines added. 1 line removed.**

The change is structurally minimal. It does not alter what gets run. It does not change which hooks are called or in what order. It only changes what happens when those hooks fail — from silent discard to visible failure.

---

## Before and After — What the Generated Script Looks Like

### Before (what postinst looks like currently)

```bash
#!/bin/sh
set -e

export DEB_MAINT_PARAMS="$*"
export INITRD=Yes

hookdirs=
for dir in /etc/kernel /usr/share/kernel; do
    test -d "$dir/postinst.d" || continue
    hookdirs="$hookdirs $dir/postinst.d"
done
hookdirs="${hookdirs# }"
test -n "$hookdirs" && run-parts --arg="6.17.0-14-generic" \
    --arg="/boot/vmlinuz-6.17.0-14-generic" $hookdirs
exit 0                    ← always succeeds
```

### After (what postinst looks like with the fix)

```bash
#!/bin/sh
set -e

export DEB_MAINT_PARAMS="$*"
export INITRD=Yes

hookdirs=
for dir in /etc/kernel /usr/share/kernel; do
    test -d "$dir/postinst.d" || continue
    hookdirs="$hookdirs $dir/postinst.d"
done
hookdirs="${hookdirs# }"
if [ -n "$hookdirs" ]; then
    if ! run-parts --arg="6.17.0-14-generic" \
        --arg="/boot/vmlinuz-6.17.0-14-generic" $hookdirs; then
        echo "E: Post-install hooks failed." >&2
        exit 1            ← fails when hooks fail
    fi
fi
exit 0                    ← only reached on success
```

The difference in behavior:

```
Hook fails (e.g., initramfs-tools exits 1):

Before:
  run-parts → exit 1 → discarded → postinst exits 0
  dpkg: "package installed successfully"
  GRUB: creates boot entry
  User reboots → possible kernel panic

After:
  run-parts → exit 1 → caught → "E: Post-install hooks failed."
  postinst exits 1
  dpkg: "package half-configured"
  apt: reports error to user
  GRUB: does NOT create boot entry for broken install
  User sees error, fixes hook issue before rebooting
```

---

## Patch Submission

```
Subject:  [PATCH] kbuild: deb-pkg: propagate hook script failures in builddeb
To:       Masahiro Yamada <masahiroy@kernel.org>
CC:       linux-kbuild@vger.kernel.org
Reviewed: Nathan Chancellor <nathan@kernel.org>

v1: Malformed — sent via Gmail instead of git send-email
v2: Correctly formatted, arrived on lore.kernel.org
v3: All review feedback addressed — under review

Lore: https://lore.kernel.org/linux-kbuild/?q=jillravaliya
```

The commit message connected the abstract fix to a concrete real-world consequence:

> *"On systems with modular storage drivers (CONFIG_BLK_DEV_NVME=m), an unnoticed failure in an early hook can prevent the initrd from being correctly updated, leading to a panic on reboot."*

This is important in kernel patch submissions — maintainers need to understand not just what changed but what real-world failure the change prevents.

---

## Connection to Ubuntu Bug #2141741

The Ubuntu bug and this mainline patch address the same failure at different layers:

```
Layer 1 — Mainline Kbuild (this patch):
  scripts/package/builddeb generates postinst
  postinst calls run-parts
  run-parts exit code is now checked
  Installation fails visibly if any hook fails

Layer 2 — Ubuntu systemd (Bug #2141741):
  55-initrd.install detects missing initrd
  Currently exits 0 despite missing initrd
  Should exit 1 to signal failure to run-parts

Both layers need fixing.
If Layer 1 is fixed but Layer 2 is not:
  run-parts succeeds (all hooks return 0)
  but initrd is still not built
  → postinst exits 0 → same problem

If Layer 2 is fixed but Layer 1 is not:
  55-initrd.install exits 1
  run-parts sees the failure
  but postinst ignores it with exit 0
  → same problem

Defense in depth requires both.
This patch fixes Layer 1.
```

---

## Files

```
mainline-kbuild-patch/
├── README.md              ← this document
└── patch/
    └── 0001-kbuild-deb-pkg-propagate-hook-script-failures.patch
```

The `.patch` file is the formatted output of `git format-patch` against the mainline tree. It includes the full diff, commit message, and `Signed-off-by` line — the standard format for Linux kernel patch submission.

---

## References

- **Patch on lore.kernel.org**
  https://lore.kernel.org/linux-kbuild/?q=jillravaliya

- **Ubuntu Bug #2141741** — 55-initrd.install silent exit 0
  https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2141741

- **Ubuntu Bug #2136499** — VirtualBox DKMS FTBFS for Linux 6.17 (fixed)
  https://bugs.launchpad.net/ubuntu/+source/virtualbox/+bug/2136499

- **Parent repository** — full kernel panic investigation
  https://github.com/jillravaliya/kernel-panic-investigation

- **linux-kbuild mailing list archive**
  https://lore.kernel.org/linux-kbuild/

---

## Author

**Jill Ravaliya**
- GitHub: [github.com/jillravaliya](https://github.com/jillravaliya)
- Email: jillravaliya@gmail.com
- LinkedIn: [linkedin.com/in/jill-ravaliya-684a98264](https://linkedin.com/in/jill-ravaliya-684a98264)

---

> *The kernel's build system should never silently produce an unbootable package. One exit code check makes the difference between a user seeing an error message and a user seeing a kernel panic.*
