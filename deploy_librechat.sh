#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-southeast-2}"
VPC_ID="${VPC_ID:-vpc-xxxxxxxx}"
SUBNET_ID="${SUBNET_ID:-subnet-xxxxxxxx}"
KEY_NAME="${KEY_NAME:-librechat-key}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/librechat-key.pem}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3a.medium}"
ROOT_VOL_GB="${ROOT_VOL_GB:-30}"
TAG_VALUE="${TAG_VALUE:-librechat}"
SG_NAME="${SG_NAME:-librechat-sg}"
LOCAL_SRC_DIR="${LOCAL_SRC_DIR:-$(pwd)}"


[[ -d "$LOCAL_SRC_DIR" ]] || { echo "❌ Working directory not found."; exit 1; }
[[ -f "$LOCAL_SRC_DIR/deploy-compose.yml" ]] || {
  echo "❌ deploy-compose.yml not found in $LOCAL_SRC_DIR"; exit 1; }

echo "➜ Reusing or creating security group \"$SG_NAME\" …"
SG_ID=$(aws ec2 describe-security-groups \
          --filters "Name=group-name,Values=$SG_NAME" \
          --region "$REGION" --query 'SecurityGroups[0].GroupId' \
          --output text 2>/dev/null || true)

if [[ -z "$SG_ID" ]]; then
  SG_ID=$(aws ec2 create-security-group \
            --vpc-id "$VPC_ID" \
            --group-name "$SG_NAME" \
            --description "LibreChat host" \
            --region "$REGION" \
            --query 'GroupId' --output text)
  echo "   ↳ Created SG $SG_ID"
fi

for PORT in 22 80 443; do
  aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 \
      --region "$REGION" 2>/dev/null || true
done

echo "➜ Terminating any previous \"$TAG_VALUE\" instance …"
OLD_ID=$(aws ec2 describe-instances \
           --filters "Name=tag:Name,Values=$TAG_VALUE" \
                     "Name=instance-state-name,Values=pending,running,stopping,stopped" \
           --region "$REGION" \
           --query 'Reservations[].Instances[].InstanceId' \
           --output text)
if [[ -n "$OLD_ID" ]]; then
  aws ec2 terminate-instances --instance-ids "$OLD_ID" --region "$REGION" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$OLD_ID" --region "$REGION"
  echo "   ↳ Previous instance $OLD_ID terminated."
fi
# Reference: terminate-instances CLI :contentReference[oaicite:1]{index=1}

echo "➜ Finding latest Ubuntu 22.04 LTS AMI …"
AMI_ID=$(aws ec2 describe-images \
           --owners 099720109477 \
           --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
                     "Name=state,Values=available" \
           --region "$REGION" \
           --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' \
           --output text)

echo "➜ Launching new EC2 instance …"
INSTANCE_ID=$(aws ec2 run-instances \
                --image-id "$AMI_ID" \
                --instance-type "$INSTANCE_TYPE" \
                --key-name "$KEY_NAME" \
                --security-group-ids "$SG_ID" \
                --subnet-id "$SUBNET_ID" \
                --associate-public-ip-address \
                --user-data file://userdata.sh \
                --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":'"$ROOT_VOL_GB"',"VolumeType":"gp3","DeleteOnTermination":true}}]' \
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_VALUE}]" \
                --region "$REGION" \
                --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
             --region "$REGION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "   ↳ Instance $INSTANCE_ID ready @ $PUBLIC_IP"

echo "➜ Syncing local source ($LOCAL_SRC_DIR) …"
rsync -avz --delete -e "ssh -i $KEY_PATH -o StrictHostKeyChecking=no" \
      "$LOCAL_SRC_DIR"/ ubuntu@"$PUBLIC_IP":~/librechat/

echo "➜ Starting LibreChat via docker-compose …"
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$PUBLIC_IP" <<'EOF'
cd ~/librechat
docker-compose -f deploy-compose.yml up -d
EOF

echo -e "\n🎉 Deployment complete → http://$PUBLIC_IP\n"
