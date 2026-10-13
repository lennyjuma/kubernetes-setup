#!/bin/bash
#
# STEP 10 — The admin's own kubectl config (remote access)
#
# WHY THIS EXISTS
# Everything up to now used `--kubeconfig admin.kubeconfig` explicitly. This
# writes the same credential into the *default* location (~/.kube/config), so
# plain `kubectl get nodes` works from this machine without flags — which is
# what steps 11-14 assume.
#
# The difference from the admin.kubeconfig built in step 3 is the server
# address: that one points at 127.0.0.1 (it was for use on a control plane
# node), this one points at the load balancer, so it works from anywhere and
# survives one control plane node failing.
#
# It is also the first real end-to-end check: if these two kubectl calls return
# anything, then the certs (step 2), etcd (5), the control plane (6a) and the
# load balancer (6b) are all genuinely working together.

LOADBALANCER=$(dig +short loadbalancer)


# No --kubeconfig flag anywhere in this block, so all four commands write to
# ~/.kube/config. --embed-certs=true on the cluster entry inlines the CA so the
# file does not depend on ca.crt staying put in the current directory.
{

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://${LOADBALANCER}:6443

  kubectl config set-credentials admin \
    --client-certificate=admin.crt \
    --client-key=admin.key

  kubectl config set-context kubernetes-the-hard-way \
    --cluster=kubernetes-the-hard-way \
    --user=admin

  # Select it, otherwise kubectl has a context defined but none active.
  kubectl config use-context kubernetes-the-hard-way
}

# Verification. componentstatuses is deprecated and may report nothing useful on
# current releases; `kubectl get nodes` is the check that matters.
kubectl get componentstatuses

# Expect both workers listed. NotReady is the correct state at this point —
# the kubelet holds the node back until a CNI plugin provides pod networking,
# which is step 11.
kubectl get nodes
