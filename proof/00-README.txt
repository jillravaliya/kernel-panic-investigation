================================================================================
                    BUG #2141741 EVIDENCE PACKAGE
================================================================================

SUMMARY:
The script /usr/lib/kernel/install.d/55-initrd.install detects when initrd
is missing but returns exit 0 (success) anyway. This allows GRUB to create
boot entries for unbootable kernels, causing kernel panics on NVMe systems.

FILES IN THIS PACKAGE:
  00-README.txt           - This file
  01-dpkg-timeline.txt    - 3-day installation failure pattern
  02-dkms-failure.txt     - VirtualBox DKMS exit 11 blocking initramfs
  03-buggy-script.txt     - The script showing "exit 0" on line 26
  04-system-config.txt    - Proves NVMe driver is module-only
  05-reproducer.sh        - Script demonstrating the bug
  05-reproducer-output.txt - Output from running reproducer

COMPLETE FAILURE CHAIN:
  1. User runs: apt upgrade
  2. Kernel 6.17.0-14 installation begins
  3. /etc/kernel/postinst.d/dkms runs (alphabetically first)
  4. VirtualBox DKMS compilation fails → exits with code 11
  5. run-parts stops immediately (does not continue)
  6. /etc/kernel/postinst.d/initramfs-tools NEVER runs
  7. Result: /boot/initrd.img-6.17.0-14-generic is NEVER created
  8. /usr/lib/kernel/install.d/55-initrd.install runs
  9. Script checks: if [ -e "$INITRD_SRC" ] → FALSE (file missing)
 10. Script enters else branch → prints warning
 11. Script executes: exit 0 ← THIS IS THE BUG
 12. dpkg thinks kernel installation succeeded
 13. GRUB generates boot entry for 6.17
 14. GRUB marks 6.17 as default (newest kernel)
 15. User reboots
 16. GRUB loads kernel 6.17 without initrd
 17. Kernel boots → needs NVMe driver to mount root
 18. NVMe driver is in initrd (CONFIG_BLK_DEV_NVME=m)
 19. Initrd is missing → driver not loaded
 20. Kernel cannot see NVMe SSD → unknown-block(0,0)
 21. KERNEL PANIC: VFS unable to mount root fs

WHY THIS IS A SYSTEMD BUG:
  - Yes, DKMS *should* fail harder (that's Bug #2136499)
  - But 55-initrd.install has ONE job: detect missing initrd and FAIL
  - The script already DETECTS the problem (line 23-24 check works)
  - But then it returns SUCCESS anyway (line 26: exit 0)
  - This is defense-in-depth failure
  - Even if every DKMS module is perfect, boot scripts should validate
  - Silent success on critical missing files creates unbootable systems

THE FIX:
  Change line 26 in /usr/lib/kernel/install.d/55-initrd.install
  From:  exit 0
  To:    exit 1

  This makes the failure visible to dpkg/apt BEFORE the user reboots.

AFFECTED SYSTEMS:
  - Any system where CONFIG_BLK_DEV_NVME=m (module, not built-in)
  - Any system where CONFIG_SCSI=m or root device driver is modular
  - Essentially: any modern Ubuntu system with modular drivers

REPORTER: Jill Ravaliya
BUG URL: https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2141741
DATE: 2026-02-13
================================================================================
