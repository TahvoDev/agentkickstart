#!/usr/bin/bash
# Prepare the bootc-generic-iso installer container: Anaconda + the kernel
# initramfs + the EFI tree the ISO contract expects. The payload container is
# installed by Anaconda (from the kickstart below), so this container is just
# the installer environment.
set -exo pipefail
payload_ref="${1:?usage: build.sh <payload-ref>}"

dnf install -qy \
    anaconda \
    anaconda-install-img-deps \
    anaconda-dracut \
    dracut-config-generic \
    dracut-network \
    net-tools \
    cryptsetup \
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

# --- erase-and-go kickstart ------------------------------------------------
#
# The kickstart Anaconda loads is REWRITTEN just before Anaconda starts, by the
# picker service below: it asks which internal disk to erase (with a typed
# ERASE confirmation) and fills in the storage lines here. We cannot use %pre +
# %include for this - kickstart %include is expanded at parse time, before
# %pre runs - so the picker rewrites the whole kickstart instead.
#
# The leading 'text' is load-bearing. Anaconda loads this file as the kickstart
# when no inst.ks is given, and a 'text' *from kickstart* sets
# DisplayModeTextKickstarted, which suppresses the interactive RDP question in
# AskRDSpoke. Without it, upstream commit b97165de6f (shipped F43/F44) makes
# apply() unconditionally write a None field to the DBus RDP property, and the
# dasbus write fails with "AnacondaError: Invalid DBus value 'None'" ("Pane is
# dead"). The inst.text on the kernel cmdline boots text mode but does NOT set
# that flag, so it does not avoid the crash on its own. Remove this line once
# https://github.com/rhinstaller/anaconda/pull/6512 is fixed upstream.
mkdir -p /usr/libexec/agentbox-installer
cat > /usr/libexec/agentbox-installer/kickstart.tmpl <<'EOF'
text
@STORAGE@
rootpw --lock
bootc --source-imgref containers-storage:PAYLOAD_REF --target-imgref PAYLOAD_REF

%post --interpreter=/bin/bash --erroronfail
root=$(findmnt -n -o SOURCE /)
cryptdev=$(cryptsetup status "$root" 2>/dev/null | awk '/device:/{print $2}')
cryptdev=${cryptdev:-$(blkid -t TYPE=crypto_LUKS -o device | head -n1)}
# Auto-unlock from the TPM (PCR 7 = Secure Boot state) and print a one-time
# recovery key. The random LUKS passphrase autopart was given stays as a dead
# keyslot nobody holds; TPM + recovery are the real ways in.
# ponytail: leave the random passphrase slot; kill it if slot hygiene matters.
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$cryptdev"
systemd-cryptenroll --recovery-key "$cryptdev" | tee /root/recovery-key.txt
%end
EOF
sed -i "s|PAYLOAD_REF|${payload_ref}|g" /usr/libexec/agentbox-installer/kickstart.tmpl
# A default (interactive-storage) kickstart so the RDP workaround still applies
# if the picker never rewrites it.
sed 's|^@STORAGE@$||' /usr/libexec/agentbox-installer/kickstart.tmpl > /usr/share/anaconda/interactive-defaults.ks

cat > /usr/libexec/agentbox-installer/pick-disk <<'EOF'
#!/bin/bash
# pick-disk - choose the disk to erase, before Anaconda starts.
# Filters out the boot USB / removable media, then requires a typed ERASE.
# Unattended opt-in: kernel arg agentbox.target=/dev/nvme0n1 (or the
# environment variable AGENTBOX_TARGET) skips the prompt.
set -uo pipefail
tmpl=/usr/libexec/agentbox-installer/kickstart.tmpl
ks=/usr/share/anaconda/interactive-defaults.ks

mapfile -t CONSOLES < <(for c in $(cat /sys/class/tty/console/active 2>/dev/null); do printf '/dev/%s\n' "$c"; done)
[ "${#CONSOLES[@]}" -gt 0 ] || CONSOLES=(/dev/console)
emit() { local c; for c in "${CONSOLES[@]}"; do { [ -c "$c" ] && printf '%s\n' "$*" >"$c"; } 2>/dev/null; done; }
ask_read() {
  local fifo; fifo=$(mktemp -u) || return 1
  mkfifo "$fifo" || return 1
  local c pids=()
  for c in "${CONSOLES[@]}"; do
    [ -r "$c" ] || continue
    ( while IFS= read -r line <"$c"; do printf '%s\n' "$line" >"$fifo"; done ) 2>/dev/null &
    pids+=($!)
  done
  local reply; IFS= read -r reply <"$fifo"
  kill "${pids[@]}" 2>/dev/null
  rm -f "$fifo"
  printf '%s' "$reply"
}
fail() { emit "$*"; emit "Refusing to install; the disk is untouched."; exec sleep infinity; }

rand() { head -c 24 /dev/urandom | base64 | tr -d '/+='; }

target=${AGENTBOX_TARGET:-}
for a in $(cat /proc/cmdline); do case "$a" in agentbox.target=*) target=${a#agentbox.target=} ;; esac; done

if [ -n "$target" ]; then
  [ -b "$target" ] || fail "agentbox.target=$target is not a block device"
  pick=$target
else
  mapfile -t devs < <(lsblk -J -d -o NAME,TYPE,RM,TRAN,HOTPLUG 2>/dev/null | jq -r '
    .blockdevices[] | select(.type=="disk" and .rm==false and .hotplug==false and ((.tran//"")!="usb")) | "/dev/"+.name')
  info() { lsblk -J -d -o MODEL,SIZE "$1" 2>/dev/null | jq -r '.blockdevices[0] | "\(.model // "disk")  \(.size)"'; }
  [ "${#devs[@]}" -gt 0 ] || fail "no internal disk found; refusing to guess"
  if [ "${#devs[@]}" -eq 1 ]; then
    pick=${devs[0]}
    emit "Found one internal disk: $pick ($(info "$pick"))"
  else
    emit "Multiple internal disks found:"
    i=1; for d in "${devs[@]}"; do emit "  $i) $d  ($(info "$d"))"; i=$((i+1)); done
    emit "disk to erase [1-${#devs[@]}]:"
    choice=$(ask_read)
    case "$choice" in ''|*[!0-9]*) fail "invalid choice: '$choice'" ;; esac
    { [ "$choice" -ge 1 ] && [ "$choice" -le "${#devs[@]}" ]; } || fail "out of range: $choice"
    pick=${devs[$((choice-1))]}
  fi
  emit "This ERASES everything on $pick ($(info "$pick")) and installs agentbox."
  emit "Type ERASE to continue:"
  confirm=$(ask_read)
  [ "$confirm" = ERASE ] || fail "not confirmed (got '$confirm')"
fi

storage="ignoredisk --only-use=$pick
clearpart --all --initlabel --disklabel=gpt --drives=$pick
autopart --fstype=xfs --encrypted --passphrase=$(rand)"
awk -v s="$storage" '{ print ($0=="@STORAGE@") ? s : $0 }' "$tmpl" > "$ks"
emit "agentbox: erasing $pick and installing; this can take several minutes."
EOF
chmod 0755 /usr/libexec/agentbox-installer/pick-disk

cat > /usr/lib/systemd/system/agentbox-pick.service <<'EOF'
[Unit]
Description=agentbox: choose the disk to erase and install to
After=systemd-vconsole-setup.service
Before=anaconda.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/agentbox-installer/pick-disk
# The script writes to / reads from the console devices itself; give it time.
TimeoutStartSec=infinity

[Install]
WantedBy=anaconda.target
EOF
mkdir -p /etc/systemd/system/anaconda.target.wants
ln -sf /usr/lib/systemd/system/agentbox-pick.service /etc/systemd/system/anaconda.target.wants/agentbox-pick.service

# initramfs with the Anaconda module.
mkdir -p "$(realpath /root)"
kernel=$(kernel-install list --json pretty | jq -r '.[] | select(.has_kernel == true) | .version')
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "anaconda" "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

# ISO menu/config for image-builder.
mkdir -p /usr/lib/image-builder/bootc
cp /src/iso.yaml /usr/lib/image-builder/bootc/iso.yaml
