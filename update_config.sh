#!/usr/bin/env bash
#
# Push runtime config (.env + librechat.yaml) to the EC2 host and
# restart the stack defined in deploy-compose.yml.
#
# Returns 0  – when the site is up on port 80
#         1  – when no running instance is found
#         2  – when restart fails or health-check times out
#

set -uo pipefail           # no ‘-e’ – we capture exit codes manually

# ── defaults, overridable by env or flags ────────────────────────────
REGION="${REGION:-$(aws configure get region || true)}"
TAG_VALUE="${TAG_VALUE:-librechat}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/librechat-key.pem}"
ENV_FILE="${ENV_FILE:-.env}"
LOCAL_SRC_DIR="${LOCAL_SRC_DIR:-$(pwd)}"
REMOTE_IP=""
# ─────────────────────────────────────────────────────────────────────

usage() { echo "Usage: $0 [-h ip] [-r region] [-k pem] [-e envfile]"; exit 1; }

while getopts ":h:r:k:e:" opt; do
  case $opt in
    h) REMOTE_IP=$OPTARG ;;
    r) REGION=$OPTARG ;;
    k) KEY_PATH=$OPTARG ;;
    e) ENV_FILE=$OPTARG ;;
    *) usage ;;
  esac
done

[[ -z $REGION   ]] && { echo "❌ REGION not set."; exit 1; }
[[ -f $KEY_PATH ]] || { echo "❌ SSH key not found: $KEY_PATH"; exit 1; }
[[ -f $LOCAL_SRC_DIR/$ENV_FILE        ]] || { echo "❌ $ENV_FILE missing";        exit 1; }
[[ -f $LOCAL_SRC_DIR/librechat.yaml   ]] || { echo "❌ librechat.yaml missing";   exit 1; }

# ── locate the EC2 instance by tag (unless IP supplied) ─────────────
if [[ -z $REMOTE_IP ]]; then
  REMOTE_IP=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=$TAG_VALUE" \
                "Name=instance-state-name,Values=running" \
      --region "$REGION" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text 2>/dev/null || true)
  [[ $REMOTE_IP == "None" || -z $REMOTE_IP ]] && {
    echo "❌ No running instance tagged Name=$TAG_VALUE."; exit 1; }
fi

echo "🔄  Copying config to $REMOTE_IP …"
scp -i "$KEY_PATH" -q \
    "$LOCAL_SRC_DIR/$ENV_FILE" \
    "$LOCAL_SRC_DIR/librechat.yaml" \
    ubuntu@"$REMOTE_IP":~/librechat/

# ── restart & health-check via SSH ──────────────────────────────────
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$REMOTE_IP" bash <<'REMOTE'
set -e
cd ~/librechat

docker compose -f deploy-compose.yml down --remove-orphans
docker compose -f deploy-compose.yml up -d --force-recreate

# wait ≤20 s for NGINX on port 80
for i in {1..20}; do
  if curl -sf http://localhost/ >/dev/null ; then
     echo "✅  Site up"
     exit 0
  fi
  sleep 1
done

echo "❌  Port 80 never became healthy" >&2
docker compose -f deploy-compose.yml ps
exit 2
REMOTE
SSH_STATUS=$?

if [[ $SSH_STATUS -ne 0 ]]; then
  exit $SSH_STATUS          # propagate 1 or 2 back to make
fi

echo -e "\n🎉  Config update complete – open: http://$REMOTE_IP\n"
exit 0
