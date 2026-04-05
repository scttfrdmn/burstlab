# BurstLab — Claude Code Instructions

## Testing as alice

Always SSH directly as alice when running demos or workload scripts. Never use `sudo -u alice` or `su - alice`.

```bash
ssh -i ~/.ssh/burstlab-key.pem alice@<head_node_public_ip>
```

Alice uses the same key as rocky (`~/.ssh/burstlab-key.pem`). Using `sudo -u alice` strips PATH (no `/usr/local/bin`), breaking the AWS CLI, and bypasses end-to-end SSH validation.

## AWS CLI / Profile

Always use `AWS_PROFILE=aws` for all local AWS CLI commands (e.g. `terraform apply`, `aws` commands run from the developer machine). The profile is named `aws`.

On EC2 instances (head node, burst nodes), the instance profile is used automatically — no profile needed.
