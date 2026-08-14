# A `urunc`-based sandbox

This example shows how to use [urunc](https://github.com/urunc-dev/urunc), as a
container runtime for agent-sandbox deployments. As an exmaple here, we wll use
the sandbox runs the existing
[`python-runtime-sandbox`](../python-runtime-sandbox) FastAPI server on port
`8888`, unmodified. Only the *packaging* of the image changes,


## About `urunc`

`urunc` is a CNCF Sandbox project, which acts as a container runtime for
unikernels and single application kernels.  It is agnostic to the sandbox and
the guest. It supports both VM-based sandboxes and saoftware-based sandboxes.
Also, it supports various types of guests, from unikernels to more generic
kernels like Linux and BSD. It does not require any component alongside the
sandbox or inside it. In a Linux container this means that the container's init
is the init of the microVM. Thanks to its design it can acheve near-container
spawn times while consuming as less resources as possible.

## How urunc differs from other sandboxed container runtimes

As other snadboxed contianer runtimes `urunc` does not execute applications
directly on the host. Instead, it runs them inside microVMs or software-based
monitors, introducing an additional layer of isolation between the application
and the host. 

The key distinction between `urunc` and other sandboxed xontainer runtimes,
like `gVisor` or `Kata contianers` is that `urunc` spawns every contianer in
its own sandobx. does not require any guest component or sandbox side process
in the host and it is unopionionated , meaning it can support any types of
sandbox (VM or software based) and any type of guest.  Guests cna be as small
as unikernels and as big as generic kernels like Linux and BSD. Therefore,
`urunc` is highly configurable and extensible to what guests and sandbox
monitors t can support.

The above design has the side effect that every container spawned with urunc runs
in its own sandbox, but inside the same pod.

Dues to its design, `urunc` expects every workload to come along with its kernel
wither in the form of unikernel or in the form of a normal application packages
with a kernel. Therefore, for the case of existing container images, we need to
attach a Linux kernel which `urunc` will use to spaw the microVM.

> **NOTE**: We are in discussions to provide a default Linux kernel in order
> to allow existing Linux containers to execute on top of `urunc` unmodified.

TO simplify this process, we highly recommend the use of
T[bunny](https://github.com/nubificus/bunny),, a buildkit frontend which
builds unikernels and kernels or simply takes care of attaching a LInux kernel
in Linux contianers.

Due to its design, `urunc` is able to spawn sandboxed applications in near-contianer
time with low resource consumption while maintaining high isolation boundaries with
much smaller attack surface.

wo constraints follow from urunc's design, and both shape this example:

1. **Images must carry their own kernel.** urunc does not run a shared guest
   image with your rootfs bind-mounted in; each workload is packaged with the
   kernel it boots. [bunny](https://github.com/nubificus/bunny), a BuildKit
   frontend, does this repackaging and emits an ordinary OCI image, so registries
   and CRI implementations are none the wiser. See [`bunnyfile`](./bunnyfile).

2. **One container per microVM.** The sandbox is deliberately minimal and wraps
   only the untrusted workload.

In exchange you get a VM boundary at roughly gVisor's startup cost, and the
option of dropping Linux altogether for a unikernel guest with a far smaller
attack surface.

## Exmaple architecture

```text
   Control plane / HTTP client
          │
          │  HTTP (port 8888)
          │  ───── Sandbox Service ─── OR ─── sandbox-router (X-Sandbox-ID) ───┐
          │                                                                    │
          ▼                                                                    │
   Pod (runtimeClassName: urunc)                                               │
   ┌────────────────────────────────────┐                                      │
   │  microVM (QEMU) + Linux kernel     │                                      │
   │  ┌──────────────────────────────┐  │                                      │
   │  │ urunit (init)                │  │                                      │
   │  │  └─ python-runtime (main.py) │◀─┼──────────────────────────────────────┘
   │  │     - GET  /                 │  │
   │  │     - POST /execute          │  │
   │  └──────────────────────────────┘  │
   └────────────────────────────────────┘
          ▲
          │
   agent-sandbox controller
   (Sandbox, or SandboxClaim against a SandboxTemplate + SandboxWarmPool)
```

## Prerequisites

1. A **Linux** node with **hardware virtualization (KVM)**. urunc boots the
   workload in a VMM, so `/dev/kvm` must be present on every node that will
   schedule these sandboxes. Verify with `ls /dev/kvm` and
   `egrep -c '(vmx|svm)' /proc/cpuinfo`. On GCP this means an **N2** instance
   with [nested virtualization enabled](https://cloud.google.com/compute/docs/instances/nested-virtualization/managing-constraint);
   on bare metal, enable VT-x or AMD-V in the BIOS and load the KVM modules.
2. A Kubernetes cluster with the agent-sandbox controller installed — see the
   [Installation Guide](../../README.md#installation). This example was
   validated on single-node [k3s](https://k3s.io/) and on kubeadm clusters.
3. [`kubectl`](https://kubernetes.io/docs/tasks/tools/) configured to talk to
   the cluster.
4. Docker and a registry the cluster can
   pull from. bunny runs as a BuildKit frontend, so BuildKit must be enabled —
   it is the default in modern Docker.

## Step 0: Install the agent-sandbox controller

Follow the [installation guide](../../README.md#installation) to install the
controller and CRDs.

## Step 1: Install urunc on the nodes

For a smoother installation process `urunc` provides a daemon set which takes
care of installing all supported monitors, `urunc` and configures both
`containerd` and `urunc`.The exact commands to use the daemon set are in the
[documentation of `urunc`](https://urunc.io/tutorials/How-to-urunc-on-k8s/).
For this exmaple though, the [`setup.sh`](./setup.sh) script It applies the
urunc-deploy RBAC and DaemonSet, waits for the rollout, and registers the
`urunc` RuntimeClass:

```shell
./setup.sh                    # kind, kubeadm, EKS, ...
./setup.sh --flavor k3s       # k3s requires different kustomize
```

urunc-deploy installs the `urunc` binaries and the supported sandbox monitors on each
node, rewrites the containerd configuration, reloads containerd, and labels the
node `urunc.io/urunc-runtime=true`. That label is what the RuntimeClass and the
manifests in this directory select on.

Confirm it worked:

```shell
kubectl get runtimeclass urunc
kubectl get nodes -l urunc.io/urunc-runtime=true
```

## Step 2: Build the image appending the kernel

The sandbox application is the unmodified `python-runtime-sandbox` example.
So inside its directory we need to prepend the line 

```
#syntax=harbor.nbfc.io/nubificus/bunny:latest
```

above all comments to instruct docker to use `bunny`. We cna then build the image
as usual:

```shell
export BASE_IMAGE=<registry>/python-runtime-sandbox:latest
docker build -f Dockerfile -t ${BASE_IMAGE} .
docker push ${BASE_IMAGE}
```

The result is a normal OCI image with some extra layers and annotations for
`urunc`:
- An extra layer containing a Linux kernel
- An extra layer containing `urunit`, a small C process that sets up the
  execution environment inside the VM.
- Annotations for `urunc`.

> In case the python-runtime-sandbox contianer image has already been built
> you can use `bunnyfile` to append kernel and anything else.

## Step 3: Deploy a single Sandbox

```shell
kubectl apply -f sandbox-urunc.yaml
kubectl wait --for=condition=Ready sandbox/urunc-example --timeout=5m
```

Reach it through its stable hostname (`urunc-example`) from inside the cluster,
or port-forward the Sandbox Service:

```shell
kubectl port-forward svc/urunc-example 8888:8888
curl http://localhost:8888
```

```json
{"status":"ok","message":"Sandbox Runtime is active."}
```

Execute a command inside the `urunc` container:

```shell
curl -s -X POST http://localhost:8888/execute \
  -H 'Content-Type: application/json' \
  -d '{"command":"echo hello world"}'
```

```json
{"stdout":"hello world\n","stderr":"","exit_code":0}
```

## Step 4:  Verify the isolation

The point of urunc is a kernel boundary between the sandbox and the host. As
with Kata, comparing kernel versions proves it:

```shell
# Host node kernel
kubectl get nodes -o wide

# Sandbox kernel, via the runtime's own /execute endpoint
curl -s -X POST http://localhost:8888/execute \
  -H 'Content-Type: application/json' \
  -d '{"command":"uname -r"}'
```

A different kernel version means the workload is running in its own VM. An
identical one means the pod fell back to the default runtime — check that
`spec.runtimeClassName` survived to the pod:

```shell
kubectl get pods -l sandbox=urunc \
  -o jsonpath=$'{range .items[*]}{.metadata.name}: {.spec.runtimeClassName}\n{end}'
```

## Cleanup

```shell
kubectl delete sandboxclaim urunc-claim --ignore-not-found
envsubst < sandbox-template-urunc.yaml | kubectl delete -f - --ignore-not-found
envsubst < sandbox-urunc.yaml | kubectl delete -f - --ignore-not-found
```

To remove urunc from the nodes, delete the urunc-deploy DaemonSet — its
`preStop` hook runs the cleanup script that restores the containerd
configuration.

## Additional resources

- [urunc documentation](urunc.io)
- [Sandboxed containers in a Raspberry Pi](https://nubificus.co.uk/blog/runtime_benchmarking_rpi/)
- [Related blogpost](https://www.nofire.ai/blog/Urunc-Integration-with-Kubernetes-Agent-Sandbox)
