# Hetzner Rescue → Debian 13 → Proxmox VE

This repository contains a script that helps in deploying Proxmox VE on Hertzner server.

The script can be executed after manually activating the Linux rescue mode on Hertzner and acquiring the new root password.

**This is destructive provisioning for a fresh install. Do not run installation mode against your current working server unless you intend to erase BOTH selected disks.**

## Prerequistes
1- Actiate the Linux rescue mode on the Hetzner server.
2- Save the root password that you will get after activating the linux rescue mode.

## Steps
1- From your laptop, upload the script and your public SSH key:

```bash
$ scp install-pve.sh root@162.55.94.253:/root/
$ scp ~/.ssh/id_ed25519.pub root@162.55.94.253:/root/admin.pub
```

2- Connect using the Rescue password:

```bash
$ ssh root@162.55.94.253
```

3- Install `tmux`

```bash
$ apt install tmux
```

4- Run the command

```bash
tmux new -s pve
```

5- Update the email and the SHA of the Proxmox VE iso

```bash
# Get the SHA
curl -fsSL https://enterprise.proxmox.com/iso/SHA256SUMS | grep proxmox-ve_9.1-1.iso
# Update the install-pve.sh script with the SHA value
```

6- run the installation script

```bash
$ bash /root/install-pve.sh
```

7- You will be prompted to enter the Proxmox root password

```bash
[2/12] Checking Rescue, BIOS mode, disks, and network...
3072 SHA256:bP+RldVrmoiAejKWdoHksFRfH+PcyPQCMoX0F0SW8fY mayman@Mohameds-MacBook-Pro-2.local (RSA)
[3/12] Installation settings...
New Proxmox root password:
Repeat password:
```

8- It will ask your confirmation to erase all the disks

```bash
NAME          SIZE MODEL                SERIAL       FSTYPE            MOUNTPOINTS
loop0         3.8G                                   ext2
nvme1n1     953.9G KXG60ZNV1T02 TOSHIBA 61MF727RFQH1
├─nvme1n1p1     4G                                   linux_raid_member
│ └─md0         4G                                   swap
├─nvme1n1p2     1G                                   linux_raid_member
│ └─md1      1022M                                   ext3
└─nvme1n1p3 948.9G                                   linux_raid_member
  └─md2     948.7G                                   ext4
nvme0n1     953.9G KXG60ZNV1T02 TOSHIBA 61MF728TFQH1
├─nvme0n1p1     4G                                   linux_raid_member
│ └─md0         4G                                   swap
├─nvme0n1p2     1G                                   linux_raid_member
│ └─md1      1022M                                   ext3
└─nvme0n1p3 948.9G                                   linux_raid_member
  └─md2     948.7G                                   ext4

ERASE /dev/nvme0n1 (61MF728TFQH1) and /dev/nvme1n1 (61MF727RFQH1). Install Proxmox with ZFS RAID1.
Idle RAID arrays on ONLY these disks will be stopped. The server will reboot after verification.
Type ERASE BOTH DISKS to begin: ERASE BOTH DISKS
```