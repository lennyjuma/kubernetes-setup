#!/bin/bash
#
# STEP 3 — kubeconfig files for the non-human components
#
# WHY THIS EXISTS
# A certificate alone is not enough. Each component also needs to know *where*
# the API server is and *which* CA to trust. A kubeconfig bundles those three
# things — cluster (address + CA), user (client cert + key), context (which pair
# to use) — into one file that the component is pointed at with --kubeconfig.
#
# Note that `kubectl config` is being used here purely as a file writer. No
# cluster exists yet; nothing in this script talks to the network.
#
# The important detail is the --server address, which differs deliberately:
#
#   kube-proxy          -> https://<loadbalancer>:6443
#        It runs on worker nodes, which are not control plane members, so it
#        must go through the LB and survive one control plane dying.
#
#   controller-manager  -> https://127.0.0.1:6443
#   scheduler           -> https://127.0.0.1:6443
#        Both run *on* a control plane node, alongide an API server. Talking to
#        localhost skips the load balancer entirely: one less hop, one less
#        thing that can fail, and no risk of a component being cut off from the
#        cluster because the LB is down.
#
# Run this on controlplane01, after step 2.

LOADBALANCER=$(dig +short loadbalancer)

# --- kube-proxy -------------------------------------------------------------
# Paths point at /var/lib/kubernetes/pki/... — where the cert files will live
# *on the worker* once step 8b/9b moves them there, not where they are now.
# This is why --embed-certs is NOT used: the file only references the certs.
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
    --server=https://${LOADBALANCER}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=/var/lib/kubernetes/pki/kube-proxy.crt \
    --client-key=/var/lib/kubernetes/pki/kube-proxy.key \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  # A kubeconfig with no *current* context is unusable, so select it.
  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
}


# --- kube-controller-manager ------------------------------------------------
# Local API server (127.0.0.1): it is co-located on the control plane node.
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=/var/lib/kubernetes/pki/kube-controller-manager.crt \
    --client-key=/var/lib/kubernetes/pki/kube-controller-manager.key \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
}


# --- kube-scheduler ---------------------------------------------------------
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=/var/lib/kubernetes/pki/kube-scheduler.crt \
    --client-key=/var/lib/kubernetes/pki/kube-scheduler.key \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
}

# --- admin ------------------------------------------------------------------
# Unlike the three above, this one uses --embed-certs=true, which inlines the
# cert and key as base64 into the file. That makes admin.kubeconfig entirely
# self-contained and portable — scripts 9a and 12 run `kubectl --kubeconfig
# admin.kubeconfig` from the home directory, where the loose .crt/.key files
# may already have been moved into /var/lib/kubernetes/pki by step 6a.
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.crt \
    --client-key=admin.key \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default --kubeconfig=admin.kubeconfig
}


# Ship each kubeconfig to the machine whose component will read it.
for instance in node01 node02; do
  scp kube-proxy.kubeconfig ${instance}:~/
done

for instance in controlplane01 controlplane02; do
  scp admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ${instance}:~/
done
