#!/bin/sh
set -eu

BINFMT_MISC="/proc/sys/fs/binfmt_misc"

log() { echo "qemu-binfmt: $*"; }

# Check for kernel support
if ! grep -q binfmt_misc /proc/filesystems 2>/dev/null; then
    log "kernel does not support binfmt_misc, skipping"
    exit 0
fi

# Mount if necessary
if ! grep -q "$BINFMT_MISC" /proc/mounts; then
    if ! mount -t binfmt_misc binfmt_misc "$BINFMT_MISC"; then
        log "failed to mount binfmt_misc, skipping"
        exit 0
    fi
fi

# Done
exit 0
