#!/bin/bash
#
# STEP 13 — CoreDNS: cluster DNS
#
# WHY THIS COMPONENT IS NEEDED
# Service discovery in Kubernetes is DNS. A Service gets a ClusterIP, but
# nothing in a pod knows that IP — application code connects to a *name* like
# "my-svc.default.svc.cluster.local". CoreDNS is what resolves those names
# (plus pod-to-pod names and forwarding for external lookups).
#
# Everything is already pointed at it: the kubelet config in step 8b/9b writes
#     clusterDNS: 10.96.0.10
#     clusterDomain: cluster.local
# into every pod's /etc/resolv.conf. If CoreDNS is not running, those lookups
# simply time out — pods start, networking works by IP, and every name-based
# connection fails. The manifest claims the matching 10.96.0.10 ClusterIP, which
# is why the kubelet's CLUSTER_DNS is derived from SERVICE_CIDR rather than
# guessed.
#
# Must come after step 11 — CoreDNS is itself a pod and needs pod networking.
#
# Run from controlplane01.

kubectl apply -f https://raw.githubusercontent.com/mmumshad/kubernetes-the-hard-way/master/deployments/coredns.yaml

# Expect two coredns pods Running (the manifest runs 2 replicas for redundancy,
# since DNS is on the hot path of nearly every request in the cluster).
kubectl get pods -l k8s-app=kube-dns -n kube-system
