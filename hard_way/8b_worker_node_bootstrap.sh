#!/bin/bash
#
# STEP 8b — Bring up the worker: kubelet + kube-proxy (manual-certificate path)
#
# WHY THESE COMPONENTS EXIST
#
#   kubelet
#       The node agent. It watches the API server for pods assigned to this
#       node, tells containerd to run their containers, mounts their volumes,
#       runs their probes, and reports Node and Pod status back. It is also the
#       only component that must run on every machine that hosts workloads.
#
#   kube-proxy
#       Makes Services work. A ClusterIP is not a real address — nothing
#       answers it. kube-proxy watches Services and Endpoints and writes
#       iptables rules that DNAT traffic for a ClusterIP to one of the backing
#       pod IPs. Without it, pods run fine but no Service name or NodePort
#       resolves to anything.
#
# Run this on node01 and node02, after step 8a has delivered their certificates
# and step 7 has installed containerd.
#
# This is the counterpart of 8a (manual certs). If you took the TLS
# bootstrapping path instead, run 9b on the worker rather than this file.

KUBE_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)

wget -q --show-progress --https-only --timestamping \
  https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kube-proxy \
  https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubelet


# The directories each component expects:
#   /var/lib/kubelet      — kubelet config + its kubeconfig
#   /var/lib/kube-proxy   — kube-proxy config + its kubeconfig
#   /var/lib/kubernetes/pki — shared cert location, same convention as the
#                             control plane
#   /var/run/kubernetes   — runtime sockets/state
sudo mkdir -p \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes/pki \
  /var/run/kubernetes

{
  chmod +x kube-proxy kubelet
  sudo mv kube-proxy kubelet /usr/local/bin/
}

# $HOSTNAME is what makes this one script work unmodified on both workers — the
# files delivered by 8a are named after the node (node01.crt, node02.crt...).
# The kubeconfig is renamed to the generic kubelet.kubeconfig because that is
# the path hard-coded in the unit file below.
# 0600/root again: node01.key is this node's identity.
{
  sudo mv ${HOSTNAME}.key ${HOSTNAME}.crt /var/lib/kubernetes/pki/
  sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubelet.kubeconfig
  sudo mv ca.crt /var/lib/kubernetes/pki/
  sudo mv kube-proxy.crt kube-proxy.key /var/lib/kubernetes/pki/
  sudo chown root:root /var/lib/kubernetes/pki/*
  sudo chmod 600 /var/lib/kubernetes/pki/*
  sudo chown root:root /var/lib/kubelet/*
  sudo chmod 600 /var/lib/kubelet/*
}

# Must match the values used on the control plane in step 6a exactly.
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/16

# By convention the cluster DNS service takes the .10 address of the service
# range, and that is what step 13's CoreDNS manifest claims. Derived rather than
# hard-coded so the two stay in sync if SERVICE_CIDR changes.
CLUSTER_DNS=$(echo $SERVICE_CIDR | awk 'BEGIN {FS="."} ; { printf("%s.%s.%s.10", $1, $2, $3) }')

cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /var/lib/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
clusterDomain: cluster.local
clusterDNS:
  - ${CLUSTER_DNS}
cgroupDriver: systemd
resolvConf: /run/systemd/resolve/resolv.conf
runtimeRequestTimeout: "15m"
tlsCertFile: /var/lib/kubernetes/pki/${HOSTNAME}.crt
tlsPrivateKeyFile: /var/lib/kubernetes/pki/${HOSTNAME}.key
registerNode: true
EOF
# Most of this file is about securing the kubelet's own API on port 10250, which
# is a genuinely dangerous endpoint — it can exec into any container on the node:
#
#   anonymous.enabled: false   Closes the classic hole where an unauthenticated
#                              request to :10250 gets you container exec.
#   x509.clientCAFile          Accept client certs signed by the cluster CA —
#                              this is what lets the API server in (it presents
#                              apiserver-kubelet-client from step 2).
#   authorization.mode: Webhook + authentication.webhook
#                              Don't decide locally: ask the API server
#                              "is this caller allowed?" via SubjectAccessReview,
#                              so kubelet access is governed by the same RBAC as
#                              everything else (see step 12).
#
# The rest:
#   containerRuntimeEndpoint   The CRI socket from step 7 — how it reaches
#                              containerd.
#   clusterDNS / clusterDomain What gets written into every pod's resolv.conf,
#                              so pods resolve Service names via CoreDNS.
#   cgroupDriver: systemd      Must match containerd's SystemdCgroup=true.
#   resolvConf                 Points at systemd-resolved's *real* upstream
#                              file. /etc/resolv.conf on Ubuntu is a stub
#                              pointing at 127.0.0.53, which a pod cannot
#                              reach — inheriting it would break all external
#                              DNS from inside containers.
#   tlsCertFile/tlsPrivateKeyFile  The serving cert issued in 8a.
#   registerNode: true         Self-register with the API server on startup
#                              instead of requiring the Node to be pre-created.

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --kubeconfig=/var/lib/kubelet/kubelet.kubeconfig \\
  --node-ip=${PRIMARY_IP} \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# Requires/After containerd: the kubelet is useless without its runtime, so
# systemd both orders them and tears the kubelet down if containerd goes away.
# --node-ip pins the address this node advertises, which matters on hosts with
# more than one interface — otherwise the kubelet may advertise an address the
# control plane cannot route to.


sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/

cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: /var/lib/kube-proxy/kube-proxy.kubeconfig
mode: iptables
clusterCIDR: ${POD_CIDR}
EOF
# mode: iptables is the classic, dependency-free proxy mode (ipvs is the
# alternative — step 7 installs ipvsadm/ipset in case you switch).
# clusterCIDR tells kube-proxy which source addresses are pod traffic, so it can
# tell "from a pod" from "from off-cluster" and masquerade only the latter.


cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Once these start, the node registers itself and shows up in `kubectl get
# nodes` — as NotReady until a CNI plugin is installed (step 11), because
# without pod networking the kubelet refuses to declare itself ready.
{
  sudo systemctl daemon-reload
  sudo systemctl enable kubelet kube-proxy
  sudo systemctl start kubelet kube-proxy
}
