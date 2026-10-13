#!/bin/bash
#
# STEP 1 — Jumpbox / client tooling
#
# Run this on controlplane01, which acts as the "jumpbox" for the whole build.
# Every later script copies certificates and config files to the other four
# machines over SSH, so two things have to exist first:
#
#   1. Passwordless SSH from here to every other node. Without it, the dozens
#      of scp/ssh calls in steps 2-9 would each stop and prompt for a password.
#   2. kubectl on this machine. kubectl is not only the admin CLI — steps 3, 8
#      and 9 use `kubectl config` purely as a *file generator* to build the
#      kubeconfig files that the control plane and worker components need in
#      order to authenticate to the API server. That works offline; no running
#      cluster is required yet.

# Generate this user's SSH keypair (accept the defaults, empty passphrase).
ssh-keygen
# Authorise the key against *this* host too, so controlplane01 can ssh to itself.
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Push the public key to the remaining machines. StrictHostKeyChecking=no skips
# the interactive "unknown host, continue?" prompt on first contact — acceptable
# on a private lab network, and it keeps these scripts non-interactive.
ssh-copy-id -o StrictHostKeyChecking=no $(whoami)@controlplane02
ssh-copy-id -o StrictHostKeyChecking=no $(whoami)@loadbalancer
ssh-copy-id -o StrictHostKeyChecking=no $(whoami)@node01
ssh-copy-id -o StrictHostKeyChecking=no $(whoami)@node02

# Install kubectl. The inner curl resolves the current stable release tag
# (e.g. v1.31.0) so the client version always matches the server binaries that
# step 6a downloads from the same channel.
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
