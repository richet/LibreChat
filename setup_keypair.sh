#!/usr/bin/env bash
#
# Ensure an EC2 key pair exists.
# ▸ -n NAME    (required)   key-pair name in AWS
# ▸ -r REGION  (optional)   defaults to AWS CLI region
# ▸ -p PUBKEY  (optional)   import this public key file
#
# If a local private key ~/.ssh/<NAME>.pem exists but *.pub is missing,
# the script derives the public key automatically with ssh-keygen -y.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -n <key-name> [-r <region>] [-p <public_key_path>]

  -n   Key pair name (required, unique per region)
  -r   AWS region (default: value from 'aws configure get region')
  -p   Path to a public key to import (skip to create if absent)
EOF
  exit 1
}

# ---------- parse flags ----------
REGION=""
KEY_NAME=""
PUB_KEY=""
while getopts ":n:r:p:" opt; do
  case $opt in
    n) KEY_NAME=$OPTARG ;;
    r) REGION=$OPTARG ;;
    p) PUB_KEY=$OPTARG ;;
    *) usage ;;
  esac
done
[[ -z $KEY_NAME ]] && usage
[[ -z $REGION   ]] && REGION=$(aws configure get region || true)
[[ -z $REGION   ]] && { echo "❌ No region specified or configured."; exit 1; }

# ---------- helper: best-guess key path ----------
guess_key_path() {
  local guess="$HOME/.ssh/${KEY_NAME}.pem"
  [[ -f $guess ]] && { echo "$guess"; return; }
  [[ -n $PUB_KEY ]] && echo "${PUB_KEY%.pub}" && return
  echo "~/.ssh/<your-private-key>.pem"
}

# ---------- fast-path: key already in AWS ----------
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" --output text 2>/dev/null; then
  echo -e "🎉 Created earlier – ready to use.\nKEY_NAME=\"$KEY_NAME\"\nKEY_PATH=\"$(guess_key_path)\""
  exit 0
fi

# ---------- import or create ----------
LOCAL_PEM="$HOME/.ssh/${KEY_NAME}.pem"

if [[ -n $PUB_KEY ]]; then
  [[ -f $PUB_KEY ]] || { echo "❌ Public key file not found: $PUB_KEY"; exit 1; }
  echo "➜ Importing $PUB_KEY as '$KEY_NAME' ..."
  aws ec2 import-key-pair --key-name "$KEY_NAME" \
       --public-key-material fileb://"$PUB_KEY" \
       --region "$REGION" >/dev/null
  echo -e "🎉 Created.\nKEY_NAME=\"$KEY_NAME\"\nKEY_PATH=\"$(guess_key_path)\""
  exit 0
fi

# ----- we reach here when PUB_KEY not supplied -----
if [[ -f $LOCAL_PEM ]]; then
  echo "➜ Found private key $LOCAL_PEM but no public key – deriving one …"
  TMP_PUB=$(mktemp /tmp/${KEY_NAME}.pub.XXXX)
  ssh-keygen -y -f "$LOCAL_PEM" > "$TMP_PUB"
  aws ec2 import-key-pair --key-name "$KEY_NAME" \
       --public-key-material fileb://"$TMP_PUB" \
       --region "$REGION" >/dev/null
  rm -f "$TMP_PUB"
  echo -e "🎉 Created (imported derived pubkey).\nKEY_NAME=\"$KEY_NAME\"\nKEY_PATH=\"$LOCAL_PEM\""
  exit 0
fi

# ----- last resort: create new pair -----
echo "➜ Creating new key pair → $LOCAL_PEM"
aws ec2 create-key-pair --key-name "$KEY_NAME" \
     --query 'KeyMaterial' --output text --region "$REGION" > "$LOCAL_PEM"
chmod 400 "$LOCAL_PEM"
echo -e "🎉 Created.\nKEY_NAME=\"$KEY_NAME\"\nKEY_PATH=\"$LOCAL_PEM\""
