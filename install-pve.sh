#!/usr/bin/env bash
# Run in Hetzner Linux Rescue. BIOS only. ERASES BOTH selected NVMe disks.
# Linear learning script: no functions. Reboots automatically after verification.
#
# Changes vs. previous version:
#  - QEMU boots the installer kernel/initrd directly (copied from the auto ISO) with a
#    serial console added, so installer output is visible on -serial stdio. Previously
#    output stopped at "Loading initial ramdisk ..." while the installer ran unseen.
#    The ISO itself is not rebuilt (xorriso cannot repack this hybrid image).
#  - The install QEMU runs under a timeout, so a stuck installer stops the script
#    safely instead of waiting forever.
#  - The install QEMU also exposes a localhost-only VNC screen as an optional fallback.
#  - Must run inside tmux/screen, so an SSH disconnect cannot kill the install.
set -Eeuo pipefail
umask 077
trap 'echo "ERROR at line $LINENO. Installation stopped; no automatic reboot. Log file: /root/proxmox-simple/run.log" >&2' ERR

# 1. Server settings. Verify these before running.
FQDN='pve-hetzner.aymantech.net'
EMAIL=''                           # Empty means ask at startup.
COUNTRY='de'
TIMEZONE='Europe/Amsterdam'
IP_CIDR='162.55.94.253/26'
GATEWAY='162.55.94.193'
DNS='1.1.1.1'
MAC='f0:2f:74:82:27:12'
SERIAL1='61MF728TFQH1'
SERIAL2='61MF727RFQH1'
PUBLIC_KEY_FILE='/root/admin.pub'
ISO_URL='https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso'
ISO_SHA256=''                      # Empty means ask for the official checksum.
INSTALL_TIMEOUT='45m'              # Max time for the unattended installer run.
ZFS_RAID='raid0'                   # raid0 = stripe both disks (full capacity, NO redundancy); raid1 = mirror.
WORK='/root/proxmox-simple'
BUILD='/root/proxmox-trixie-build'

# 2. Check the environment before changing anything.
if [[ $ZFS_RAID != raid0 && $ZFS_RAID != raid1 ]]; then echo 'STOP: ZFS_RAID must be raid0 or raid1.'; exit 1; fi
echo '[2/12] Checking Rescue, BIOS mode, disks, and network...'
if [[ $EUID != 0 || $(hostname -s) != rescue || -d /sys/firmware/efi ]]; then
    echo 'STOP: requires root in Hetzner Rescue, booted in BIOS/Legacy mode.'; exit 1
fi
# A dropped SSH connection kills a foreground script AND the QEMU installer with it.
# Inside tmux/screen the install keeps running; reconnect with: tmux attach -t pve
if [[ -z ${TMUX:-} && -z ${STY:-} ]]; then
    echo 'STOP: run this inside tmux so an SSH disconnect cannot kill the install:'
    echo '      tmux new -s pve'
    echo '      bash /root/install-proxmox-hetzner.sh'
    echo 'After a disconnect, reconnect and run: tmux attach -t pve'; exit 1
fi
# NVMe numbering can swap between boots: resolve the intended disks by serial.
DISK1=$(lsblk -dn -o PATH,SERIAL | awk -v serial="$SERIAL1" '$2 == serial {print $1}')
DISK2=$(lsblk -dn -o PATH,SERIAL | awk -v serial="$SERIAL2" '$2 == serial {print $1}')
if [[ ! $DISK1 =~ ^/dev/nvme[0-9]+n[0-9]+$ || ! $DISK2 =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
    lsblk -d -o NAME,MODEL,SERIAL
    echo 'STOP: expected NVMe serials were not found uniquely.'; exit 1
fi
if [[ ! -c /dev/kvm || ! -b $DISK1 || ! -b $DISK2 || $DISK1 == "$DISK2" ]]; then
    echo 'STOP: KVM or the two target disks are unavailable.'; exit 1
fi
if [[ $(lsblk -dn -o SERIAL "$DISK1" | xargs) != "$SERIAL1" ||
      $(lsblk -dn -o SERIAL "$DISK2" | xargs) != "$SERIAL2" ]]; then
    lsblk -d -o NAME,MODEL,SERIAL
    echo 'STOP: disk names and expected serials do not match. Correct the settings.'; exit 1
fi
if [[ ! -s $PUBLIC_KEY_FILE ]]; then echo "STOP: upload your public SSH key to $PUBLIC_KEY_FILE"; exit 1; fi
ssh-keygen -lf "$PUBLIC_KEY_FILE"
PUBLIC_KEY=$(awk 'NR == 1 {print $1 " " $2}' "$PUBLIC_KEY_FILE")
[[ $PUBLIC_KEY =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+$ ]]
ip -o -4 addr show | grep -F " $IP_CIDR " >/dev/null
grep -Fxq "$MAC" /sys/class/net/*/address
# Rescue needs no ZFS module: the installed Proxmox kernel performs verification.
for TOOL in flock openssl ssh-keygen ssh timeout; do
    if ! command -v "$TOOL" >/dev/null; then echo "STOP: Rescue lacks $TOOL; no installation started."; exit 1; fi
done
# If a different Rescue environment has already imported pools, stop safely.
if [[ -d /proc/spl/kstat/zfs ]] && command -v zpool >/dev/null; then
    if [[ -n $(zpool list -H -o name) ]]; then
        echo 'STOP: a ZFS pool is already imported. Export it safely first.'; exit 1
    fi
fi
mkdir -p "$WORK"
chmod 700 "$WORK"
exec 9>"$WORK/run.lock"
if ! flock -n 9; then echo 'STOP: this installer is already running.'; exit 1; fi
if [[ -e $WORK/install.started ]]; then
    echo 'STOP: disk installation was already attempted in this Rescue session.'
    echo 'Inspect the logs; refusing to erase the disks again automatically.'; exit 1
fi

# 3. Ask all questions now. Password mistakes cause no download or disk write.
echo '[3/12] Installation settings...'
if [[ -z $EMAIL ]]; then read -r -p 'Email for Proxmox alerts: ' EMAIL; fi
if [[ -z $ISO_SHA256 ]]; then read -r -p 'Official SHA256 for proxmox-ve_9.1-1.iso: ' ISO_SHA256; fi
[[ $EMAIL =~ ^[A-Za-z0-9._+%-]+@[A-Za-z0-9.-]+$ ]] || { echo 'STOP: invalid email.'; exit 1; }
[[ $ISO_SHA256 =~ ^[a-fA-F0-9]{64}$ ]] || { echo 'STOP: SHA256 must contain 64 hexadecimal characters.'; exit 1; }
read -r -s -p 'New Proxmox root password: ' PASSWORD; echo
read -r -s -p 'Repeat password: ' PASSWORD_AGAIN; echo
if [[ -z $PASSWORD ]]; then echo 'STOP: password cannot be empty.'; exit 1; fi
if [[ $PASSWORD != "$PASSWORD_AGAIN" ]]; then echo 'STOP: passwords do not match. Run the script again.'; exit 1; fi
PASSWORD_HASH=$(printf '%s\n' "$PASSWORD" | openssl passwd -6 -stdin)
unset PASSWORD PASSWORD_AGAIN
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
printf '\nERASE %s (%s) and %s (%s). Install Proxmox with ZFS %s.\n' "$DISK1" "$SERIAL1" "$DISK2" "$SERIAL2" "${ZFS_RAID^^}"
if [[ $ZFS_RAID == raid0 ]]; then
    echo 'WARNING: RAID0 stripes both disks into one pool. If EITHER disk fails, the server'
    echo '         will not boot and ALL data (OS and VMs) is lost. Keep backups elsewhere.'
fi
echo 'Idle RAID arrays on ONLY these disks will be stopped. The server will reboot after verification.'
read -r -p 'Type ERASE BOTH DISKS to begin: ' CONFIRM
if [[ $CONFIRM != 'ERASE BOTH DISKS' ]]; then echo 'Cancelled.'; exit 1; fi
exec > >(tee -a "$WORK/run.log") 2>&1

# 4. Install Rescue tools and reuse an already downloaded, verified ISO.
echo '[4/12] Installing build tools and verifying ISO...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y debootstrap curl ca-certificates openssl qemu-system-x86 mdadm parted
if [[ ! -f $WORK/proxmox.iso ]]; then
    curl --fail --location --retry 3 "$ISO_URL" -o "$WORK/proxmox.iso.part"
    mv "$WORK/proxmox.iso.part" "$WORK/proxmox.iso"
fi
printf '%s  %s\n' "$ISO_SHA256" "$WORK/proxmox.iso" | sha256sum -c -

# 5. Generate answers. The password hash stays private; never print this file.
echo '[5/12] Writing installer answers...'
# Temporary key is used only for local test boot, then removed from Proxmox.
if [[ ! -f $WORK/verify-key ]]; then
    ssh-keygen -q -t ed25519 -N '' -C rescue-verification -f "$WORK/verify-key"
fi
VERIFY_PUBLIC_KEY=$(awk 'NR == 1 {print $1 " " $2}' "$WORK/verify-key.pub")
cat > "$WORK/answer.toml" <<EOF
[global]
keyboard = "en-us"
country = "$COUNTRY"
fqdn = "$FQDN"
mailto = "$EMAIL"
timezone = "$TIMEZONE"
root-password-hashed = '$PASSWORD_HASH'
root-ssh-keys = ["$PUBLIC_KEY", "$VERIFY_PUBLIC_KEY"]
reboot-mode = "power-off"

[network]
source = "from-answer"
cidr = "$IP_CIDR"
gateway = "$GATEWAY"
dns = "$DNS"
filter.ID_NET_NAME_MAC = "*${MAC//:/}"

[network.interface-name-pinning]
enabled = true

[network.interface-name-pinning.mapping]
"$MAC" = "nic0"

[disk-setup]
filesystem = "zfs"
zfs.raid = "$ZFS_RAID"
disk-list = ["nvme0n1", "nvme1n1"]
EOF

# 6. Create or reuse the Trixie build environment.
echo '[6/12] Preparing Trixie build environment...'
if [[ ! -e $BUILD ]]; then
    debootstrap --arch=amd64 trixie "$BUILD" http://deb.debian.org/debian
elif [[ ! -x $BUILD/bin/bash || ! -f $BUILD/etc/debian_version || -d $BUILD/debootstrap ]]; then
    echo 'STOP: an incomplete build environment exists; inspect it before continuing.'; exit 1
fi
mkdir -p "$BUILD/work"
if ! mountpoint -q "$BUILD/work"; then mount --bind "$WORK" "$BUILD/work"; fi
trap 'if mountpoint -q "$BUILD/work"; then umount "$BUILD/work"; fi' EXIT
cp -L /etc/resolv.conf "$BUILD/etc/resolv.conf"

# 7. Repair permissions BEFORE apt update, including on a retry.
echo '[7/12] Installing assistant and building unattended ISO...'
chroot "$BUILD" /bin/bash <<'CHROOT'
set -euo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
for FILE in /usr/share/keyrings/proxmox-archive-keyring.gpg /etc/apt/sources.list.d/proxmox.sources; do
    if [[ -f $FILE ]]; then chmod 644 "$FILE"; fi
done
apt-get update
apt-get install -y curl ca-certificates
curl -fsS https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -o /usr/share/keyrings/proxmox-archive-keyring.gpg
chmod 644 /usr/share/keyrings/proxmox-archive-keyring.gpg
cat > /etc/apt/sources.list.d/proxmox.sources <<'REPO'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
REPO
chmod 644 /etc/apt/sources.list.d/proxmox.sources
apt-get update
apt-get install -y proxmox-auto-install-assistant xorriso
proxmox-auto-install-assistant validate-answer /work/answer.toml
# Remove only previously GENERATED files; keep the downloaded original ISO.
rm -f /work/proxmox-auto.iso /work/proxmox-auto-serial.iso /work/grub.cfg \
      /work/installer-kernel /work/installer-initrd /work/installer-cmdline
proxmox-auto-install-assistant prepare-iso /work/proxmox.iso \
  --fetch-from iso --answer-file /work/answer.toml --output /work/proxmox-auto.iso
chmod 600 /work/proxmox-auto.iso

# The ISO is NOT rebuilt (xorriso cannot rewrite this hybrid image's partition table).
# Instead, copy out the installer kernel + initrd of the "Automated" boot entry and let
# QEMU boot them directly with a serial console added. The unmodified auto ISO stays
# attached as CD-ROM, so the installer still finds its packages and the answer file.
xorriso -osirrox on -indev /work/proxmox-auto.iso -extract /boot/grub/grub.cfg /work/grub.cfg
AUTO_LINE=$(grep -m1 -E '^[[:space:]]*linux[[:space:]].*proxmox-start-auto-installer' /work/grub.cfg || true)
INITRD_PATH=$(awk '/proxmox-start-auto-installer/ {found = 1} found && $1 == "initrd" {print $2; exit}' /work/grub.cfg)
if [[ -z $AUTO_LINE || -z $INITRD_PATH ]]; then
    echo 'STOP: automated boot entry not found in the ISO boot menu.'; exit 1
fi
read -r _ KERNEL_PATH KERNEL_ARGS <<< "$AUTO_LINE"
KERNEL_ARGS=" $KERNEL_ARGS "
KERNEL_ARGS=${KERNEL_ARGS// quiet / }
KERNEL_ARGS=${KERNEL_ARGS// splash=silent / }
KERNEL_ARGS=$(echo $KERNEL_ARGS)
# ttyS0 last, so installer output goes to the serial port (/dev/console).
KERNEL_ARGS="$KERNEL_ARGS console=tty0 console=ttyS0,115200"
xorriso -osirrox on -indev /work/proxmox-auto.iso \
  -extract "$KERNEL_PATH" /work/installer-kernel \
  -extract "$INITRD_PATH" /work/installer-initrd
printf '%s\n' "$KERNEL_ARGS" > /work/installer-cmdline
chmod 600 /work/installer-kernel /work/installer-initrd /work/installer-cmdline
rm -f /work/grub.cfg
echo "Installer kernel: $KERNEL_PATH  initrd: $INITRD_PATH"
echo "Installer cmdline: $KERNEL_ARGS"
CHROOT
for FILE in proxmox-auto.iso installer-kernel installer-initrd installer-cmdline; do
    if [[ ! -s $WORK/$FILE ]]; then echo "STOP: $WORK/$FILE was not created."; exit 1; fi
done
grep -q 'proxmox-start-auto-installer' "$WORK/installer-cmdline"
umount "$BUILD/work"
trap - EXIT

# 8. Release old mdraid on the two authorized disks only.
echo '[8/12] Checking old storage and releasing idle RAID arrays...'
if pgrep -f '[q]emu-system-' >/dev/null; then echo 'STOP: another QEMU process is running.'; exit 1; fi
# Stop BEFORE changing storage if any filesystem on the target hierarchy is mounted.
while read -r DEVICE; do
    if findmnt -rn -S "$DEVICE" >/dev/null; then echo "STOP: $DEVICE is mounted."; exit 1; fi
done < <(lsblk -nrpo NAME "$DISK1" "$DISK2" | sort -u)
# Refuse RAID devices that also use a third disk.
mapfile -t ARRAYS < <(lsblk -nrpo NAME,TYPE "$DISK1" "$DISK2" | awk '$2 ~ /^raid/ {print $1}' | sort -u)
for ARRAY in "${ARRAYS[@]}"; do
    for MEMBER in /sys/class/block/"${ARRAY##*/}"/slaves/*; do
        PARENT=$(lsblk -dn -o PKNAME "/dev/${MEMBER##*/}")
        if [[ /dev/$PARENT != "$DISK1" && /dev/$PARENT != "$DISK2" ]]; then
            echo "STOP: $ARRAY has a member outside the selected disks."; exit 1
        fi
    done
done
while read -r DEVICE; do
    if swapon --noheadings --show=NAME | grep -Fxq "$DEVICE"; then swapoff "$DEVICE"; fi
done < <(lsblk -nrpo NAME "$DISK1" "$DISK2" | sort -u)
for ARRAY in "${ARRAYS[@]}"; do mdadm --stop "$ARRAY"; done
for DISK in "$DISK1" "$DISK2"; do
    while read -r DEVICE; do
        for HOLDER in /sys/class/block/"${DEVICE##*/}"/holders/*; do
            if [[ -e $HOLDER ]]; then echo "STOP: $DEVICE still has holder $HOLDER."; exit 1; fi
        done
    done < <(lsblk -nrpo NAME "$DISK")
done
[[ $(lsblk -dn -o SERIAL "$DISK1" | xargs) == "$SERIAL1" ]]
[[ $(lsblk -dn -o SERIAL "$DISK2" | xargs) == "$SERIAL2" ]]

# 9. Start the destructive installation exactly once per Rescue session.
echo "[9/12] Installing Proxmox onto BOTH disks (takes ~10-20 min, limit $INSTALL_TIMEOUT)..."
echo 'Installer output follows. Optional live screen: ssh -L 5900:127.0.0.1:5900 root@<server>, then VNC to localhost:5900.'
KERNEL_CMDLINE=$(cat "$WORK/installer-cmdline")
touch "$WORK/install.started"
# If the installer hangs, timeout kills QEMU; pipefail + the ERR trap stop the script
# before the test boot or any physical reboot.
# --foreground and </dev/null: without them timeout puts QEMU in a background process
# group, and QEMU's -serial stdio terminal setup gets it STOPPED by the kernel (SIGTTOU),
# which looks like a silent hang at 0% CPU.
timeout --foreground --kill-after=30s "$INSTALL_TIMEOUT" qemu-system-x86_64 \
  -enable-kvm -cpu host -machine q35 -m 8192 \
  -drive "file=$DISK1,format=raw,if=none,id=drive0" \
  -device nvme,drive=drive0,serial=install0 \
  -drive "file=$DISK2,format=raw,if=none,id=drive1" \
  -device nvme,drive=drive1,serial=install1 \
  -kernel "$WORK/installer-kernel" -initrd "$WORK/installer-initrd" \
  -append "$KERNEL_CMDLINE" \
  -cdrom "$WORK/proxmox-auto.iso" \
  -netdev user,id=net0 -device "virtio-net-pci,netdev=net0,mac=$MAC" \
  -vnc 127.0.0.1:0 -monitor none -serial stdio -no-reboot \
  </dev/null 2>&1 | tee "$WORK/install.log"

# 10. Test boot the installed disks with Proxmox's OWN kernel and ZFS support.
echo '[10/12] Test-booting Proxmox and checking its services through local SSH...'
trap 'echo "STOPPED at line $LINENO during verification. Proxmox itself was installed; the server was NOT rebooted. Details: /root/proxmox-simple/run.log" >&2' ERR
# Use the configured subnet inside QEMU so Proxmox's static IP works.
# This is isolated user networking, not a bridge onto Hetzner's network.
IFS=. read -r A B C D <<< "${IP_CIDR%/*}"
PREFIX=${IP_CIDR#*/}
[[ $PREFIX =~ ^[0-9]+$ ]] && (( PREFIX >= 8 && PREFIX <= 29 ))
ADDRESS=$(( (10#$A << 24) | (10#$B << 16) | (10#$C << 8) | 10#$D ))
NETWORK=$(( ADDRESS & (0xffffffff << (32-PREFIX)) & 0xffffffff ))
printf -v QEMU_NETWORK '%d.%d.%d.%d/%d' "$((NETWORK >> 24 & 255))" "$((NETWORK >> 16 & 255))" "$((NETWORK >> 8 & 255))" "$((NETWORK & 255))" "$PREFIX"
# A DNS proxy address within this isolated subnet, distinct from guest/gateway.
DNS_NUMBER=$((NETWORK + 3))
printf -v QEMU_DNS '%d.%d.%d.%d' "$((DNS_NUMBER >> 24 & 255))" "$((DNS_NUMBER >> 16 & 255))" "$((DNS_NUMBER >> 8 & 255))" "$((DNS_NUMBER & 255))"
[[ $QEMU_DNS != "$GATEWAY" && $QEMU_DNS != "${IP_CIDR%/*}" ]]
# Binding failure (e.g. occupied port) makes this QEMU exit and blocks reboot.
qemu-system-x86_64 \
  -enable-kvm -cpu host -machine q35 -m 8192 \
  -drive "file=$DISK1,format=raw,if=none,id=drive0" \
  -device nvme,drive=drive0,serial=install0 \
  -drive "file=$DISK2,format=raw,if=none,id=drive1" \
  -device nvme,drive=drive1,serial=install1 \
  -boot order=c \
  -netdev "user,id=net0,net=$QEMU_NETWORK,host=$GATEWAY,dns=$QEMU_DNS,dhcpstart=${IP_CIDR%/*},restrict=on,hostfwd=tcp:127.0.0.1:2222-${IP_CIDR%/*}:22" \
  -device "virtio-net-pci,netdev=net0,mac=$MAC" \
  -display none -monitor none -serial "file:$WORK/verify-console.log" -no-reboot \
  >"$WORK/verify-qemu.log" 2>&1 &
VERIFY_PID=$!
# Trust is first-use only on this localhost port, created by our own QEMU.
# Do not disable host-key checks on the server's public SSH connection.
SSH_OPTIONS=(-p 2222 -i "$WORK/verify-key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o ConnectTimeout=5 -o ConnectionAttempts=1
             -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/verify-known-hosts")
READY=no
for ATTEMPT in {1..90}; do
    if ! kill -0 "$VERIFY_PID" 2>/dev/null; then
        cat "$WORK/verify-qemu.log"; echo 'STOP: test-boot QEMU exited early.'; exit 1
    fi
    if ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 true 2>/dev/null; then READY=yes; break; fi
    sleep 5
done
if [[ $READY != yes ]]; then
    echo "STOP: test boot did not become reachable. Check $WORK/verify-console.log."
    echo "Verification QEMU remains running (PID $VERIFY_PID); physical reboot was cancelled."; exit 1
fi
# Send expected values through SSH stdin, never in process-list password arguments.
{
    printf 'EXPECTED_HASH=%q\n' "$PASSWORD_HASH"
    printf 'EXPECTED_HOST=%q\n' "${FQDN%%.*}"
    printf 'EXPECTED_IP=%q\n' "$IP_CIDR"
    printf 'EXPECTED_MAC=%q\n' "$MAC"
    printf 'EXPECTED_RAID=%q\n' "$ZFS_RAID"
    printf 'TEMP_PUBLIC=%q\n' "$VERIFY_PUBLIC_KEY"
    printf 'ADMIN_PUBLIC=%q\n' "$PUBLIC_KEY"
    cat <<'VERIFY'
set -Eeuo pipefail
# CRITICAL checks: if one fails, the install is not trustworthy and the script stops.
trap 'echo "CRITICAL CHECK FAILED inside test VM: $BASH_COMMAND" >&2' ERR
echo "Kernel: $(uname -r)";            uname -r | grep -q -- '-pve$'
echo "Hostname: $(hostname -s)";       [[ $(hostname -s) == "$EXPECTED_HOST" ]]
[[ $(awk -F: '$1 == "root" {print $2}' /etc/shadow) == "$EXPECTED_HASH" ]] && echo 'Root password: as configured'
echo "ZFS rpool: $(zpool list -H -o health rpool)"
[[ $(zpool list -H -o health rpool) == ONLINE ]]
# Both disks must be in the pool: 2 leaf devices, striped (raid0) or in a mirror (raid1).
echo "ZFS disks in rpool: $(zpool list -v -H -P rpool | grep -c '/dev/')"
[[ $(zpool list -v -H -P rpool | grep -c '/dev/') -eq 2 ]]
MIRRORS=$(zpool status rpool | grep -c 'mirror-' || true)
echo "ZFS layout: $MIRRORS mirror vdev(s), expected $EXPECTED_RAID"
if [[ $EXPECTED_RAID == raid1 ]]; then [[ $MIRRORS -ge 1 ]]; else [[ $MIRRORS -eq 0 ]]; fi
ip -o -4 addr show | grep -qF " $EXPECTED_IP " && echo "IP: $EXPECTED_IP"
grep -Fq "$ADMIN_PUBLIC" /root/.ssh/authorized_keys && echo 'Admin SSH key: present'
trap - ERR

# NON-CRITICAL checks: first-boot timing in the nested test VM can make these fail even
# though the real server comes up fine. They are reported as warnings, never as errors.
WARNINGS=0
NIC_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || echo missing)
if [[ $NIC_MAC == "$EXPECTED_MAC" ]]; then echo "nic0 MAC: $NIC_MAC"
else echo "WARNING: nic0 MAC is '$NIC_MAC', expected $EXPECTED_MAC"; WARNINGS=$((WARNINGS + 1)); fi
echo 'Waiting for Proxmox services and web UI (up to 5 minutes)...'
for ATTEMPT in {1..60}; do
    HTTP=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:8006/ || true)
    if systemctl is-active --quiet pve-cluster && systemctl is-active --quiet pvedaemon &&
       systemctl is-active --quiet pveproxy && [[ $HTTP == 200 ]]; then break; fi
    sleep 5
done
for SERVICE in pve-cluster pvedaemon pveproxy; do
    STATE=$(systemctl is-active "$SERVICE" || true)
    if [[ $STATE == active ]]; then echo "Service $SERVICE: active"
    else echo "WARNING: service $SERVICE is '$STATE' in the test VM"; WARNINGS=$((WARNINGS + 1)); fi
done
# The web UI login page needs no authentication (the /api2 endpoints return 401 without login).
HTTP=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1:8006/ || true)
if [[ $HTTP == 200 ]]; then echo 'Web UI: HTTP 200'
else echo "WARNING: web UI returned HTTP '$HTTP' in the test VM"; WARNINGS=$((WARNINGS + 1)); fi

echo 'SSH host key fingerprints (save these):'
for KEY in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$KEY"; done
# Remove only the temporary verification key; the admin key was confirmed above.
awk -v key="$TEMP_PUBLIC" 'index($0, key) != 1' /root/.ssh/authorized_keys > /root/authorized-keys.checked
cat /root/authorized-keys.checked > /root/.ssh/authorized_keys
rm /root/authorized-keys.checked
if (( WARNINGS == 0 )); then
    echo 'VERIFIED: boot, password, ZFS pool, network, services and web UI all OK.'
else
    echo "VERIFIED with $WARNINGS warning(s): critical checks passed; recheck the warnings after reboot."
fi
nohup sh -c 'sleep 3; systemctl poweroff' >/dev/null 2>&1 </dev/null &
VERIFY
} | ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 bash -s | tee "$WORK/verification.log"

# 11. Wait for a clean guest shutdown before booting the physical server.
echo '[11/12] Waiting for verified Proxmox guest to power off...'
for ATTEMPT in {1..60}; do
    if ! kill -0 "$VERIFY_PID" 2>/dev/null; then break; fi
    sleep 2
done
if kill -0 "$VERIFY_PID" 2>/dev/null; then
    echo 'STOP: guest did not shut down; physical reboot cancelled.'; exit 1
fi
wait "$VERIFY_PID"
rm -f "$WORK/verify-key" "$WORK/verify-key.pub"
touch "$WORK/verified"
echo 'Copy the SSH fingerprints above and save this terminal output before disconnecting.'
echo "After reboot, connect to https://${IP_CIDR%/*}:8006 with root / Linux PAM."
echo 'The test boot does not verify physical firmware disk selection or external firewall rules.'

# 12. Reboot the physical server. No further prompt is needed.
echo '[12/12] Rebooting in 30 seconds. Ctrl+C cancels the reboot.'
sleep 30
sync
systemctl reboot