#!/usr/bin/bash
# Prepare the bootc-generic-iso installer container: Anaconda + the kernel
# initramfs + the EFI tree the ISO contract expects. The payload container is
# installed by Anaconda (named in interactive-defaults.ks), so this container
# is just the installer environment.
set -exo pipefail
payload_ref="${1:?usage: build.sh <payload-ref>}"

dnf install -qy \
    anaconda \
    anaconda-install-img-deps \
    anaconda-dracut \
    dracut-config-generic \
    dracut-network \
    net-tools \
    grub2-efi-x64-cdboot \
    shim-x64 \
    grub2-efi-x64 \
    grub2-common \
    grub2-pc-modules \
    grub2-tools \
    xorriso \
    squashfs-tools \
    isomd5sum \
    jq
dnf clean all

# Fedora 44 moved the EFI binaries to /usr/lib/efi; the ISO contract wants them
# under /boot/efi/EFI/$VENDOR.
mkdir -p /boot/efi && cp -ra /usr/lib/efi/*/*/EFI /boot/efi

# lorax normally builds the Anaconda runtime; this is the bare minimum.
echo "install:x:0:0:root:/root:/usr/libexec/anaconda/run-anaconda" >> /etc/passwd
echo "install::14438:0:99999:7:::" >> /etc/shadow
passwd -d root
mv /usr/share/anaconda/list-harddrives-stub /usr/bin/list-harddrives
mv /etc/yum.repos.d /etc/anaconda.repos.d
ln -s /lib/systemd/system/anaconda.target /etc/systemd/system/default.target
rm -vf /usr/lib/systemd/system-generators/systemd-gpt-auto-generator
rm -f /usr/lib/systemd/system/autovt@.service
ln -s /usr/lib/systemd/system/anaconda-shell@.service /usr/lib/systemd/system/autovt@.service
mkdir -p /usr/lib/systemd/logind.conf.d
printf '[Login]\nReserveVT=2\n' > /usr/lib/systemd/logind.conf.d/anaconda-shell.conf

# Anaconda defaults: install the (embedded) payload, and when the root is
# encrypted bind it to the TPM and print a recovery key.
cat > /usr/share/anaconda/interactive-defaults.ks <<EOF
bootc --source-imgref containers-storage:${payload_ref} --target-imgref ${payload_ref}

%post --interpreter=/bin/bash --erroronfail
root=\$(findmnt -n -o SOURCE /)
cryptdev=\$(cryptsetup status "\$root" 2>/dev/null | awk '/device:/{print \$2}')
cryptdev=\${cryptdev:-\$(blkid -t TYPE=crypto_LUKS -o device | head -n1)}
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "\$cryptdev"
systemd-cryptenroll --recovery-key "\$cryptdev" | tee /root/recovery-key.txt
%end
EOF

# initramfs with the Anaconda module.
mkdir -p "$(realpath /root)"
kernel=$(kernel-install list --json pretty | jq -r '.[] | select(.has_kernel == true) | .version')
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "anaconda" "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

# ISO menu/config for image-builder.
mkdir -p /usr/lib/image-builder/bootc
cp /src/iso.yaml /usr/lib/image-builder/bootc/iso.yaml
