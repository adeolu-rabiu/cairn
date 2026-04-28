# Phase 0 Troubleshooting Reference

> **Scope**: Proxmox VE · Terraform · Kubernetes (kubeadm) · Cilium CNI  
> **Author**: Adeolu Rabiu  
> **Last updated**: April 2026  
> **Save location**: `docs/troubleshooting/phase-0-troubleshooting.md`

---

## Quick reference index

| Category | Jump to |
|---|---|
| Proxmox host | [Section 1](#1-proxmox-host) |
| VM and template | [Section 2](#2-vm-and-template) |
| Terraform | [Section 3](#3-terraform) |
| Kubernetes nodes | [Section 4](#4-kubernetes-nodes) |
| Control plane | [Section 5](#5-control-plane) |
| Cilium CNI | [Section 6](#6-cilium-cni) |
| Hubble | [Section 7](#7-hubble) |
| CoreDNS | [Section 8](#8-coredns) |
| Networking | [Section 9](#9-networking) |
| SSH and access | [Section 10](#10-ssh-and-access) |
| Storage | [Section 11](#11-storage) |
| Cloud-init | [Section 12](#12-cloud-init) |

---

## 1. Proxmox host

All commands in this section run on the **Proxmox shell** (`ssh root@192.168.1.235` or via Proxmox UI → Shell).

---

### 1.1 Check Proxmox version and status

```bash
pveversion
```
Shows Proxmox VE version, kernel, and component versions. Use to confirm you are on 9.x (Trixie).

---

```bash
pvesh get /nodes/rabtech/status
```
Returns CPU usage, memory usage, uptime, and load average for the Proxmox node in JSON. Useful to confirm the host is not resource-starved.

---

```bash
systemctl status pvedaemon pveproxy pvestatd
```
Checks the three core Proxmox services. All should show `active (running)`. If any are stopped, Proxmox UI and API will be unavailable.

---

### 1.2 Check storage

```bash
pvesm status
```
Lists all configured storage pools with their type, status, total size, used, and available space. Look for `vmdata` showing `active`.

---

```bash
df -h /mnt/vmdata
```
Shows disk usage for the vmdata mount. Confirms the 1TB drive is mounted and has free space for VM disk images.

---

```bash
lsblk
```
Lists all block devices and their partitions. Use this to identify which drive is which before any destructive operation.

---

```bash
mount | grep vmdata
```
Confirms vmdata is mounted. If output is empty, the drive is not mounted and VMs will not start.

---

```bash
cat /etc/fstab | grep vmdata
```
Checks the fstab entry for vmdata. If this is missing, the drive will not mount automatically after a Proxmox reboot.

---

### 1.3 Check network bridge

```bash
ip link show vmbr0
```
Confirms the vmbr0 Linux bridge exists and is UP. This bridge provides network connectivity to all VMs.

---

```bash
brctl show vmbr0
```
Shows which physical NIC is attached to vmbr0. Should show `nic0` or `enp2s0` — never `wlan0`.

---

```bash
ip addr show vmbr0
```
Shows the IP address assigned to vmbr0 (should be `192.168.1.235/24`).

---

### 1.4 Check apt repositories

```bash
cat /etc/apt/sources.list.d/*.list
```
Shows all apt source files. Confirms enterprise repos are disabled and the free tier repo (`pve-no-subscription`) is active.

---

```bash
apt-get update 2>&1 | grep -E "Err|Hit|Get"
```
Runs apt update and shows only the relevant lines. Should show all `Hit` with no `Err` lines. Any `401 Unauthorized` means an enterprise repo is still active.

---

## 2. VM and template

All commands run on **Proxmox shell**.

---

### 2.1 List and inspect VMs

```bash
qm list
```
Lists all VMs and their status (running, stopped, template). Use to confirm VMs 101, 102, 103 exist and template 999 is present.

---

```bash
qm status 101
qm status 102
qm status 103
```
Shows running/stopped status of each VM. If stopped when they should be running, start them with `qm start <vmid>`.

---

```bash
qm config 101
```
Shows the full configuration of VM 101 (cp-1). Key things to verify:
- `boot: order=scsi0` — VM boots from disk not network
- `scsi0: vmdata:...` — disk is attached
- `agent: enabled=1` — QEMU guest agent is configured
- `ide2: vmdata:...,media=cdrom` — cloud-init drive is present

---

```bash
qm config 999
```
Shows the template configuration. Verify the same items as above before cloning. If `boot: order=scsi0` is missing, the template was created incorrectly.

---

### 2.2 VM operations

```bash
qm start 101
qm stop 101
qm reboot 101
qm shutdown 101
```
Start, force stop, reboot, and graceful shutdown a VM. Use `shutdown` before `stop` to avoid disk corruption.

---

```bash
qm destroy 101
```
Permanently deletes VM 101 and its disks. Use only when recreating. Cannot be undone.

---

```bash
qm terminal 101
```
Opens a direct serial console connection to VM 101. Does not require SSH or a network connection. Press `Ctrl+O` to exit. Use this when SSH is not working.

---

```bash
qm guest cmd 101 network-get-interfaces
```
Asks the QEMU guest agent inside VM 101 to report all network interfaces and their IP addresses. Only works if `qemu-guest-agent` is installed and running inside the VM.

---

```bash
qm cloudinit update 101
```
Regenerates the cloud-init ISO for VM 101 (for example after changing password or SSH keys with `qm set`). Must be followed by a reboot to take effect.

---

```bash
qm set 101 --cipassword ubuntu123
```
Sets a cloud-init password for the ubuntu user on VM 101. Run `qm cloudinit update 101` and reboot the VM after.

---

### 2.3 Find VM IPs when guest agent is not running

```bash
for i in $(seq 100 130); do
  ping -c1 -W1 192.168.1.$i &>/dev/null && echo "192.168.1.$i is up"
done
```
Ping sweeps the local subnet to find which IPs are responding. Use to locate VM IPs when the QEMU agent is not installed yet.

---

```bash
ip neigh | grep -i "BC:24:11"
```
Checks the ARP table for entries matching the Proxmox-assigned MAC address prefix. Maps IPs to MAC addresses to identify which VM is at which IP.

---

```bash
qm showcmd 101
```
Prints the full QEMU command used to run VM 101. Shows the MAC address (`virtio-net-pci,mac=...`) which you can then look up in the ARP table.

---

### 2.4 Disk and template issues

```bash
ls -lh /mnt/vmdata/images/101/
```
Lists the disk image files for VM 101. Should show a `.raw` file matching the configured disk size (40GB for cp-1, 80GB for workers).

---

```bash
qm importdisk 999 /tmp/noble.img vmdata --format raw
```
Imports a cloud image into vmdata as an unused disk for VM 999. The disk appears as `unused0` until explicitly attached.

---

```bash
pvesh get /nodes/rabtech/storage/vmdata/content
```
Lists all content stored in vmdata (disk images, ISOs, cloud-init drives). Use to confirm VM disks exist after import.

---

## 3. Terraform

All commands run on **laptop WSL** from `~/cairn/infra/terraform/`.

---

### 3.1 Basic operations

```bash
terraform init
```
Downloads and installs the bpg/proxmox provider. Must be run before any other Terraform command or after changing provider versions.

---

```bash
terraform validate
```
Checks `main.tf` for syntax errors and configuration problems without connecting to Proxmox. Fast way to catch typos before a slow apply.

---

```bash
terraform plan -var worker_count=2
```
Shows what Terraform will create, change, or destroy — without making any changes. Always run this before `apply` to verify the expected outcome.

---

```bash
terraform apply -var worker_count=2
```
Creates or updates the VMs on Proxmox to match the configuration. Prompts for confirmation before making changes.

---

```bash
terraform destroy -var worker_count=2
```
Destroys all VMs managed by Terraform. Use when starting fresh. Prompts for confirmation.

---

```bash
terraform state list
```
Lists all resources tracked in the Terraform state file. Use to confirm which VMs Terraform knows about.

---

```bash
terraform state show proxmox_virtual_environment_vm.cp1
```
Shows the full Terraform state for the cp-1 VM including all attributes. Use to check what Terraform thinks the current state is.

---

```bash
terraform refresh -var worker_count=2
```
Updates the Terraform state to match the actual state on Proxmox without making changes. Use when VMs were changed outside of Terraform.

---

### 3.2 Environment and secrets

```bash
echo $TF_VAR_proxmox_password
echo $TF_VAR_ssh_public_key
```
Confirms that the environment variables are set. If output is blank, Terraform will prompt for values or fail. Set them with `export TF_VAR_proxmox_password="..."`.

---

```bash
terraform output
```
Shows the output values defined in `main.tf` — in this case `cp1_vm_id` and `worker_vm_ids`. Use to confirm the correct VM IDs were created.

---

```bash
terraform providers
```
Lists all providers being used and their versions. Confirms the `bpg/proxmox ~> 0.76` provider is loaded.

---

## 4. Kubernetes nodes

Commands run on **laptop WSL** with `KUBECONFIG=~/.kube/cairn-config` set.

---

### 4.1 Node status

```bash
kubectl get nodes
```
Lists all nodes with their status (Ready/NotReady), roles, age, and Kubernetes version. The most important command — run this first when diagnosing any cluster problem.

---

```bash
kubectl get nodes -o wide
```
Same as above but also shows internal IP, OS image, kernel version, and container runtime. Use to confirm Ubuntu 24.04 and containerd are running.

---

```bash
kubectl describe node cp-1
```
Full details for the control plane node including: conditions (Ready, MemoryPressure, DiskPressure, PIDPressure), allocatable resources, running pods, and events. Check the `Conditions` section first.

---

```bash
kubectl describe node worker-1
kubectl describe node worker-2
```
Same as above for each worker node. Events at the bottom show recent problems.

---

```bash
kubectl get nodes -o json | python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
for n in nodes:
    name = n['metadata']['name']
    for c in n['status']['conditions']:
        if c['type'] == 'Ready':
            print(f\"{name}: {c['type']}={c['status']} — {c['reason']}\")
"
```
Extracts just the Ready condition for each node. Useful for quick programmatic health checks.

---

### 4.2 Node resource usage

```bash
kubectl top nodes
```
Shows real-time CPU and memory usage per node. Requires metrics-server to be installed (Phase 1). If metrics-server is not installed, use `kubectl describe node` instead.

---

```bash
kubectl describe nodes | grep -A 6 "Allocatable:"
```
Shows the allocatable CPU, memory, and pod capacity for each node without the full describe output.

---

```bash
kubectl describe nodes | grep -A 6 "Allocated resources:"
```
Shows how much CPU and memory is currently requested by running pods on each node.

---

### 4.3 Node operations

```bash
kubectl cordon worker-1
```
Marks worker-1 as unschedulable. New pods will not be placed on it. Existing pods continue running. Use before draining a node for maintenance.

---

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```
Evicts all pods from worker-1 (except DaemonSets) and marks it unschedulable. Use before rebooting or replacing a worker node.

---

```bash
kubectl uncordon worker-1
```
Marks worker-1 as schedulable again after maintenance. New pods can now be placed on it.

---

## 5. Control plane

Commands run on **laptop WSL** unless stated otherwise.

---

### 5.1 Control plane pods

```bash
kubectl get pods -n kube-system
```
Lists all pods in kube-system namespace. All control plane components (etcd, kube-apiserver, kube-controller-manager, kube-scheduler) should be `1/1 Running`.

---

```bash
kubectl get pods -n kube-system -o wide
```
Same but also shows which node each pod is running on. Control plane pods should be on cp-1.

---

```bash
kubectl logs etcd-cp-1 -n kube-system --tail=50
```
Shows the last 50 lines of etcd logs. Look for `raft` election messages and `took too long` warnings which indicate performance problems.

---

```bash
kubectl logs kube-apiserver-cp-1 -n kube-system --tail=50
```
Shows the last 50 lines of the API server logs. Look for `authentication` errors and `etcd` connectivity problems.

---

```bash
kubectl logs kube-controller-manager-cp-1 -n kube-system --tail=50
```
Shows controller manager logs. Look for `failed to sync` messages which indicate issues with deployments or other resources.

---

```bash
kubectl logs kube-scheduler-cp-1 -n kube-system --tail=50
```
Shows scheduler logs. Look for `failed to schedule pod` messages which indicate resource or taint issues.

---

### 5.2 Control plane from inside cp-1

Commands run on **cp-1** via `ssh ubuntu@192.168.1.114`.

```bash
sudo systemctl status kubelet
```
Shows kubelet service status. Kubelet must be `active (running)` for the node to function. If stopped, the node will show NotReady.

---

```bash
sudo journalctl -u kubelet --no-pager -n 100
```
Shows the last 100 lines of kubelet logs. Look for `failed to run Kubelet`, `connection refused`, and certificate errors.

---

```bash
sudo systemctl status containerd
```
Shows containerd service status. Containerd is the container runtime. If stopped, no pods can start on this node.

---

```bash
sudo crictl ps
```
Lists all running containers on the node using the CRI (Container Runtime Interface). Similar to `docker ps` but works with containerd. Use on any node to see what is actually running.

---

```bash
sudo crictl pods
```
Lists all pods on the node at the CRI level. Shows pods that kubectl may not show if they are in a very early state.

---

```bash
sudo crictl images
```
Lists all container images stored on this node. Use to check if images have been pulled successfully.

---

```bash
sudo crictl pull nginx:alpine
```
Tests whether the node can pull images from the internet. If this fails, the node has no internet connectivity or DNS resolution is broken.

---

```bash
cat /etc/kubernetes/kubelet.conf | grep server
```
Shows which API server the kubelet is connecting to. Should point to the control plane IP on port 6443.

---

```bash
sudo kubeadm token list
```
Lists active bootstrap tokens. Tokens expire after 24 hours. If you need to join a new node after the token expires, create a new one.

---

```bash
sudo kubeadm token create --print-join-command
```
Generates a new join command with a fresh token. Use when adding new worker nodes or when the original token has expired.

---

## 6. Cilium CNI

Commands run on **laptop WSL** unless stated otherwise.

---

### 6.1 Cilium status

```bash
cilium status
```
Full Cilium health report. Shows Cilium DaemonSet, Operator, Hubble Relay, and Hubble UI status. The first command to run when diagnosing any networking issue.

---

```bash
cilium status --wait
```
Same as above but waits until Cilium is fully ready before printing the result. Use after installing or restarting Cilium.

---

```bash
kubectl get daemonset cilium -n kube-system
```
Shows the Cilium DaemonSet status. `DESIRED` should equal `READY`. If not, pods are failing on one or more nodes.

---

```bash
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```
Lists all Cilium pods and which node each is running on. Use to identify which specific node has a failing Cilium pod.

---

```bash
kubectl logs -n kube-system -l k8s-app=cilium --tail=50
```
Shows logs from all Cilium pods. Look for `level=error` lines, BPF errors, and connectivity failures.

---

```bash
kubectl describe pod cilium-fsm8s -n kube-system
```
Full details for a specific Cilium pod including events. Replace `cilium-fsm8s` with the actual pod name. Check the Events section for mount failures and image pull errors.

---

### 6.2 Cilium connectivity

```bash
cilium connectivity test
```
Runs a full end-to-end connectivity test suite including pod-to-pod, pod-to-service, egress, and policy tests. Takes 5-10 minutes. The most comprehensive Cilium diagnostic available.

---

```bash
kubectl exec -n kube-system cilium-fsm8s -- cilium status
```
Runs `cilium status` from inside a Cilium pod. Shows the local node's Cilium state including BPF maps and endpoint count.

---

```bash
kubectl exec -n kube-system cilium-fsm8s -- cilium endpoint list
```
Lists all Cilium endpoints (pods) managed by this Cilium instance. Shows policy enforcement status for each pod.

---

```bash
kubectl exec -n kube-system cilium-fsm8s -- cilium monitor
```
Streams live network events from the BPF dataplane. Shows dropped packets and policy violations in real time. Press Ctrl+C to stop.

---

```bash
kubectl exec -n kube-system cilium-fsm8s -- \
  cilium monitor --type drop
```
Shows only dropped packet events. Use to diagnose NetworkPolicy blocks and connectivity issues between pods.

---

### 6.3 Required firewall ports for Cilium

Run on **each node** via SSH if Cilium pods are failing:

```bash
sudo ufw status numbered
```
Lists all UFW rules with numbers. Check that required ports are present.

---

```bash
# Run on ALL nodes — cp-1, worker-1, worker-2
sudo ufw allow 4240/tcp   # Cilium health checks
sudo ufw allow 4244/tcp   # Hubble peer (CRITICAL — missing this breaks Hubble Relay)
sudo ufw allow 4245/tcp   # Hubble peer TLS
sudo ufw allow 8472/udp   # VXLAN overlay (if using VXLAN mode)
sudo ufw allow 51871/udp  # WireGuard (if using encryption)
sudo ufw reload
```
Opens all ports required by Cilium. Port 4244 is the most commonly missed — its absence causes Hubble Relay CrashLoopBackOff.

---

## 7. Hubble

Commands run on **laptop WSL** unless stated otherwise.

---

### 7.1 Hubble status

```bash
kubectl get deployment hubble-relay -n kube-system
kubectl get deployment hubble-ui -n kube-system
```
Checks if Hubble Relay and UI deployments exist and how many replicas are ready.

---

```bash
kubectl logs deployment/hubble-relay -n kube-system --tail=50
```
Shows Hubble Relay logs. Look for `deadline exceeded`, `connection refused`, and `peer` errors which indicate the relay cannot reach the Hubble peer on one or more nodes.

---

```bash
kubectl rollout restart deployment/hubble-relay -n kube-system
kubectl rollout status deployment/hubble-relay -n kube-system
```
Restarts Hubble Relay and waits for the rollout to complete. Try this first when Relay is in CrashLoopBackOff.

---

```bash
cilium hubble disable
sleep 30
cilium hubble enable --ui
```
Fully disables and re-enables Hubble. Use when Relay keeps crashing after restarts.

---

### 7.2 Hubble UI access

```bash
cilium hubble port-forward &
```
Forwards Hubble UI to `http://localhost:12000` on your laptop. Run in the background with `&`. Open the URL in your browser to see live traffic flows.

---

```bash
hubble observe --last 20
```
Shows the last 20 network flow events captured by Hubble. Requires Hubble CLI installed and port-forward active.

---

```bash
hubble observe --namespace kube-system --last 20
```
Shows the last 20 flow events in the kube-system namespace only. Useful for debugging system pod connectivity.

---

## 8. CoreDNS

Commands run on **laptop WSL** unless stated otherwise.

---

### 8.1 CoreDNS status

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```
Lists CoreDNS pods. Both should be `1/1 Running`. CoreDNS is the cluster DNS — if it is down, no service discovery works.

---

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```
Shows CoreDNS logs. Look for `SERVFAIL`, `connection refused`, and `plugin/errors` messages.

---

```bash
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system
```
Restarts CoreDNS. Use when DNS resolution is failing inside the cluster.

---

### 8.2 DNS resolution tests

```bash
kubectl run dns-test --image=busybox:1.28 --restart=Never \
  --command -- nslookup kubernetes.default
sleep 10
kubectl logs dns-test
kubectl delete pod dns-test
```
Runs a DNS lookup for the Kubernetes API service from inside the cluster. `kubernetes.default.svc.cluster.local` must resolve for the cluster to function.

---

```bash
kubectl run dns-test2 --image=busybox:1.28 --restart=Never \
  --command -- nslookup hubble-peer.kube-system.svc.cluster.local
sleep 10
kubectl logs dns-test2
kubectl delete pod dns-test2
```
Tests DNS resolution for the Hubble peer service specifically. Used to diagnose Hubble Relay failures.

---

```bash
kubectl exec -n kube-system -it coredns-cf76796b5-g2p92 -- \
  cat /etc/coredns/Corefile
```
Shows the CoreDNS configuration. Replace the pod name with the actual pod name. Confirms forward rules and cluster domain settings.

---

## 9. Networking

Commands run on **laptop WSL** or **node SSH** as indicated.

---

### 9.1 Pod connectivity

```bash
kubectl run nettest --image=nicolaka/netshoot --restart=Never -it --rm
```
Starts an interactive networking debug pod with tools like `ping`, `curl`, `tcpdump`, `nslookup`, `netstat`, and `ss` pre-installed. The most useful pod for network debugging.

---

```bash
kubectl run ping-test --image=busybox --restart=Never \
  --command -- ping -c 4 10.244.0.1
sleep 10
kubectl logs ping-test
kubectl delete pod ping-test
```
Pings the pod network gateway from inside the cluster. Tests basic pod network connectivity.

---

```bash
kubectl get svc -n kube-system kubernetes
```
Shows the Kubernetes API ClusterIP service. This should always exist with IP `10.96.0.1` or similar. If missing, the cluster is severely broken.

---

### 9.2 Node-level networking

Run on **each node** via SSH.

```bash
ip route show
```
Shows the routing table. Confirms the node has a default route to the gateway and pod network routes are present.

---

```bash
ip addr show
```
Shows all network interfaces and their IP addresses. Confirms the node has an IP on the correct subnet.

---

```bash
ss -tlnp | grep -E "6443|10250|4244|2379"
```
Checks that required Kubernetes ports are listening. `6443` is the API server, `10250` is kubelet, `4244` is Hubble peer, `2379` is etcd.

---

```bash
sudo ufw status verbose
```
Shows all UFW firewall rules in detail. Check that required ports are open and that the firewall is not blocking cluster communication.

---

```bash
curl -k https://192.168.1.114:6443/healthz
```
Tests the Kubernetes API server health endpoint from any machine. Should return `ok`. If it returns nothing or times out, the API server is down or unreachable.

---

```bash
nc -zv 192.168.1.114 4244
```
Tests TCP connectivity to port 4244 (Hubble peer) on the control plane. Should show `succeeded`. If it times out, UFW is blocking the port.

---

## 10. SSH and access

---

### 10.1 SSH problems

```bash
ssh-keygen -f '/home/adeol/.ssh/known_hosts' -R '192.168.1.114'
```
Removes the stored host key for cp-1. Run this when SSH shows `REMOTE HOST IDENTIFICATION HAS CHANGED`. This happens when a VM is recreated and gets a new SSH host key.

---

```bash
ssh -i ~/.ssh/id_ed25519_cairn ubuntu@192.168.1.114
```
SSH into cp-1 using the cairn-specific SSH key explicitly. Use when the default SSH key is not the cairn key.

---

```bash
ssh-keygen -t ed25519 -C "cairn-proxmox-terraform" -f ~/.ssh/id_ed25519_cairn
cat ~/.ssh/id_ed25519_cairn.pub
```
Generates a new SSH key pair for Cairn. Copy the public key output and add it to GitHub under Settings → SSH keys.

---

```bash
ssh-keygen -lf ~/.ssh/id_ed25519_cairn.pub
```
Shows the fingerprint of your cairn SSH public key. Compare this with the fingerprint shown in GitHub to confirm they match.

---

### 10.2 kubeconfig problems

```bash
echo $KUBECONFIG
```
Confirms which kubeconfig file is active. If blank, kubectl connects to `localhost:8080` which causes `connection refused` errors.

---

```bash
export KUBECONFIG=~/.kube/cairn-config
```
Sets the kubeconfig for the current terminal session. Add this to `~/.bashrc` to make it permanent.

---

```bash
kubectl config view
```
Shows the current kubeconfig contents including cluster, user, and context. Use to confirm the API server address is correct.

---

```bash
kubectl config current-context
```
Shows the currently active context. Should be `kubernetes-admin@kubernetes` or similar.

---

```bash
scp -i ~/.ssh/id_ed25519_cairn ubuntu@192.168.1.114:~/.kube/config ~/.kube/cairn-config
```
Copies the kubeconfig from cp-1 to your laptop. Run this after recreating the cluster to get a fresh kubeconfig.

---

## 11. Storage

---

### 11.1 vmdata storage

```bash
df -h /mnt/vmdata
```
Shows vmdata usage. Run before creating VMs to confirm there is enough space. Each worker disk is 80GB, control plane is 40GB.

---

```bash
ls -lh /mnt/vmdata/images/
```
Lists all VM disk image directories. Each VM has its own folder named by VM ID (101, 102, 103).

---

```bash
ls -lh /mnt/vmdata/images/101/
```
Lists the disk files for VM 101 (cp-1). Should show a `.raw` file of 40GB and a `.qcow2` cloud-init file.

---

```bash
qemu-img info /mnt/vmdata/images/101/vm-101-disk-0.raw
```
Shows details about the VM disk image including format, virtual size, and actual disk usage. Use to confirm the image is valid and not corrupted.

---

### 11.2 Cloud-init storage

```bash
ls -lh /mnt/vmdata/images/9000/
```
Lists template disk files. Should show the raw Ubuntu cloud image and the cloud-init qcow2.

---

```bash
qemu-img check /mnt/vmdata/images/101/vm-101-disk-0.raw
```
Validates the integrity of the VM disk image. Reports any corruption. A clean image reports `No errors were found`.

---

## 12. Cloud-init

Run these on **each VM** via SSH or `qm terminal`.

---

```bash
cloud-init status
```
Shows whether cloud-init has run and its outcome. Should show `status: done`. If it shows `disabled`, cloud-init was not triggered — the template may be incorrect.

---

```bash
cloud-init status --wait
```
Waits until cloud-init completes before returning. Use on first boot to confirm setup is finished before running other commands.

---

```bash
sudo cat /var/log/cloud-init-output.log
```
Shows the full output of cloud-init execution. Look for errors during package installation, SSH key injection, and user creation.

---

```bash
sudo cat /var/log/cloud-init.log | grep -i error
```
Filters cloud-init log for errors only. Faster than reading the full log.

---

```bash
sudo cloud-init clean --reboot
```
Clears all cloud-init state and reboots the VM so cloud-init runs again from scratch. Use to re-apply cloud-init configuration after changes to the cloud-init ISO.

---

```bash
sudo cat /home/ubuntu/.ssh/authorized_keys
```
Shows which SSH public keys are authorised for the ubuntu user. If this is empty, SSH key injection from Terraform failed.

---

```bash
hostname
ip a | grep "inet "
cat /etc/os-release | grep VERSION
```
Basic node identity check. Run inside any VM to confirm hostname, IP, and OS version are correct.

---

## Quick reference cheat sheet

```
# Is the cluster up?
kubectl get nodes

# Are all pods running?
kubectl get pods -n kube-system

# Is Cilium healthy?
cilium status

# Is DNS working?
kubectl run dns-test --image=busybox:1.28 --restart=Never \
  --command -- nslookup kubernetes.default

# Can pods be scheduled?
kubectl run test --image=nginx:alpine --restart=Never && \
  kubectl get pod test && kubectl delete pod test

# What is wrong with a specific pod?
kubectl describe pod <pod-name> -n <namespace>

# What are the recent logs for a pod?
kubectl logs <pod-name> -n <namespace> --tail=50

# What is consuming resources on a node?
kubectl describe node <node-name> | grep -A 10 "Allocated resources:"

# Is the Proxmox API reachable?
curl -k https://192.168.1.235:8006/api2/json/version

# Is the Kubernetes API reachable?
curl -k https://192.168.1.114:6443/healthz

# Open firewall ports for Cilium on a node (run on each node)
sudo ufw allow 4240/tcp 4244/tcp 4245/tcp && sudo ufw reload
```

---

*This document covers Phase 0 (Proxmox + Terraform + Kubernetes + Cilium) only.*  
*Phase 1 troubleshooting (Argo CD, Vault, cert-manager, observability) is in `docs/troubleshooting/phase-1-troubleshooting.md`.*
