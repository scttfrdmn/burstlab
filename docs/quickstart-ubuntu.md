# Quickstart: Ubuntu Generations (Gen 4 & 5)

This page covers **only what differs** from the canonical
[quickstart.md](quickstart.md) when deploying an Ubuntu cluster. Read the canonical
quickstart first — the workflow (clone, set `BURSTLAB_ROOT`/`AWS_PROFILE`/`AWS_REGION`/
`SSH_KEY`, build AMI, `terraform apply`, validate, tear down) is identical. Only the
AMI, the generation directory, the SSH user, and a few OS conventions change.

BurstLab's two Ubuntu LTS generations:

| Generation | OS | Slurm | Equivalent Rocky gen |
|------------|----|----|----|
| **Gen 4** | Ubuntu 22.04 LTS (Jammy) | 23.11 | Gen 2 (Rocky 9) |
| **Gen 5** | Ubuntu 24.04 LTS (Noble) | 24.05 | Gen 3 (Rocky 10) |

See the [support matrix](support-matrix.md) for authoritative capability status and
[generations.md](generations.md) for the full cross-generation comparison.

---

## What differs from the canonical flow

### SSH user
`ubuntu`, not `rocky`:

```bash
ssh -i "$SSH_KEY" ubuntu@<head_node_public_ip>
```

### AMI and generation directory
Substitute these into the canonical quickstart's Step 1 (build) and Step 2 (deploy):

| | Gen 4 | Gen 5 |
|---|---|---|
| Packer template | `ami/ubuntu2204-slurm2311.pkr.hcl` | `ami/ubuntu2404-slurm2405.pkr.hcl` |
| Terraform dir | `terraform/generations/gen4-slurm2311-ubuntu2204` | `terraform/generations/gen5-slurm2405-ubuntu2404` |
| AMI name filter | `burstlab-gen4-*` | `burstlab-gen5-*` |

### OS conventions (informational — the AMI and init scripts handle these)
- **Package manager:** `apt-get` (not `dnf`); dev packages use `-dev` (not `-devel`)
- **Environment files:** `/etc/default/` (not `/etc/sysconfig/`)
- **MAC / firewall:** AppArmor + `ufw` (not SELinux + `firewalld`); BurstLab disables
  `ufw` in favor of VPC security groups, and Slurm runs AppArmor-unconfined
- **FSx Lustre:** AWS publishes no Ubuntu Lustre client, so the node init scripts
  auto-install a compatible client (Lustre 2.17.53) from
  [burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre) at boot. EFS works
  everywhere; the full Scenario 4 FSx workload has not yet been re-validated on Ubuntu
  (see the [support matrix](support-matrix.md)).

---

## Deploy (Gen 5 shown; for Gen 4 swap the template and directory per the table above)

Assumes the [canonical setup](quickstart.md#before-you-start) — repo cloned and
`BURSTLAB_ROOT`, `AWS_PROFILE`, `AWS_REGION`, `SSH_KEY` exported.

```bash
# 1. Build the AMI (~15-20 min)
packer init "$BURSTLAB_ROOT/ami"
packer build -var "aws_profile=$AWS_PROFILE" "$BURSTLAB_ROOT/ami/ubuntu2404-slurm2405.pkr.hcl"

# 2. Look up the AMI ID it produced
AMI_ID=$(aws ec2 describe-images --owners self \
  --filters 'Name=name,Values=burstlab-gen5-*' \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

# 3. Configure and deploy
cd "$BURSTLAB_ROOT/terraform/generations/gen5-slurm2405-ubuntu2404/"
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set key_name and head_node_ami="$AMI_ID"
terraform init && terraform apply

# 4. Connect (ubuntu user)
ssh -i "$SSH_KEY" ubuntu@$(terraform output -raw head_node_public_ip)

# 5. Validate on the head node
bash /opt/slurm/etc/validate-cluster.sh
bash /opt/slurm/etc/demo-burst.sh

# 6. Tear down when done (from your local workstation)
terraform -chdir="$BURSTLAB_ROOT/terraform/generations/gen5-slurm2405-ubuntu2404" destroy
```

Everything else — quota checks, cost expectations, security posture, node states,
teardown of the AMI — is identical to [quickstart.md](quickstart.md).

---

## When to use Ubuntu generations

- The customer runs Ubuntu 22.04 or 24.04 on their HPC cluster
- Academic research computing (Ubuntu is common)
- Cloud-native HPC teams standardized on Ubuntu, or that prefer Debian-based systems
  over RHEL/Rocky
