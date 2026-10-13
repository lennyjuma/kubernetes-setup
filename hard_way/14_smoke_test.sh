#!/bin/bash
#
# STEP 14 — Smoke test
#
# WHY THIS EXISTS
# Every component can report healthy while the cluster is still broken in ways
# that only show up when you actually use it. This walks the main paths one at a
# time so a failure points at a specific step rather than "it doesn't work":
#
#   1. Secret encryption at rest   -> step 4 + 6a
#   2. Deployment creates a pod    -> controller manager + scheduler (6a)
#   3. NodePort reachable          -> kube-proxy (8b/9b) + CNI (11)
#   4. Logs                        -> apiserver->kubelet RBAC (12)
#   5. Exec                        -> same path, interactive
#
# Run from controlplane01 after step 13. It cleans up after itself.

# --- 1. Is encryption at rest really on? ------------------------------------
kubectl create secret generic kubernetes-the-hard-way \
  --from-literal="mykey=mydata"

# Read the raw bytes straight out of etcd, bypassing the API server entirely.
# The hexdump should begin with "k8s:enc:aescbc:v1:key1" and the value should be
# ciphertext. If you can read "mydata" in the output, the API server is not
# using encryption-config.yaml and step 4 or the --encryption-provider-config
# flag in 6a is wrong.
sudo ETCDCTL_API=3 etcdctl get \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key\
  /registry/secrets/default/kubernetes-the-hard-way | hexdump -C

kubectl delete secret kubernetes-the-hard-way

# --- 2. Does the control plane actually schedule work? ----------------------
# This single command exercises the whole chain: API server persists the
# Deployment, the controller manager creates a ReplicaSet then a Pod, the
# scheduler assigns a node, the kubelet pulls the image via containerd, and the
# CNI plugin gives it an IP.
kubectl create deployment nginx --image=nginx:alpine

# Should reach Running. Pending => scheduler or CNI; ContainerCreating stuck =>
# containerd or networking on the node.
kubectl get pods -l app=nginx

# --- 3. Does Service networking work? ---------------------------------------
# NodePort opens the same port on every node and forwards it to the pod, so
# curling *both* nodes proves two separate things: kube-proxy wrote the rules on
# each node, and cross-node pod routing works (one of these requests has to hop
# to the node that isn't hosting the pod).
kubectl expose deploy nginx --type=NodePort --port 80
PORT_NUMBER=$(kubectl get svc -l app=nginx -o jsonpath="{.items[0].spec.ports[0].nodePort}")
curl -v http://node01:$PORT_NUMBER
curl -v http://node02:$PORT_NUMBER

# --- 4 & 5. Can the API server reach the kubelets? --------------------------
# Both of these are proxied through the kubelet on port 10250, so a 403 here
# means step 12's RBAC is missing, and a TLS error means the kubelet's serving
# certificate is wrong (or, on the 9b path, its serverTLSBootstrap CSR is still
# unapproved).
POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
kubectl logs $POD_NAME

kubectl exec -ti $POD_NAME -- nginx -v

# --- Cleanup ----------------------------------------------------------------
# (The busybox line is a leftover from the DNS check in the upstream guide; it
# is harmless if no such pod exists.)
kubectl delete pod -n default busybox
kubectl delete service -n default nginx
kubectl delete deployment -n default nginx
