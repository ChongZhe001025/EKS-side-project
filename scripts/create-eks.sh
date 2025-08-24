#!/usr/bin/env bash
# create-eks.sh — Create/Update a Terraform-provisioned EKS and get it ready for use.
#
# Features
# - Auto-detect cluster_name/region from TF outputs (-json) with CLI/env/variables.tf fallbacks.
# - Optional workspace select/new.
# - plan-only / dry-run / auto-approve apply.
# - Two-phase apply (optional): Phase1 VPC+EKS (容錯 target 不存在時自動退回一般 apply)，Phase2 其餘附加元件。
# - Post steps: wait for EKS ACTIVE, update kubeconfig (alias=cluster name), wait nodes ready.
# - Optional: apply infra/aws-auth.yaml, wait addons rollout (ALB Controller / Argo CD)。
# - AWS profile 與 kubeconfig 路徑支援；完整日誌與摘要輸出。
#
# Usage:
#   scripts/create-eks.sh [options]
#
# Options:
#   -y, --yes                     Non-interactive; terraform apply -auto-approve
#   --infra-dir DIR               Path to Terraform infra directory (default: ./infra)
#   --region REGION               Override AWS region (fallback: TF output -> env -> variables.tf)
#   --cluster-name NAME           Override cluster name (fallback: TF output -> variables.tf)
#   --workspace NAME              Terraform workspace to select (auto-create if missing)
#   --var-file FILE               Pass a .tfvars file (repeatable)
#   --var KEY=VAL                 Extra -var (repeatable)
#   --plan-only                   Only run terraform plan (no apply)
#   --dry-run                     Show steps/plan; skip apply and side-effects
#   --wait-nodes COUNT            Wait until at least COUNT Ready nodes (default: 1)
#   --skip-wait                   Skip EKS status/node waits
#   --confirm-account             Ask to confirm AWS account ID before apply
#   --two-phase-apply             Phase1: VPC+EKS → kubeconfig → Phase2: addons
#   --apply-aws-auth              After Phase1, kubectl apply infra/aws-auth.yaml
#   --wait-addons                 After apply, wait ALB Controller / Argo CD rollout
#   --profile NAME                Use specific AWS profile
#   --kubeconfig PATH             Use specific kubeconfig file path
#   -h, --help                    Show this help
#
# Examples:
#   scripts/create-eks.sh --plan-only
#   scripts/create-eks.sh -y --workspace dev --region ap-southeast-2
#   scripts/create-eks.sh -y --var-file dev.tfvars --var desired_capacity=1
set -euo pipefail
IFS=$'\n\t'

YES="false"
INFRA_DIR=""
OVERRIDE_REGION=""
CLUSTER_NAME_OVERRIDE=""
WORKSPACE=""
PLAN_ONLY="false"
CONFIRM_ACCOUNT="false"
WAIT_NODES="1"
SKIP_WAIT="false"
TWO_PHASE_APPLY="false"
APPLY_AWS_AUTH="false"
WAIT_ADDONS="false"
AWS_PROFILE_NAME=""
KUBECONFIG_PATH=""
DRY_RUN="false"
declare -a VAR_FILES
declare -a EXTRA_VARS
LOG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES="true"; shift ;;
    --infra-dir) INFRA_DIR="${2:-}"; shift 2 ;;
    --region) OVERRIDE_REGION="${2:-}"; shift 2 ;;
    --cluster-name) CLUSTER_NAME_OVERRIDE="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --var-file) VAR_FILES+=("${2:-}"); shift 2 ;;
    --var) EXTRA_VARS+=("${2:-}"); shift 2 ;;
    --plan-only) PLAN_ONLY="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --wait-nodes) WAIT_NODES="${2:-1}"; shift 2 ;;
    --skip-wait) SKIP_WAIT="true"; shift ;;
    --confirm-account) CONFIRM_ACCOUNT="true"; shift ;;
    --two-phase-apply) TWO_PHASE_APPLY="true"; shift ;;
    --apply-aws-auth) APPLY_AWS_AUTH="true"; shift ;;
    --wait-addons) WAIT_ADDONS="true"; shift ;;
    --profile) AWS_PROFILE_NAME="${2:-}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" | { tee -a "${LOG_FILE:-/dev/null}" || true; }; }
warn(){ printf '[%s] \033[33mWARN\033[0m %s\n' "$(date +'%F %T')" "$*" | { tee -a "${LOG_FILE:-/dev/null}" >&2 || true; }; }
err() { printf '[%s] \033[31mERROR\033[0m %s\n' "$(date +'%F %T')" "$*" | { tee -a "${LOG_FILE:-/dev/null}" >&2 || true; }; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found in PATH"; exit 4; }; }

# Safer runner (no eval)
run() { local cmd=( $* ); "${cmd[@]}"; }

# Retry wrapper for terraform apply (API throttling 等偶發)
retry_tf_apply() {
  local tries=${1:-2} delay=10 i=1; shift || true
  while true; do
    if run "$*"; then return 0; fi
    if (( i >= tries )); then return 1; fi
    warn "terraform apply failed; retrying in ${delay}s (attempt $((i+1))/$tries)..."
    sleep "$delay"; ((i++))
  done
}

# Paths
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Default infra dir
if [[ -z "$INFRA_DIR" ]]; then
  if [[ -d "$REPO_ROOT/infra" ]]; then INFRA_DIR="$REPO_ROOT/infra"; else err "No infra dir. Use --infra-dir."; exit 3; fi
fi

need terraform
need aws
if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not found; kubeconfig update & node wait will be skipped"
fi

if [[ -n "$AWS_PROFILE_NAME" ]]; then export AWS_PROFILE="$AWS_PROFILE_NAME"; fi
if [[ -n "$KUBECONFIG_PATH" ]]; then export KUBECONFIG="$KUBECONFIG_PATH"; fi

JQ_AVAILABLE="true"
command -v jq >/dev/null 2>&1 || { JQ_AVAILABLE="false"; warn "jq not found; JSON 便利功能受限"; }

pushd "$INFRA_DIR" >/dev/null || exit 3
trap 'status=$?; popd >/dev/null 2>&1 || true; if [[ $status -ne 0 ]]; then err "Script failed with exit $status (see $LOG_FILE)"; fi; exit $status' EXIT

# Logging
LOG_FILE="$INFRA_DIR/create-eks-$(date +%Y%m%d-%H%M%S).log"
log "Logging to $LOG_FILE"
log "Terraform: $(terraform -v | head -n1)"
log "AWS CLI : $(aws --version 2>&1 | head -n1)"
command -v kubectl >/dev/null 2>&1 && log "kubectl  : $(kubectl version --client --output=yaml 2>/dev/null | head -n1)"

# Preflight: AWS identity（避免憑證過期）
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  err "AWS credentials invalid/expired. Run 'aws configure' or refresh your session."
  exit 9
fi

log "Initializing Terraform ..."
terraform init -input=false >/dev/null

# Workspace
if [[ -n "$WORKSPACE" ]]; then
  terraform workspace select "$WORKSPACE" >/dev/null 2>&1 || terraform workspace new "$WORKSPACE" >/dev/null
  log "Using Terraform workspace: $WORKSPACE"
fi

# Try outputs first
TF_CLUSTER_NAME=""; TF_REGION=""
if terraform output -json >/dev/null 2>&1; then
  JSON_OUT=$(terraform output -json || echo "{}")
  if [[ "$JQ_AVAILABLE" == "true" ]]; then
    TF_CLUSTER_NAME=$(echo "$JSON_OUT" | jq -r '.cluster_name.value // .eks_cluster_name.value // empty')
    TF_REGION=$(echo "$JSON_OUT" | jq -r '.region.value // .aws_region.value // empty')
  fi
fi

# Fallback: variables.tf defaults
parse_var_default() {
  local var="$1"; [[ -f "variables.tf" ]] || { echo ""; return; }
  awk -v v="$var" '
    $1=="variable" && $2=="\""v"\"" { invar=1 }
    invar && $1=="default" {
      val=$3; gsub(/^[\"']|[\"'],?$/,"",val); gsub(/[,}]/,"",val); print val; exit
    }' variables.tf 2>/dev/null || true
}

CLUSTER_NAME="${CLUSTER_NAME_OVERRIDE:-${TF_CLUSTER_NAME:-$(parse_var_default cluster_name)}}"
REGION="${OVERRIDE_REGION:-${TF_REGION:-}}"
[[ -z "$REGION" && -n "${AWS_REGION:-}" ]] && REGION="$AWS_REGION"
[[ -z "$REGION" && -n "${AWS_DEFAULT_REGION:-}" ]] && REGION="$AWS_DEFAULT_REGION"
[[ -z "$REGION" ]] && REGION="$(parse_var_default region)"

[[ -z "$CLUSTER_NAME" ]] && { err "Resolve cluster_name failed. Use --cluster-name or set variables/outputs."; exit 5; }
[[ -z "$REGION" ]] && { err "Resolve region failed. Use --region or export AWS_REGION."; exit 5; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/devnull || true)

echo
log "About to create/update EKS:"
echo "  Cluster : $CLUSTER_NAME"
echo "  Region  : $REGION"
[[ -n "$ACCOUNT_ID" ]] && echo "  Account : $ACCOUNT_ID"
[[ -n "$CALLER_ARN" ]] && echo "  Caller  : $CALLER_ARN"
echo

if [[ "$CONFIRM_ACCOUNT" == "true" && -n "$ACCOUNT_ID" ]]; then
  read -rp "Confirm AWS Account ID ($ACCOUNT_ID) to continue: " ACONF
  [[ "$ACONF" == "$ACCOUNT_ID" ]] || { err "Account mismatch. Aborting."; exit 6; }
fi

# Build TF args
TF_ARGS=( -var "region=$REGION" -var "cluster_name=$CLUSTER_NAME" )
for f in "${VAR_FILES[@]:-}"; do TF_ARGS+=( -var-file "$f" ); done
for v in "${EXTRA_VARS[@]:-}"; do TF_ARGS+=( -var "$v" ); done

# Validate & Plan
terraform validate
log "Planning changes..."
terraform plan "${TF_ARGS[@]}"

if [[ "$PLAN_ONLY" == "true" || "$DRY_RUN" == "true" ]]; then
  log "Plan-only/dry-run requested. Exit."
  exit 0
fi

# Phase1 (optional): VPC+EKS，若 target 名稱不符，自動退回一般 apply
phase1_apply() {
  if [[ "$YES" == "true" ]]; then
    retry_tf_apply 2 terraform apply -auto-approve -target=module.vpc -target=module.eks "${TF_ARGS[@]}" \
      || { warn "Phase1 targeted apply failed (module names may differ). Falling back to normal apply."; \
           retry_tf_apply 2 terraform apply -auto-approve "${TF_ARGS[@]}"; }
  else
    if ! terraform apply -target=module.vpc -target=module.eks "${TF_ARGS[@]}"; then
      warn "Phase1 targeted apply failed. Falling back to normal apply."
      terraform apply "${TF_ARGS[@]}"
    fi
  fi
}

# Single-phase apply
single_apply() {
  if [[ "$YES" == "true" ]]; then
    retry_tf_apply 2 terraform apply -auto-approve "${TF_ARGS[@]}" || { err "terraform apply failed."; exit 7; }
  else
    terraform apply "${TF_ARGS[@]}"
  fi
}

if [[ "$TWO_PHASE_APPLY" == "true" ]]; then
  log "Phase1: Applying core (VPC+EKS)..."
  phase1_apply
else
  log "Single-phase apply (all resources)..."
  single_apply
fi

# Wait & kubeconfig
if [[ "$SKIP_WAIT" != "true" ]]; then
  log "Waiting EKS ACTIVE ..."
  aws eks wait cluster-active --region "$REGION" --name "$CLUSTER_NAME" 2>/dev/null || warn "eks wait skipped/failed (continuing)"

  if command -v kubectl >/dev/null 2>&1; then
    log "Updating kubeconfig (alias='$CLUSTER_NAME') ..."
    AWS_UK_ARGS=( --region "$REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" )
    [[ -n "$KUBECONFIG_PATH" ]] && AWS_UK_ARGS+=( --kubeconfig "$KUBECONFIG_PATH" )
    aws eks update-kubeconfig "${AWS_UK_ARGS[@]}"

    if [[ "$WAIT_NODES" =~ ^[0-9]+$ && "$WAIT_NODES" -gt 0 ]]; then
      log "Waiting for $WAIT_NODES Ready node(s) ..."
      ready=0; for _ in {1..60}; do
        ready=$(kubectl get nodes 2>/dev/null | awk '/ Ready /{c++} END{print c+0}')
        (( ready >= WAIT_NODES )) && break; sleep 10
      done
      (( ready >= WAIT_NODES )) || warn "Only $ready node(s) Ready; continuing."
    fi

    if [[ "$APPLY_AWS_AUTH" == "true" && -f "$INFRA_DIR/aws-auth.yaml" ]]; then
      log "Applying infra/aws-auth.yaml ..."
      kubectl apply -f "$INFRA_DIR/aws-auth.yaml" || warn "apply aws-auth failed (continuing)"
    fi
  fi
else
  warn "Skip wait (--skip-wait)"
fi

# Phase2（若兩段）
if [[ "$TWO_PHASE_APPLY" == "true" ]]; then
  log "Phase2: Applying remaining resources (addons) ..."
  single_apply
fi

# Optional addon waits
if [[ "$WAIT_ADDONS" == "true" && "$SKIP_WAIT" != "true" && -n "$(command -v kubectl || true)" ]]; then
  log "Waiting addons rollout ..."
  kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=10m || warn "ALB Controller not ready"
  if kubectl get ns argocd >/dev/null 2>&1; then
    kubectl -n argocd rollout status deploy/argocd-server --timeout=10m || warn "Argo CD server not ready"
  fi
fi

# Summary
ENDPOINT=""; OIDC=""; NG_COUNT=""; KCTX=""
ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.endpoint' --output text 2>/dev/null || echo "")
OIDC=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || echo "")
NG_COUNT=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'length(nodegroups)' --output text 2>/dev/null || echo "")
command -v kubectl >/dev/null 2>&1 && KCTX=$(kubectl config current-context 2>/dev/null || echo "")

echo
log "Summary:"
echo "  Cluster       : $CLUSTER_NAME"
echo "  Region        : $REGION"
[[ -n "$ENDPOINT" ]] && echo "  API Endpoint  : $ENDPOINT"
[[ -n "$OIDC" ]] && echo "  OIDC Issuer   : $OIDC"
[[ -n "$NG_COUNT" ]] && echo "  NodeGroups    : $NG_COUNT"
[[ -n "$KCTX" ]] && echo "  kube-context  : $KCTX"
if [[ "$WAIT_ADDONS" == "true" && -n "$(command -v kubectl || true)" ]]; then
  ALB_HOSTS=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null | grep -v '\t$' || true)
  if [[ -n "$ALB_HOSTS" ]]; then
    echo "  LB Services   :"; echo "$ALB_HOSTS" | sed 's/^/    /'
  fi
fi
echo
log "Done. Your EKS cluster should be ready."


# chmod +x scripts/create-eks.sh

# ./scripts/create-eks.sh --plan-only

# ./scripts/create-eks.sh -y \
#   --two-phase-apply --apply-aws-auth --wait-addons \
#   --region ap-southeast-2 --workspace dev
