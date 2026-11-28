#!/usr/bin/env bash
#
# Deploy the batched Project Gutenberg -> R2 mirror to the IONOS VPS.
#
# Secrets stay on the operator workstation and the VPS:
#   ~/.config/voxglass-gutenberg.env  -> /etc/voxglass-gutenberg.env (mode 600)
#   ~/.local/state/.../uploaded-ids    -> /opt/voxglass-gutenberg/state/uploaded-ids
#
# The repository contains only scripts and systemd unit files.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

VPS_HOST="${VOXGLASS_VPS_HOST:-root@217.76.158.90}"
REMOTE_ROOT="${VOXGLASS_GUTENBERG_ROOT:-/opt/voxglass-gutenberg}"
SERVICE_USER="${VOXGLASS_GUTENBERG_USER:-voxglass-gutenberg}"
ENV_FILE="${VOXGLASS_GUTENBERG_ENV:-/etc/voxglass-gutenberg.env}"
LOCAL_ENV="${VOXGLASS_GUTENBERG_LOCAL_ENV:-$HOME/.config/voxglass-gutenberg.env}"
LOCAL_STATE="${VOXGLASS_GUTENBERG_LOCAL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/voxglass-gutenberg-mirror}"
BATCH_SIZE="${VOXGLASS_GUTENBERG_BATCH_SIZE:-500}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[[ -r "$LOCAL_ENV" ]] || die "missing $LOCAL_ENV"
[[ -x "$REPO_ROOT/scripts/gutenberg-mirror.sh" ]] || die "missing mirror script"
[[ -f "$REPO_ROOT/scripts/build-gutenberg-index.py" ]] || die "missing index builder"
[[ -f "$REPO_ROOT/scripts/gutenberg-refresh-plan.py" ]] || die "missing refresh planner"
[[ -f "$REPO_ROOT/deploy/gutenberg-mirror/voxglass-gutenberg-mirror.service" ]] || die "missing systemd service"
[[ -f "$REPO_ROOT/deploy/gutenberg-mirror/voxglass-gutenberg-mirror.timer" ]] || die "missing systemd timer"

log "checking SSH access to $VPS_HOST"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" true || die "cannot SSH to $VPS_HOST"

FREE_MB="$(ssh "${SSH_OPTS[@]}" "$VPS_HOST" "df -Pm / | awk 'NR==2 { print \$4 }'")"
log "VPS free disk: ${FREE_MB} MiB"
if [[ "$FREE_MB" -lt 800 ]]; then
  log "WARNING: less than 800 MiB free; the default 500-book batch peaks around 150-200 MiB"
fi

log "creating service user and directories"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" "
  id -u $(printf '%q' "$SERVICE_USER") >/dev/null 2>&1 ||
    useradd --system --home $(printf '%q' "$REMOTE_ROOT") --shell /usr/sbin/nologin $(printf '%q' "$SERVICE_USER")
  install -d -o $(printf '%q' "$SERVICE_USER") -g $(printf '%q' "$SERVICE_USER") -m 700 \
    $(printf '%q' "$REMOTE_ROOT") \
    $(printf '%q' "$REMOTE_ROOT")/bin \
    $(printf '%q' "$REMOTE_ROOT")/cache \
    $(printf '%q' "$REMOTE_ROOT")/state
"

log "installing mirror scripts"
tar -C "$REPO_ROOT/scripts" -cf - gutenberg-mirror.sh build-gutenberg-index.py gutenberg-refresh-plan.py |
  ssh "${SSH_OPTS[@]}" "$VPS_HOST" "
    tar -x -C $(printf '%q' "$REMOTE_ROOT")/bin
    chmod 755 $(printf '%q' "$REMOTE_ROOT")/bin/gutenberg-mirror.sh $(printf '%q' "$REMOTE_ROOT")/bin/build-gutenberg-index.py $(printf '%q' "$REMOTE_ROOT")/bin/gutenberg-refresh-plan.py
    chown -R $(printf '%q' "$SERVICE_USER"):$(printf '%q' "$SERVICE_USER") $(printf '%q' "$REMOTE_ROOT")/bin
  "

log "installing environment file (secrets are streamed, never printed)"
{
  cat "$LOCAL_ENV"
  printf '\nGUTENBERG_STAGING_DIR=%s/cache\n' "$REMOTE_ROOT"
  printf 'GUTENBERG_STATE_DIR=%s/state\n' "$REMOTE_ROOT"
  printf 'GUTENBERG_BATCH_SIZE=%s\n' "$BATCH_SIZE"
} | ssh "${SSH_OPTS[@]}" "$VPS_HOST" "
  umask 077
  cat > $(printf '%q' "$ENV_FILE")
  chown root:root $(printf '%q' "$ENV_FILE")
  chmod 600 $(printf '%q' "$ENV_FILE")
"

MERGED_IDS="$(mktemp "${TMPDIR:-/tmp}/voxglass-gutenberg-ids.XXXXXX")"
trap 'rm -f "$MERGED_IDS"' EXIT

if [[ -s "$LOCAL_STATE/uploaded-ids" ]]; then
  cat "$LOCAL_STATE/uploaded-ids" >> "$MERGED_IDS"
fi
ssh "${SSH_OPTS[@]}" "$VPS_HOST" \
  "cat $(printf '%q' "$REMOTE_ROOT")/state/uploaded-ids 2>/dev/null || true" >> "$MERGED_IDS"
if [[ -s "$MERGED_IDS" ]]; then
  # Union the workstation and VPS state. A stale local copy must never shrink
  # the remote progress file and trigger a full re-download.
  LC_ALL=C sort -u -o "$MERGED_IDS" "$MERGED_IDS"
  log "seeding completed IDs (merged $(wc -l < "$MERGED_IDS" | tr -d ' ') IDs)"
  ssh "${SSH_OPTS[@]}" "$VPS_HOST" "
    cat > $(printf '%q' "$REMOTE_ROOT")/state/uploaded-ids
    chown $(printf '%q' "$SERVICE_USER"):$(printf '%q' "$SERVICE_USER") $(printf '%q' "$REMOTE_ROOT")/state/uploaded-ids
    chmod 600 $(printf '%q' "$REMOTE_ROOT")/state/uploaded-ids
  " < "$MERGED_IDS"
else
  log "no local or remote uploaded-ids state; the VPS will start from the beginning"
fi

log "installing systemd units"
for unit in voxglass-gutenberg-mirror.service voxglass-gutenberg-mirror.timer; do
  ssh "${SSH_OPTS[@]}" "$VPS_HOST" "cat > /etc/systemd/system/$unit; chmod 644 /etc/systemd/system/$unit" < "$REPO_ROOT/deploy/gutenberg-mirror/$unit"
done

log "enabling nightly timer and starting the initial sync"
ssh "${SSH_OPTS[@]}" "$VPS_HOST" "
  systemctl daemon-reload
  systemctl enable --now voxglass-gutenberg-mirror.timer
  systemctl reset-failed voxglass-gutenberg-mirror.service 2>/dev/null || true
  systemctl start --no-block voxglass-gutenberg-mirror.service
"

log "deployed. Useful commands:"
cat <<EOF
  ssh $VPS_HOST 'systemctl status voxglass-gutenberg-mirror.service --no-pager'
  ssh $VPS_HOST 'systemctl list-timers voxglass-gutenberg-mirror.timer --no-pager'
  ssh $VPS_HOST 'journalctl -u voxglass-gutenberg-mirror.service -f'
  ssh $VPS_HOST 'sudo -u $SERVICE_USER env GUTENBERG_STAGING_DIR=$REMOTE_ROOT/cache GUTENBERG_STATE_DIR=$REMOTE_ROOT/state GUTENBERG_BATCH_SIZE=$BATCH_SIZE $REMOTE_ROOT/bin/gutenberg-mirror.sh --status'
EOF
