# Phase 0 Cilium Recovery Root Cause

The cluster failure was caused by stale Kubernetes control-plane configuration after the VM IPs changed.

The control-plane node was now reachable at:

- cp-1: `192.168.1.105`
- worker-1: `192.168.1.111`
- worker-2: `192.168.1.109`

However, some Kubernetes control-plane components still referenced the old API server IP:

- `192.168.1.103`

The stale IP remained inside Kubernetes configuration files and static pod manifests used by:

- `kube-controller-manager`
- `kube-scheduler`
- Cilium configuration

Because `kube-controller-manager` and `kube-scheduler` could not reach the API server correctly, workloads were not being scheduled. As a result, the Cilium DaemonSet stayed at:

```text
DESIRED: 0
CURRENT: 0
READY: 0

This created a chicken-and-egg problem:

Scheduler/controller-manager were broken.
Cilium pods could not be scheduled.
Without Cilium, the CNI layer was unavailable.
Application/test pods stayed Pending.
Phase 0 verification failed.
Fix Applied

The stale 192.168.1.103 references were replaced with the correct API server IP:

192.168.1.105

The affected Kubernetes configuration files and static pod manifests were corrected, then the static control-plane pods were restarted by moving their manifests out of /etc/kubernetes/manifests/ and back in.

After the controller-manager and scheduler reconnected to the correct API server, Cilium immediately changed from:

DESIRED: 0

to:

DESIRED: 3

Cilium pods then progressed through their init containers and reached Running.

Lesson Learned

For Kubernetes clusters, control-plane and worker node IPs should be static before cluster bootstrap.

DHCP-assigned IPs that change after reboot can break:

kubeconfig files
kubelet configuration
controller-manager configuration
scheduler configuration
API server certificates/SANs
CNI configuration such as Cilium

Going forward, all Kubernetes VM IPs should be fixed either through:

Proxmox Cloud-Init static IP configuration
router DHCP reservation
static Netplan configuration inside the VM
EOF
