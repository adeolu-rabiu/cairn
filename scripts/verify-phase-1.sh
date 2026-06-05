#!/usr/bin/env bash

set -u
set -o pipefail

PASS=0
FAIL=0
WARN=0

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

section() {
  echo
  echo "══════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════"
}

pass() {
  echo -e "  ${GREEN}✅ PASS${NC}  $1"
  PASS=$((PASS+1))
}

fail() {
  echo -e "  ${RED}❌ FAIL${NC}  $1"
  FAIL=$((FAIL+1))
}

warn() {
  echo -e "  ${YELLOW}⚠️  WARN${NC}  $1"
  WARN=$((WARN+1))
}

info() {
  echo -e "  ${BLUE}ℹ️  INFO${NC}  $1"
}

exists_ns() {
  kubectl get ns "$1" >/dev/null 2>&1
}

pods_ready_in_ns() {
  local ns="$1"
  local bad
  bad=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $0}')
  if [ -z "$bad" ]; then
    return 0
  else
    echo "$bad"
    return 1
  fi
}

deployment_ready() {
  local ns="$1"
  local name="$2"
  kubectl -n "$ns" rollout status deploy/"$name" --timeout=20s >/dev/null 2>&1
}

echo
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║     CAIRN — Phase 1 Verification          ║"
echo "  ║     GitOps + TLS + Ingress + Secrets      ║"
echo "  ║     Observability + Admission Policy      ║"
echo "  ╚═══════════════════════════════════════════╝"
echo
echo "  Started at: $(date)"
echo "  KUBECONFIG: ${KUBECONFIG:-not set}"

section "0. Prerequisites"

if command -v kubectl >/dev/null 2>&1; then
  pass "kubectl available: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
else
  fail "kubectl not found"
  exit 1
fi

if kubectl cluster-info >/dev/null 2>&1; then
  pass "Cluster API server reachable"
else
  fail "Cannot reach cluster API server"
  exit 1
fi

if command -v helm >/dev/null 2>&1; then
  pass "helm available: $(helm version --short 2>/dev/null)"
else
  warn "helm not found on this machine"
fi

if command -v argocd >/dev/null 2>&1; then
  pass "argocd CLI available"
else
  warn "argocd CLI not found; Argo CD will be checked with kubectl only"
fi

section "1. Phase 0 Baseline Still Healthy"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print}' | wc -l | tr -d ' ')

info "Total nodes: $NODE_COUNT | Ready nodes: $READY_COUNT"

if [ "$NODE_COUNT" -eq 3 ]; then
  pass "Node count is 3"
else
  fail "Node count is $NODE_COUNT, expected 3"
fi

if [ "$READY_COUNT" -eq 3 ]; then
  pass "All nodes Ready"
else
  fail "Not all nodes are Ready"
fi

kubectl get nodes -o wide

if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  CILIUM_DESIRED=$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  CILIUM_READY=$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)

  if [ "$CILIUM_DESIRED" = "3" ] && [ "$CILIUM_READY" = "3" ]; then
    pass "Cilium DaemonSet ready: $CILIUM_READY/$CILIUM_DESIRED"
  else
    fail "Cilium DaemonSet not healthy: $CILIUM_READY/$CILIUM_DESIRED"
  fi
else
  fail "Cilium DaemonSet not found"
fi

section "2. Argo CD"

if exists_ns argocd; then
  pass "argocd namespace exists"
else
  fail "argocd namespace missing"
fi

if pods_ready_in_ns argocd >/tmp/phase1-argocd-bad-pods 2>/dev/null; then
  pass "All Argo CD pods Running"
else
  fail "Some Argo CD pods not Running"
  cat /tmp/phase1-argocd-bad-pods
fi

kubectl get pods -n argocd 2>/dev/null || true

if kubectl -n argocd get app cairn-platform >/dev/null 2>&1; then
  APP_HEALTH=$(kubectl -n argocd get app cairn-platform -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  APP_SYNC=$(kubectl -n argocd get app cairn-platform -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

  if [ "$APP_HEALTH" = "Healthy" ] && [ "$APP_SYNC" = "Synced" ]; then
    pass "cairn-platform Argo CD app Healthy/Synced"
  else
    warn "cairn-platform app health=$APP_HEALTH sync=$APP_SYNC"
  fi
else
  warn "cairn-platform root app not found"
fi

if command -v argocd >/dev/null 2>&1; then
  argocd app list 2>/dev/null || warn "argocd CLI present but not logged in or cannot reach Argo CD"
fi

section "3. cert-manager"

if exists_ns cert-manager; then
  pass "cert-manager namespace exists"
else
  fail "cert-manager namespace missing"
fi

if pods_ready_in_ns cert-manager >/tmp/phase1-cert-bad-pods 2>/dev/null; then
  pass "All cert-manager pods Running"
else
  fail "Some cert-manager pods not Running"
  cat /tmp/phase1-cert-bad-pods
fi

if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
  ISSUER_READY=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$ISSUER_READY" = "True" ]; then
    pass "ClusterIssuer letsencrypt-prod Ready=True"
  else
    warn "ClusterIssuer letsencrypt-prod exists but Ready=$ISSUER_READY"
  fi
else
  warn "ClusterIssuer letsencrypt-prod not found"
fi

section "4. NGINX Ingress"

if exists_ns ingress-nginx; then
  pass "ingress-nginx namespace exists"
else
  fail "ingress-nginx namespace missing"
fi

if pods_ready_in_ns ingress-nginx >/tmp/phase1-ingress-bad-pods 2>/dev/null; then
  pass "NGINX Ingress pods Running"
else
  fail "Some NGINX Ingress pods not Running"
  cat /tmp/phase1-ingress-bad-pods
fi

INGRESS_SVC=$(kubectl get svc -n ingress-nginx --no-headers 2>/dev/null | grep -E 'NodePort|LoadBalancer' || true)
if echo "$INGRESS_SVC" | grep -q "31080"; then
  pass "Ingress HTTP NodePort 31080 found"
else
  warn "Ingress HTTP NodePort 31080 not found"
fi

if echo "$INGRESS_SVC" | grep -q "31443"; then
  pass "Ingress HTTPS NodePort 31443 found"
else
  warn "Ingress HTTPS NodePort 31443 not found"
fi

kubectl get svc -n ingress-nginx 2>/dev/null || true

section "5. local-path Storage"

if kubectl get storageclass local-path >/dev/null 2>&1; then
  pass "local-path storage class exists"
else
  fail "local-path storage class missing"
fi

DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
if echo "$DEFAULT_SC" | grep -q "local-path"; then
  pass "local-path is default storage class"
else
  warn "local-path is not default storage class. Current default: ${DEFAULT_SC:-none}"
fi

section "6. Vault"

if exists_ns vault; then
  pass "vault namespace exists"
else
  fail "vault namespace missing"
fi

if kubectl -n vault get pod vault-0 >/dev/null 2>&1; then
  VAULT_READY=$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  VAULT_PHASE=$(kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  if [ "$VAULT_READY" = "true" ] && [ "$VAULT_PHASE" = "Running" ]; then
    pass "vault-0 pod Ready"
  else
    fail "vault-0 is not Ready. phase=$VAULT_PHASE ready=$VAULT_READY"
  fi

  if kubectl -n vault exec vault-0 -- vault status >/tmp/phase1-vault-status 2>/dev/null; then
    if grep -q "Sealed.*false" /tmp/phase1-vault-status; then
      pass "Vault is unsealed"
    else
      fail "Vault status reachable but Vault is sealed"
      cat /tmp/phase1-vault-status
    fi
  else
    fail "Could not run vault status inside vault-0"
  fi
else
  fail "vault-0 pod not found"
fi

kubectl get pods -n vault 2>/dev/null || true
kubectl get pvc -n vault 2>/dev/null || true

section "7. External Secrets Operator"

if exists_ns external-secrets; then
  pass "external-secrets namespace exists"
else
  warn "external-secrets namespace missing"
fi

if kubectl get pods -n external-secrets >/dev/null 2>&1; then
  if pods_ready_in_ns external-secrets >/tmp/phase1-eso-bad-pods 2>/dev/null; then
    pass "External Secrets pods Running"
  else
    fail "Some External Secrets pods not Running"
    cat /tmp/phase1-eso-bad-pods
  fi
else
  warn "External Secrets pods not found"
fi

if kubectl get clustersecretstore vault-backend >/dev/null 2>&1; then
  STORE_READY=$(kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STORE_READY" = "True" ]; then
    pass "ClusterSecretStore vault-backend Ready=True"
  else
    warn "ClusterSecretStore vault-backend Ready=$STORE_READY"
  fi
else
  warn "ClusterSecretStore vault-backend not found"
fi

if kubectl get externalsecret slack-webhook >/dev/null 2>&1; then
  ES_READY=$(kubectl get externalsecret slack-webhook -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$ES_READY" = "True" ]; then
    pass "ExternalSecret slack-webhook Ready=True"
  else
    warn "ExternalSecret slack-webhook Ready=$ES_READY"
  fi
else
  warn "ExternalSecret slack-webhook not found"
fi

if kubectl get secret slack-webhook >/dev/null 2>&1; then
  pass "Kubernetes secret slack-webhook exists"
else
  warn "Kubernetes secret slack-webhook not found"
fi

section "8. Observability"

if exists_ns monitoring; then
  pass "monitoring namespace exists"
else
  warn "monitoring namespace missing"
fi

if kubectl get pods -n monitoring >/dev/null 2>&1; then
  if pods_ready_in_ns monitoring >/tmp/phase1-monitoring-bad-pods 2>/dev/null; then
    pass "All monitoring pods Running"
  else
    fail "Some monitoring pods not Running"
    cat /tmp/phase1-monitoring-bad-pods
  fi
else
  warn "No monitoring pods found"
fi

if kubectl get svc -n monitoring | grep -qi grafana; then
  pass "Grafana service found"
else
  warn "Grafana service not found"
fi

if kubectl get svc -n monitoring | grep -qi prometheus; then
  pass "Prometheus service found"
else
  warn "Prometheus service not found"
fi

if kubectl get pods -n monitoring 2>/dev/null | grep -qi loki; then
  pass "Loki pod found"
else
  warn "Loki pod not found"
fi

if kubectl get pods -n monitoring 2>/dev/null | grep -qi tempo; then
  pass "Tempo pod found"
else
  warn "Tempo pod not found"
fi

section "9. Kyverno"

if exists_ns kyverno; then
  pass "kyverno namespace exists"
else
  warn "kyverno namespace missing"
fi

if kubectl get pods -n kyverno >/dev/null 2>&1; then
  if pods_ready_in_ns kyverno >/tmp/phase1-kyverno-bad-pods 2>/dev/null; then
    pass "Kyverno pods Running"
  else
    fail "Some Kyverno pods not Running"
    cat /tmp/phase1-kyverno-bad-pods
  fi
else
  warn "Kyverno pods not found"
fi

POLICY_COUNT=$(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$POLICY_COUNT" -ge 3 ]; then
  pass "Kyverno ClusterPolicies found: $POLICY_COUNT"
else
  warn "Expected at least 3 Kyverno ClusterPolicies, found $POLICY_COUNT"
fi

if kubectl run phase1-latest-test --image=nginx:latest --restart=Never >/tmp/phase1-kyverno-test 2>&1; then
  kubectl delete pod phase1-latest-test --ignore-not-found >/dev/null 2>&1
  warn "Kyverno did not block nginx:latest test pod"
else
  if grep -qi "denied\|disallow-latest\|latest" /tmp/phase1-kyverno-test; then
    pass "Kyverno blocked nginx:latest test pod"
  else
    warn "nginx:latest test failed, but not clearly due to Kyverno"
    cat /tmp/phase1-kyverno-test
  fi
fi

section "10. Argo CD Application Summary"

if kubectl -n argocd get applications.argoproj.io >/dev/null 2>&1; then
  kubectl -n argocd get applications.argoproj.io
else
  warn "No Argo CD Application CRs found or CRD unavailable"
fi

BAD_APPS=$(kubectl -n argocd get applications.argoproj.io --no-headers 2>/dev/null | awk '$2!="Synced" || $3!="Healthy" {print $0}' || true)

if [ -z "$BAD_APPS" ]; then
  pass "All Argo CD applications Synced/Healthy"
else
  warn "Some Argo CD apps are not Synced/Healthy"
  echo "$BAD_APPS"
fi

section "11. Final Cluster Pod Health"

BAD_ALL=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" {print $0}' || true)

if [ -z "$BAD_ALL" ]; then
  pass "All cluster pods Running or Completed"
else
  fail "Some cluster pods are not healthy"
  echo "$BAD_ALL"
fi

echo
echo "══════════════════════════════════════════════════"
echo "  PHASE 1 VERIFICATION SUMMARY"
echo "══════════════════════════════════════════════════"
echo
echo "  PASS:  $PASS"
echo "  FAIL:  $FAIL"
echo "  WARN:  $WARN"
echo "  TOTAL: $((PASS+FAIL+WARN))"
echo
echo "  Completed at: $(date)"
echo

if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}╔═══════════════════════════════════════════╗${NC}"
  echo -e "  ${GREEN}║   ✅  PHASE 1 VERIFICATION PASSED         ║${NC}"
  echo -e "  ${GREEN}║       Ready to tag v0.2.0-platform        ║${NC}"
  echo -e "  ${GREEN}╚═══════════════════════════════════════════╝${NC}"
  exit 0
else
  echo -e "  ${RED}╔═══════════════════════════════════════════╗${NC}"
  echo -e "  ${RED}║   ❌  PHASE 1 VERIFICATION FAILED         ║${NC}"
  echo -e "  ${RED}║       Fix failures before tagging Phase 1 ║${NC}"
  echo -e "  ${RED}╚═══════════════════════════════════════════╝${NC}"
  exit 1
fi
