# One Missing File. Three Days of Silent Failures.

## A Note on This Document

This is a **reconstructed postmortem**, not a live incident log. The investigation happened across **February 11–13, 2026**. I collected dpkg logs, apt terminal logs, and boot journals throughout, then structured this afterward. The order reflects the logical progression of reasoning, not a precise chronological transcript.

---

## Background

**January 9, 2026** — I completed the Linux Foundation's *"A Beginner's Guide to Linux Kernel Development"* (LFD103) course and wanted to go further. I built a small character device driver — a kernel module that creates `/dev/jill`, handles blocking reads and writes using wait queues, and accepts IOCTL commands. Kernel modules run in Ring 0 — the most privileged CPU mode — where a bad pointer dereference crashes the entire system instantly with no recovery.

To keep experiments safe, I installed VirtualBox and ran everything inside a VM:

- If the kernel crashed, only the VM died
- The host stayed completely untouched
- All experiments were isolated inside the virtual machine

> That was the intent. The host did stay safe during experiments. But VirtualBox's presence on the host — registered with DKMS — quietly became a problem waiting to surface on the next kernel upgrade.

---

## The Panic

**February 13, 2026 — Morning**

Powered on the laptop. Instead of the login screen:

```
KERNEL PANIC!
Please reboot your computer.
VFS: Unable to mount root fs on unknown-block(0,0)
```

![Kernel Panic Screen](../screenshots/kernel-panic.jpg)

**Purple screen — VFS unable to mount root fs on unknown-block(0,0)**

> The host machine. The one I had never experimented on directly.

---

## Recovery: GRUB

Powered off, powered back on. Interrupted the automatic boot and opened the GRUB menu — GRUB (Grand Unified Bootloader) is the program that runs after UEFI but before Linux starts. Its job is to load the kernel into memory and hand off control.

The menu showed two options:

- `Ubuntu, with Linux 6.17.0-14-generic` ← just panicked
- `Ubuntu, with Linux 6.14.0-37-generic` ← previous kernel

![GRUB Boot Menu](../screenshots/grub-menu.jpg)

**GRUB showing two available kernels — 6.17 broken, 6.14 working**

Selected `6.14`. Desktop appeared normally.

> GRUB always selects the newest kernel by default — `6.17 > 6.14` numerically. Every automatic reboot would go straight back to the panic without manual intervention.

---

## Initial Check: The Missing initrd

Once on the working kernel, confirmed which one was running:

```bash
$ uname -r
6.14.0-37-generic
```

Then looked at `/boot` — the directory where kernel-related files live:

```bash
$ ls -la /boot/initrd*
lrwxrwxrwx  1 root root    28 Feb 13 08:41  initrd.img -> initrd.img-6.17.0-14-generic
-rw-r--r--  1 root root 73101720 Jan 16 08:57  initrd.img-6.14.0-37-generic
lrwxrwxrwx  1 root root    28 Feb 11 09:09  initrd.img.old -> initrd.img-6.14.0-37-generic
```

The symlink `initrd.img` pointed to `initrd.img-6.17.0-14-generic`. But that file did not exist.

![Missing initrd file](../screenshots/missing-initrd.png)

**The symlink points to a file that was never created**

> A symlink is a pointer to another file — like a shortcut. The pointer existed. The destination never did.

The initrd (initial RAM disk) is a small temporary filesystem that GRUB loads into RAM alongside the kernel at boot. It contains the storage drivers the kernel needs to access the disk — including the NVMe driver. Without it, the kernel boots with no way to see the SSD.

> `unknown-block(0,0)` means block device with major number 0 and minor number 0 — in Linux that literally means "no device found." The kernel looked for a disk and found nothing, because the NVMe driver that would have made the disk visible never loaded.

---

## Why NVMe Systems Specifically

Checked the kernel configuration — the file that records how the kernel was compiled:

```bash
$ cat /boot/config-6.17.0-14-generic | grep "NVME\|INITRAMFS"
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE=""
CONFIG_BLK_DEV_NVME=m
```

![Kernel configuration](../screenshots/kernel-config.png)

**CONFIG_BLK_DEV_NVME=m — NVMe compiled as a loadable module, not into the kernel itself**

What each flag means:

- `CONFIG_BLK_DEV_INITRD=y` — the kernel can load an external initrd, but does not have one built in
- `CONFIG_INITRAMFS_SOURCE=""` — empty string means no initrd is embedded inside the kernel binary itself
- `CONFIG_BLK_DEV_NVME=m` — `=m` means NVMe support is a **loadable module**, a separate file that must be loaded at runtime

Compare with SATA:

```bash
$ cat /boot/config-6.17.0-14-generic | grep "CONFIG_ATA="
CONFIG_ATA=y
```

> `=y` means SATA support is compiled directly into the kernel binary — no initrd needed. An NVMe system cannot boot without initrd because the driver exists only as `nvme-core.ko.zst` inside it.

Confirmed the NVMe modules live inside the initrd:

```bash
$ lsinitramfs /boot/initrd.img-6.17.0-14-generic | grep -i "nvme"
usr/lib/modules/6.17.0-14-generic/kernel/drivers/nvme/host/nvme-core.ko.zst
usr/lib/modules/6.17.0-14-generic/kernel/drivers/nvme/host/nvme.ko.zst
```

![NVMe modules in initramfs](../screenshots/lsinitramfs-nvme .png)

**The NVMe driver modules exist only inside the initrd — nowhere on the disk itself**

> The `.ko.zst` files are compressed kernel modules. Without initrd loading them into RAM at boot, the kernel has no NVMe support. The disk is invisible.

---

## The Quick Fix

Generated the missing initrd manually:

```bash
$ sudo update-initramfs -c -k 6.17.0-14-generic
```

`update-initramfs` builds the initrd file — it gathers the necessary kernel modules and packages them into a compressed archive. `-c` means create, `-k` specifies the kernel version.

```bash
$ ls -la /boot/initrd.img-6.17.0-14-generic
-rw-r--r--  1 root root 73711966 Feb 13 11:58  initrd.img-6.17.0-14-generic
```

Updated GRUB so it could find the new file:

```bash
$ sudo update-grub
Found linux image: /boot/vmlinuz-6.17.0-14-generic
Found initrd image: /boot/initrd.img-6.17.0-14-generic
```

```bash
$ sudo reboot
$ uname -r
6.17.0-14-generic
```

System booted. But the question remained:

> **Why was the initrd never generated in the first place?**

---

## The Three-Day Pattern

Ubuntu generates the initrd automatically as part of kernel installation. Something must have gone wrong during that process. Checked the dpkg log — dpkg is the low-level package manager that records every install, remove, and configuration event on the system:

```bash
$ sudo cat /var/log/dpkg.log | grep "6.17.0-14" | grep "trigproc\|half-configured"
```

```
2026-02-11 09:09:32  trigproc linux-image-6.17.0-14-generic:amd64 6.17.0-14.14-24.04.1 <none>
2026-02-11 09:09:32  status half-configured linux-image-6.17.0-14-generic:amd64 6.17.0-14.14-24.04.1

2026-02-12 09:36:03  trigproc linux-image-6.17.0-14-generic:amd64 6.17.0-14.14-24.04.1 <none>
2026-02-12 09:36:03  status half-configured linux-image-6.17.0-14-generic:amd64 6.17.0-14.14-24.04.1

2026-02-13 08:41:13  trigproc linux-image-6.17.0-14-generic:amd64 6.17.0-14.14-24.04.1 <none>
2026-02-13 08:41:13  status half-configured linux-image-6.17.0-14-generic:amd64 6.17.0-14.14-24.04.1
```

![Three-day failure pattern](../screenshots/three-day-pattern.png)

**Three consecutive days — same failure state each time**

- **February 11, 09:09** — first `apt upgrade` attempt, stuck at `half-configured`
- **February 12, 09:36** — second retry, same failure
- **February 13, 08:41** — third retry, same failure — reboot happened 3 hours later

> `trigproc` means trigger processing — the post-installation scripts that run after a package's files are placed on disk. `half-configured` means the package started configuration but did not finish. Three days in a row. Nothing surfaced to the screen.

---

## Finding the Actual Error

The dpkg log shows status changes but not the error details. The apt terminal log captures full command output during installations:

```bash
$ sudo cat /var/log/apt/term.log | grep -C 10 "exit status 11"
```

```
Setting up linux-image-6.17.0-14-generic (6.17.0-14.14-24.04.1) ...
I: /boot/vmlinuz is now a symlink to vmlinuz-6.17.0-14-generic
I: /boot/initrd.img is now a symlink to initrd.img-6.17.0-14-generic
dkms: running auto installation service for kernel 6.17.0-14-generic
...fail!
run-parts: /etc/kernel/postinst.d/dkms exited with return code 11

dpkg: error processing package linux-image-6.17.0-14-generic (--configure):
 installed linux-image-6.17.0-14-generic package post-installation script
 subprocess returned error exit status 11
```

> DKMS failed with exit code 11. When it failed, `run-parts` stopped. Everything after it — including `initramfs-tools` — never ran.

---

## The Alphabetical Execution Trap

Looked at the post-install scripts directory:

```bash
$ ls /etc/kernel/postinst.d/
dkms
initramfs-tools
unattended-upgrades
update-notifier
xx-update-initrd-links
zz-shim
zz-update-grub
```

![Post-install scripts directory](../screenshots/postinst-scripts.png)

**The post-install scripts directory — executed alphabetically by run-parts**

`run-parts` executes these in alphabetical order and stops on the first non-zero exit code:

- `dkms` — starts with `d`, runs **first**
- `initramfs-tools` — starts with `i`, runs **second**
- `zz-update-grub` — starts with `zz`, runs **last**

> The naming is intentional — `zz-update-grub` starts with `zz` to ensure it always runs after everything else. The stop-on-error behavior exists because later scripts often depend on earlier ones succeeding. The design makes sense in principle — but here it meant one unrelated failure cascaded into a missing critical boot file.

When DKMS returned exit code 11, `run-parts` stopped. `initramfs-tools` never ran. The initrd was never created.

---

## The Broken VirtualBox Package

Checked which DKMS module had failed:

```bash
$ sudo cat /var/log/apt/term.log | grep -B 5 -A 10 "VBox"
```

```
Building module:
make -j2 KERNELRELEASE=6.17.0-14-generic -C /lib/modules/6.17.0-14-generic/build
  M=/var/lib/dkms/virtualbox/7.0.16/build
...(bad exit status: 2)

Error! Bad return status for module build on kernel: 6.17.0-14-generic (x86_64)

fatal error: VBox/cdefs.h: No such file or directory
   47 | #include <VBox/cdefs.h>
compilation terminated.
```

![VirtualBox compilation error](../screenshots/vbox-error.png)

**VirtualBox DKMS compilation failure — missing header file VBox/cdefs.h**

VirtualBox. The one installed specifically to keep kernel experiments safe.

```bash
$ apt-cache policy virtualbox
virtualbox:
  Installed: 7.0.16-dfsg-2ubuntu1.1
```

The `-dfsg` suffix indicates Ubuntu modified the package to comply with open-source guidelines — DFSG stands for Debian Free Software Guidelines. In doing so, they removed proprietary components that contained critical header files, including `VBox/cdefs.h`. A header file contains declarations that code needs in order to compile — without it, the compiler cannot proceed.

> The package was registering itself with DKMS to compile on every new kernel, but was missing the files it needs to actually compile. It would have failed on any kernel upgrade from the moment it was installed.

---

## The systemd Silent Failure

After the DKMS failure, a script from the systemd package — `55-initrd.install` — ran as part of the kernel install infrastructure. systemd is the init system that manages services and system startup on Ubuntu. This script's job is to copy the initrd into the correct boot location:

```bash
$ cat /usr/lib/kernel/install.d/55-initrd.install
```

The relevant section:

```bash
if [ -e "$INITRD_SRC" ]; then
    install -m 0644 "$INITRD_SRC" "$INITRD_DEST"
else
    [ "$KERNEL_INSTALL_VERBOSE" -gt 0 ] && \
      echo "$INITRD_SRC does not exist, not installing an initrd"
fi

exit 0
```

![systemd exit 0 bug](../screenshots/exit-0-bug.png)

**Line 26 — exit 0 returned even when no initrd exists**

What happened step by step:

- Script checked for initrd — **not found**
- Verbose mode is off by default during `apt upgrade` — **nothing printed**
- Script returned **exit 0 — success**

> Exit code 0 is how programs tell the system "everything went fine." Any non-zero code signals failure. This script told the entire installation chain that everything was fine — when a critical boot file was completely absent.

GRUB received that success signal and created a boot entry for kernel `6.17`. It had no reason to think anything was wrong. The system appeared fully updated and ready to reboot.

```bash
$ dpkg -S /usr/lib/kernel/install.d/55-initrd.install
systemd: /usr/lib/kernel/install.d/55-initrd.install
```

The behavior suggests returning **exit 1** here would cause dpkg to report a visible error, stop GRUB from writing an unbootable entry, and give the user a chance to fix the problem before rebooting. That is what the bug report covers.

![Multiple exit 0 instances](../screenshots/exit-0-multiple.png)

**Multiple places in the script where exit 0 is returned regardless of initrd presence**

---

## Trigger vs Underlying Issue

At this point the full chain was clear. But there is an important distinction:

> **VirtualBox is the trigger. The underlying issue is the silent exit 0.**

Any DKMS module failure would produce the same outcome on an NVMe system:

- NVIDIA driver fails to compile → same path
- ZFS module fails to compile → same path
- WireGuard or any custom driver fails → same path

In every case:

- DKMS fails → `run-parts` stops → `initramfs-tools` never runs
- `55-initrd.install` silently returns exit 0
- GRUB creates an unbootable entry
- NVMe system panics on next reboot

> VirtualBox was just what happened to be installed here. The system produced no visible error, no failed package state visible to the user, and no warning before rebooting into a panic.

---

## Filing the Bug Report

Searched Launchpad first. The VirtualBox DKMS compilation failure was already documented:

**Bug #2136499** — `virtualbox-dkms` fails to build for kernel 6.17

- 110+ affected users, 618 comments
- Everyone focused on VirtualBox specifically
- Nobody had traced why this led to an unbootable system instead of a visible installation error

Filed a new report against the systemd package:

> **[Bug #2141741](https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2141741)** — `55-initrd.install` silently exits 0 when initrd missing, causing undetectable kernel panic on NVMe systems

The report included:

- The complete failure chain from DKMS to panic
- The exact script content and the line returning exit 0
- dpkg and apt logs from all three installation attempts
- Kernel configuration showing `CONFIG_BLK_DEV_NVME=m`
- The distinction between the VirtualBox trigger and the systemd underlying issue

![Bug initially filed](../screenshots/bug-filed.png)

> ****Bug #2141741 filed - Also posted on Bug #2136499 connecting the 110+ affected VirtualBox users to the deeper systemd issue.

![Bug confirmed by Ubuntu](../screenshots/bug-confirmed.png)

> **Within **2 hours**, Ubuntu developers confirmed the report. Status changed from **New** to **Confirmed**.**


---

## System Restored

```bash
$ sudo apt remove --purge virtualbox
$ sudo dkms remove virtualbox/7.0.16 --all
$ sudo update-initramfs -c -k 6.17.0-14-generic
$ sudo update-grub
$ sudo reboot
```

**Verify:**

```bash
$ uname -r
6.17.0-14-generic

$ ls -la /boot/initrd*
-rw-r--r--  73101720  initrd.img-6.14.0-37-generic
-rw-r--r--  73711966  initrd.img-6.17.0-14-generic

$ dkms status
[empty — VirtualBox removed]
```

> Both kernels have valid initrd files. System stable.

---

## Complete Failure Chain

```
Ubuntu ships virtualbox-7.0.16-dfsg (missing VBox/cdefs.h header)
    ↓
Feb 11 09:09 — apt upgrade installs kernel 6.17
    ↓
DKMS attempts VirtualBox compilation → fails, exit code 11
    ↓
run-parts executes /etc/kernel/postinst.d/ alphabetically
dkms (d) runs before initramfs-tools (i) → error → STOPS
    ↓
initramfs-tools never runs
initrd.img-6.17.0-14-generic never created
    ↓
55-initrd.install detects missing initrd
prints nothing (verbose=0) → returns exit 0
    ↓
GRUB receives success signal
creates boot entry for 6.17 pointing to missing initrd
    ↓
Feb 13 morning — first reboot since kernel install
    ↓
GRUB loads kernel 6.17 → tries to load initrd → does not exist
Kernel boots without NVMe driver (CONFIG_BLK_DEV_NVME=m)
NVMe SSD invisible to kernel
    ↓
unknown-block(0,0) → KERNEL PANIC
```

---

## What I Took Away From This

The panic looked like it could have been anything — bad kernel, hardware issue, experiments somehow escaping the VM. The actual cause was only traceable by reading logs carefully and following each failure back to its source.

Each step narrowed it:

- **Kernel 6.14 works, 6.17 panics** → specific to this kernel's installation, not hardware
- **initrd missing for 6.17** → the file was never created, not corrupted
- **dpkg log: half-configured three days in a row** → installation was consistently failing silently
- **apt term.log: DKMS exit 11** → something DKMS was managing failed to compile
- **VirtualBox -dfsg missing headers** → the trigger identified
- **55-initrd.install: exit 0 with no initrd** → the underlying issue identified

> The biggest lesson: filtering logs for errors alone — `--priority=err`, `grep -i error` — would not have found this. The failure was logged at info level. A quiet status change in dpkg. A missing file. A script returning success when it should not have. Reading the full log sequence was what made it visible.

The bug report is for Ubuntu and systemd developers to address. My part was tracing the chain far enough to identify where the silent failure was occurring and report it with enough evidence to be confirmed.

---

## System Status After Workaround

```bash
$ uname -r
6.17.0-14-generic

$ ls -la /boot/initrd*
-rw-r--r--  1 root root 73101720  initrd.img-6.14.0-37-generic
-rw-r--r--  1 root root 73711966  initrd.img-6.17.0-14-generic

$ dkms status
[empty — VirtualBox removed]

$ systemctl status gdm
● gdm.service - GNOME Display Manager
     Active: active (running)
```

---

## Connect With Me

I am currently looking for internship opportunities in systems programming or Linux. If you found this write-up useful or want to discuss it, feel free to reach out.

- **Email:** jillahir9999@gmail.com
- **LinkedIn:** [linkedin.com/in/jill-ravaliya-684a98264](https://linkedin.com/in/jill-ravaliya-684a98264)
- **GitHub:** [github.com/jillravaliya](https://github.com/jillravaliya)

---

> *Three days of silent failures. One missing file. One script returning success when it should not have. The system never warned me — so I had to read everything until it did.*
