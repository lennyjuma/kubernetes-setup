#!/bin/bash
#
# STEP 2 — The cluster PKI (certificate authority + every component certificate)
#
# WHY THIS EXISTS
# Kubernetes has no passwords. Every component — the API server, the scheduler,
# the controller manager, kube-proxy, the kubelets and the human admin — proves
# who it is with a client TLS certificate signed by one trusted CA. The API
# server then derives identity straight from the certificate's subject:
#
#   CN  (Common Name)   -> the *username*
#   O   (Organization)  -> the *group* membership
#
# That is why the subjects below are not cosmetic. "/O=system:masters" grants
# full cluster-admin via a pre-existing binding; "/CN=system:kube-scheduler"
# matches the identity the built-in scheduler RBAC role is bound to. Get a
# subject wrong and the component authenticates fine but is denied everything.
#
# Run this on controlplane01. It generates everything in the home directory and
# then fans the files out to the machines that need them.

# Resolve the real IPs of the control plane and the load balancer. These must be
# baked into the API server certificate as SANs (see openssl.cnf below) because
# clients reach the API server by several different addresses.
CONTROL01=$(dig +short controlplane01)
CONTROL02=$(dig +short controlplane02)
LOADBALANCER=$(dig +short loadbalancer)

# The service network. Kubernetes always assigns the first address in this range
# to the built-in "kubernetes" Service, which is how in-cluster pods reach the
# API server. 10.96.0.0/24 -> 10.96.0.1.
SERVICE_CIDR=10.96.0.0/24
API_SERVICE=$(echo $SERVICE_CIDR | awk 'BEGIN {FS="."} ; { printf("%s.%s.%s.1", $1, $2, $3) }')


# ---------------------------------------------------------------------------
# The Certificate Authority — the root of trust every component is told to
# trust (ca.crt) and the only key allowed to sign cluster identities (ca.key).
# ---------------------------------------------------------------------------

# Create private key for CA
openssl genrsa -out ca.key 2048
# Create CSR using the private key
openssl req -new -key ca.key -subj "/CN=KUBERNETES-CA/O=Kubernetes" -out ca.csr
# Self sign the csr using its own private key
openssl x509 -req -in ca.csr -signkey ca.key -CAcreateserial -out ca.crt -days 1000


# ---------------------------------------------------------------------------
# admin — the human operator's credential, used by kubectl in steps 9a/10/12.
# ---------------------------------------------------------------------------

# Generate private key for admin user
openssl genrsa -out admin.key 2048
# Generate CSR for admin user. Note the OU.
# O=system:masters is the magic part: the cluster-admin ClusterRoleBinding ships
# bound to that group, so this cert gets full access without any extra RBAC.
openssl req -new -key admin.key -subj "/CN=admin/O=system:masters" -out admin.csr
# Sign certificate for admin user using CA servers private key
openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt -days 1000



# ---------------------------------------------------------------------------
# kube-controller-manager — runs the reconcile loops (node, replicaset,
# endpoints, service-account controllers...). It is an API *client*, so it only
# needs a client cert whose CN matches the system:kube-controller-manager role.
# ---------------------------------------------------------------------------
openssl genrsa -out kube-controller-manager.key 2048
openssl req -new -key kube-controller-manager.key \
  -subj "/CN=system:kube-controller-manager/O=system:kube-controller-manager" -out kube-controller-manager.csr
openssl x509 -req -in kube-controller-manager.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-controller-manager.crt -days 1000




# ---------------------------------------------------------------------------
# kube-proxy — runs on every worker and programmes iptables so that Service
# ClusterIPs actually route to pods. O=system:node-proxier maps to the built-in
# system:node-proxier role (watch services and endpoints).
# ---------------------------------------------------------------------------
openssl genrsa -out kube-proxy.key 2048
openssl req -new -key kube-proxy.key \
  -subj "/CN=system:kube-proxy/O=system:node-proxier" -out kube-proxy.csr
openssl x509 -req -in kube-proxy.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-proxy.crt -days 1000




# ---------------------------------------------------------------------------
# kube-scheduler — decides which node each pending pod lands on. Client cert
# only, CN matched to the system:kube-scheduler role.
# ---------------------------------------------------------------------------
openssl genrsa -out kube-scheduler.key 2048
openssl req -new -key kube-scheduler.key \
  -subj "/CN=system:kube-scheduler/O=system:kube-scheduler" -out kube-scheduler.csr
openssl x509 -req -in kube-scheduler.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-scheduler.crt -days 1000



# ---------------------------------------------------------------------------
# kube-apiserver *serving* certificate.
#
# This one needs an explicit config file because it is the only cert that is
# presented to clients as a server, and TLS verification checks the hostname.
# Clients reach the API server by many names, every one of which must appear in
# subjectAltName or the connection is rejected:
#   - kubernetes[.default[.svc[.cluster[.local]]]]  from inside the cluster
#   - 10.96.0.1                                     the in-cluster Service IP
#   - controlplane01/02 IPs                         direct, and for peering
#   - loadbalancer IP                               how kubectl and kubelets connect
#   - 127.0.0.1                                     local components (step 3)
# extendedKeyUsage=serverAuth marks it as a server cert; CA:FALSE stops it being
# able to sign anything itself.
# ---------------------------------------------------------------------------
cat > openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster
DNS.5 = kubernetes.default.svc.cluster.local
IP.1 = ${API_SERVICE}
IP.2 = ${CONTROL01}
IP.3 = ${CONTROL02}
IP.4 = ${LOADBALANCER}
IP.5 = 127.0.0.1
EOF



openssl genrsa -out kube-apiserver.key 2048
openssl req -new -key kube-apiserver.key \
  -subj "/CN=kube-apiserver/O=Kubernetes" -out kube-apiserver.csr -config openssl.cnf
openssl x509 -req -in kube-apiserver.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-apiserver.crt -extensions v3_req -extfile openssl.cnf -days 1000

# ---------------------------------------------------------------------------
# apiserver-kubelet-client — the direction of trust most people forget.
#
# The API server also acts as a *client*: `kubectl logs`, `kubectl exec` and
# metrics all mean the API server dialling the kubelet's HTTPS port. The kubelet
# requires a client cert for that, so the API server needs its own. No SANs
# needed (it never serves with this), hence extendedKeyUsage=clientAuth only.
# O=system:masters pairs with the RBAC rules applied in step 12.
# ---------------------------------------------------------------------------
cat > openssl-kubelet.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF


openssl genrsa -out apiserver-kubelet-client.key 2048
openssl req -new -key apiserver-kubelet-client.key \
  -subj "/CN=kube-apiserver-kubelet-client/O=system:masters" -out apiserver-kubelet-client.csr -config openssl-kubelet.cnf
openssl x509 -req -in apiserver-kubelet-client.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out apiserver-kubelet-client.crt -extensions v3_req -extfile openssl-kubelet.cnf -days 1000




# ---------------------------------------------------------------------------
# etcd server certificate. etcd holds all cluster state, so it is locked down
# with mutual TLS (step 5 passes --client-cert-auth and --peer-client-cert-auth).
# The same cert is reused for both roles, so the SANs must cover both control
# plane IPs — peer-to-peer replication connects node-to-node, and 127.0.0.1
# covers the local API server and any etcdctl run on the box (step 14).
# ---------------------------------------------------------------------------
cat > openssl-etcd.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
IP.1 = ${CONTROL01}
IP.2 = ${CONTROL02}
IP.3 = 127.0.0.1
EOF


openssl genrsa -out etcd-server.key 2048
openssl req -new -key etcd-server.key \
  -subj "/CN=etcd-server/O=Kubernetes" -out etcd-server.csr -config openssl-etcd.cnf
openssl x509 -req -in etcd-server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out etcd-server.crt -extensions v3_req -extfile openssl-etcd.cnf -days 1000






# ---------------------------------------------------------------------------
# service-account keypair. This is NOT used for TLS. The API server signs
# ServiceAccount JWTs with service-account.key and the controller manager uses
# the same key to mint the tokens it injects into pods; the public half verifies
# them. Without this pair, no pod can talk to the API server.
# ---------------------------------------------------------------------------
openssl genrsa -out service-account.key 2048
openssl req -new -key service-account.key \
  -subj "/CN=service-accounts/O=Kubernetes" -out service-account.csr
openssl x509 -req -in service-account.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out service-account.crt -days 1000



# ---------------------------------------------------------------------------
# Distribution. Each machine gets only what it needs.
# ---------------------------------------------------------------------------

# Control planes get the server-side material. Note ca.key goes here too: the
# controller manager signs CSRs with it (step 6a --cluster-signing-key-file),
# which is what makes the TLS bootstrapping in step 9 possible.
for instance in controlplane01 controlplane02; do
  scp -o StrictHostKeyChecking=no ca.crt ca.key kube-apiserver.key kube-apiserver.crt \
    apiserver-kubelet-client.crt apiserver-kubelet-client.key \
    service-account.key service-account.crt \
    etcd-server.key etcd-server.crt \
    kube-controller-manager.key kube-controller-manager.crt \
    kube-scheduler.key kube-scheduler.crt \
    ${instance}:~/
done

# Workers get only the CA (to verify the API server) and the kube-proxy identity.
# Their kubelet certs are issued separately — manually in step 8a, or
# automatically via TLS bootstrapping in step 9b.
for instance in node01 node02 ; do
  scp ca.crt kube-proxy.crt kube-proxy.key ${instance}:~/
done
