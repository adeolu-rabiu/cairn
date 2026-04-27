#!/usr/bin/env bash
# =============================================================================
# Cairn — Phase 0 Verification Script
# =============================================================================
# Usage:   bash scripts/verify-phase-0.sh
# Purpose: Verifies all Phase 0 deliverables are healthy before Phase 1 starts
# Author:  Adeolu Rabiu
# =============================================================================

set -uo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}✅ PASS${RESET}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}❌ FAIL${RESET}  $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠️  WARN${RESET}  $1"; ((WARN++)); }
info() { echo -e "  ${CYAN}ℹ️  INFO${RESET}  $1"; }
section() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  $1${RESET}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║     CAIRN — Phase 0 Verification          ║"
echo "  ║     Proxmox + Terraform + K8s + Cilium    ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${CYAN}Started at: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "  ${CYAN}KUBECONFIG:  ${KUBECONFIG:-not set}${RESET}"

# ── Check KUBECONFIG ──────────────────────────────────────────────────────────
section "0. Prerequisites"

if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/cairn-config" ]]; then
    export KUBECONFIG="$HOME/.kube/cairn-config"
    warn "KUBECONFIG was not set — auto-loaded from ~/.kube/cairn-config"
  else
    fail "KUBECONFIG not set and ~/.kube/cairn-config not found"
    echo -e "\n  ${RED}Run: export KUBECONFIG=~/.kube/cairn-config${RESET}"
    exit 1
  fi
fi

# Check kubectl is available
if ! command -v kubectl &>/dev/null; then
  fail "kubectl not found — install with: sudo snap install kubectl --classic"
  exit 1
fi
pass "kubectl available: $(kubectl version --client -o json 2>/dev/null | \
  python3 -c 'import sys,json; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo 'version unknown')"

# Check cilium CLI is available
if command -v cilium &>/dev/null; then
  pass "cilium CLI available: $(cilium version 2>/dev/null | head -1 || echo 'version unknown')"
else
  warn "cilium CLI not found — Cilium checks will be skipped"
fi

# Check cluster is reachable
if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
  fail "Cannot reach cluster — check KUBECONFIG and cluster status"
  exit 1
fi
pass "Cluster API server reachable"

# ── Section 1: Nodes ──────────────────────────────────────────────────────────
section "1. Kubernetes Nodes"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady" || true)

info "Total nodes: $NODE_COUNT | Ready: $READY_COUNT | NotReady: $NOT_READY"

if [[ "$NODE_COUNT" -lt 3 ]]; then
  fail "Expected 3 nodes, found $NODE_COUNT"
else
  pass "Node count: $NODE_COUNT (expected 3)"
fi

if [[ "$NOT_READY" -gt 0 ]]; then
  fail "$NOT_READY node(s) in NotReady state"
else
  pass "All nodes in Ready state"
fi

# Check for control plane node
CP_NODE=$(kubectl get nodes --no-headers \
  -l node-role.kubernetes.io/control-plane 2>/dev/null | awk '{print $1}')
if [[ -n "$CP_NODE" ]]; then
  pass "Control plane node found: $CP_NODE"
else
  fail "No control plane node found"
fi

# Check worker nodes
WORKER_COUNT=$(kubectl get nodes --no-headers \
  -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | wc -l)
if [[ "$WORKER_COUNT" -ge 2 ]]; then
  pass "Worker nodes: $WORKER_COUNT (expected 2)"
else
  fail "Worker nodes: $WORKER_COUNT (expected 2)"
fi

# Print node table
echo ""
kubectl get nodes -o wide 2>/dev/null || true

# ── Section 2: Control Plane Pods ────────────────────────────────────────────
section "2. Control Plane Components"

for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  POD=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | \
    grep "^${component}" | awk '{print $1}' | head -1)
  if [[ -z "$POD" ]]; then
    fail "${component}: pod not found"
  else
    STATUS=$(kubectl get pod "$POD" -n kube-system \
      --no-headers 2>/dev/null | awk '{print $3}')
    READY=$(kubectl get pod "$POD" -n kube-system \
      --no-headers 2>/dev/null | awk '{print $2}')
    if [[ "$STATUS" == "Running" ]]; then
      pass "${component}: Running ($READY)"
    else
      fail "${component}: $STATUS ($READY)"
    fi
  fi
done

# ── Section 3: Cilium CNI ─────────────────────────────────────────────────────
section "3. Cilium CNI"

CILIUM_DESIRED=$(kubectl get daemonset cilium -n kube-system \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
CILIUM_READY=$(kubectl get daemonset cilium -n kube-system \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [[ "$CILIUM_DESIRED" -gt 0 && "$CILIUM_DESIRED" == "$CILIUM_READY" ]]; then
  pass "Cilium DaemonSet: $CILIUM_READY/$CILIUM_DESIRED pods ready"
else
  fail "Cilium DaemonSet: $CILIUM_READY/$CILIUM_DESIRED pods ready"
fi

# Cilium operator
CILIUM_OP=$(kubectl get deployment cilium-operator -n kube-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$CILIUM_OP" -ge 1 ]]; then
  pass "Cilium Operator: $CILIUM_OP/1 ready"
else
  fail "Cilium Operator: not ready"
fi

# Hubble Relay
HUBBLE_RELAY=$(kubectl get deployment hubble-relay -n kube-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$HUBBLE_RELAY" -ge 1 ]]; then
  pass "Hubble Relay: $HUBBLE_RELAY/1 ready"
else
  warn "Hubble Relay: not ready (non-blocking — fix port 4244/tcp on all nodes)"
fi

# Hubble UI
HUBBLE_UI=$(kubectl get deployment hubble-ui -n kube-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$HUBBLE_UI" -ge 1 ]]; then
  pass "Hubble UI: $HUBBLE_UI/1 ready"
else
  warn "Hubble UI: not ready"
fi

# ── Section 4: CoreDNS ────────────────────────────────────────────────────────
section "4. CoreDNS"

COREDNS_READY=$(kubectl get deployment coredns -n kube-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
COREDNS_DESIRED=$(kubectl get deployment coredns -n kube-system \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "2")

if [[ "$COREDNS_READY" -ge 1 ]]; then
  pass "CoreDNS: $COREDNS_READY/$COREDNS_DESIRED replicas ready"
else
  fail "CoreDNS: $COREDNS_READY/$COREDNS_DESIRED replicas ready"
fi

# DNS resolution test from inside cluster
info "Running DNS resolution test inside cluster..."
DNS_RESULT=$(kubectl run dns-verify --image=busybox:1.28 \
  --restart=Never --rm -it --quiet \
  --command -- nslookup kubernetes.default 2>/dev/null | \
  grep -c "kubernetes.default.svc.cluster.local" || echo "0")

if [[ "$DNS_RESULT" -ge 1 ]]; then
  pass "DNS resolution: kubernetes.default.svc.cluster.local resolved"
else
  warn "DNS resolution test inconclusive — check manually"
fi

# ── Section 5: Pod Scheduling ────────────────────────────────────────────────
section "5. Pod Scheduling"

info "Scheduling test pod on cluster..."
kubectl run phase0-verify --image=nginx:alpine \
  --restart=Never --quiet 2>/dev/null || true

sleep 15

POD_STATUS=$(kubectl get pod phase0-verify \
  --no-headers 2>/dev/null | awk '{print $3}' || echo "NotFound")

if [[ "$POD_STATUS" == "Running" ]]; then
  pass "Test pod scheduled and Running"
elif [[ "$POD_STATUS" == "ContainerCreating" ]]; then
  warn "Test pod still ContainerCreating — image pull may be slow"
else
  fail "Test pod status: $POD_STATUS"
fi

kubectl delete pod phase0-verify --ignore-not-found --quiet 2>/dev/null || true

# ── Section 6: kube-proxy ────────────────────────────────────────────────────
section "6. kube-proxy"

PROXY_DESIRED=$(kubectl get daemonset kube-proxy -n kube-system \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
PROXY_READY=$(kubectl get daemonset kube-proxy -n kube-system \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [[ "$PROXY_DESIRED" -gt 0 && "$PROXY_DESIRED" == "$PROXY_READY" ]]; then
  pass "kube-proxy: $PROXY_READY/$PROXY_DESIRED ready"
else
  fail "kube-proxy: $PROXY_READY/$PROXY_DESIRED ready"
fi

# ── Section 7: All kube-system pods ──────────────────────────────────────────
section "7. All kube-system Pods"

NOT_RUNNING=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | \
  grep -v "Running\|Completed" | wc -l)

if [[ "$NOT_RUNNING" -eq 0 ]]; then
  pass "All kube-system pods Running"
else
  warn "$NOT_RUNNING pod(s) not in Running state:"
  kubectl get pods -n kube-system --no-headers 2>/dev/null | \
    grep -v "Running\|Completed" || true
fi

echo ""
kubectl get pods -n kube-system 2>/dev/null || true

# ── Section 8: Node Resources ────────────────────────────────────────────────
section "8. Node Resources"

echo ""
kubectl describe nodes 2>/dev/null | \
  grep -A 6 "Allocatable:" | \
  grep -E "Allocatable:|cpu:|memory:|pods:" || true

# Check no node has memory or disk pressure
MEMORY_PRESSURE=$(kubectl get nodes -o json 2>/dev/null | \
  python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
count = sum(1 for n in nodes
  for c in n['status']['conditions']
  if c['type'] == 'MemoryPressure' and c['status'] == 'True')
print(count)" 2>/dev/null || echo "0")

DISK_PRESSURE=$(kubectl get nodes -o json 2>/dev/null | \
  python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
count = sum(1 for n in nodes
  for c in n['status']['conditions']
  if c['type'] == 'DiskPressure' and c['status'] == 'True')
print(count)" 2>/dev/null || echo "0")

if [[ "$MEMORY_PRESSURE" -eq 0 ]]; then
  pass "No nodes under memory pressure"
else
  fail "$MEMORY_PRESSURE node(s) under memory pressure"
fi

if [[ "$DISK_PRESSURE" -eq 0 ]]; then
  pass "No nodes under disk pressure"
else
  fail "$DISK_PRESSURE node(s) under disk pressure"
fi

# ── Section 9: Cilium CLI Status ─────────────────────────────────────────────
section "9. Cilium CLI Status"

if command -v cilium &>/dev/null; then
  echo ""
  cilium status 2>/dev/null || warn "cilium status returned non-zero"
  CILIUM_OK=$(cilium status 2>/dev/null | grep -c "Cilium:.*OK" || echo "0")
  if [[ "$CILIUM_OK" -ge 1 ]]; then
    pass "Cilium reports OK"
  else
    fail "Cilium not reporting OK"
  fi
else
  warn "cilium CLI not available — skipping cilium status check"
fi

# ── Final Summary ────────────────────────────────────────────────────────────
section "PHASE 0 VERIFICATION SUMMARY"

TOTAL=$((PASS + FAIL + WARN))
echo ""
echo -e "  ${GREEN}${BOLD}PASS: $PASS${RESET}"
echo -e "  ${RED}${BOLD}FAIL: $FAIL${RESET}"
echo -e "  ${YELLOW}${BOLD}WARN: $WARN${RESET}"
echo -e "  ${CYAN}${BOLD}TOTAL CHECKS: $TOTAL${RESET}"
echo ""
echo -e "  Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║   ✅  PHASE 0 FULLY VERIFIED              ║"
  echo "  ║       Ready to start Phase 1              ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${RESET}"
  exit 0
elif [[ "$FAIL" -eq 0 ]]; then
  echo -e "${YELLOW}${BOLD}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║   ⚠️   PHASE 0 VERIFIED WITH WARNINGS     ║"
  echo "  ║       Review warnings before Phase 1      ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${RESET}"
  exit 0
else
  echo -e "${RED}${BOLD}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║   ❌  PHASE 0 VERIFICATION FAILED         ║"
  echo "  ║       Fix failures before Phase 1         ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${RESET}"
  exit 1
fi
