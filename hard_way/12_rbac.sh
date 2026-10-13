#!/bin/bash
#
# STEP 12 — RBAC: let the API server call the kubelets
#
# WHY THIS EXISTS
# The kubelet configs in step 8b/9b set `authorization.mode: Webhook`, which
# means the kubelet does not decide for itself who may hit its API on port
# 10250 — it asks the API server "is this caller authorised?". The API server
# answers using RBAC. So the API server itself needs an RBAC rule granting it
# access to the kubelet, or it is refused by its own answer.
#
# Without this, the cluster looks healthy but these all fail with 403 Forbidden:
#   kubectl logs <pod>
#   kubectl exec -ti <pod> -- sh
#   kubectl top / metrics-server scraping
#
# These are the same objects kubeadm creates automatically; here they are
# applied by hand, which is the point of the exercise.
#
# Run on controlplane01 once the workers have joined.

# The ClusterRole: permission over the kubelet's HTTPS sub-resources on Node
# objects. These are not stored data — each one is a proxied call to the kubelet
# on that node:
#   nodes/proxy   — the generic tunnel used by logs and exec
#   nodes/stats   — resource usage
#   nodes/log     — host log files
#   nodes/spec    — node hardware/config detail
#   nodes/metrics — the kubelet's Prometheus endpoint
#
# The autoupdate annotation and the rbac-defaults label mirror what the API
# server puts on its own bootstrap roles, so it will reconcile this role back to
# this definition if it is edited.
cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

# The binding: grant that role to the user named "kube-apiserver".
#
# That name is not arbitrary — it is the CN of the certificate the API server
# presents when dialling a kubelet. Step 2 created it as:
#     -subj "/CN=kube-apiserver/O=Kubernetes"   (kube-apiserver.crt)
# and step 6a passes it as --kubelet-client-certificate. If that CN and this
# `name:` ever drift apart, logs/exec break with a 403 and nothing else does,
# which makes it a confusing failure to diagnose.
#
# Cluster-scoped, so `namespace: ""` is correct — Node objects have no namespace.
cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kube-apiserver
EOF
