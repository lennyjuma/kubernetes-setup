#!/bin/bash
#
# STEP 6b — HAProxy in front of the two API servers
#
# WHY THIS COMPONENT IS NEEDED
# There are two API servers, but a client can only be configured with one
# address. Workers, kubectl and anything outside the control plane need a single
# stable endpoint that survives one control plane node going down — that is all
# this box is. It is the address baked into the kube-proxy and kubelet
# kubeconfigs (steps 3, 8a, 9b), into the API server certificate's SANs
# (step 2) and into --service-account-issuer (step 6a).
#
# Components that run *on* a control plane node deliberately bypass it and use
# 127.0.0.1 instead, so the LB is never a dependency for the control plane's own
# internal wiring.
#
# Run this on the loadbalancer machine, after step 6a.

sudo apt-get update && sudo apt-get install -y haproxy

CONTROL01=$(dig +short controlplane01)
CONTROL02=$(dig +short controlplane02)
LOADBALANCER=$(dig +short loadbalancer)

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
frontend kubernetes
    bind ${LOADBALANCER}:6443
    option tcplog
    mode tcp
    default_backend kubernetes-controlplane-nodes

backend kubernetes-controlplane-nodes
    mode tcp
    balance roundrobin
    option tcp-check
    server controlplane01 ${CONTROL01}:6443 check fall 3 rise 2
    server controlplane02 ${CONTROL02}:6443 check fall 3 rise 2
EOF
# mode tcp is the critical choice, not an arbitrary one. This must be a layer-4
# pass-through: the client's TLS session terminates at the API server itself, so
# the API server still sees the client certificate and can authenticate it. An
# HTTP-mode proxy would terminate TLS here and every component would lose its
# identity (and HAProxy would need the server key).
#
# Listening on 6443 — the same port as the backends — keeps the LB transparent,
# so one address works everywhere without rewriting ports.
#
# option tcp-check + "check fall 3 rise 2": health-check by opening a TCP
# connection; take a node out after 3 consecutive failures, put it back after 2
# successes. The asymmetry is deliberate — slow to evict (avoid flapping on a
# blip), quick to restore.
#
# balance roundrobin is safe here because the API server is stateless; any
# request can go to either node.

sudo systemctl restart haproxy
