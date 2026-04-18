#!/bin/bash
# Debian profile hooks — stub. Fully implemented in Phase 3.

function _debian_not_implemented() {
    >&2 echo "ERROR: Debian profile is a stub until Phase 3 (${FUNCNAME[1]})."
    exit 1
}

function profile_install_live_stack()  { _debian_not_implemented; }
function profile_kernel_install()      { _debian_not_implemented; }
function profile_write_image_marker()  { _debian_not_implemented; }
function profile_write_boot_configs()  { _debian_not_implemented; }
