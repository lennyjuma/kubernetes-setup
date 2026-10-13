#!/bin/bash
#
# STEP 9b — Worker node joining via TLS bootstrapping
#
# WHAT IS DIFFERENT FROM 8b
# Nothing about the kubelet's job changes; only how it gets its identity. Here
# the node arrives with no certificate at all — just the shared bootstrap token
# from 9a — and obtains its own:
#
#   1. kubelet starts, finds no cert at --kubeconfig, falls back to
#      --bootstrap-kubeconfig (token auth).
#   2. It generates a keypair locally and submits a CSR to the API server.
#   3. The bindings from 9a auto-approve it; the controller manager signs it
#      with the cluster CA.
#   4. The kubelet writes the issued cert into --cert-dir and a real
#      kubeconfig to /var/lib/kubelet/kubeconfig, then uses that from then on.
#
# The private key never leaves the node, and rotateCertificates means this
# repeats automatically before expiry. That is the whole point.
#
# Run this on node01 and node02 after 9a, instead of 8a+8b.

KUBE_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)

wget -q --show-progress --https-only --timestamping \
  https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kube-proxy \
  https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubelet

# /var/lib/kubelet/pki is the extra directory compared with 8b: it is where the
# kubelet writes the keys and certificates it obtains for itself.
sudo mkdir -p \
  /var/lib/kubelet/pki \
  /var/lib/kube-proxy \
  /var/lib/kubernetes/pki \
  /var/run/kubernetes

{
  chmod +x kube-proxy kubelet
  sudo mv kube-proxy kubelet /usr/local/bin/
}

# Only three files arrive from the control plane here — note there is no
# node01.crt/node01.key, which is exactly the saving this approach buys:
#   ca.crt        — to verify the API server (and later, the kubelet's own cert)
#   kube-proxy.*  — kube-proxy still uses a pre-issued cert; only the kubelet
#                   bootstraps.
{
  sudo mv ca.crt kube-proxy.crt kube-proxy.key /var/lib/kubernetes/pki
  sudo chown root:root /var/lib/kubernetes/pki/*
  sudo chmod 600 /var/lib/kubernetes/pki/*
}

LOADBALANCER=$(dig +short loadbalancer)
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/16
CLUSTER_DNS=$(echo $SERVICE_CIDR | awk 'BEGIN {FS="."} ; { printf("%s.%s.%s.10", $1, $2, $3) }')

# The bootstrap kubeconfig: a throwaway credential used for exactly one
# conversation — "please sign my CSR". set-credentials takes --token rather than
# a client cert/key, and the token value must match the Secret created in 9a.
# Once the kubelet has a real certificate it stops using this file.
{
  sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \
    set-cluster bootstrap --server="https://${LOADBALANCER}:6443" --certificate-authority=/var/lib/kubernetes/pki/ca.crt

  sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \
    set-credentials kubelet-bootstrap --token=07401b.f395accd246ae52d

  sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \
    set-context bootstrap --user=kubelet-bootstrap --cluster=bootstrap

  sudo kubectl config --kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \
    use-context bootstrap
}


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
cgroupDriver: systemd
clusterDomain: "cluster.local"
clusterDNS:
  - ${CLUSTER_DNS}
registerNode: true
resolvConf: /run/systemd/resolve/resolv.conf
rotateCertificates: true
runtimeRequestTimeout: "15m"
serverTLSBootstrap: true
EOF
# Same hardening as 8b (anonymous off, x509 client CA, webhook authz against
# the API server's RBAC), with two additions and one notable absence:
#
#   rotateCertificates: true
#       Renew the *client* certificate automatically as it approaches expiry,
#       by submitting a new CSR. Paired with the selfnodeclient auto-approval
#       binding in 9a, kubelet certs never expire unattended.
#
#   serverTLSBootstrap: true
#       Also request the kubelet's *serving* certificate through the CSR API
#       instead of using a self-signed one. Worth knowing: these CSRs are NOT
#       auto-approved by 9a — the kubeserving signer has no auto-approver by
#       design — so until they are approved (`kubectl get csr`, then `kubectl
#       certificate approve <name>`) the API server cannot verify the kubelet
#       and `kubectl logs` / `exec` will fail.
#
#   No tlsCertFile/tlsPrivateKeyFile
#       Unlike 8b, there is no pre-issued serving cert to point at; the kubelet
#       manages its own under --cert-dir.

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --bootstrap-kubeconfig="/var/lib/kubelet/bootstrap-kubeconfig" \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --cert-dir=/var/lib/kubelet/pki/ \\
  --node-ip=${PRIMARY_IP} \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# The interplay of these three paths is the bootstrap mechanism:
#   --kubeconfig            where the kubelet will *write* and then read its
#                           real credential. Does not exist on first start.
#   --bootstrap-kubeconfig  the token-based fallback used only while the above
#                           is missing or its cert has expired.
#   --cert-dir              where issued key/cert pairs are stored.


{
  sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/
  sudo chown root:root /var/lib/kube-proxy/kube-proxy.kubeconfig
  sudo chmod 600 /var/lib/kube-proxy/kube-proxy.kubeconfig
}


# kube-proxy is unchanged from 8b — it is not part of TLS bootstrapping and
# keeps the certificate issued back in step 2.
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: /var/lib/kube-proxy/kube-proxy.kubeconfig
mode: iptables
clusterCIDR: ${POD_CIDR}
EOF

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

# After this, watch the join happen from the control plane with
# `kubectl get csr` — you should see an approved+issued CSR per node, then the
# node appearing in `kubectl get nodes` (NotReady until step 11's CNI).
{
  sudo systemctl daemon-reload
  sudo systemctl enable kubelet kube-proxy
  sudo systemctl start kubelet kube-proxy
}
