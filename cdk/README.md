# BurstLab CDK (Go) — experimental, Gen 1 only

This directory is an **AWS CDK** implementation of BurstLab, written in **Go**
(not TypeScript). It is an alternative to the Terraform under `../terraform/`
for SAs and customers who prefer a CDK / CloudFormation workflow.

> **Status: experimental.** The CDK currently provisions **Gen 1 only**
> (Rocky 8 + Slurm 22.05) and does **not** implement the workloads overlay
> (Scenarios 1–4). Terraform remains the reference implementation and the only
> one covering all five generations. See [Scope](#scope) below before using.

## Scope

| Capability | Terraform | CDK (this dir) |
|---|---|---|
| Gen 1 (Rocky 8 / Slurm 22.05) | ✅ | ✅ |
| Gen 2–5 (Rocky 9/10, Ubuntu 22.04/24.04) | ✅ | ❌ not ported |
| Core cluster (VPC, IAM, EFS, head + compute nodes, burst launch template) | ✅ | ✅ |
| Workloads overlay (Spack/GROMACS, RODA, ephemeral EFS/FSx) | ✅ | ❌ not implemented |

The CDK reuses the **same config and UserData templates** as Terraform
(`../configs/gen1-slurm2205-rocky8/` and `../scripts/userdata/`), rendering the
`${VAR}` placeholders in Go. The resulting cluster is intended to match what the
Gen 1 Terraform produces.

## Prerequisites

- Go 1.21+ (module targets `go 1.21`; developed against the toolchain in `go.mod`)
- [AWS CDK CLI](https://docs.aws.amazon.com/cdk/v2/guide/getting_started.html) v2
- AWS credentials (use `AWS_PROFILE=aws`, per the repo convention)
- A Gen 1 AMI built with Packer (`../ami/rocky8-slurm2205.pkr.hcl`) and an EC2 key pair

## Build & verify

```bash
cd cdk/
go build ./...   # compiles all constructs and the app entrypoint
go vet ./...     # static checks
```

`go.sum` is committed, so a fresh clone builds without extra steps.

## Deploy

The app is pinned to `us-west-2` (the architecture assumes `us-west-2a/2b`).
`keyName` and `headNodeAmi` are required — there are no defaults because they are
account- and region-specific.

```bash
cd cdk/
AWS_PROFILE=aws cdk deploy \
  --context clusterName=burstlab \
  --context keyName=burstlab-key \
  --context headNodeAmi=ami-0abcdef1234567890
```

Stack outputs include the head node public/private IPs, EFS DNS name, and the
burst launch template ID — the same values the Terraform outputs expose.

## Teardown

```bash
cd cdk/
AWS_PROFILE=aws cdk destroy --context clusterName=burstlab \
  --context keyName=burstlab-key --context headNodeAmi=ami-0abcdef1234567890
```

Burst nodes launched by the Slurm plugin are **not** part of this stack; drain
them first (see `../scripts/teardown.sh` / `../scripts/cleanup-burst-nodes.sh`).

## Known gaps

- **Gen 1 only.** Porting Gen 2–5 means new stacks under `lib/stacks/` plus
  generation-specific config wiring (mirrors the Terraform `generations/` dirs).
- **No workloads overlay.** Scenarios 1–4 exist only in Terraform
  (`../terraform/workloads/`).
- **Secrets.** The munge key and slurmdbd DB password are generated at synth
  time and embedded in the rendered UserData (as in Terraform). Treat synthesized
  templates and any saved CloudFormation output as sensitive — do not commit them
  (see `../docs/SECURITY-INCIDENT-issue-1.md`).
