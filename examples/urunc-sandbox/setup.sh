#!/bin/bash
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Setup script for urunc on a Kubernetes cluster.
# Installs urunc-deploy (RBAC + DaemonSet), registers the urunc RuntimeClass,
# and waits for the nodes to be labeled by the installer.

set -euo pipefail

# Defaults
URUNC_VERSION="main"
RUNTIME_CLASS_NAME="urunc"
NODE_LABEL_KEY="urunc.io/urunc-runtime"
NODE_LABEL_VALUE="true"
FLAVOR="base"
INSTALL_URUNC=true
CHECK_KVM=true

usage() {
    cat <<'USAGE'
Usage: ./setup.sh [OPTIONS...]

  --urunc-version <ref>   Git ref of urunc-dev/urunc to install from (default: main)
  --flavor <base|k3s>     Kustomize overlay to use. Use "k3s" on k3s clusters,
                          which keep containerd's config outside /etc/containerd
                          (default: base)
  --runtime-class-name    RuntimeClass name to register (default: urunc)
  --no-install            Skip urunc-deploy; only register the RuntimeClass
  --skip-kvm-check        Do not verify /dev/kvm on the local host
  -h, --help              Show this message
USAGE
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --urunc-version)      URUNC_VERSION="$2"; shift ;;
        --flavor)             FLAVOR="$2"; shift ;;
        --runtime-class-name) RUNTIME_CLASS_NAME="$2"; shift ;;
        --no-install)         INSTALL_URUNC=false ;;
        --skip-kvm-check)     CHECK_KVM=false ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
    esac
    shift
done

if [[ "${FLAVOR}" != "base" && "${FLAVOR}" != "k3s" ]]; then
    echo "Error: --flavor must be 'base' or 'k3s' (got '${FLAVOR}')."
    exit 1
fi

# Validate the ref so it cannot be used to escape the kustomize URL path.
if [[ ! "${URUNC_VERSION}" =~ ^[0-9A-Za-z._/-]+$ ]]; then
    echo "Error: Invalid urunc version/ref: '${URUNC_VERSION}'"
    exit 1
fi

URUNC_REPO="https://github.com/urunc-dev/urunc"

echo "### Configuration ###"
echo "URUNC_VERSION:       ${URUNC_VERSION}"
echo "FLAVOR:              ${FLAVOR}"
echo "RUNTIME_CLASS_NAME:  ${RUNTIME_CLASS_NAME}"
echo "INSTALL_URUNC:       ${INSTALL_URUNC}"
echo "#####################"
echo ""

#############################################################################
# Step 1: Verify KVM support
#############################################################################
echo "### Step 1: Verifying KVM support ###"
if [[ "${CHECK_KVM}" == "true" ]]; then
    if [[ ! -e /dev/kvm ]]; then
        echo "Error: /dev/kvm not found. urunc boots workloads inside a VMM"
        echo "(QEMU, Firecracker, Cloud Hypervisor) and needs hardware virtualization."
        echo "Ensure your host CPU supports VT-x/AMD-V and that KVM modules are loaded."
        echo "Try: sudo modprobe kvm && sudo modprobe kvm_intel (or kvm_amd)"
        echo ""
        echo "If you are running this script from a workstation that drives a remote"
        echo "cluster whose nodes do have KVM, pass --skip-kvm-check to bypass."
        exit 1
    fi
    echo "### KVM support detected at /dev/kvm ###"
    echo ""
    echo "Note: this check runs on the local machine only. Ensure every target node"
    echo "      has /dev/kvm before scheduling urunc pods onto it."
else
    echo "### Step 1: Skipped (--skip-kvm-check) ###"
fi
echo ""

#############################################################################
# Step 2: Install urunc via urunc-deploy
#############################################################################
if [[ "${INSTALL_URUNC}" == "true" ]]; then
    echo "### Step 2: Installing urunc (urunc-deploy) ###"

    echo "--- Applying urunc RBAC ---"
    kubectl apply -k "${URUNC_REPO}/deployment/urunc-deploy/urunc-rbac?ref=${URUNC_VERSION}"

    echo "--- Applying urunc-deploy DaemonSet (${FLAVOR}) ---"
    if [[ "${FLAVOR}" == "k3s" ]]; then
        DEPLOY_PATH="deployment/urunc-deploy/urunc-deploy/overlays/k3s"
    else
        DEPLOY_PATH="deployment/urunc-deploy/urunc-deploy/base"
    fi
    kubectl apply -k "${URUNC_REPO}/${DEPLOY_PATH}?ref=${URUNC_VERSION}"

    echo "--- Waiting for urunc-deploy rollout (this may take several minutes) ---"
    echo "    The installer places the urunc binaries and hypervisors on each node,"
    echo "    rewrites the containerd config, and reloads containerd."
    kubectl -n kube-system rollout status daemonset/urunc-deploy --timeout=10m
    echo "### urunc installed ###"
else
    echo "### Step 2: Skipped (--no-install) ###"
fi
echo ""

#############################################################################
# Step 3: Register the urunc RuntimeClass
#############################################################################
echo "### Step 3: Registering RuntimeClass '${RUNTIME_CLASS_NAME}' ###"

cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: ${RUNTIME_CLASS_NAME}
handler: urunc
scheduling:
  nodeSelector:
    kubernetes.io/os: linux
    ${NODE_LABEL_KEY}: "${NODE_LABEL_VALUE}"
EOF

echo "### RuntimeClass '${RUNTIME_CLASS_NAME}' created ###"
echo ""

#############################################################################
# Step 4: Verify installation
#############################################################################
echo "### Step 4: Verifying installation ###"
echo "--- RuntimeClasses ---"
kubectl get runtimeclasses
echo ""
echo "--- Nodes with urunc installed ---"
# urunc-deploy applies this label itself once install.sh finishes on the node.
# An empty list means the DaemonSet has not finished; check its logs with:
#   kubectl logs -n kube-system -l name=urunc-deploy
kubectl get nodes -l "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" -o wide || true
echo ""
echo "### Setup complete! ###"
echo "You can now deploy urunc-based Agent Sandboxes using RuntimeClass '${RUNTIME_CLASS_NAME}'."
echo "Remember: the sandbox image must be repackaged for urunc first — see bunnyfile."
