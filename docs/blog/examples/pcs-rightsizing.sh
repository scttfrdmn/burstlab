#!/usr/bin/env bash
# =============================================================================
#  Right-sizing on AWS PCS (Parallel Computing Service) — the managed path
# -----------------------------------------------------------------------------
#  Same idea as the ParallelCluster example, expressed through the PCS API:
#  one QUEUE spanning several COMPUTE NODE GROUPS (one per shape), each with a
#  per-node Weight so the scheduler picks the cheapest node that fits.
#
#  KEY FACT (verified live, Slurm 25.11): "Weight" is an allow-listed
#  slurmCustomSettings parameter for compute node groups, alongside CpuSpecList,
#  Features, MemSpecLimit, RealMemory. It maps directly to the Slurm node Weight.
#  So the right-sizing model works on PCS with no controller access needed.
#
#  Prereqs you must create first (see comments): a VPC with DNS hostnames +
#  resolution ON, a security group allowing intra-cluster traffic, an EC2 launch
#  template, an IAM instance profile whose role name starts with "AWSPCS" (or has
#  path /aws-pcs/) and includes pcs:RegisterComputeNodeGroupInstance, and a PCS
#  sample AMI id.
#
#  Replace every REPLACE_ME_* below.
# =============================================================================
set -euo pipefail

REGION=us-east-1
SUBNET=REPLACE_ME_SUBNET_ID          # in a VPC with DNS hostnames + resolution ON
SG=REPLACE_ME_SECURITY_GROUP_ID      # allows all traffic within itself
LT=REPLACE_ME_LAUNCH_TEMPLATE_ID     # minimal LT (can just set the SG)
PROFILE_ARN=REPLACE_ME_INSTANCE_PROFILE_ARN
AMI=REPLACE_ME_PCS_AMI_ID            # a PCS-compatible AMI for the chosen Slurm version

# 1. The managed cluster (controller is fully managed; no head node to run).
CLUSTER=$(aws pcs create-cluster --region "$REGION" \
  --cluster-name rightsizing \
  --scheduler type=SLURM,version=25.11 \
  --size SMALL \
  --networking "subnetIds=$SUBNET,securityGroupIds=$SG" \
  --query 'cluster.id' --output text)
echo "cluster: $CLUSTER (wait for ACTIVE before continuing)"
# aws pcs get-cluster --region $REGION --cluster-identifier $CLUSTER --query cluster.status

# 2. One compute node group per shape. Weight (slurmCustomSettings) = the
#    right-sizing knob. One shape per node group == one Weight per node group,
#    which fits PCS's model exactly. (Add m-2xl/c-8xl/... the same way.)
mk_cng () {  # name  instanceType  weight
  aws pcs create-compute-node-group --region "$REGION" \
    --cluster-identifier "$CLUSTER" \
    --compute-node-group-name "$1" \
    --scaling-configuration minInstanceCount=0,maxInstanceCount=50 \
    --instance-configs "instanceType=$2" \
    --subnet-ids "$SUBNET" \
    --custom-launch-template "id=$LT,version=1" \
    --ami-id "$AMI" \
    --iam-instance-profile-arn "$PROFILE_ARN" \
    --slurm-configuration "slurmCustomSettings=[{parameterName=Weight,parameterValue=$3}]" \
    --query 'computeNodeGroup.id' --output text
}
C2XL=$(mk_cng c-2xl c8i.2xlarge 37)
R8XL=$(mk_cng r-8xl r8i.8xlarge 236)
# ... m-2xl 46, r-2xl 59, c-8xl 148, m-8xl 184 ...
echo "node groups: $C2XL $R8XL (wait for ACTIVE)"

# 3. One queue spanning the node groups == one Slurm partition "general".
#    NOTE: computeNodeGroupId must be the pcs_ ID, not the name.
aws pcs create-queue --region "$REGION" \
  --cluster-identifier "$CLUSTER" \
  --queue-name general \
  --compute-node-group-configurations \
      "computeNodeGroupId=$C2XL" "computeNodeGroupId=$R8XL"

# -----------------------------------------------------------------------------
#  Result (verified): the managed Slurm config shows the weights, and one
#  partition spans both shapes, scaled to zero at rest:
#
#    NodeName=c-2xl-1  RealMemory=15564   Weight=37   State=IDLE+CLOUD+POWERED_DOWN Partition=general
#    NodeName=r-8xl-1  RealMemory=249036  Weight=236  State=IDLE+CLOUD+POWERED_DOWN Partition=general
#
#  And cheapest-fit works identically to ParallelCluster:
#    sbatch --test-only -p general -c 2 --mem=4G    ->  c-2xl
#    sbatch --test-only -p general -c 2 --mem=200G  ->  r-8xl   (only 249G fits)
# -----------------------------------------------------------------------------
