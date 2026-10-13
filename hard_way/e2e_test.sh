#!/bin/bash
#
# OPTIONAL — Kubernetes conformance (end-to-end) test suite
#
# WHY THIS EXISTS
# The smoke test in step 14 checks the handful of paths this build is most
# likely to have broken. This runs the *official* upstream conformance suite —
# several hundred tests from the Kubernetes project itself — and is the real
# answer to "is this a legitimate Kubernetes cluster?". It is what CNCF
# certification is based on.
#
# It is slow (tens of minutes to hours) and it creates and destroys a lot of
# objects, so it belongs on a freshly built lab cluster, not a cluster with
# anything on it you care about.
#
# Tooling: kubetest2 is the upstream test orchestrator, written in Go, so Go has
# to be installed first — hence the first half of this script.
#
# Run on controlplane01, after step 13 and ideally after step 14 passes.

# Install the current Go toolchain. Resolving the version from go.dev rather
# than pinning avoids a stale toolchain the current kubetest2 won't build with.
GO_VERSION=$(curl -s 'https://go.dev/VERSION?m=text' | head -1)
wget "https://dl.google.com/go/${GO_VERSION}.linux-${ARCH}.tar.gz"

sudo tar -C /usr/local -xzf ${GO_VERSION}.linux-${ARCH}.tar.gz

# Symlink into /usr/local/bin rather than editing PATH, so go works under sudo
# and in non-login shells too.
sudo ln -s /usr/local/go/bin/go /usr/local/bin/go
sudo ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# `go env` prints shell-style assignments; sourcing it imports GOPATH etc. so
# the next line's installed binaries can be found.
source <(go env)
export PATH=$PATH:$GOPATH/bin


# kubetest2 downloads and drives the ginkgo-based e2e binaries.
go install sigs.k8s.io/kubetest2/...@latest
# The suite's test fixtures expect gcloud on PATH even for a non-GCP cluster.
sudo snap install google-cloud-cli --classic

# The test binaries are version-matched to the cluster, so pull the same stable
# tag the components were installed from.
KUBE_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
# Run as many tests in parallel as there are cores; without this the suite takes
# considerably longer.
NUM_CPU=$(cat /proc/cpuinfo | grep '^processor' | wc -l)

cd ~
# --noop          : "the cluster already exists" — do not try to provision one.
#                   The deployer's only job here is to run tests.
# --kubeconfig    : the admin credential written by step 10.
# --test=ginkgo   : use the upstream ginkgo e2e runner.
# --focus-regex='\[Conformance\]'
#                   Restrict to the conformance subset. Without it you also pull
#                   in provider-specific, alpha and disruptive tests that will
#                   fail on a hand-built bare-metal cluster for reasons that say
#                   nothing about whether the build is correct.
kubetest2 noop --kubeconfig ${PWD}/.kube/config --test=ginkgo -- \
  --focus-regex='\[Conformance\]' --test-package-version $KUBE_VERSION --parallel $NUM_CPU

# Live view of what the suite is creating and tearing down across all namespaces
# while it runs.
watch kubectl get all -A
