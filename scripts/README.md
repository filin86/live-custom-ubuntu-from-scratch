# Build Scripts

## build.sh

```console
This script builds a bootable ubuntu ISO image

Supported commands : setup_host debootstrap prechroot chr_setup_host chr_install_pkg chr_customize_image chr_custom_conf chr_postpkginst chr_build_image chr_finish_up postchroot build_iso

Syntax: ./build.sh [start_cmd] [-] [end_cmd]
  run from start_cmd to end_end
  if start_cmd is omitted, start from first command
  if end_cmd is omitted, end with last command
  enter single cmd to run the specific command
  enter '-' as only argument to run all commands
```

## How to Customize

1. Copy the `default_config.sh` file to `config.sh` in the scripts directory.
2. Make any necessary edits there, the script will pick up `config.sh` over `default_config.sh`.

## LXQt runtime profile (for this repository config.sh)

This repository `config.sh` is tailored for a restricted LXQt kiosk runtime with mandatory:
- SSH access (key-based)
- VNC access (`x11vnc` service)
- startup hooks from a persistent partition marked with `.inautolock`

### Persistent partition structure

The mounted persistent partition root is `/home/inauto`.

Expected layout:

```text
/home/inauto/
  .inautolock
  on_start/
    before_login/
    oneshot/
    forking/
  on_login/
  staff/lxqt/
    netplan/*.yaml
    etc/
    usr/
    opt/
    home/inauto/
    xdg/
    autostart/
    systemd/
    certs/system-ca/
    secrets/x11vnc.pass
```

`ApplyStaffLXQT.service` copies data from `/home/inauto/staff/lxqt` into the live filesystem and applies:
- netplan config (`netplan generate && netplan apply`)
- optional CA certificates (`update-ca-certificates`)
- optional VNC password file (`/etc/x11vnc.pass`)

## How to Update

The configuration script is versioned with the variable CONFIG_FILE_VERSION. Any time that the configuration
format is changed in `default_config.sh`, this value is bumped. Once this happens `config.sh` must be updated manually
from the default file to ensure the new/changed variables are as desired. Once the merge is complete the `config.sh` file's
CONFIG_FILE_VERSION should match the default and the build will run.
