#!/bin/bash
#
# STEP 7 — Container runtime and kernel prerequisites on the workers
#
# WHY THIS COMPONENT IS NEEDED
# The kubelet does not run containers itself. It speaks CRI (the Container
# Runtime Interface) over a unix socket to a runtime that does the actual work
# of pulling images and starting processes. containerd is that runtime — without
# it the kubelet starts, registers the node, and then fails every pod.
#
# This script also does the kernel plumbing that container networking depends
# on, which is the part people skip and then spend hours debugging.
#
# Run this on node01 and node02, before step 8b/9b.

{
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl
}


# Two kernel modules that pod networking cannot work without:
#   overlay      — the overlayfs snapshotter containerd uses to layer images.
#   br_netfilter — lets iptables see traffic crossing a Linux bridge, which is
#                  what kube-proxy's Service rules and NetworkPolicy rely on.
# The file in /etc/modules-load.d makes them load again after a reboot; the two
# modprobe calls load them right now for this boot.
{
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter
}

# The matching sysctls:
#   bridge-nf-call-ip[6]tables=1 — bridged packets traverse iptables, so
#       Service ClusterIPs get DNAT'd for pod-to-pod traffic on the same node.
#   ip_forward=1 — the node must route packets between the pod network and the
#       outside world. Off by default on Debian/Ubuntu; leave it off and
#       cross-node pod traffic silently blackholes.
# Written as a file (not just `sysctl -w`) so it survives reboots; `sysctl
# --system` reloads everything from disk immediately.
{
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sudo sysctl --system
}
# pkgs.k8s.io is versioned per minor release (v1.31, not v1.31.4), so trim the
# patch component off the stable tag to build the repo URL.
KUBE_LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt | awk 'BEGIN { FS="." } { printf "%s.%s", $1, $2 }')

# Add the official Kubernetes apt repo, with its signing key, so packages are
# verified rather than trusted blindly.
{
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBE_LATEST}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
}

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_LATEST}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
# containerd        — the CRI runtime.
# kubernetes-cni    — the reference CNI plugin binaries in /opt/cni/bin, which
#                     the CNI config from step 11 invokes to wire up each pod.
# kubectl           — convenient for debugging from the node.
# ipvsadm, ipset    — kube-proxy's IPVS-mode dependencies. Step 8b/9b configure
#                     iptables mode, so these are installed for the option to
#                     switch later rather than being required right now.
sudo apt-get install -y containerd kubernetes-cni kubectl ipvsadm ipset


# Generate containerd's default config and flip one value.
#
# SystemdCgroup=true is not optional: the kubelet is configured with
# cgroupDriver=systemd (step 8b/9b), and if the runtime and the kubelet disagree
# about who owns the cgroup hierarchy you get two competing views of resource
# limits, which shows up as pods being killed or node instability under load.
{
    sudo mkdir -p /etc/containerd
    containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' | sudo tee /etc/containerd/config.toml
}

sudo systemctl restart containerd
