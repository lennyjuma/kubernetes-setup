#!/bin/bash
#
# STEP 8a — Manually issue a kubelet certificate + kubeconfig for node01
#
# WHY THIS EXISTS
# A kubelet has to authenticate to the API server like any other client, so each
# worker needs its own identity. The subject is what makes it a *node* identity
# rather than a generic user:
#
#   CN=system:node:node01   — the Node authoriser (step 6a, --authorization-mode
#                             =Node) parses the node name out of this CN and
#                             restricts the kubelet to objects scheduled on
#                             node01 only.
#   O=system:nodes          — the group the built-in system:node ClusterRole is
#                             bound to.
#
# Change node01 to anything else and the kubelet authenticates but is denied,
# because the API server will not let "node01" act for a different node.
#
# NOTE ON SCRIPT 8 vs SCRIPT 9
# This is the manual path: you generate each node's cert by hand, here, on the
# control plane. Scripts 9a/9b are the *alternative* automatic path (TLS
# bootstrapping), where the node requests its own cert with a shared bootstrap
# token and the controller manager signs it. Pick one. 8 is simpler to follow
# and good for understanding what is really going on; 9 is what you would
# actually run at scale, and it also rotates certs automatically.
#
# Run this on controlplane01. For node02, re-run with node01 -> node02
# throughout (the hostname appears in the SANs, the CN, the filenames and the
# scp target).

NODE01=$(dig +short node01)

# The kubelet also *serves* HTTPS on port 10250 — the API server connects to it
# for `kubectl logs` and `kubectl exec`. That means the cert needs SANs matching
# how the API server addresses the node (both its name and its IP), on top of
# being a valid client cert.
cat > openssl-node01.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = node01
IP.1 = ${NODE01}
EOF

# Signed with the cluster CA from step 2, which is the only CA the API server
# trusts for client certs (--client-ca-file).
openssl genrsa -out node01.key 2048
openssl req -new -key node01.key -subj "/CN=system:node:node01/O=system:nodes" -out node01.csr -config openssl-node01.cnf
openssl x509 -req -in node01.csr -CA ca.crt -CAkey ca.key -CAcreateserial  -out node01.crt -extensions v3_req -extfile openssl-node01.cnf -days 1000



LOADBALANCER=$(dig +short loadbalancer)

# Build node01's kubeconfig. It points at the load balancer, not at a specific
# control plane node, so the kubelet keeps working when one API server dies.
#
# The cert paths are the paths *on the worker* after step 8b moves the files
# into place — nothing is embedded, so the file is just a set of references.
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
    --server=https://${LOADBALANCER}:6443 \
    --kubeconfig=node01.kubeconfig

  kubectl config set-credentials system:node:node01 \
    --client-certificate=/var/lib/kubernetes/pki/node01.crt \
    --client-key=/var/lib/kubernetes/pki/node01.key \
    --kubeconfig=node01.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:node01 \
    --kubeconfig=node01.kubeconfig

  kubectl config use-context default --kubeconfig=node01.kubeconfig
}

# Ship the identity to the node. Step 8b, run on node01 itself, puts these in
# the directories the kubelet unit expects.
scp ca.crt node01.crt node01.key node01.kubeconfig node01:~/
