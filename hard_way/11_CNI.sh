#!/bin/bash
#
# STEP 11 — CNI: pod networking (Weave Net)
#
# WHY THIS COMPONENT IS NEEDED
# Kubernetes does not implement pod networking. It defines a contract — every
# pod gets its own IP, and every pod can reach every other pod across nodes
# without NAT — and leaves the implementation to a CNI plugin. Until one is
# installed:
#   - nodes stay NotReady (the kubelet refuses readiness without a network),
#   - no pod can be scheduled successfully,
#   - and nothing in step 13 or 14 will work.
#
# Weave Net runs as a DaemonSet, so one pod per node, each programming the host
# so pods get addresses out of the /24 that the controller manager assigned to
# that node (POD_CIDR -> Node.spec.podCIDR, see --allocate-node-cidrs in 6a).
#
# Note the division of labour with kube-proxy: CNI gives pods real IPs and
# routes between them; kube-proxy turns Service ClusterIPs into those pod IPs.
# Both are required.
#
# Run from controlplane01, after step 10 so kubectl works without flags.

kubectl apply -f "https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s-1.11.yaml"

# Watch for one weave-net pod per node reaching Running. Until then, nodes stay
# NotReady — re-run this until the pods settle.
kubectl get pods -n kube-system

kubectl get pods -n kube-system
