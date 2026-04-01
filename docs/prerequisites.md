# BurstLab Prerequisites

This document covers everything you need before running `packer build` or `terraform apply`.
If you skip this and hit a quota error mid-deploy, you will need to clean up a partially
deployed cluster before retrying.

**Recommendation:** Run `scripts/check-quotas.sh` before deploying any generation.
It checks the most common blockers in under 30 seconds.

> **Profile name:** BurstLab uses `aws` as the default AWS CLI profile name. Replace it
> with your actual profile name wherever you see `--profile aws` or `aws_profile = "aws"`.
> Run `aws configure list-profiles` to see what profiles you have.

---

## Local Tools

| Tool | Minimum Version | Check | Install |
|---|---|---|---|
| AWS CLI | v2.x | `aws --version` | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | 1.5 | `terraform version` | https://developer.hashicorp.com/terraform/install |
| Packer | 1.10 | `packer version` | https://developer.hashicorp.com/packer/install |
| SSH client | any | `ssh -V` | Pre-installed on macOS and Linux |

AWS CLI v1 will not work — BurstLab scripts use `--output json` with flags that are v2-only.

---

## AWS CLI Profile

BurstLab uses `aws` as the default AWS CLI profile name throughout its scripts, docs, and
Terraform defaults. This is a convention — **replace `aws` with your actual profile name**
wherever you see it.

To check what profiles you have configured:
```bash
aws configure list-profiles
```

Verify your profile works:
```bash
aws --profile YOUR_PROFILE sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/yourname"
}
```

If this errors, run `aws configure --profile YOUR_PROFILE` to set up credentials.

**To use a different profile name across BurstLab:**
- `terraform.tfvars`: set `aws_profile = "YOUR_PROFILE"`
- Scripts: pass `--profile YOUR_PROFILE` (e.g., `bash scripts/check-quotas.sh --profile YOUR_PROFILE`)
- Packer: pass `-var "aws_profile=YOUR_PROFILE"` to `packer build`

---

## IAM Permissions

Your AWS user or role needs permission to create the resources BurstLab manages.
`AdministratorAccess` is the simplest option. If you are working with a scoped policy,
the required services are:

| Service | Actions needed |
|---|---|
| EC2 | Full (create instances, VPCs, security groups, key pairs, launch templates, EIPs, fleet) |
| IAM | CreateRole, AttachRolePolicy, PassRole, CreateInstanceProfile |
| EFS | CreateFileSystem, CreateMountTarget, CreateAccessPoint |
| S3 | CreateBucket, PutObject, GetObject (for cluster scripts bucket) |
| Service Quotas | GetServiceQuota (for the pre-flight check script) |
| SSM | (optional) StartSession on EC2 instances — useful for debugging without SSH |

The exact IAM resources created by BurstLab are in `terraform/modules/iam/main.tf`.

---

## EC2 Key Pair

You need an EC2 key pair in the target region. This is the SSH key for all cluster nodes.

Check if you have one:
```bash
aws --profile aws ec2 describe-key-pairs \
  --region us-west-2 \
  --query 'KeyPairs[].KeyName' \
  --output text
```

If you need to create one:
```bash
aws --profile aws ec2 create-key-pair \
  --region us-west-2 \
  --key-name burstlab-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/burstlab-key.pem

chmod 400 ~/.ssh/burstlab-key.pem
```

> **Rocky 10 / Gen 3 note:** RHEL 10's default crypto policy blocks RSA-2048 SSH keys.
> EC2 key pairs created in the console are RSA-2048. If you plan to deploy Gen 3, use
> an ED25519 key pair (not affected) or the Gen 3 AMI handles this via `LEGACY` crypto
> policy. See [slurm-gen3-deep-dive.md](slurm-gen3-deep-dive.md) for details.

---

## AWS Quota Requirements

This is the section that catches people. The most common reason a BurstLab deployment
fails halfway through is an EC2 vCPU quota that is too low.

### Per-Cluster Resource Usage

A single BurstLab cluster (one generation deployed) uses:

| Resource | Count | Notes |
|---|---|---|
| EC2 instances | 1 head + 4 compute + 0–8 burst | Burst nodes appear/disappear on demand |
| On-Demand Standard vCPUs | 40 base (5 × m7a.2xlarge) | Up to 104 with all 8 burst nodes active |
| VPC | 1 | |
| Elastic IP address | 1 | Head node EIP |
| Internet Gateway | 1 | |
| EFS file system | 1 | |
| S3 bucket | 1 | Cluster scripts (auto-deleted on destroy) |
| Security groups | 6 | One per node type + EFS + head node |
| Subnets | 4 | Management, on-prem, cloud-A, cloud-B |

### Quota Table

| Quota | AWS Quota Code | Per Cluster | Default Limit | Risk |
|---|---|---|---|---|
| **Running On-Demand Standard (vCPU)** | `L-1216C47A` (ec2) | 40 base / 104 burst | 32–192 (varies by account age) | **HIGH — most common blocker** |
| VPCs per region | `L-F678F1CE` (vpc) | 1 | 5 | Medium — see note below |
| Elastic IPs per region | `L-0263D0A3` (ec2) | 1 | 5 | Low |
| Internet Gateways per region | `L-A4707A72` (ec2) | 1 | 5 | Same as VPC limit |
| EFS file systems | N/A | 1 | 1000+ | None |

**On-Demand Standard vCPUs** covers m7a, m6a, m6i, m5, c6i, r5, t3, and most other
common instance families. If your account is new or has a low limit (often 32 vCPUs),
you will hit the quota when trying to launch compute nodes (4 × m7a.2xlarge = 32 vCPUs)
before the head node (8 vCPUs) is even counted.

**Recommendation for full burst testing:** request a quota of at least 192 vCPUs in
your target region. This allows one cluster with all burst nodes active (104 vCPUs)
plus headroom.

### VPC Limit: Running Multiple Generations

The default VPC limit is 5 per region. BurstLab uses 1 VPC per generation deployed.
If you deploy all three generations simultaneously you need 3 VPCs — this works within
the default limit.

If you already have 4 or 5 VPCs in the region from other projects, you will hit the
limit when deploying. Either:
- Deploy generations sequentially (destroy Gen N before deploying Gen N+1) — this always
  works within default limits and is the recommended workflow
- Request a VPC limit increase before deploying multiple generations in parallel

---

## Running the Quota Check Script

Before deploying, run the pre-flight quota check:

```bash
bash scripts/check-quotas.sh --profile aws --region us-west-2
```

Example output when everything is fine:
```
=== BurstLab Pre-Flight Quota Check ===
  Region:  us-west-2
  Profile: aws

  [PASS] On-Demand Standard vCPUs:  quota=192  in-use=8    needed-base=40  needed-full=104
  [PASS] VPCs per region:           quota=5    in-use=1    needed=1
  [PASS] Elastic IP addresses:      quota=5    in-use=1    needed=1
  [INFO] EC2 key pairs:             burstlab-key

All quota checks passed. Safe to deploy.
```

Example output when vCPU quota is too low:
```
  [FAIL] On-Demand Standard vCPUs:  quota=32   in-use=16   needed-base=40  needed-full=104
         Not enough vCPU quota for even one BurstLab cluster.
         Request an increase at: https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A

1 check(s) failed. Resolve before deploying.
```

---

## Requesting Quota Increases

### Via AWS Console

1. Open https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas
2. Search for "Running On-Demand Standard"
3. Click the quota → "Request quota increase"
4. Enter the new value (192 recommended) and submit

Approval is typically automatic for increases to 192 vCPUs. Larger increases may require
a business justification and take 1–3 business days.

### Via AWS CLI

```bash
aws service-quotas request-service-quota-increase \
  --profile aws \
  --region us-west-2 \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 192
```

For VPCs:
```bash
aws service-quotas request-service-quota-increase \
  --profile aws \
  --region us-west-2 \
  --service-code vpc \
  --quota-code L-F678F1CE \
  --desired-value 10
```

Check the status of a pending request:
```bash
aws service-quotas list-requested-service-quota-changes-by-service \
  --profile aws \
  --region us-west-2 \
  --service-code ec2
```

---

## Region Selection

BurstLab defaults to `us-west-2`. The `m7a` instance family is available in all major
US, EU, and APAC regions. If you deploy to a different region, verify `m7a.2xlarge`
availability:

```bash
aws --profile aws ec2 describe-instance-type-offerings \
  --region your-region \
  --filters "Name=instance-type,Values=m7a.2xlarge" \
  --query 'InstanceTypeOfferings[].Location' \
  --output text
```

If `m7a.2xlarge` is not available in your region, you can use `m6a.2xlarge` (same vCPU/
memory) by changing `head_node_instance_type`, `compute_node_instance_type`, and
`burst_node_instance_type` in `terraform.tfvars`, and updating the `CPUs` and `RealMemory`
values in `configs/<generation>/partitions.json.tpl` if they differ.

---

## Next Steps

Once all checks pass:

1. See [quickstart.md](quickstart.md) for the full step-by-step deploy guide (Gen 1)
2. See [generations.md](generations.md) to choose the right generation for your customer
3. See [sa-guide.md](sa-guide.md) for the customer demo flow
