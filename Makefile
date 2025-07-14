# ----------- CONFIGURE EVERYTHING HERE ------------
AWS_REGION        ?= ap-southeast-2
VPC_ID            ?= vpc-xxxxx
SUBNET_ID         ?= subnet-xxxxx
KEY_NAME          ?= librechat-key
KEY_PATH          ?= $(HOME)/.ssh/$(KEY_NAME).pem   # path to the private key
PUB_KEY           ?=                                # set if you want to import an existing .pub
INSTANCE_TYPE     ?= t3a.medium
ROOT_VOL_GB       ?= 30
TAG_VALUE         ?= librechat
SG_NAME           ?= librechat-sg
SRC_DIR           ?= $(CURDIR)        # deploy/update the directory you run make from
# ---------------------------------------------------

export AWS_REGION VPC_ID SUBNET_ID KEY_NAME KEY_PATH \
       INSTANCE_TYPE ROOT_VOL_GB TAG_VALUE SG_NAME SRC_DIR

.PHONY: init deploy update logs shell ssh

# ----- 1. Key-pair helper ----------------------------------------------------
# ---------- 1. Key-pair helper ----------------------------------
init:
	@echo "🔑  Ensuring EC2 key-pair '$(KEY_NAME)' exists ..."
	@if [ -f "$(KEY_PATH)" ]; then \
		echo "   → Found private key: $(KEY_PATH)"; \
		PUB=$$(echo "$(KEY_PATH)" | sed 's/\.pem$$/.pub/'); \
		if [ -f "$$PUB" ]; then \
			echo "   → Importing its public half: $$PUB"; \
			./setup_keypair.sh -n $(KEY_NAME) -r $(AWS_REGION) -p $$PUB; \
		else \
			echo "   → No .pub file; assuming key already in AWS"; \
			./setup_keypair.sh -n $(KEY_NAME) -r $(AWS_REGION); \
		fi; \
	else \
		if [ -n "$(strip $(PUB_KEY))" ]; then \
			./setup_keypair.sh -n $(KEY_NAME) -r $(AWS_REGION) -p $(PUB_KEY); \
		else \
			./setup_keypair.sh -n $(KEY_NAME) -r $(AWS_REGION); \
		fi; \
	fi


# ----- 2. Full deploy/replace ------------------------------------------------
deploy:
	@echo "🛠  Deploying LibreChat → AWS ($(AWS_REGION))"
	@REGION=$(AWS_REGION) VPC_ID=$(VPC_ID) SUBNET_ID=$(SUBNET_ID) \
	 KEY_NAME=$(KEY_NAME) KEY_PATH=$(KEY_PATH) INSTANCE_TYPE=$(INSTANCE_TYPE) \
	 ROOT_VOL_GB=$(ROOT_VOL_GB) TAG_VALUE=$(TAG_VALUE) SG_NAME=$(SG_NAME) \
	 LOCAL_SRC_DIR=$(SRC_DIR) ./deploy_librechat.sh

# ----- 3. Push config/code changes ------------------------------------------
update:
	@./update_config.sh -r $(AWS_REGION) -k $(KEY_PATH)

ssh:
	@echo "🔑  Opening SSH session …"
	@REGION="$(AWS_REGION)" ; \
	KEY="$(KEY_PATH)" ; \
	TAG="$(TAG_VALUE)" ; \
	: "$${REGION:=$(shell aws configure get region)}" ; \
	: "$${KEY:=$(HOME)/.ssh/librechat-key.pem}" ; \
	: "$${TAG:=librechat}" ; \
	IP="$$(aws ec2 describe-instances \
	      --filters Name=tag:Name,Values=$${TAG} \
	                Name=instance-state-name,Values=running \
	      --region "$${REGION}" \
	      --query 'Reservations[0].Instances[0].PublicIpAddress' \
	      --output text)" ; \
	if [ "$$IP" = "None" ] || [ -z "$$IP" ]; then \
	  echo "❌ No running instance tagged Name=$${TAG} in $${REGION}"; exit 1; \
	fi ; \
	echo "➡️  Connecting to $$IP (region $${REGION})" ; \
	ssh -i "$${KEY}" ubuntu@$$IP

# Usage:
#   make logs                → all containers
#   make logs SERVICE=api    → single container
logs:
	@echo "▶️  Tailing logs …  (Ctrl-C to stop)"
	@IP=$$(aws ec2 describe-instances \
	      --filters "Name=tag:Name,Values=$(TAG_VALUE)" \
	                "Name=instance-state-name,Values=running" \
	      --region $(AWS_REGION) \
	      --query 'Reservations[0].Instances[0].PublicIpAddress' \
	      --output text) && \
	if [ "$$IP" = "None" ] || [ -z "$$IP" ]; then \
	  echo "❌ No running EC2 instance tagged Name=$(TAG_VALUE)"; exit 1; \
	fi && \
	echo "Connecting to $$IP" && \
	ssh -i $(KEY_PATH) -o StrictHostKeyChecking=no ubuntu@$$IP \
	  "cd ~/librechat && docker compose logs -f --tail=100 $(SERVICE)"

