#!/bin/bash
#
# This script demonstrates the bug in 55-initrd.install
# It shows that the script CAN detect missing initrd
# but chooses to exit 0 (success) instead of exit 1 (failure)
#

echo "=== Reproducing 55-initrd.install Bug ==="
echo ""

KERNEL_VERSION="6.17.0-14-generic"
INITRD_SRC="/boot/initrd.img-$KERNEL_VERSION"

echo "Checking for initrd: $INITRD_SRC"
echo ""

if [ -e "$INITRD_SRC" ]; then
    echo "✓ FOUND: initrd exists"
    echo "  → Script creates symlink"
    echo "  → Script exits 0 (correct behavior)"
else
    echo "✗ MISSING: initrd does not exist"
    echo ""
    echo "  CURRENT BEHAVIOR (buggy):"
    echo "    → Script prints warning to console"
    echo "    → Script exits 0 (pretends everything is fine)"
    echo "    → dpkg thinks installation succeeded"
    echo "    → GRUB creates boot entry"
    echo "    → User reboots → KERNEL PANIC"
    echo ""
    echo "  EXPECTED BEHAVIOR (fixed):"
    echo "    → Script prints warning"
    echo "    → Script exits 1 (reports failure)"
    echo "    → dpkg marks package as half-configured"
    echo "    → apt shows visible error to user"
    echo "    → User fixes issue BEFORE rebooting"
fi

echo ""
echo "=== End of reproduction ==="
