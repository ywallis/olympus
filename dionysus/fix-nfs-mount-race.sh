#!/bin/bash
#
# Repair stale NFS bind mounts on dionysus, and stop them recurring.
#
# dockerd raced mnt-media.mount at boot and won, so every bind under
# /mnt/media resolved to the empty directory on the root filesystem
# underneath the mountpoint. Bind mounts resolve once, at container start,
# so the containers stayed pinned to local disk and filled it.
#
# Deletes the orphaned downloads from both the shadowed local folder and the
# NAS share. It does not migrate anything. Dry run unless given --apply.
#
# Run it on the host, not over a pipe: --apply needs a terminal to confirm on,
# and ssh will not allocate one when stdin is redirected.
#
#   ./fix-nfs-mount-race.sh
#   sudo ./fix-nfs-mount-race.sh --apply
#
set -euo pipefail

APPLY=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

TARGET_USER="${SUDO_USER:-$(whoami)}"
COMPOSE_DIR="/home/$TARGET_USER/olympus/dionysus"
# Falls back when piped in over stdin, which is how this runs when the root
# filesystem is too full to copy it.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$COMPOSE_DIR/fix-nfs-mount-race.sh}")" && pwd)"
NAS_OPTS="_netdev,nofail,hard,timeo=600,retrans=2"
MOUNTS=(/mnt/media /mnt/immich)
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN="$DROPIN_DIR/wait-for-nfs.conf"
ROOTVIEW=""
AFFECTED=(deluge sonarr radarr bazarr shelfmark)
SHADOWED=("Downloads" "Movies" "TV Shows" "Books/book_dock" "Books/library")

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() {
  if [ "$APPLY" -eq 1 ]; then
    "$@"
  else
    printf '    [dry-run] %s\n' "$*"
  fi
}

# Talks to the terminal directly, not stdin: piped into bash -s, stdin is the
# script text and a bare read would silently eat the next lines of it. Opening
# /dev/tty is the test, since [ -r /dev/tty ] passes even where the open fails.
# The prompt is printed rather than passed to read -p, which suppresses it
# whenever stdin is not itself a terminal and leaves this looking hung.
confirm() {
  [ "$APPLY" -eq 1 ] || return 0
  [ "$ASSUME_YES" -eq 1 ] && return 0
  exec 3<>/dev/tty 2>/dev/null \
    || die "no terminal to confirm on; copy this to the host and run it there, or pass --yes"
  local reply
  printf '    %s [y/N] ' "$1" >&3
  read -r reply <&3
  exec 3>&-
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user"
}

cleanup() {
  if [ -n "$ROOTVIEW" ] && mountpoint -q "$ROOTVIEW"; then
    umount "$ROOTVIEW" && rmdir "$ROOTVIEW"
  fi
}
trap cleanup EXIT

hidden_path() { printf '%s/mnt/media/%s' "$ROOTVIEW" "$1"; }

# Without this, an unset ROOTVIEW would collapse hidden_path onto the live NFS
# share and the purge would wipe the NAS.
assert_rootview() {
  [ "$APPLY" -eq 1 ] || return 0
  [ -n "$ROOTVIEW" ] || die "ROOTVIEW is unset, refusing to delete anything"
  mountpoint -q "$ROOTVIEW" || die "$ROOTVIEW is not a mountpoint, refusing to delete anything"
  [ "$(stat -c %d "$ROOTVIEW")" = "$(stat -c %d /)" ] \
    || die "$ROOTVIEW is not the root filesystem, refusing to delete anything"
}

purge_dir() {
  local dir="$1" label="$2"
  if [ ! -d "$dir" ]; then
    if [ "$APPLY" -eq 0 ]; then
      info "[dry-run] would delete everything under $label"
    else
      info "$label: does not exist, skipping"
    fi
    return 0
  fi
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    info "$label: already empty"
    return 0
  fi
  info "$label currently holds $(du -shx "$dir" 2>/dev/null | cut -f1):"
  find "$dir" -mindepth 1 -maxdepth 1 -printf '      %f\n' 2>/dev/null | sort
  if [ "$APPLY" -eq 0 ]; then
    info "[dry-run] would delete all of the above"
    return 0
  fi
  confirm "permanently delete all of the above from $label?"
  find "$dir" -mindepth 1 -maxdepth 1 -print0 | xargs -0 rm -rf --
  info "$label: purged"
}

# USER is interpolated into the compose file's volume paths, so running as root
# without pinning it expands to /home/root/... and creates empty config dirs.
compose() {
  run env USER="$TARGET_USER" docker compose --project-directory "$COMPOSE_DIR" "$@"
}

say "Preflight"

if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "--apply needs root, run with sudo"
fi
[ -d "$COMPOSE_DIR" ] || die "compose dir not found: $COMPOSE_DIR"

for m in "${MOUNTS[@]}"; do
  findmnt -t nfs,nfs4 "$m" >/dev/null 2>&1 || die "$m is not NFS-mounted; mount it before running this"
  info "$m is mounted from $(findmnt -no SOURCE "$m")"
done

info "compose project dir: $COMPOSE_DIR"
info "running as user:     $TARGET_USER"
[ "$APPLY" -eq 1 ] || warn "DRY RUN - nothing will be changed. Re-run with --apply."

say "1. fstab mount options"

# Identified by mount point, and only the options field is rewritten. Whatever
# names the NAS in field 1 is left as it stands, so this neither hardcodes the
# address nor swaps it for a name that has to resolve before the mount at boot.
fstab_fixed() {
  awk -v opts="$NAS_OPTS" 'BEGIN { OFS = "  " }
    /^[^#]/ && ($2 == "/mnt/media" || $2 == "/mnt/immich") {
      print $1, $2, $3, opts, ($5 == "" ? 0 : $5), ($6 == "" ? 0 : $6)
      next
    }
    { print }' "$1"
}

if grep -qE "^[^#].*[[:space:]](/mnt/media|/mnt/immich)[[:space:]].*_netdev" /etc/fstab; then
  info "already carries _netdev, leaving alone"
else
  info "current entries use bare 'defaults', which is what lost the boot race:"
  grep -nE "^[^#].*[[:space:]](/mnt/media|/mnt/immich)[[:space:]]" /etc/fstab | sed 's/^/      /' || true
  info "would become:"
  fstab_fixed /etc/fstab | grep -E "[[:space:]](/mnt/media|/mnt/immich)[[:space:]]" | sed 's/^/      /'
  confirm "rewrite the two NAS lines in /etc/fstab? (a backup is kept)"
  if [ "$APPLY" -eq 1 ]; then
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    fstab_fixed /etc/fstab > /etc/fstab.new
    findmnt --verify --tab-file /etc/fstab.new >/dev/null \
      || die "rewritten fstab failed verification, left it at /etc/fstab.new"
    mv /etc/fstab.new /etc/fstab
    info "rewritten and verified"
  else
    info "[dry-run] would rewrite both lines and back up /etc/fstab"
  fi
fi

say "2. docker.service mount ordering"

if [ -f "$DROPIN" ] && grep -q "RequiresMountsFor" "$DROPIN"; then
  info "drop-in already present at $DROPIN"
else
  info "installing $DROPIN"
  run mkdir -p "$DROPIN_DIR"
  run install -m 0644 "$REPO_DIR/systemd/docker.service.d/wait-for-nfs.conf" "$DROPIN"
fi
run systemctl daemon-reload
info "docker.service will now order itself after mnt-media.mount and mnt-immich.mount"

say "3. Stopping the affected services"

# Not a whole-stack down: homarr, overseerr and tautulli are unaffected, and
# bookorbit-app has never been created here, so an unscoped up -d would start it.
info "stopping: ${AFFECTED[*]}"
compose stop "${AFFECTED[@]}"

say "4. Exposing the shadowed directories"

# Bind-mounting / elsewhere shows the root filesystem without the NFS mounts on
# top of it.
if [ "$APPLY" -eq 1 ]; then
  ROOTVIEW="$(mktemp -d /mnt/.rootview.XXXXXX)"
  mount --bind / "$ROOTVIEW"
  info "root filesystem exposed at $ROOTVIEW"
else
  ROOTVIEW="/mnt/.rootview (dry-run placeholder)"
  info "[dry-run] would bind-mount / at a temporary directory"
fi

say "5. Purging the trapped downloads"

assert_rootview
if [ "$APPLY" -eq 0 ]; then
  # A dry run has no root and so cannot reach the shadowed directory by path,
  # but deluge is still bound to it.
  info "previewing through deluge, which is still bound to the shadowed path:"
  docker exec deluge sh -c 'du -shx /downloads 2>/dev/null; ls -1 /downloads' 2>/dev/null \
    | sed 's/^/      /' || info "      (deluge not running, cannot preview)"
fi
purge_dir "$(hidden_path Downloads)" "the trapped Downloads folder (local disk)"

# Reported, not deleted: a stray file under Movies or TV Shows would be real
# media that never reached the NAS, not an abandoned download.
for rel in "${SHADOWED[@]}"; do
  [ "$rel" = "Downloads" ] && continue
  [ "$APPLY" -eq 1 ] || continue
  src="$(hidden_path "$rel")"
  [ -d "$src" ] || continue
  if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    warn "$rel is shadowing files on local disk. Left alone, review by hand:"
    find "$src" -mindepth 1 -maxdepth 1 -printf '      %f\n' | sort
  fi
done

say "6. Purging the incomplete downloads on the NAS"

purge_dir "/mnt/media/Downloads" "the NAS Downloads folder"

say "7. Restarting the affected services"

# The root view has to go first, or the containers could bind through it.
cleanup
ROOTVIEW=""

# --force-recreate is the point: a plain start reuses the container and its
# stale bind.
compose up -d --force-recreate "${AFFECTED[@]}"

say "8. Verifying container binds"

if [ "$APPLY" -eq 1 ]; then
  sleep 5
  want="$(stat -c %d /mnt/media)"
  failed=0
  for c in $(docker ps --format '{{.Names}}'); do
    while IFS='|' read -r src dst; do
      [ -n "$dst" ] || continue
      got="$(docker exec "$c" stat -c %d "$dst" 2>/dev/null || echo n/a)"
      if [ "$got" = "$want" ]; then
        printf '    %-14s %-24s OK (on NAS)\n' "$c" "$dst"
      else
        printf '    \033[31m%-14s %-24s STILL LOCAL\033[0m\n' "$c" "$dst"
        failed=1
      fi
    done < <(docker inspect "$c" \
      --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{println}}{{end}}{{end}}' \
      | grep '^/mnt/media' || true)
  done
  [ "$failed" -eq 0 ] || die "some binds are still on local disk"
  say "Done"
  df -hT / /mnt/media | sed 's/^/    /'
else
  info "[dry-run] would compare each container's /mnt/media bind against the NFS device id"
  say "Dry run complete - re-run with --apply to make these changes"
fi
