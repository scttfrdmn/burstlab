#!/bin/bash
# =============================================================================
# check-quotas.sh — BurstLab AWS pre-flight quota check
#
# Verifies that the AWS account has enough quota headroom to deploy a BurstLab
# cluster before you commit to a full packer build + terraform apply cycle.
#
# Usage:
#   bash scripts/check-quotas.sh [--profile PROFILE] [--region REGION]
#
# Defaults:
#   --profile  aws        (BurstLab convention — replace with your actual profile name)
#   --region   us-west-2
#
# Exit codes:
#   0  all checks passed or only warnings
#   1  one or more checks failed (not enough quota)
# =============================================================================

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
PROFILE="aws"
REGION="us-west-2"

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--profile PROFILE] [--region REGION]"
      echo ""
      echo "Options:"
      echo "  --profile  AWS CLI profile name (default: aws)"
      echo "  --region   AWS region (default: us-west-2)"
      echo ""
      echo "Checks On-Demand Standard vCPU quota, VPC count, Elastic IPs, and key pairs."
      echo "Exit 0 = all pass/warn. Exit 1 = any fail."
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# --- vCPU lookup table (Standard family: A, C, D, H, I, M, R, T, Z) ---------
# Add instance types as needed. Values are vCPU count.
declare -A VCPU_MAP
VCPU_MAP["m7a.large"]=2
VCPU_MAP["m7a.xlarge"]=4
VCPU_MAP["m7a.2xlarge"]=8
VCPU_MAP["m7a.4xlarge"]=16
VCPU_MAP["m7a.8xlarge"]=32
VCPU_MAP["m6a.large"]=2
VCPU_MAP["m6a.xlarge"]=4
VCPU_MAP["m6a.2xlarge"]=8
VCPU_MAP["m6a.4xlarge"]=16
VCPU_MAP["m6i.large"]=2
VCPU_MAP["m6i.xlarge"]=4
VCPU_MAP["m6i.2xlarge"]=8
VCPU_MAP["m6i.4xlarge"]=16
VCPU_MAP["m5.large"]=2
VCPU_MAP["m5.xlarge"]=4
VCPU_MAP["m5.2xlarge"]=8
VCPU_MAP["m5.4xlarge"]=16
VCPU_MAP["c6i.large"]=2
VCPU_MAP["c6i.xlarge"]=4
VCPU_MAP["c6i.2xlarge"]=8
VCPU_MAP["c7i.large"]=2
VCPU_MAP["c7i.xlarge"]=4
VCPU_MAP["c7i.2xlarge"]=8
VCPU_MAP["r6i.large"]=2
VCPU_MAP["r6i.xlarge"]=4
VCPU_MAP["r6i.2xlarge"]=8
VCPU_MAP["r7a.large"]=2
VCPU_MAP["r7a.xlarge"]=4
VCPU_MAP["r7a.2xlarge"]=8
VCPU_MAP["t3.micro"]=2
VCPU_MAP["t3.small"]=2
VCPU_MAP["t3.medium"]=2
VCPU_MAP["t3.large"]=2
VCPU_MAP["t3.xlarge"]=4
VCPU_MAP["t3.2xlarge"]=8
VCPU_MAP["t3a.micro"]=2
VCPU_MAP["t3a.small"]=2
VCPU_MAP["t3a.medium"]=2
VCPU_MAP["t3a.large"]=2
VCPU_MAP["t3a.xlarge"]=4
VCPU_MAP["t3a.2xlarge"]=8

# --- BurstLab requirements ---------------------------------------------------
# 1 head (m7a.2xlarge = 8) + 4 compute (4x8=32) = 40 vCPUs base
# + up to 8 burst nodes (8x8=64) = 104 vCPUs full
NEEDED_BASE=40
NEEDED_FULL=104

# --- Helpers -----------------------------------------------------------------
PASS=0
WARN=0
FAIL=0

_pass() { echo "  [PASS] $*"; }
_warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
_fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
_info() { echo "  [INFO] $*"; }
_note() { echo "         $*"; }

AWS_CMD="aws --profile $PROFILE --region $REGION"

# --- Header ------------------------------------------------------------------
echo ""
echo "=== BurstLab Pre-Flight Quota Check ==="
echo "  Region:  $REGION"
echo "  Profile: $PROFILE"
echo ""

# --- Check 1: On-Demand Standard vCPU quota ----------------------------------
VCPU_QUOTA=$(
  $AWS_CMD service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-1216C47A \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "0"
)
VCPU_QUOTA=${VCPU_QUOTA%.*}  # strip decimals (quota API returns floats)

# Count vCPUs in use by running/pending Standard instances
RUNNING_TYPES=$(
  $AWS_CMD ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running,pending" \
    --query "Reservations[].Instances[].InstanceType" \
    --output text 2>/dev/null || echo ""
)

VCPU_INUSE=0
for itype in $RUNNING_TYPES; do
  # Look up vCPU count; fall back to querying EC2 API for unknown types
  if [[ -n "${VCPU_MAP[$itype]+x}" ]]; then
    VCPU_INUSE=$((VCPU_INUSE + VCPU_MAP[$itype]))
  else
    VCPUS=$(
      $AWS_CMD ec2 describe-instance-types \
        --instance-types "$itype" \
        --query "InstanceTypes[0].VCpuInfo.DefaultVCpus" \
        --output text 2>/dev/null || echo "0"
    )
    VCPU_INUSE=$((VCPU_INUSE + VCPUS))
  fi
done

if [[ "$VCPU_QUOTA" -eq 0 ]]; then
  _warn "On-Demand Standard vCPUs:  could not retrieve quota (check IAM permissions)"
  _note "Needed: base=$NEEDED_BASE  full-burst=$NEEDED_FULL"
else
  VCPU_AVAILABLE=$((VCPU_QUOTA - VCPU_INUSE))
  if [[ "$VCPU_AVAILABLE" -ge "$NEEDED_FULL" ]]; then
    _pass "On-Demand Standard vCPUs:  quota=$VCPU_QUOTA  in-use=$VCPU_INUSE  available=$VCPU_AVAILABLE  needed-base=$NEEDED_BASE  needed-full=$NEEDED_FULL"
  elif [[ "$VCPU_AVAILABLE" -ge "$NEEDED_BASE" ]]; then
    _warn "On-Demand Standard vCPUs:  quota=$VCPU_QUOTA  in-use=$VCPU_INUSE  available=$VCPU_AVAILABLE"
    _note "Enough for base cluster (head+compute) but not full burst ($NEEDED_FULL vCPUs needed)."
    _note "Burst jobs will fail when all $((NEEDED_FULL - NEEDED_BASE)) burst node slots are filled."
    _note "Request an increase: https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
  else
    _fail "On-Demand Standard vCPUs:  quota=$VCPU_QUOTA  in-use=$VCPU_INUSE  available=$VCPU_AVAILABLE  needed-base=$NEEDED_BASE"
    _note "Not enough vCPU quota for even one BurstLab cluster."
    _note "Request an increase: https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
    _note "Recommended value: 192"
  fi
fi

# --- Check 2: VPCs per region ------------------------------------------------
VPC_QUOTA=$(
  $AWS_CMD service-quotas get-service-quota \
    --service-code vpc \
    --quota-code L-F678F1CE \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "0"
)
VPC_QUOTA=${VPC_QUOTA%.*}

VPC_COUNT=$(
  $AWS_CMD ec2 describe-vpcs \
    --query 'length(Vpcs)' \
    --output text 2>/dev/null || echo "0"
)

if [[ "$VPC_QUOTA" -eq 0 ]]; then
  _warn "VPCs per region:           could not retrieve quota (check IAM permissions)"
else
  VPC_AVAILABLE=$((VPC_QUOTA - VPC_COUNT))
  if [[ "$VPC_AVAILABLE" -ge 3 ]]; then
    _pass "VPCs per region:           quota=$VPC_QUOTA  in-use=$VPC_COUNT  available=$VPC_AVAILABLE  (can run all 3 generations in parallel)"
  elif [[ "$VPC_AVAILABLE" -ge 1 ]]; then
    _warn "VPCs per region:           quota=$VPC_QUOTA  in-use=$VPC_COUNT  available=$VPC_AVAILABLE"
    _note "Can deploy $VPC_AVAILABLE generation(s) at a time. Deploy sequentially (destroy before next)."
    if [[ "$VPC_AVAILABLE" -lt 1 ]]; then
      _note "Consider requesting a VPC limit increase:"
      _note "  aws service-quotas request-service-quota-increase --service-code vpc --quota-code L-F678F1CE --desired-value 10"
    fi
  else
    _fail "VPCs per region:           quota=$VPC_QUOTA  in-use=$VPC_COUNT  available=$VPC_AVAILABLE"
    _note "No VPC capacity remaining. Delete an existing VPC or request a quota increase."
  fi
fi

# --- Check 3: Elastic IP addresses -------------------------------------------
EIP_QUOTA=$(
  $AWS_CMD service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-0263D0A3 \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "0"
)
EIP_QUOTA=${EIP_QUOTA%.*}

EIP_COUNT=$(
  $AWS_CMD ec2 describe-addresses \
    --query 'length(Addresses)' \
    --output text 2>/dev/null || echo "0"
)

if [[ "$EIP_QUOTA" -eq 0 ]]; then
  _warn "Elastic IP addresses:      could not retrieve quota (check IAM permissions)"
else
  EIP_AVAILABLE=$((EIP_QUOTA - EIP_COUNT))
  if [[ "$EIP_AVAILABLE" -ge 1 ]]; then
    _pass "Elastic IP addresses:      quota=$EIP_QUOTA  in-use=$EIP_COUNT  available=$EIP_AVAILABLE"
  else
    _fail "Elastic IP addresses:      quota=$EIP_QUOTA  in-use=$EIP_COUNT  available=$EIP_AVAILABLE"
    _note "No EIP capacity. Release an unused EIP or request a quota increase."
  fi
fi

# --- Check 4: Key pairs (informational) --------------------------------------
KEY_PAIRS=$(
  $AWS_CMD ec2 describe-key-pairs \
    --query 'KeyPairs[].KeyName' \
    --output text 2>/dev/null || echo ""
)

if [[ -z "$KEY_PAIRS" ]]; then
  _warn "EC2 key pairs:             none found in $REGION"
  _note "Create one: aws --profile $PROFILE ec2 create-key-pair --region $REGION --key-name burstlab-key --query KeyMaterial --output text > ~/.ssh/burstlab-key.pem && chmod 400 ~/.ssh/burstlab-key.pem"
else
  # Format as comma-separated for display
  KEY_LIST=$(echo "$KEY_PAIRS" | tr '\t' ', ')
  _info "EC2 key pairs:             $KEY_LIST"
fi

# --- Summary -----------------------------------------------------------------
echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "$FAIL check(s) failed. Resolve before deploying."
  echo ""
  echo "Quick links:"
  echo "  vCPU quota:  https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
  echo "  VPC quota:   https://console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
  echo "  EIP quota:   https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-0263D0A3"
  echo ""
  echo "See docs/prerequisites.md for full quota requirements and how to request increases."
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "$WARN warning(s). Deployment may succeed but burst capacity will be limited."
  echo "See docs/prerequisites.md for details."
  exit 0
else
  echo "All quota checks passed. Safe to deploy."
  exit 0
fi
