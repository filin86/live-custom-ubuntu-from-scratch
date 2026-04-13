# Build Scripts

## build.sh

```console
This script builds a bootable ubuntu ISO image

Supported commands : setup_host debootstrap prechroot chr_setup_host chr_install_pkg chr_customize_image chr_custom_conf chr_postpkginst scan_vulnerabilities chr_build_image chr_finish_up postchroot build_iso

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

## Vulnerability Report Stage

The `scan_vulnerabilities` stage scans the prepared `chroot/` as a root filesystem and writes artifacts to `scripts/reports/<target>-<timestamp>/`.

Requirements:
- `trivy` must be installed on the build host
- `jq` is installed by `./build.sh setup_host`

Generated files:
- `metadata.txt` - scan parameters and Trivy version
- `os-release` - target OS metadata from the chroot
- `packages.tsv` - installed package inventory
- `trivy-rootfs.json` - full machine-readable vulnerability report
- `trivy-rootfs.txt` - human-readable vulnerability table
- `vulnerabilities.tsv` - package/version/CVE/fixed-version rows for analysis
- `affected-packages.txt` - unique package names with findings
- `summary.txt` - quick severity totals

Examples:

```console
./build.sh chr_postpkginst - scan_vulnerabilities
./build.sh scan_vulnerabilities
```

Optional environment variables:
- `VULN_SCAN_SEVERITIES` default: `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL`
- `VULN_SCAN_TIMEOUT` default: `15m`
- `VULN_REPORT_DIR` default: `scripts/reports/<target>-<timestamp>`

If a `.trivyignore` file exists in the repository root or `scripts/`, it will be used automatically.
