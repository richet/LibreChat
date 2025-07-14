# AWS Deploy

Follow these steps to do a quick deployment to AWS EC2. It's not recommended for production loads but for a quick test it works well.

> Note that the min EC2 size that will work with this deploy is t3a.medium

## Pre-requisites

The scripts assume you have AWS CLI installed.

If you need to target a different AWS profile prepend the make commands with `AWS_PROFILE=xxx`.

## Deploy

You can test locally and configure LibreChat by following the standard LibreChat installation instructions.

Once you have the .env and librechat.yaml setup how you want it then you can deploy this to EC2 using the following steps.

### 1. Configure Makefile

The key settings are at the top of the file. You will need to set AWS VPC and Subnet.

You can also configure the SSH keypair that will be created to allow the deploy and access to the instance.

### 2. Initialize

This step sets up your SSH keypair.

```sh
make init
```

### 3. Deploy

Start the deploy

```sh
make deploy
```

Once the deploy is complete an IP address will be displayed where you can access LibreChat.

## Making changes

If you want to tweak the .env or librechat.yaml files after the deploy then you can change them locally and run make to update the remote server.

```sh
make update
```

## Shell access

If you need to get into the EC2 instance to upgrade or change something you can use

```sh
make ssh
```
