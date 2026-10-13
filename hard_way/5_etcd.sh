#!/bin/bash
#
# STEP 5 — etcd cluster
#
# WHY THIS COMPONENT IS NEEDED
# etcd is the only stateful piece of Kubernetes and the single source of truth.
# Every Node, Pod, Secret, Deployment and lease lives here; the API server is
# essentially a validating, authorising REST front-end over etcd. Lose etcd and
# you have lost the cluster, which is why it runs as two members (a quorum
# cluster) and why it is wrapped in mutual TLS on both its client and peer ports.
#
# Two ports, two distinct purposes:
#   2379 — client port. The API server connects here.
#   2380 — peer port.   etcd members replicate the Raft log to each other here.
#
# IMPORTANT: run this on *both* controlplane01 and controlplane02. The script is
# node-aware (it reads the local hostname and PRIMARY_IP), so the same file
# produces the correct per-node unit. Expect etcd to sit waiting for its peer
# until the second node has been started — that is normal for --initial-cluster-
# state=new, which blocks until quorum forms.

ETCD_VERSION="v3.5.9"
wget -q --show-progress --https-only --timestamping \
  "https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"


# Install both binaries: etcd (the server) and etcdctl (the CLI used in step 14).
{
  tar -xvf etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz
  sudo mv etcd-${ETCD_VERSION}-linux-${ARCH}/etcd* /usr/local/bin/
}

# Lay out the certs and lock them down. 0600/root-owned matters: etcd-server.key
# is enough to impersonate etcd and read the entire cluster state.
#
# The symlink on the last line is the reason the CA lives under
# /var/lib/kubernetes/pki rather than /etc/etcd — the API server, controller
# manager and scheduler all read ca.crt from that one location, so there is a
# single copy to rotate, and etcd just points at it.
{
  sudo mkdir -p /etc/etcd /var/lib/etcd /var/lib/kubernetes/pki
  sudo cp etcd-server.key etcd-server.crt /etc/etcd/
  sudo cp ca.crt /var/lib/kubernetes/pki/
  sudo chown root:root /etc/etcd/*
  sudo chmod 600 /etc/etcd/*
  sudo chown root:root /var/lib/kubernetes/pki/*
  sudo chmod 600 /var/lib/kubernetes/pki/*
  sudo ln -s /var/lib/kubernetes/pki/ca.crt /etc/etcd/ca.crt
}

CONTROL01=$(dig +short controlplane01)
CONTROL02=$(dig +short controlplane02)
# Each member must announce itself under a unique name that matches its entry in
# --initial-cluster below; the short hostname (controlplane01/02) is exactly that.
ETCD_NAME=$(hostname -s)



cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/etcd-server.crt \\
  --key-file=/etc/etcd/etcd-server.key \\
  --peer-cert-file=/etc/etcd/etcd-server.crt \\
  --peer-key-file=/etc/etcd/etcd-server.key \\
  --trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${PRIMARY_IP}:2380 \\
  --listen-peer-urls https://${PRIMARY_IP}:2380 \\
  --listen-client-urls https://${PRIMARY_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${PRIMARY_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster controlplane01=https://${CONTROL01}:2380,controlplane02=https://${CONTROL02}:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# Flag notes, since these are the ones that bite:
#   --client-cert-auth / --peer-client-cert-auth
#       Turn on *mutual* TLS. Without these, TLS only proves the server's
#       identity and any client that trusts the CA could read all of etcd.
#   --listen-client-urls  includes 127.0.0.1 so the local API server (and
#       etcdctl in step 14) can connect over loopback.
#   --advertise-client-urls / --initial-advertise-peer-urls
#       The addresses etcd tells *other* parties to use. These must be the
#       routable PRIMARY_IP, never 127.0.0.1, or the peer could never reach it.
#   --initial-cluster
#       The static bootstrap roster. Both members list both nodes, identically.
#   --initial-cluster-state new
#       "I am forming a brand new cluster." Only correct on first bootstrap —
#       use 'existing' when adding a member to a live cluster.
#   Restart=on-failure + RestartSec=5
#       etcd is started before its peer exists, so the first few attempts may
#       die; systemd simply keeps retrying until quorum forms.


{
  sudo systemctl daemon-reload
  sudo systemctl enable etcd
  sudo systemctl start etcd
}
