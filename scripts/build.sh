#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

CMD=(setup_host debootstrap prechroot chr_setup_host chr_install_pkg chr_customize_image chr_custom_conf chr_postpkginst scan_vulnerabilities chr_build_image chr_finish_up postchroot build_iso)

DATE=`TZ="UTC" date +"%y%m%d-%H%M%S"`

function help() {
    # if $1 is set, use $1 as headline message in help()
    if [ -z ${1+x} ]; then
        echo -e "This script builds a bootable ubuntu ISO image"
        echo -e
    else
        echo -e $1
        echo
    fi
    echo -e "Supported commands : ${CMD[*]}"
    echo -e
    echo -e "Syntax: $0 [start_cmd] [-] [end_cmd]"
    echo -e "\trun from start_cmd to end_end"
    echo -e "\tif start_cmd is omitted, start from first command"
    echo -e "\tif end_cmd is omitted, end with last command"
    echo -e "\tenter single cmd to run the specific command"
    echo -e "\tenter '-' as only argument to run all commands"
    echo -e
    exit 0
}

function find_index() {
    local ret;
    local i;
    for ((i=0; i<${#CMD[*]}; i++)); do
        if [ "${CMD[i]}" == "$1" ]; then
            index=$i;
            return;
        fi
    done
    help "Command not found : $1"
}

function chroot_enter_setup() {
    sudo mount --bind /dev chroot/dev
    sudo mount --bind /run chroot/run
    sudo chroot chroot mount none -t proc /proc
    sudo chroot chroot mount none -t sysfs /sys
    sudo chroot chroot mount none -t devpts /dev/pts
}

function chroot_exit_teardown() {
    sudo chroot chroot umount /proc
    sudo chroot chroot umount /sys
    sudo chroot chroot umount /dev/pts
    sudo umount chroot/dev
    sudo umount chroot/run
}

function check_host() {
    local os_ver
    os_ver=`lsb_release -i | grep -E "(Ubuntu|Debian)"`
    if [[ -z "$os_ver" ]]; then
        echo "WARNING : OS is not Debian or Ubuntu and is untested"
    fi

    if [ $(id -u) -eq 0 ]; then
        echo "This script should not be run as 'root'"
        exit 1
    fi
}

# Load configuration values from file
function load_config() {
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
        . "$SCRIPT_DIR/config.sh"
    elif [[ -f "$SCRIPT_DIR/default_config.sh" ]]; then
        . "$SCRIPT_DIR/default_config.sh"
    else
        >&2 echo "Unable to find default config file  $SCRIPT_DIR/default_config.sh, aborting."
        exit 1
    fi
}

# Verify that necessary configuration values are set and they are valid
function check_config() {
    local expected_config_version
    expected_config_version="0.4"

    if [[ "$CONFIG_FILE_VERSION" != "$expected_config_version" ]]; then
        >&2 echo "Invalid or old config version $CONFIG_FILE_VERSION, expected $expected_config_version. Please update your configuration file from the default."
        exit 1
    fi
}

function setup_host() {
    echo "=====> running setup_host ..."
    sudo apt update
    sudo apt install -y debootstrap squashfs-tools xorriso binutils zstd jq
    sudo mkdir -p chroot
}

function debootstrap() {
    echo "=====> running debootstrap ... will take a couple of minutes ..."
    local extractor_args
    extractor_args=()

    if [[ -d chroot ]] && find chroot -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        >&2 echo "ERROR: target directory 'chroot' is not empty."
        >&2 echo "Remove it before restarting debootstrap, or resume the build from a later step."
        exit 1
    fi

    if ! command -v zstd >/dev/null 2>&1; then
        >&2 echo "ERROR: zstd is required by debootstrap to unpack modern Ubuntu .deb packages."
        >&2 echo "Run './scripts/build.sh setup_host' or install the 'zstd' package on the host."
        exit 1
    fi

    if dpkg-deb --version 2>&1 | grep -qi "busybox"; then
        echo "WARNING: BusyBox dpkg-deb detected on host, forcing debootstrap extractor=ar"
        extractor_args=(--extractor=ar)
    fi

    sudo debootstrap \
        --verbose \
        "${extractor_args[@]}" \
        --arch=amd64 \
        --variant=minbase \
        $TARGET_UBUNTU_VERSION \
        chroot \
        $TARGET_UBUNTU_MIRROR
}

function scan_vulnerabilities() {
    echo "=====> running scan_vulnerabilities ..."

    local report_root
    local metadata_report
    local package_inventory
    local affected_packages
    local trivy_json_report
    local trivy_table_report
    local vulnerability_tsv
    local summary_report
    local os_release_report
    local repo_root
    local trivy_ignorefile
    local trivy_bin
    local trivy_help
    local trivy_version
    local trivy_type_args
    local trivy_common_args
    local severity_filter
    local scan_timeout
    local ignore_args
    local package_count
    local result_count

    repo_root="$(dirname "$SCRIPT_DIR")"
    severity_filter="${VULN_SCAN_SEVERITIES:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}"
    scan_timeout="${VULN_SCAN_TIMEOUT:-15m}"
    report_root="${VULN_REPORT_DIR:-$SCRIPT_DIR/reports/${TARGET_NAME}-${DATE}}"

    metadata_report="$report_root/metadata.txt"
    package_inventory="$report_root/packages.tsv"
    affected_packages="$report_root/affected-packages.txt"
    trivy_json_report="$report_root/trivy-rootfs.json"
    trivy_table_report="$report_root/trivy-rootfs.txt"
    vulnerability_tsv="$report_root/vulnerabilities.tsv"
    summary_report="$report_root/summary.txt"
    os_release_report="$report_root/os-release"
    trivy_bin="${TRIVY_BIN:-trivy}"
    ignore_args=()
    trivy_type_args=()
    trivy_common_args=()
    trivy_ignorefile=""
    trivy_help=""
    trivy_version=""
    package_count=0
    result_count=0

    if [[ ! -d chroot ]]; then
        >&2 echo "ERROR: chroot directory does not exist. Run debootstrap and package customization first."
        exit 1
    fi

    if [[ ! -f chroot/var/lib/dpkg/status ]]; then
        >&2 echo "ERROR: chroot does not look like a prepared Ubuntu rootfs (missing var/lib/dpkg/status)."
        exit 1
    fi

    if ! command -v "$trivy_bin" >/dev/null 2>&1; then
        >&2 echo "ERROR: Trivy is required for the vulnerability report stage."
        >&2 echo "Install Trivy on the build host or set TRIVY_BIN to the scanner path, then rerun './scripts/build.sh scan_vulnerabilities'."
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        >&2 echo "ERROR: jq is required to post-process the Trivy report."
        >&2 echo "Run './scripts/build.sh setup_host' or install the 'jq' package on the host."
        exit 1
    fi

    if ! trivy_help="$("$trivy_bin" rootfs --help 2>&1)"; then
        >&2 echo "ERROR: unable to execute '$trivy_bin rootfs --help'."
        >&2 printf '%s\n' "$trivy_help"
        exit 1
    fi

    if grep -q -- '--pkg-types' <<< "$trivy_help"; then
        trivy_type_args=(--pkg-types os)
    elif grep -q -- '--vuln-type' <<< "$trivy_help"; then
        trivy_type_args=(--vuln-type os)
    fi

    trivy_version="$("$trivy_bin" --version 2>&1 | head -n 1 || true)"

    if [[ -f "$repo_root/.trivyignore" ]]; then
        trivy_ignorefile="$repo_root/.trivyignore"
    elif [[ -f "$SCRIPT_DIR/.trivyignore" ]]; then
        trivy_ignorefile="$SCRIPT_DIR/.trivyignore"
    fi

    if [[ -n "$trivy_ignorefile" ]]; then
        ignore_args=(--ignorefile "$trivy_ignorefile")
    fi

    mkdir -p "$report_root"

    {
        echo "target_name=$TARGET_NAME"
        echo "target_ubuntu_version=$TARGET_UBUNTU_VERSION"
        echo "target_ubuntu_mirror=$TARGET_UBUNTU_MIRROR"
        echo "generated_at_utc=$(TZ=UTC date -Iseconds)"
        echo "scan_timeout=$scan_timeout"
        echo "severity_filter=$severity_filter"
        echo "trivy_bin=$trivy_bin"
        echo "trivy_version=$trivy_version"
        if [[ -n "$trivy_ignorefile" ]]; then
            echo "trivy_ignorefile=$trivy_ignorefile"
        else
            echo "trivy_ignorefile=<none>"
        fi
    } > "$metadata_report"

    sudo cat chroot/etc/os-release > "$os_release_report"
    {
        printf 'package\tversion\tarchitecture\n'
        sudo chroot chroot dpkg-query -W --showformat='${Package}\t${Version}\t${Architecture}\n' | sort
    } > "$package_inventory"

    package_count=$(tail -n +2 "$package_inventory" | wc -l | tr -d ' ')

    trivy_common_args=(
        rootfs
        --scanners vuln
        "${trivy_type_args[@]}"
        --severity "$severity_filter"
        --timeout "$scan_timeout"
        "${ignore_args[@]}"
    )

    "$trivy_bin" "${trivy_common_args[@]}" \
        --list-all-pkgs \
        --format json \
        --output "$trivy_json_report" \
        chroot

    "$trivy_bin" "${trivy_common_args[@]}" \
        --format table \
        --output "$trivy_table_report" \
        chroot

    result_count=$(jq '(.Results // []) | length' "$trivy_json_report")

    if [[ "$result_count" -eq 0 && "$package_count" -gt 0 ]]; then
        >&2 echo "WARNING: Trivy returned zero scan results for a rootfs with $package_count installed packages."
        >&2 echo "WARNING: Treat this as an inconclusive scan, not as proof that the image has no CVEs."
        >&2 echo "WARNING: Check Trivy version/DB and compare with a newer official Trivy build if possible."
    fi

    {
        printf 'package\tinstalled_version\tseverity\tvulnerability_id\tfixed_version\tprimary_url\n'
        jq -r '
            [
                .Results[]?.Vulnerabilities[]?
                | [
                    .PkgName,
                    .InstalledVersion,
                    .Severity,
                    .VulnerabilityID,
                    (.FixedVersion // ""),
                    (.PrimaryURL // "")
                ]
            ]
            | sort_by(.[0], .[2], .[3])
            | .[]
            | @tsv
        ' "$trivy_json_report"
    } > "$vulnerability_tsv"

    jq -r '
        [
            .Results[]?.Vulnerabilities[]?.PkgName
        ]
        | map(select(. != null))
        | unique
        | .[]
    ' "$trivy_json_report" > "$affected_packages"

    jq -r '
        def severity_count(level):
            ([.Results[]?.Vulnerabilities[]? | select(.Severity == level)] | length);
        [
            "Report directory: '"$report_root"'",
            "Total vulnerabilities: " + (([.Results[]?.Vulnerabilities[]?] | length) | tostring),
            "Affected packages: " + (([.Results[]?.Vulnerabilities[]?.PkgName] | map(select(. != null)) | unique | length) | tostring),
            "CRITICAL: " + (severity_count("CRITICAL") | tostring),
            "HIGH: " + (severity_count("HIGH") | tostring),
            "MEDIUM: " + (severity_count("MEDIUM") | tostring),
            "LOW: " + (severity_count("LOW") | tostring),
            "UNKNOWN: " + (severity_count("UNKNOWN") | tostring)
        ]
        | .[]
    ' "$trivy_json_report" > "$summary_report"

    cat "$summary_report"
}

function prechroot() {
    echo "=====> running run_chroot ..."

    chroot_enter_setup

    # Setup build scripts in chroot environment
    sudo ln -f $SCRIPT_DIR/chroot_build.sh chroot/root/chroot_build.sh
    sudo ln -f $SCRIPT_DIR/default_config.sh chroot/root/default_config.sh
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
        sudo ln -f $SCRIPT_DIR/config.sh chroot/root/config.sh
    fi

}

# function run_chroot() {

#     # Launch into chroot environment to build install image.
#     sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh -

# }

function chr_setup_host() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh setup_host
    
}

function chr_install_pkg() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh install_pkg
    
}

function chr_customize_image() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh customize_image
    
}

function chr_custom_conf() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh custom_conf
    
}

function chr_postpkginst() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh postpkginst
    
}

function chr_build_image() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh build_image
    
}

function chr_finish_up() {
    sudo chroot chroot /usr/bin/env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} /root/chroot_build.sh finish_up
    
}

function postchroot() {
       # Cleanup after image changes
    sudo rm -f chroot/root/chroot_build.sh
    sudo rm -f chroot/root/default_config.sh
    if [[ -f "chroot/root/config.sh" ]]; then
        sudo rm -f chroot/root/config.sh
    fi

    chroot_exit_teardown

}

function build_iso() {
    echo "=====> running build_iso ..."

    # move image artifacts
    sudo mv chroot/image .

    # compress rootfs
    sudo mksquashfs chroot image/casper/filesystem.squashfs \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -comp xz -b 1M -Xdict-size 100% \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile"

    # write the filesystem.size
    printf $(sudo du -sx --block-size=1 chroot | cut -f1) | sudo tee image/casper/filesystem.size

    pushd $SCRIPT_DIR/image

    sudo xorriso \
        -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -J -J -joliet-long \
        -volid "$TARGET_NAME" \
        -output "$SCRIPT_DIR/$TARGET_NAME.iso" \
      -eltorito-boot isolinux/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog boot.catalog \
        --grub2-boot-info \
        --grub2-mbr ../chroot/usr/lib/grub/i386-pc/boot_hybrid.img \
        -partition_offset 16 \
        --mbr-force-bootable \
      -eltorito-alt-boot \
        -no-emul-boot \
        -e isolinux/efiboot.img \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b isolinux/efiboot.img \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -m "isolinux/efiboot.img" \
        -m "isolinux/bios.img" \
        -e '--interval:appended_partition_2:::' \
      -exclude isolinux \
      -graft-points \
         "/EFI/boot/bootx64.efi=isolinux/bootx64.efi" \
         "/EFI/boot/mmx64.efi=isolinux/mmx64.efi" \
         "/EFI/boot/grubx64.efi=isolinux/grubx64.efi" \
         "/EFI/ubuntu/grub.cfg=isolinux/grub.cfg" \
         "/isolinux/bios.img=isolinux/bios.img" \
         "/isolinux/efiboot.img=isolinux/efiboot.img" \
         "."

    popd
}

# =============   main  ================

# we always stay in $SCRIPT_DIR
cd $SCRIPT_DIR

load_config
check_config
check_host

# check number of args
if [[ $# == 0 || $# > 3 ]]; then help; fi

# loop through args
dash_flag=false
start_index=0
end_index=${#CMD[*]}
for ii in "$@";
do
    if [[ $ii == "-" ]]; then
        dash_flag=true
        continue
    fi
    find_index $ii
    if [[ $dash_flag == false ]]; then
        start_index=$index
    else
        end_index=$(($index+1))
    fi
done
if [[ $dash_flag == false ]]; then
    end_index=$(($start_index + 1))
fi

#loop through the commands
for ((ii=$start_index; ii<$end_index; ii++)); do
    ${CMD[ii]}
done

echo "$0 - Initial build is done!"
