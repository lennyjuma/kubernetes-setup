#!/bin/bash
#
# STEP 6a — The control plane: kube-apiserver, kube-controller-manager, kube-scheduler
#
# WHY THESE THREE COMPONENTS EXIST
#
#   kube-apiserver
#       The front door and the only component that talks to etcd. It does
#       authentication, authorisation, admission control and validation, then
#       persists the result. Everything else in Kubernetes — kubectl, the
#       kubelets, the controllers, the scheduler — is just an API client. It is
#       stateless, which is why two copies can run behind the load balancer.
#
#   kube-controller-manager
#       The reconcile engine. It bundles dozens of control loops that each
#       watch desired state and act to make reality match: node lifecycle,
#       ReplicaSet -> Pod creation, Endpoints, ServiceAccount tokens, and the
#       CSR signer that makes TLS bootstrapping (step 9) work. Without it a
#       Deployment is an inert object — nothing would ever create its pods.
#
#   kube-scheduler
#       Watches for pods with no nodeName and picks a node for each, based on
#       resource requests, affinity and taints. Without it pods stay Pending
#       forever.
#
# Run this on *both* controlplane01 and controlplane02 (it uses the local
# PRIMARY_IP). Only the API server is active/active — the controller manager and
# scheduler use --leader-elect so exactly one of the two is doing work at a
# time, with the other on standby.

KUBE_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)

wget -q --show-progress --https-only --timestamping \
  "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kube-apiserver" \
  "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kube-controller-manager" \
  "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kube-scheduler" \
  "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl"


{
  chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
  sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
}

{
  sudo mkdir -p /var/lib/kubernetes/pki

  # Only copy CA keys as we'll need them again for workers.
  # (cp, not mv — steps 8a/9a still read ca.crt/ca.key from the home directory
  # to sign worker certificates. Everything else is moved, since nothing later
  # needs it here.)
  sudo cp ca.crt ca.key /var/lib/kubernetes/pki
  for c in kube-apiserver service-account apiserver-kubelet-client etcd-server kube-scheduler kube-controller-manager
  do
    sudo mv "$c.crt" "$c.key" /var/lib/kubernetes/pki/
  done
  # Private keys must not be world-readable; the API server runs as root.
  sudo chown root:root /var/lib/kubernetes/pki/*
  sudo chmod 600 /var/lib/kubernetes/pki/*
}

LOADBALANCER=$(dig +short loadbalancer)

CONTROL01=$(dig +short controlplane01)
CONTROL02=$(dig +short controlplane02)

# The two cluster networks. They must not overlap, and the same values have to
# be repeated identically in step 8b/9b for the workers:
#   POD_CIDR     — addresses handed to pods; carved into /24s per node and
#                  routed by the CNI plugin (step 11).
#   SERVICE_CIDR — virtual ClusterIP range; purely an iptables fiction
#                  maintained by kube-proxy, nothing ever ARPs for these.
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/16

cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${PRIMARY_IP} \\
  --allow-privileged=true \\
  --apiserver-count=2 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=/var/lib/kubernetes/pki/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/pki/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/pki/etcd-server.key \\
  --etcd-servers=https://${CONTROL01}:2379,https://${CONTROL02}:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/pki/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/pki/apiserver-kubelet-client.crt \\
  --kubelet-client-key=/var/lib/kubernetes/pki/apiserver-kubelet-client.key \\
  --runtime-config=api/all=true \\
  --service-account-key-file=/var/lib/kubernetes/pki/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/pki/service-account.key \\
  --service-account-issuer=https://${LOADBALANCER}:6443 \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/pki/kube-apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/pki/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# The flags that actually matter here:
#
#   --authorization-mode=Node,RBAC
#       Two authorisers, tried in order. RBAC is the general rules engine;
#       the Node authoriser additionally restricts each kubelet to reading only
#       the Secrets/ConfigMaps/Pods belonging to pods on *its own* node — so a
#       compromised worker cannot read the whole cluster's secrets.
#   --enable-admission-plugins=NodeRestriction,ServiceAccount
#       NodeRestriction is the write-side partner to the Node authoriser: a
#       kubelet may only modify its own Node and Pod objects. ServiceAccount
#       auto-injects the SA token into every pod.
#   --client-ca-file
#       The CA used to *verify incoming client certs*. This is the line that
#       makes every identity minted in step 2 actually accepted.
#   --tls-cert-file / --tls-private-key-file
#       The serving cert with all those SANs.
#   --kubelet-client-certificate / --kubelet-certificate-authority
#       The reverse direction: credentials the API server presents when it
#       dials a kubelet for logs/exec, plus the CA to verify the kubelet.
#   --etcd-* : mutual TLS to etcd. Both members are listed so the API server
#       fails over if one dies.
#   --service-account-key-file (public) and --service-account-signing-key-file
#       (private) — verify and issue ServiceAccount JWTs respectively.
#   --service-account-issuer
#       The 'iss' claim baked into those tokens; points at the LB because that
#       is the address a third party could reach to validate them.
#   --encryption-provider-config : activates step 4's at-rest encryption.
#   --enable-bootstrap-token-auth : accepts the bootstrap token from step 9a.
#   --advertise-address : the IP this API server publishes to cluster clients;
#       must be the node's real IP, while --bind-address=0.0.0.0 just means
#       "listen on all interfaces".
#   --apiserver-count=2 : sizes the endpoint reconciler for a 2-node HA setup.
#   --service-node-port-range : the ports NodePort Services may claim (used in
#       the step 14 smoke test).
#   --audit-log-* : records every API request to /var/log/audit.log with
#       rotation, so there is a forensic trail of who changed what.


sudo mv kube-controller-manager.kubeconfig /var/lib/kubernetes/

cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --allocate-node-cidrs=true \\
  --authentication-kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --authorization-kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --bind-address=127.0.0.1 \\
  --client-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --cluster-cidr=${POD_CIDR} \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/pki/ca.crt \\
  --cluster-signing-key-file=/var/lib/kubernetes/pki/ca.key \\
  --controllers=*,bootstrapsigner,tokencleaner \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --node-cidr-mask-size=24 \\
  --requestheader-client-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --root-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --service-account-private-key-file=/var/lib/kubernetes/pki/service-account.key \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# Flag notes:
#
#   --allocate-node-cidrs + --cluster-cidr + --node-cidr-mask-size=24
#       The node IPAM controller slices POD_CIDR (10.244.0.0/16) into a /24 per
#       node and writes it to Node.spec.podCIDR. The CNI plugin in step 11 reads
#       that to decide which addresses it owns on each host.
#   --cluster-signing-cert-file / --cluster-signing-key-file
#       This is why ca.key had to be shipped to the control plane: the CSR
#       signing controller uses it to issue certificates for CertificateSigning
#       Request objects. That is the whole mechanism behind step 9's automatic
#       kubelet certificates.
#   --controllers=*,bootstrapsigner,tokencleaner
#       Everything, plus two that are off by default. bootstrapsigner publishes
#       cluster-info so a bootstrapping kubelet can trust the CA; tokencleaner
#       deletes bootstrap tokens once they expire (step 9a sets a 7-day TTL).
#   --leader-elect=true
#       With two replicas running, both would otherwise reconcile the same
#       objects and fight. Leader election via a Lease means one works, one waits.
#   --use-service-account-credentials=true
#       Each internal controller acts as its own ServiceAccount rather than as
#       one superuser, so RBAC can scope them individually.
#   --service-account-private-key-file : signs the SA tokens it injects.
#   --root-ca-file : the CA bundle copied into every pod's token secret, which
#       is how in-cluster clients learn to trust the API server.
#   --bind-address=127.0.0.1 : its metrics/health port is not exposed off-box.

sudo mv kube-scheduler.kubeconfig /var/lib/kubernetes/

cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --kubeconfig=/var/lib/kubernetes/kube-scheduler.kubeconfig \\
  --leader-elect=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# The scheduler needs almost no configuration: the kubeconfig tells it how to
# reach and authenticate to the API server, and --leader-elect keeps the two
# replicas from both assigning the same pod to different nodes. Everything else
# (predicates, scoring) runs on sane defaults.

# These kubeconfigs embed no secrets but do reference key paths; 0600 keeps them
# consistent with the rest of the control plane material.
sudo chmod 600 /var/lib/kubernetes/*.kubeconfig

# daemon-reload makes systemd read the three new unit files, enable sets them to
# start at boot, start brings them up now. Order within the command is fine:
# the API server may log etcd connection errors until etcd has quorum, and the
# controller manager/scheduler retry until the API server answers.
{
  sudo systemctl daemon-reload
  sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
  sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
}
