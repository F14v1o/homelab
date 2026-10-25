#!/usr/bin/env bash
#
# config-backup.sh
#
# Weekly configuration snapshot of the home server into a git repo.
# CONFIGURATION ONLY - no media, no downloads, no sqlite databases, no keys.
#
# Runs as root (needed to read /var/lib/casaos and the container /config dirs),
# but commits and pushes as $GIT_USER so it uses that user's SSH key.
#
# Usage:
#   sudo ./config-backup.sh            # run a snapshot now
#   sudo ./config-backup.sh install    # install + enable the weekly timer
#   sudo ./config-backup.sh uninstall  # remove the timer
#
# ---------------------------------------------------------------------------
set -uo pipefail
GIT_USER="${GIT_USER:-admin}"                     # commits and pushes as this user (its SSH key)
REPO="${REPO:-/home/${GIT_USER}/homelab}"
SNAP="${REPO}/snapshot"
REDACT_SECRETS="${REDACT_SECRETS:-1}"   # 1 = blank out API keys before committing
LOGFILE="/var/log/config-backup.log"
KUMA_PUSH="${KUMA_PUSH:-}"                      # optional Uptime Kuma push URL, pinged after a successful push
# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------
SELF="$(readlink -f "$0")"
install_timer() {
  cat >/etc/systemd/system/config-backup.service <<EOF
[Unit]
Description=Weekly configuration snapshot to Git
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${SELF}
Environment=GIT_USER=${GIT_USER}
Environment=REPO=${REPO}
Environment=REDACT_SECRETS=${REDACT_SECRETS}
Environment=KUMA_PUSH=${KUMA_PUSH}
EOF
  cat >/etc/systemd/system/config-backup.timer <<'EOF'
[Unit]
Description=Run the configuration snapshot weekly
[Timer]
OnCalendar=Sun 03:00
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now config-backup.timer
  echo
  echo "Installed. Next run:"
  systemctl list-timers config-backup.timer --no-pager
  echo
  echo "Test it right now with:  sudo systemctl start config-backup.service"
  echo "Watch the log with:      journalctl -u config-backup -f"
  exit 0
}
uninstall_timer() {
  systemctl disable --now config-backup.timer 2>/dev/null
  rm -f /etc/systemd/system/config-backup.{service,timer}
  systemctl daemon-reload
  echo "Timer removed. The repo and snapshot were left untouched."
  exit 0
}
case "${1:-run}" in
  install)   [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }; install_timer ;;
  uninstall) [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }; uninstall_timer ;;
  run)       ;;
  *)         echo "usage: $0 [run|install|uninstall]"; exit 1 ;;
esac
# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "This needs root to read the container config dirs. Use sudo."; exit 1; }
command -v docker >/dev/null || { echo "docker not found in PATH"; exit 1; }
[ -d "${REPO}/.git" ] || { echo "${REPO} is not a git repository"; exit 1; }
touch "$LOGFILE" 2>/dev/null
exec > >(tee -a "$LOGFILE") 2>&1
echo
echo "=========================================================="
echo "  Config snapshot  -  $(date -Is)"
echo "=========================================================="
# Start from a clean snapshot dir so deletions upstream show up as deletions
# in git, rather than leaving stale files behind forever.
rm -rf "$SNAP"
mkdir -p "$SNAP"/{compose,casaos,apps,dotfiles,system,n8n}
# copy SRC DESTDIR  - never fails the run if the source is absent
copy() {
  if [ ! -e "$1" ]; then echo "    skip (missing) $1"; return 0; fi
  mkdir -p "$2"
  cp -a "$1" "$2"/ 2>/dev/null && echo "    ok   $1" || echo "    FAIL $1"
}
# capture "label" command...  - records command output, or the error
capture() {
  local out="$SNAP/system/$1"; shift
  if "$@" >"$out" 2>&1; then echo "    ok   $(basename "$out")"
  else echo "    (command unavailable) $(basename "$out")"; fi
}
# ---------------------------------------------------------------------------
# 1. compose stack + env
# ---------------------------------------------------------------------------
echo
echo "[1/6] Compose stack"
for f in "$REPO"/compose/docker-compose.yml "$REPO"/compose/docker-compose.yaml \
         "$REPO"/compose/.env; do
  copy "$f" "$SNAP/compose"
done
# ---------------------------------------------------------------------------
# 2. CasaOS
# ---------------------------------------------------------------------------
echo
echo "[2/6] CasaOS configuration (skipped if not installed)"
copy /etc/casaos "$SNAP/casaos"
if [ -d /var/lib/casaos/apps ]; then
  mkdir -p "$SNAP/casaos/apps"
  find /var/lib/casaos/apps -maxdepth 2 -name 'docker-compose.yml' \
    -exec cp -a --parents {} "$SNAP/casaos/apps/" \; 2>/dev/null
  echo "    ok   /var/lib/casaos/apps/*/docker-compose.yml"
fi
# ---------------------------------------------------------------------------
# 3. per-container /config directories, auto-discovered
# ---------------------------------------------------------------------------
echo
echo "[3/6] Application configs (auto-discovered from container mounts)"
for c in $(docker ps --format '{{.Names}}'); do
  src=$(docker inspect "$c" \
        --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}')
  [ -n "$src" ] && [ -d "$src" ] || continue
  dest="$SNAP/apps/$c"
  mkdir -p "$dest"
  # Text config only. No .db, no logs, no artwork caches, no backup archives.
  find "$src" -maxdepth 2 -type f \
       \( -name '*.xml' -o -name '*.json' -o -name '*.conf' \
          -o -name '*.ini' -o -name '*.yml' -o -name '*.yaml' \) \
       ! -path '*/logs/*' ! -path '*/Definitions/*' ! -path '*/Backups/*' ! -path '*/cache/*' \
       ! -path '*/MediaCover/*' ! -path '*/metadata/*' \
       ! -name 'key-*.xml' ! -name '*secrets*.json' \
       -exec cp -a {} "$dest"/ \; 2>/dev/null
  n=$(find "$dest" -type f | wc -l)
  echo "    ok   $c  ($src) -> $n file(s)"
done
# ---------------------------------------------------------------------------
# 4. n8n workflows
# ---------------------------------------------------------------------------
echo
echo "[4/6] n8n workflows"
N8N=$(docker ps --format '{{.Names}}' | grep -i -m1 n8n)
if [ -n "$N8N" ]; then
  if docker exec "$N8N" n8n export:workflow --all --separate --output=/tmp/wfexport >/dev/null 2>&1; then
    mkdir -p "$SNAP/n8n/workflows"
    docker cp "$N8N":/tmp/wfexport/. "$SNAP/n8n/workflows/" >/dev/null 2>&1
    docker exec "$N8N" rm -rf /tmp/wfexport >/dev/null 2>&1
    echo "    ok   exported $(find "$SNAP/n8n/workflows" -name '*.json' | wc -l) workflow(s)"
  else
    echo "    FAIL n8n CLI export - check: docker exec $N8N n8n export:workflow --all --separate --output=/tmp/x"
  fi
  # Credentials are deliberately NOT exported. They are only decryptable with
  # N8N_ENCRYPTION_KEY, which belongs in a password manager, not in git.
else
  echo "    skip - no running container matching 'n8n'"
fi
# ---------------------------------------------------------------------------
# 5. dotfiles
# ---------------------------------------------------------------------------
echo
echo "[5/6] Dotfiles for ${GIT_USER}"
H="/home/${GIT_USER}"
for f in .bashrc .bash_aliases .bash_profile .profile .zshrc .gitconfig \
         .vimrc .tmux.conf .inputrc; do
  copy "$H/$f" "$SNAP/dotfiles"
done
copy "$H/.ssh/config" "$SNAP/dotfiles/ssh"     # config only - never the keys
copy "$H/.ssh/known_hosts" "$SNAP/dotfiles/ssh"
for d in .config/htop .config/nvim .config/rclone; do
  copy "$H/$d" "$SNAP/dotfiles/config"
done
# ---------------------------------------------------------------------------
# 6. system state
# ---------------------------------------------------------------------------
echo
echo "[6/6] System state"
copy /etc/fstab            "$SNAP/system"
copy /etc/hosts            "$SNAP/system"
copy /etc/hostname         "$SNAP/system"
copy /etc/samba/smb.conf   "$SNAP/system"
copy /etc/docker/daemon.json "$SNAP/system"
capture packages-manual.txt   apt-mark showmanual
capture disks.txt             lsblk -f
capture systemd-enabled.txt   systemctl list-unit-files --state=enabled --no-pager
capture systemd-timers.txt    systemctl list-timers --all --no-pager
capture ip-addr.txt           ip -br addr
capture ip-route.txt          ip route
capture docker-ps.txt         docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
crontab -u "$GIT_USER" -l >"$SNAP/system/crontab-${GIT_USER}.txt" 2>&1
crontab -l                >"$SNAP/system/crontab-root.txt"        2>&1
# Container topology: image, restart policy, ports, volume mappings.
{
  for c in $(docker ps -a --format '{{.Names}}'); do
    docker inspect "$c" --format '=== {{.Name}}
  image:   {{.Config.Image}}
  restart: {{.HostConfig.RestartPolicy.Name}}
  ports:   {{range $p, $b := .HostConfig.PortBindings}}{{$p}} <- {{range $b}}{{.HostPort}}{{end}}  {{end}}
  mounts:{{range .Mounts}}
    {{.Source}} : {{.Destination}}{{end}}
'
  done
} >"$SNAP/system/container-topology.txt" 2>&1
echo "    ok   container-topology.txt"
# ---------------------------------------------------------------------------
# 7. redact, then commit and push
# ---------------------------------------------------------------------------
echo
echo "[7] Redact, commit, push"
if [ "$REDACT_SECRETS" = "1" ]; then
  # <ApiKey> elements in XML configs. Regenerable on restore.
  find "$SNAP/apps" -name 'config.xml' -exec \
    sed -i -E 's#<ApiKey>[^<]*</ApiKey>#<ApiKey>REDACTED</ApiKey>#g' {} \; 2>/dev/null
  # Anything that looks like an assigned secret in captured text files.
  find "$SNAP" -type f \( -name '*.env' -o -name '.env' \) -exec \
    sed -i -E 's/(PASSWORD|TOKEN|SECRET|API_?KEY)=.*/\1=REDACTED/I' {} \; 2>/dev/null
  # JSON/YAML secrets (ErsatzTV, Homepage widgets, anything that stores keys as "apiKey": "...").
  find "$SNAP" -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -exec \
    sed -i -E 's/("?(api[_-]?key|token|secret|password|access[_-]?token|refresh[_-]?token)"?[[:space:]]*[:=][[:space:]]*)"[^"]*"/\1"REDACTED"/Ig' {} \; 2>/dev/null
  # ASP.NET data-protection key rings hold the master key that encrypts stored credentials. Never commit them.
  find "$SNAP" -name 'key-*.xml' -delete 2>/dev/null
  # Application logs contain API keys in request URLs.
  find "$SNAP" -type d -name logs -prune -exec rm -rf {} + 2>/dev/null
  echo "    ok   secrets redacted"
fi
# Safety net, only written if you don't already have one.
if [ ! -f "$REPO/.gitignore" ]; then
  cat >"$REPO/.gitignore" <<'EOF'
# never commit these
*.db
*.db-shm
*.db-wal
*.sqlite*
id_rsa
id_ed25519
*.pem
*.key
*.pfx
.env.local
# never commit media
*.mkv
*.mp4
*.avi
*.nfo
*.jpg
*.png
EOF
  echo "    ok   wrote default .gitignore"
fi
chown -R "${GIT_USER}:${GIT_USER}" "$REPO"
BRANCH=$(sudo -u "$GIT_USER" -H git -C "$REPO" rev-parse --abbrev-ref HEAD)
sudo -u "$GIT_USER" -H git -C "$REPO" add -A
if sudo -u "$GIT_USER" -H git -C "$REPO" diff --cached --quiet; then
  echo "    no configuration changes since last snapshot"
else
  sudo -u "$GIT_USER" -H git -C "$REPO" \
    commit -q -m "chore(snapshot): weekly config backup $(date +%F)"
  echo "    ok   committed"
fi
# Push unconditionally, so a previously failed push still gets retried.
if sudo -u "$GIT_USER" -H git -C "$REPO" push origin "$BRANCH"; then
  echo "    ok   pushed to origin/$BRANCH"
  if [ -n "$KUMA_PUSH" ]; then
    curl -fsS --max-time 10 "${KUMA_PUSH}?status=up&msg=OK" >/dev/null \
      && echo "    ok   pinged Uptime Kuma" \
      || echo "    warn Kuma ping failed (backup itself succeeded)"
  fi
else
  echo "    FAIL push to origin/$BRANCH - check the SSH deploy key for ${GIT_USER}"
  exit 1
fi
echo
echo "Snapshot complete: $(date -Is)"
echo "Size: $(du -sh "$SNAP" | cut -f1)"
