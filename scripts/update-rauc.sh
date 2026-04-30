BUNDLE="inauto-panel-ubuntu-amd64-pc-efi-2026.04.30.4.raucb"
install -m 0644 prod-keyring.pem /etc/rauc/keyring.pem

# RAUC 1.15.x не принимает efi-loader/efi-cmdline в system.conf. Если эти
# ключи были добавлены вручную при отладке, rauc не сможет даже выполнить
# `rauc info`. Kernel cmdline хранится в UEFI-записях, а не в system.conf.
sed -i '/^efi-loader=/d;/^efi-cmdline=/d' /etc/rauc/system.conf
systemctl restart rauc.service || true

EFI_A=/dev/disk/by-partlabel/efi_A
EFI_B=/dev/disk/by-partlabel/efi_B
DISK="/dev/$(lsblk -no PKNAME "$EFI_A" | head -n1 | tr -d '[:space:]')"
EFI_A_PART="$(lsblk -dn -o PARTN "$EFI_A" | tr -d '[:space:]')"
EFI_B_PART="$(lsblk -dn -o PARTN "$EFI_B" | tr -d '[:space:]')"

for bootnum in $(efibootmgr -v | awk '/system0|system1/ { sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1 }'); do
    efibootmgr --bootnum "$bootnum" --delete-bootnum
done

efibootmgr --create --disk "$DISK" --part "$EFI_A_PART" \
    --label system0 \
    --loader '\EFI\BOOT\BOOTX64.EFI' \
    --unicode 'initrd=\EFI\Linux\initrd.img rauc.slot=system0 root=PARTLABEL=rootfs_A rootfstype=squashfs ro quiet panic=30'

efibootmgr --create --disk "$DISK" --part "$EFI_B_PART" \
    --label system1 \
    --loader '\EFI\BOOT\BOOTX64.EFI' \
    --unicode 'initrd=\EFI\Linux\initrd.img rauc.slot=system1 root=PARTLABEL=rootfs_B rootfstype=squashfs ro quiet panic=30'

efibootmgr -v | grep -E 'system0|system1'

rauc info "$BUNDLE"
rauc install "$BUNDLE"
sync
systemctl reboot

