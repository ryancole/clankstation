# clankstation-install: install Clankstation from the installer ISO.
#
# Fully offline. The ISO carries prebuilt systems and disko scripts for both
# layouts (two disks, one disk). Their disko layouts target the fixed paths
# /dev/clank-boot and /dev/clank-data; this script points those at the disks
# you choose, runs the disko script, then nixos-install --system.
#
# Set by the Nix wrapper:
#   SYSTEM_TWO / DISKO_TWO   system + destroy-format-mount script, two-disk layout
#   SYSTEM_ONE / DISKO_ONE   the same, one-disk layout

usage() {
  cat <<'EOF'
Usage: clankstation-install [options]

Installs Clankstation, erasing the chosen disk(s). Asks for anything not given.

  --boot-disk DEV       Disk for the OS (EFI + root), e.g. /dev/nvme0n1
  --data-disk DEV|none  Separate disk for /var/lib/clankstation (recommended),
                        or "none" to put data on the boot disk
  --ssh-key KEY         SSH public key for the admin user
  --ssh-key-file FILE   ...or read it from a file
  --yes                 Don't ask for confirmation (erases the disks!)
  --no-reboot           Don't reboot at the end
EOF
}

die() {
  echo "clankstation-install: $*" >&2
  exit 1
}

boot_disk=''
data_disk=''
ssh_key=''
yes=false
reboot=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --boot-disk) boot_disk="${2:-}"; shift 2 ;;
    --data-disk) data_disk="${2:-}"; shift 2 ;;
    --ssh-key) ssh_key="${2:-}"; shift 2 ;;
    --ssh-key-file) ssh_key=$(cat "${2:-/dev/null}") || die "can't read ${2:-}"; shift 2 ;;
    --yes) yes=true; shift ;;
    --no-reboot) reboot=false; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root: sudo clankstation-install"
[ -d /sys/firmware/efi ] ||
  die "this machine booted the installer in legacy BIOS mode; Clankstation needs UEFI. Enable UEFI boot in the firmware settings and boot the USB stick again."

interactive=false
if [ -t 0 ]; then interactive=true; fi

# Disks we could install to: whole disks, not the installer's own USB stick.
live_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /iso 2>/dev/null)" 2>/dev/null || true)
mapfile -t candidates < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" { print $1 }' |
  grep -v -x -F "/dev/${live_disk:-none}" || true)

describe() {
  lsblk -dno SIZE,MODEL "$1" | sed 's/  */ /g'
}

pick_disk() {
  local prompt="$1" allow_none="$2" i choice
  echo >&2
  for i in "${!candidates[@]}"; do
    printf '  %d) %s  %s\n' "$((i + 1))" "${candidates[$i]}" "$(describe "${candidates[$i]}")" >&2
  done
  if [ "$allow_none" = true ]; then echo "  0) none: put data on the boot disk" >&2; fi
  while true; do
    read -r -p "$prompt " choice
    if [ "$allow_none" = true ] && [ "$choice" = 0 ]; then echo none; return; fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
      echo "${candidates[$((choice - 1))]}"
      return
    fi
    echo "Pick a number from the list." >&2
  done
}

[ "${#candidates[@]}" -gt 0 ] || die "no disks found"

if [ -z "$boot_disk" ]; then
  [ "$interactive" = true ] || die "--boot-disk is required"
  echo "Which disk should hold the OS?"
  boot_disk=$(pick_disk "OS disk:" false)
fi
if [ -z "$data_disk" ]; then
  if [ "${#candidates[@]}" -gt 1 ] && [ "$interactive" = true ]; then
    echo "Which disk should hold Clankstation's data (projects, tasks, Docker, VM images)?"
    data_disk=$(pick_disk "Data disk:" true)
  else
    data_disk=none
  fi
fi

check_disk() {
  [ -b "$1" ] || die "$1 is not a block device"
  [ "$(lsblk -dno TYPE "$1")" = disk ] || die "$1 is not a whole disk"
  [ "$1" != "/dev/${live_disk:-none}" ] || die "$1 is the installer's own USB stick"
}
check_disk "$boot_disk"
if [ "$data_disk" != none ]; then check_disk "$data_disk"; fi
[ "$boot_disk" != "$data_disk" ] || die "the OS disk and the data disk must be different"

if [ -z "$ssh_key" ] && [ "$interactive" = true ]; then
  echo
  echo "Paste an SSH public key for the admin user (one line, from e.g. ~/.ssh/id_ed25519.pub),"
  echo "or press Enter to set a console password instead."
  read -r -p "> " ssh_key
fi
if [ -n "$ssh_key" ]; then
  case "$ssh_key" in
    ssh-* | ecdsa-* | sk-*) ;;
    *) die "that doesn't look like an SSH public key" ;;
  esac
fi

echo
echo "About to install Clankstation:"
echo "  OS disk:   $boot_disk ($(describe "$boot_disk"))"
if [ "$data_disk" = none ]; then
  echo "  Data:      on the OS disk"
else
  echo "  Data disk: $data_disk ($(describe "$data_disk"))"
fi
echo "  Admin login: ${ssh_key:+SSH key}${ssh_key:-console password (set below)}"
echo
echo "ALL DATA on the disk(s) above will be erased."
if [ "$yes" != true ]; then
  [ "$interactive" = true ] || die "refusing to erase disks without --yes"
  read -r -p "Type ERASE to continue: " answer
  [ "$answer" = ERASE ] || die "aborted"
fi

if [ "$data_disk" = none ]; then
  system=$SYSTEM_ONE disko=$DISKO_ONE
else
  system=$SYSTEM_TWO disko=$DISKO_TWO
  ln -sfn "$data_disk" /dev/clank-data
fi
ln -sfn "$boot_disk" /dev/clank-boot

echo "== Partitioning and formatting"
"$disko" --yes-wipe-all-disks

echo "== Installing"
nixos-install --system "$system" --root /mnt --no-root-passwd --no-channel-copy

if [ -n "$ssh_key" ]; then
  # admin is uid 1000, group users (100); see modules/base.nix.
  install -d -m 0700 -o 1000 -g 100 /mnt/home/admin /mnt/home/admin/.ssh
  printf '%s\n' "$ssh_key" >/mnt/home/admin/.ssh/authorized_keys
  chown 1000:100 /mnt/home/admin/.ssh/authorized_keys
  chmod 0600 /mnt/home/admin/.ssh/authorized_keys
else
  echo "Set a password for the admin user (console login only; SSH needs a key):"
  nixos-enter --root /mnt -c 'passwd admin'
fi

umount -R /mnt
rm -f /dev/clank-boot /dev/clank-data
echo
echo "Clankstation is installed. Remove the USB stick; it will be at clankstation.local."
echo "  ssh admin@clankstation.local"
if [ "$reboot" = true ]; then
  read -r -t 15 -p "Rebooting in 15 seconds (Enter to reboot now)... " _ || true
  reboot
fi
