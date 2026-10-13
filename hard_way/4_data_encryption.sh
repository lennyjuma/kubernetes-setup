#!/bin/bash
#
# STEP 4 — Encryption at rest for Secrets
#
# WHY THIS EXISTS
# By default the API server writes Secrets into etcd as plain base64 — not
# encryption. Anyone who can read the etcd data directory, or restore an etcd
# backup, reads every password and token in the cluster.
#
# This config tells the API server (step 6a, --encryption-provider-config) to
# encrypt Secret objects with AES-CBC before they ever reach etcd. Step 14
# verifies it worked by hexdumping the raw etcd value and looking for the
# "k8s:enc:aescbc:v1:key1" prefix.
#
# Run this on controlplane01, before step 6a.

# 32 random bytes = AES-256. Generated once here and shared by both control
# plane nodes: either API server must be able to decrypt what the other wrote,
# so the key material has to be identical across the control plane.
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

# Provider order matters and is read top-down:
#   - aescbc is listed first, so it is used for every *write*.
#   - identity ("store as plaintext") is listed second, so it is still available
#     for *reads*. That is what lets an existing cluster with unencrypted
#     Secrets keep working after this is switched on; drop it and any Secret
#     written before encryption became unreadable.
cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

for instance in controlplane01 controlplane02; do
  scp encryption-config.yaml ${instance}:~/
done

# Move it to the path the kube-apiserver unit file expects. mkdir -p first
# because on a fresh machine /var/lib/kubernetes does not exist yet.
for instance in controlplane01 controlplane02; do
  ssh ${instance} sudo mkdir -p /var/lib/kubernetes/
  ssh ${instance} sudo mv encryption-config.yaml /var/lib/kubernetes/
done
