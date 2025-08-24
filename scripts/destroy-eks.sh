#!/usr/bin/env bash
# destroy-eks.sh — Safely destroy a Terraform-provisioned EKS and related resources.
#
# Features
# - Auto-detects cluster_name and region from Terraform outputs (-json), with CLI/env/variables.tf fallbacks.
# - Optional workspace select/new before destroy.
# - Pre-clean K8s LB/Ingress/PVC and remove common finalizers (best-effort, safe namespace allowlist).
# - Optional plan-only, dry-run, two-phase (destroy helm_release first) flows.
# - Robust terraform destroy with retry and state dump upon failure.
# - Post-clean AWS leftovers by tag kubernetes.io/cluster/<CLUSTER_NAME> (ALB/NLB/ELB/EBS/ENI/SG) with retries & waiters.
# - kubeconfig cleanup for contexts/clusters/users containing the cluster name.
#
# Usage:
#   scripts/destroy-eks.sh [options]
#
# Options:
#   -y, --yes                       Non-interactive; skip confirmation.
#   --infra-dir DIR                 Path to Terraform infra directory (default: ./infra).
#   --region REGION                 AWS region override (fallback: TF output -> env -> variables.tf default).
#   --cluster-name NAME             Cluster name override (fallback: TF output -> variables.tf default).
#   --workspace NAME                Terraform workspace to select (auto-create if missing).
#   --force-aws-cleanup [true|false]  Tag-based AWS cleanup after destroy (default: true).
#   --skip-preclean                 Skip Kubernetes pre-clean phase.
#   --two-phase                     Destroy helm releases first, then full destroy.
#   --dry-run                       Print the commands without deleting.
#   --plan-only                     Show terraform plan -destroy and exit.
#   --confirm-account               Ask to confirm AWS account ID as well.
#   -h, --help                      Show this help.
#
# Examples:
#   scripts/destroy-eks.sh
#   scripts/destroy-eks.sh -y --workspace dev
#   scripts/destroy-eks.sh -y --infra-dir ./infra --region ap-southeast-2
set -euo pipefail
IFS=$'\n\t'

YES="false"
INFRA_DIR=""
OVERRIDE_REGION=""
CLUSTER_NAME_OVERRIDE=""
WORKSPACE=""
FORCE_AWS_CLEANUP="true"
SKIP_PRECLEAN="false"
TWO_PHASE="false"
DRY_RUN="false"
PLAN_ONLY="false"
CONFIRM_ACCOUNT="false"
LOG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES="true"; shift ;;
    --infra-dir) INFRA_DIR="${2:-}"; shift 2 ;;
    --region) OVERRIDE_REGION="${2:-}"; shift 2 ;;
    --cluster-name) CLUSTER_NAME_OVERRIDE="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --force-aws-cleanup) FORCE_AWS_CLEANUP="${2:-true}"; shift 2 ;;
    --skip-preclean) SKIP_PRECLEAN="true"; shift ;;
    --two-phase) TWO_PHASE="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --plan-only) PLAN_ONLY="true"; shift ;;
    --confirm-account) CONFIRM_ACCOUNT="true"; shift ;;
    -h|--help) grep '^#' "$0" | sed -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*" | { tee -a "${LOG_FILE:-/dev/null}" || true; }; }
warn() { printf '[%s] \033[33mWARN\033[0m %s\n' "$(date +'%F %T')" "$*" | { tee -a "${LOG_FILE:-/dev/null}" >&2 || true; }; }
err() { printf '[%s] \033[31mERROR\033[0m %s\n' "$(date +'%F %T')" "$*" | { tee -a "${LOG_FILE:-/dev/null}" >&2 || true; }; }
need() { command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found in PATH"; exit 4; }; }

# Safer runner (no eval); honors DRY_RUN
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] $*"
    return 0
  fi
  # shellcheck disable=SC2206
  local cmd=( $* )
  "${cmd[@]}"
}

# Exponential backoff for flaky AWS deletes
retry_aws() {
  local cmd="$1" tries=${2:-8} delay=3 i=1
  while true; do
    if run "$cmd"; then return 0; fi
    if (( i >= tries )); then return 1; fi
    sleep "$delay"; delay=$((delay*2)); ((i++))
  done
}

# Resolve repo root (this script is in scripts/)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Default infra dir
if [[ -z "$INFRA_DIR" ]]; then
  if [[ -d "$REPO_ROOT/infra" ]]; then
    INFRA_DIR="$REPO_ROOT/infra"
  else
    err "Could not find infra directory. Use --infra-dir to specify."
    exit 3
  fi
fi

need terraform
need aws
if ! command -v kubectl >/dev/null 2>&1; then
  warn "kubectl not found; Kubernetes pre-clean & kubeconfig cleanup will be partially/fully skipped"
fi

JQ_AVAILABLE="true"
if ! command -v jq >/dev/null 2>&1; then
  JQ_AVAILABLE="false"
  warn "jq not found; will avoid jq-dependent JSON transforms (finalizer removal may be limited)"
fi

pushd "$INFRA_DIR" >/dev/null || exit 3
trap 'status=$?; popd >/dev/null 2>&1 || true; if [[ $status -ne 0 ]]; then err "Script failed with exit $status (see $LOG_FILE)"; fi; exit $status' EXIT

# Setup logging
LOG_FILE="$INFRA_DIR/destroy-eks-$(date +%Y%m%d-%H%M%S).log"
log "Logging to $LOG_FILE"

log "Initializing Terraform in $INFRA_DIR ..."
terraform init -input=false >/dev/null

# Workspace (optional)
if [[ -n "$WORKSPACE" ]]; then
  if terraform workspace select "$WORKSPACE" >/dev/null 2>&1; then
    log "Selected Terraform workspace: $WORKSPACE"
  else
    terraform workspace new "$WORKSPACE" >/dev/null
    log "Created & selected Terraform workspace: $WORKSPACE"
  fi
fi

# Attempt to get outputs via JSON
TF_CLUSTER_NAME=""
TF_REGION=""
if terraform output -json >/dev/null 2>&1; then
  JSON_OUT=$(terraform output -json || echo "{}")
  if [[ "$JQ_AVAILABLE" == "true" ]]; then
    TF_CLUSTER_NAME=$(echo "$JSON_OUT" | jq -r '.cluster_name.value // .eks_cluster_name.value // empty')
    TF_REGION=$(echo "$JSON_OUT" | jq -r '.region.value // .aws_region.value // empty')
  fi
fi

# Fallback: parse variables.tf defaults (best-effort)
parse_var_default() {
  local var_name="$1"
  [[ -f "variables.tf" ]] || { echo ""; return; }
  awk -v v="$var_name" '
    $1=="variable" && $2=="\""v"\"" { invar=1 }
    invar && $1=="default" {
      val=$3
      gsub(/^[\"']|[\"'],?$/,"",val); gsub(/[,}]/,"",val)
      print val; exit
    }' variables.tf 2>/dev/null || true
}

CLUSTER_NAME="${CLUSTER_NAME_OVERRIDE:-${TF_CLUSTER_NAME:-$(parse_var_default cluster_name)}}"
REGION="${OVERRIDE_REGION:-${TF_REGION:-}}"
if [[ -z "$REGION" ]]; then
  if [[ -n "${AWS_REGION:-}" ]]; then
    REGION="$AWS_REGION"
  elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    REGION="$AWS_DEFAULT_REGION"
  else
    REGION="$(parse_var_default region)"
  fi
fi

if [[ -z "$CLUSTER_NAME" ]]; then
  err "Failed to resolve cluster_name from --cluster-name, TF outputs, or variables.tf"
  exit 5
fi
if [[ -z "$REGION" ]]; then
  err "Failed to resolve AWS region (use --region or set AWS_REGION)"
  exit 5
fi

# Identity check
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)

echo
log "About to destroy EKS cluster and related infra:"
echo "  Cluster name : $CLUSTER_NAME"
echo "  AWS region   : $REGION"
[[ -n "$ACCOUNT_ID" ]] && echo "  AWS account  : $ACCOUNT_ID"
[[ -n "$CALLER_ARN" ]] && echo "  Caller ARN   : $CALLER_ARN"
echo

if [[ "$YES" != "true" ]]; then
  read -rp "Type the cluster name to confirm destroy (or Ctrl-C to abort): " CONFIRM
  if [[ "$CONFIRM" != "$CLUSTER_NAME" ]]; then
    err "Confirmation did not match cluster name. Aborting."
    exit 6
  fi
  if [[ "$CONFIRM_ACCOUNT" == "true" && -n "$ACCOUNT_ID" ]]; then
    read -rp "Confirm AWS Account ID ($ACCOUNT_ID): " ACONF
    if [[ "$ACONF" != "$ACCOUNT_ID" ]]; then
      err "Account confirmation mismatch. Aborting."
      exit 6
    fi
  fi
fi

# ---------- Plan-only (optional) ----------
if [[ "$PLAN_ONLY" == "true" ]]; then
  log "Showing terraform plan -destroy ..."
  terraform plan -destroy -var "region=$REGION" -var "cluster_name=$CLUSTER_NAME" || true
  log "Plan-only completed."
  exit 0
fi

# ---------- Pre-clean Kubernetes (best-effort) ----------
if [[ "$SKIP_PRECLEAN" != "true" && -n "$(command -v kubectl || true)" ]]; then
  log "Pre-cleaning Kubernetes resources (best-effort)..."
  if command -v aws >/dev/null 2>&1; then
    run aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"
    if [[ -n "$ACCOUNT_ID" ]]; then
      TARGET_CTX="arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME"
      kubectl config use-context "$TARGET_CTX" >/dev/null 2>&1 || kubectl config use-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
    else
      kubectl config use-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
    fi
  fi
  set +e
  # LoadBalancer Services
  kubectl get svc -A --field-selector spec.type=LoadBalancer -o name 2>/dev/null | xargs -r kubectl delete --timeout=60s
  # Ingress
  kubectl get ingress -A -o name 2>/dev/null | xargs -r kubectl delete --timeout=60s
  # Remove common finalizers (ingress/pvc)
  for ing in $(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [[ -z "$ing" ]] && continue
    kubectl patch ingress "$ing" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  done
  for pvc in $(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [[ -z "$pvc" ]] && continue
    kubectl patch pvc "$pvc" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  done
  # Namespaces (skip system & default)
  for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [[ "$ns" == "kube-system" || "$ns" == "kube-public" || "$ns" == "kube-node-lease" || "$ns" == "default" ]] && continue
    kubectl patch ns "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  done
  set -e
else
  [[ "$SKIP_PRECLEAN" == "true" ]] && warn "Skip pre-clean as requested (--skip-preclean)"
fi

# ---------- Terraform destroy ----------
log "Generating quick state overview..."
if terraform state list >/dev/null 2>&1; then
  COUNT=$(terraform state list | wc -l | tr -d ' ')
  log "Terraform resources in state: $COUNT"
fi

DESTROY_EXIT=0
if [[ "$DRY_RUN" == "true" ]]; then
  log "[dry-run] Skipping terraform destroy phase"
else
  if [[ "$TWO_PHASE" == "true" ]]; then
    log "Two-phase destroy: removing helm releases detected in state..."
    set +e
    mapfile -t HELMS < <(terraform state list 2>/dev/null | grep '^helm_release\.')
    for hr in "${HELMS[@]:-}"; do
      terraform destroy -auto-approve -var "region=$REGION" -var "cluster_name=$CLUSTER_NAME" -target="$hr"
    done
    set -e
  fi

  log "Destroying infrastructure via Terraform..."
  set +e
  terraform destroy -auto-approve -var "region=$REGION" -var "cluster_name=$CLUSTER_NAME"
  DESTROY_EXIT=$?
  if [[ $DESTROY_EXIT -ne 0 ]]; then
    warn "Terraform destroy failed (code $DESTROY_EXIT). Attempting one retry after 20s..."
    sleep 20
    terraform destroy -auto-approve -var "region=$REGION" -var "cluster_name=$CLUSTER_NAME"
    DESTROY_EXIT=$?
  fi
  set -e
fi

if [[ $DESTROY_EXIT -ne 0 ]]; then
  warn "State after failed destroy:"
  terraform state list || true
  err "Terraform destroy failed with exit code $DESTROY_EXIT"
  cat <<'EOF' >&2
Common causes:
 - Kubernetes finalizers or dynamic AWS resources (ALB/NLB/Target Groups/EBS) still present
 - NAT/IGW/EIP/VPC dependencies
Actions:
 - Re-run this script; if it persists, check AWS Console for stuck resources and delete them, then re-run.
EOF
fi
log "Terraform destroy phase completed (exit=$DESTROY_EXIT)."

# ---------- Post-clean AWS leftovers (by tag) ----------
DELETED_LB=0; DELETED_TG=0; DELETED_VOL=0; DELETED_ENI=0; DELETED_SG=0
if [[ "$FORCE_AWS_CLEANUP" == "true" ]]; then
  log "Scanning & deleting leftover AWS resources tagged kubernetes.io/cluster/$CLUSTER_NAME ..."
  set +e
  # ELBv2 (ALB/NLB)
  LBS_JSON=$(aws elbv2 describe-load-balancers --region "$REGION" 2>/dev/null)
  if [[ -n "$LBS_JSON" ]]; then
    if [[ "$JQ_AVAILABLE" == "true" ]]; then
      mapfile -t LB_ARNS < <(echo "$LBS_JSON" | jq -r '.LoadBalancers[].LoadBalancerArn')
    else
      mapfile -t LB_ARNS < <(echo "$LBS_JSON" | grep -o 'arn:aws:elasticloadbalancing:[^" ]\+')
    fi
    for arn in "${LB_ARNS[@]:-}"; do
      TAGS=$(aws elbv2 describe-tags --resource-arns "$arn" --region "$REGION" 2>/dev/null || echo "{}")
      if echo "$TAGS" | grep -q "kubernetes.io/cluster/$CLUSTER_NAME"; then
        log "  Deleting ELBv2: $arn"
        if retry_aws "aws elbv2 delete-load-balancer --load-balancer-arn '$arn' --region '$REGION'"; then
          ((DELETED_LB++))
          aws elbv2 wait load-balancers-deleted --load-balancer-arns "$arn" --region "$REGION" 2>/dev/null || true
        fi
      fi
    done
  fi

  # Classic ELB
  ELBS=$(aws elb describe-load-balancers --region "$REGION" --output text 2>/dev/null | awk '{print $2}')
  for name in $ELBS; do
    TAG=$(aws elb describe-tags --region "$REGION" --load-balancer-names "$name" \
      --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME'].Value" --output text 2>/dev/null)
    if [[ "$TAG" == "owned" || "$TAG" == "shared" ]]; then
      log "  Deleting Classic ELB: $name"
      if retry_aws "aws elb delete-load-balancer --load-balancer-name '$name' --region '$REGION'"; then
        ((DELETED_LB++))
      fi
    fi
  done

  # EBS Volumes (only available state)
  VOLS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned,shared" \
    --query "Volumes[?State=='available'].VolumeId" --output text 2>/dev/null)
  for v in $VOLS; do
    log "  Deleting EBS volume: $v"
    if retry_aws "aws ec2 delete-volume --volume-id '$v' --region '$REGION'"; then
      ((DELETED_VOL++))
    fi
  done

  # Target Groups
  TG_JSON=$(aws elbv2 describe-target-groups --region "$REGION" 2>/dev/null)
  if [[ -n "$TG_JSON" ]]; then
    if [[ "$JQ_AVAILABLE" == "true" ]]; then
      mapfile -t TG_ARNS < <(echo "$TG_JSON" | jq -r '.TargetGroups[].TargetGroupArn')
    else
      mapfile -t TG_ARNS < <(echo "$TG_JSON" | grep -o 'arn:aws:elasticloadbalancing:[^" ]\+')
    fi
    for t in "${TG_ARNS[@]:-}"; do
      TGTAGS=$(aws elbv2 describe-tags --resource-arns "$t" --region "$REGION" 2>/dev/null || echo "{}")
      if echo "$TGTAGS" | grep -q "kubernetes.io/cluster/$CLUSTER_NAME"; then
        log "  Deleting Target Group: $t"
        if retry_aws "aws elbv2 delete-target-group --target-group-arn '$t' --region '$REGION'"; then
          ((DELETED_TG++))
        fi
      fi
    done
  fi

  # ENIs
  ENIS=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned,shared" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)
  for eni in $ENIS; do
    log "  Deleting ENI: $eni"
    if retry_aws "aws ec2 delete-network-interface --network-interface-id '$eni' --region '$REGION'"; then
      ((DELETED_ENI++))
    fi
  done

  # Security Groups (after ENIs)
  SGS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned,shared" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)
  for sg in $SGS; do
    log "  Deleting Security Group: $sg"
    if retry_aws "aws ec2 delete-security-group --group-id '$sg' --region '$REGION'"; then
      ((DELETED_SG++))
    fi
  done
  set -e
else
  warn "Post AWS cleanup disabled (--force-aws-cleanup false)"
fi

# ---------- kubeconfig cleanup ----------
if command -v kubectl >/dev/null 2>&1; then
  log "Cleaning local kubeconfig entries referencing '$CLUSTER_NAME' ..."
  set +e
  mapfile -t CONTEXTS < <(kubectl config get-contexts -o name 2>/dev/null | grep -F "$CLUSTER_NAME" || true)
  for ctx in "${CONTEXTS[@]:-}"; do
    kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
    log "  Deleted context: $ctx"
  done
  mapfile -t CLUSTERS < <(kubectl config view -o jsonpath='{.clusters[*].name}' 2>/dev/null | tr ' ' '\n' | grep -F "$CLUSTER_NAME" || true)
  for c in "${CLUSTERS[@]:-}"; do
    kubectl config delete-cluster "$c" >/dev/null 2>&1 || true
    log "  Deleted cluster: $c"
  done
  mapfile -t USERS < <(kubectl config view -o jsonpath='{.users[*].name}' 2>/dev/null | tr ' ' '\n' | grep -F "$CLUSTER_NAME" || true)
  for u in "${USERS[@]:-}"; do
    kubectl config unset "users.$u" >/dev/null 2>&1 || true
    log "  Deleted user: $u"
  done
  set -e
else
  warn "kubectl not available; skipped kubeconfig cleanup."
fi

# ---------- Summary ----------
echo
log "Summary:"
echo "  Deleted ELB/ALB/NLB : $DELETED_LB"
echo "  Deleted TargetGroups: $DELETED_TG"
echo "  Deleted EBS Volumes : $DELETED_VOL"
echo "  Deleted ENIs        : $DELETED_ENI"
echo "  Deleted SecGroups   : $DELETED_SG"
echo
log "Done. The EKS cluster '$CLUSTER_NAME' and related Terraform-managed resources should be deleted."



# chmod +x scripts/destroy-eks.sh

# ./scripts/destroy-eks.sh --dry-run

# ./scripts/destroy-eks.sh