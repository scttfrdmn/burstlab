# Plugin v2 Setup Guide

The AWS Plugin for Slurm v2 is five Python scripts and two JSON configuration files. There is no installation wizard and no magic. Understanding what each piece does — and why — is the learning objective.

This guide walks through the plugin as if you are setting it up manually. In BurstLab, Terraform handles all of this automatically, but understanding the manual steps is what makes you effective with a customer.

---

## What the Plugin Actually Is

```
/opt/slurm/etc/aws/
├── resume.py           — called by slurmctld as ResumeProgram
├── suspend.py          — called by slurmctld as SuspendProgram
├── change_state.py     — called by cron every minute (node state reconciliation)
├── generate_conf.py    — run once to generate slurm.conf node/partition stanzas
├── common.py           — shared library: reads config.json, validates against slurm.conf
├── config.json         — plugin global configuration (must mirror slurm.conf values)
└── partitions.json     — EC2 Fleet specifications per partition and node group
```

That is the complete plugin. No daemons, no background processes, no agents on burst nodes. The Slurm power-save framework calls `resume.py` and `suspend.py` as ordinary processes, as the `slurm` user, and they make EC2 API calls via the head node's IAM role.

**Source:** `https://github.com/aws-samples/aws-plugin-for-slurm`

In BurstLab, the plugin is cloned to `/opt/slurm-baked/etc/aws/` during Packer build and copied to `/opt/slurm/etc/aws/` when EFS is populated on first boot. This means burst nodes get the plugin files automatically when they mount EFS — no separate installation step.

---

## Directory Layout

All plugin files must be in the same directory because `common.py` uses relative path resolution for `config.json` and `partitions.json`. The standard location is:

```
/opt/slurm/etc/aws/
```

This directory is on the EFS mount at `/opt/slurm/`, which means:
- Head node: reads and writes config here; runs `resume.py`, `suspend.py`, `change_state.py`
- Compute nodes: files are present but the scripts are never invoked
- Burst nodes: files are present (mounted from EFS) but scripts are never invoked

The plugin log is configured separately in `config.json`. BurstLab writes it to:

```
/var/log/slurm/aws_plugin.log
```

This log is on local disk (not EFS) so that plugin output is node-specific and does not race with other nodes reading or writing the same log file.

---

## config.json Walkthrough

Full template at `configs/gen1-slurm2205-rocky8/plugin_config.json.tpl`:

```json
{
  "LogLevel": "INFO",
  "LogFileName": "/var/log/slurm/aws_plugin.log",
  "SlurmBinPath": "/opt/slurm/bin",
  "SlurmConf": {
    "PrivateData": "CLOUD",
    "ResumeProgram": "/opt/slurm/etc/aws/resume.py",
    "SuspendProgram": "/opt/slurm/etc/aws/suspend.py",
    "ResumeRate": 100,
    "SuspendRate": 100,
    "ResumeTimeout": 300,
    "SuspendTime": 350,
    "TreeWidth": 60000
  }
}
```

**LogLevel**: `INFO` is the right default for a lab. When debugging, change to `DEBUG` — common.py will log every API call and its response.

**SlurmBinPath**: The path to `sinfo`, `scontrol`, `sacctmgr` etc. This must match where Slurm was compiled to. BurstLab installs to `/opt/slurm/bin` (the EFS mount). If you set this to `/opt/slurm-baked/bin`, the scripts will work but only if the binaries and the running slurmd agree on the path.

**SlurmConf — the critical section:** Every value under `SlurmConf` must **exactly match** the corresponding directive in `slurm.conf`. `common.py` validates these values at runtime: it reads `slurm.conf`, extracts each listed directive, and compares it to the value in `config.json`. If they do not match, the plugin logs an error and exits.

The values that are validated:
- `PrivateData` — must be `CLOUD`
- `ResumeProgram` — must point to the actual `resume.py` path
- `SuspendProgram` — must point to the actual `suspend.py` path
- `ResumeRate`, `SuspendRate`, `ResumeTimeout`, `SuspendTime`, `TreeWidth` — numeric values

**Common failure:** After running `scontrol reconfig` or editing `slurm.conf`, if you change `ResumeTimeout` or `SuspendTime` in `slurm.conf` but forget to update `config.json`, the next `resume.py` invocation will fail with:

```
ERROR: SlurmConf.ResumeTimeout in config.json (300) does not match
       slurm.conf value (600). These must match exactly.
```

---

## partitions.json Walkthrough

Full template at `configs/gen1-slurm2205-rocky8/partitions.json.tpl`:

```json
{
  "Partitions": [
    {
      "PartitionName": "cloud",
      "NodeGroups": [
        {
          "NodeGroupName": "burst",
          "MaxNodes": 10,
          "Region": "us-west-2",
          "SlurmSpecifications": {
            "CPUs": "4",
            "RealMemory": "15000",
            "Weight": "1",
            "State": "CLOUD"
          },
          "PurchasingOption": "on-demand",
          "OnDemandOptions": {
            "AllocationStrategy": "lowest-price"
          },
          "LaunchTemplateSpecification": {
            "LaunchTemplateId": "lt-XXXXXXXXXXXXXXXXX",
            "Version": "$Latest"
          },
          "LaunchTemplateOverrides": [
            { "InstanceType": "m7a.xlarge" }
          ],
          "SubnetIds": [
            "subnet-XXXXXXXXXXXXXXXXX",
            "subnet-YYYYYYYYYYYYYYYYY"
          ],
          "Tags": [
            { "Key": "Project",    "Value": "burstlab" },
            { "Key": "Generation", "Value": "gen1" },
            { "Key": "Cluster",    "Value": "burstlab-gen1" }
          ]
        }
      ],
      "PartitionOptions": {
        "Default": "No",
        "MaxTime": "4:00:00",
        "State": "UP"
      }
    }
  ]
}
```

### PartitionName and NodeGroupName: The Alphanumeric Rule

`PartitionName` and `NodeGroupName` must match the regex `^[a-zA-Z0-9]+$`. **No hyphens, no underscores, no special characters.**

This is enforced by `common.py` and is the source of one of the most confusing failures in Plugin v2 setup. The rule exists because Plugin v2 constructs Slurm node names by concatenating:

```
{PartitionName}-{NodeGroupName}-{index}
```

The hyphen is the delimiter. If either `PartitionName` or `NodeGroupName` contains a hyphen, the parsing breaks — the node names become ambiguous and cannot be correctly mapped back to their partition and node group.

**Examples:**
- `PartitionName=cloud`, `NodeGroupName=burst` → nodes named `cloud-burst-0`, `cloud-burst-1`, ...
- `PartitionName=cloudBurst`, `NodeGroupName=onDemand` → nodes named `cloudBurst-onDemand-0`, ...
- `PartitionName=cloud-burst` → **INVALID** — parser cannot determine where the partition name ends

If you use an invalid name, `generate_conf.py` may fail silently or produce incorrect node definitions. Always validate with the script in `validate-cluster.sh` which checks this explicitly.

### SlurmSpecifications

These values are used by `generate_conf.py` to produce the `NodeName` stanza in `slurm.conf`. They must be consistent with the actual instance type:

| Field | Value | Instance | Actual |
|---|---|---|---|
| `CPUs` | `"4"` | m7a.xlarge | 4 vCPUs |
| `RealMemory` | `"15000"` | m7a.xlarge | 16,384 MB - ~1,400 MB OS overhead |

If `RealMemory` is set higher than the instance actually has, jobs that request the full declared memory will OOM-kill. If it is too low, node capacity is wasted. A reasonable formula: `RealMemory = (instance_memory_mb × 0.9)` rounded down.

### PurchasingOption

`"on-demand"` is the default and is what BurstLab uses. To switch to Spot:

```json
"PurchasingOption": "spot",
"SpotOptions": {
  "AllocationStrategy": "capacity-optimized",
  "InstanceInterruptionBehavior": "terminate"
}
```

Remove the `OnDemandOptions` block when using Spot. `capacity-optimized` is recommended for HPC spot use — it picks the pool with the most available capacity rather than the lowest price, reducing interruption frequency.

### SubnetIds

Providing two subnets (cloud-a in us-west-2a, cloud-b in us-west-2b) enables the EC2 Fleet request to span AZs. When one AZ has capacity constraints, the Fleet automatically uses the other. This is transparent to Slurm — the burst node registers from whichever AZ it landed in, and routing back to the head node works the same way from either cloud subnet.

### LaunchTemplateSpecification

The launch template is created by Terraform and its ID is substituted here. The critical setting in the launch template is `InstanceMetadataTags=enabled` — see the next section.

---

## Running generate_conf.py

`generate_conf.py` reads `partitions.json` and produces `slurm.conf` stanzas for all burst nodes:

```bash
cd /opt/slurm/etc/aws/
python3 generate_conf.py >> /opt/slurm/etc/slurm.conf
```

The output looks like:

```ini
# Generated by generate_conf.py — do not edit manually
NodeName=cloud-burst-[0-9] CPUs=4 RealMemory=15000 Weight=1 State=CLOUD Feature=cloud
PartitionName=cloud Nodes=cloud-burst-[0-9] Default=NO MaxTime=4:00:00 State=UP
```

After appending, reload the Slurm configuration:

```bash
scontrol reconfig
sinfo  # verify cloud partition and nodes appear
```

Run `generate_conf.py` exactly once during initial setup. If you change `partitions.json` (different instance type, more nodes, different partition), remove the old stanza from `slurm.conf` before running it again to avoid duplicate node definitions.

In BurstLab, the head node cloud-init script runs `generate_conf.py` automatically during first boot.

---

## The change_state.py Cron

`change_state.py` is a reconciliation script that runs every minute via cron as the `slurm` user:

```bash
# Installed by BurstLab cloud-init as the slurm user:
* * * * * /opt/slurm/etc/aws/change_state.py >> /var/log/slurm/change_state.log 2>&1
```

It performs five state transitions that the resume/suspend scripts cannot do directly:

1. **CLOUD → DOWN**: A burst node that should be running (based on internal state) but is not responding is marked DOWN.
2. **alloc~ → IDLE**: A node that has been allocated but whose job finished and was not properly reported is returned to IDLE.
3. **POWER_DOWN → CLOUD**: After a node powers down successfully, it transitions from `POWER_DOWN` back to `CLOUD` state.
4. **Timeout detection**: Nodes that exceeded `ResumeTimeout` without registering are moved to `DOWN*`.
5. **Orphan cleanup**: EC2 instances that are running but not registered with Slurm (launched outside of Plugin v2) are terminated to prevent cost leakage.

`change_state.py` must run as the `slurm` user (not root) because Slurm command permissions are tied to the `SlurmUser` setting. Running as root can cause authentication errors on some Slurm configurations.

**Verifying the cron is installed:**

```bash
sudo -u slurm crontab -l
# Should show the change_state.py entry
```

If the cron is missing, the cluster will appear to work but nodes will accumulate in incorrect states. After a day of use, you may have burst nodes stuck in `POWER_DOWN` or IDLE nodes that are not actually running. Always check this in `validate-cluster.sh` output.

---

## The Launch Template: InstanceMetadataTags=enabled

The EC2 launch template has one setting that is not obvious but is absolutely required:

```
InstanceMetadataTags=enabled
```

This setting enables EC2 instance tags to be readable from within the instance via the Instance Metadata Service (IMDS). Without it, an instance cannot read its own tags, including the `Name` tag that `resume.py` sets to the Slurm node name.

**How burst node self-identification works:**

1. `resume.py` is called with argument `cloud-burst-0`
2. `resume.py` calls `ec2:CreateFleet` with the launch template
3. `resume.py` calls `ec2:CreateTags` on the new instance: `Name=cloud-burst-0`
4. Burst node boots, cloud-init runs
5. Cloud-init reads the `Name` tag from IMDS:
   ```bash
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
   SLURM_NODENAME=$(curl -s \
     -H "X-aws-ec2-metadata-token: $TOKEN" \
     "http://169.254.169.254/latest/meta-data/tags/instance/Name")
   # SLURM_NODENAME = "cloud-burst-0"
   ```
6. Cloud-init sets the hostname to `cloud-burst-0`
7. `slurmd` starts with the correct node name and registers with `slurmctld`

If `InstanceMetadataTags=enabled` is not set in the launch template, step 5 returns 404. The fallback is `ec2:DescribeTags`, which requires network access to the EC2 API. Both approaches require the burst node's IAM role to have `ec2:DescribeTags` permission.

**Why IMDSv2 is required in BurstLab:** The Packer AMI bakes in `http_tokens=required` (IMDSv2 enforcement). The IMDS call above uses the IMDSv2 token flow (PUT to get a token, then GET with the token header). Any cloud-init script that uses the old IMDSv1 format (direct curl without a token) will fail on BurstLab AMIs. This is intentional — IMDSv2 is the AWS security baseline recommendation.

---

## IAM Deep Dive

See [architecture.md](architecture.md) for the full IAM design. The Plugin v2-specific notes:

### Why ec2:CreateFleet Instead of RunInstances

Plugin v2 uses `ec2:CreateFleet` as its primary launch API, with `ec2:RunInstances` as a dependency (Fleet calls RunInstances internally). The Fleet API provides:

- **Multi-AZ in one call**: specify both `cloud-a` and `cloud-b` subnets; Fleet picks the best available capacity
- **Mixed instance types**: the `LaunchTemplateOverrides` array can list multiple instance types; Fleet picks the cheapest or most available
- **Spot/On-demand mix**: can request a combination of on-demand base capacity plus Spot for overflow

For BurstLab Gen 1 (single instance type, on-demand, two subnets), the Fleet API does not add much over direct RunInstances. But the plugin is designed for production use where Fleet's capabilities matter.

### Why iam:PassRole is Required

When `ec2:CreateFleet` launches burst instances, it needs to assign the burst node's IAM instance profile to each new instance. This is an IAM operation — the head node is "passing" an IAM role to a new resource.

Without `iam:PassRole`, the CreateFleet call fails with:

```
An error occurred (UnauthorizedOperation) when calling the CreateFleet operation:
You are not authorized to perform this operation. Encoded authorization failure message: ...
```

The `iam:PassRole` permission must be scoped to the specific burst node role ARN. This is a security control — without the ARN scope, any IAM role in the account could be passed to burst instances. BurstLab scopes it to the burst node role ARN using Terraform's `aws_iam_role.burst_node.arn` reference.

### iam:CreateServiceLinkedRole for EC2 Fleet

EC2 Fleet uses an AWS service-linked role (`AWSServiceRoleForEC2Fleet`). If this role does not exist in your account yet (it is created on first Fleet API use), the head node needs permission to create it. In most AWS accounts that have used EC2 Spot or Fleet before, this role already exists. The permission is harmless to include and prevents a confusing failure on first deploy.

---

## Debugging Common Failures

### Node Stays in CLOUD* Forever (alloc~)

The node was resumed (CreateFleet was called) but never registered with slurmctld.

**Check 1: Did the EC2 instance actually launch?**
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cloud-burst-0" \
           "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PrivateIpAddress}'
```

If no instance: check the plugin log for CreateFleet errors. Look for IAM issues, subnet capacity errors, or launch template errors.

If instance exists: check the Slurm log on the head node:
```bash
grep -i "cloud-burst-0" /var/log/slurm/slurmctld.log | tail -20
```

**Check 2: Is the instance trying to register?**

SSH to the burst node via SSM (no key needed, uses the burst node's IAM role):
```bash
aws ssm start-session --target <instance-id>
```

Then check:
```bash
sudo tail -50 /var/log/cloud-init-output.log
sudo systemctl status slurmd
sudo journalctl -u slurmd --no-pager -n 30
```

**Check 3: ResumeTimeout**

If `ResumeTimeout=60` and the node took 90 seconds to start, slurmctld already marked it DOWN:
```bash
scontrol show node cloud-burst-0 | grep -E "State|Reason"
```

Fix: Set `ResumeTimeout` to 300 or higher. If the node is already DOWN, run:
```bash
scontrol update nodename=cloud-burst-0 state=resume
```

---

### "Authentication failure" on Burst Node

```
slurmd: error: Munge encode failed: Authentication failure (in _slurm_msg_recvfrom_timeout)
```

Or the burst node's slurmd log shows:
```
slurmd error: Unable to connect to Munge daemon
```

**Most common cause:** Munge is not running on the burst node. Check:
```bash
sudo systemctl status munge
```

If munge is running but auth still fails: the munge key on the burst node does not match the head node.
```bash
# On burst node
sudo md5sum /etc/munge/munge.key

# On head node
sudo md5sum /etc/munge/munge.key
# and check the EFS copy
md5sum /opt/slurm/etc/munge/munge.key
```

All three should match. If the burst node's key differs, re-copy from EFS:
```bash
sudo cp /opt/slurm/etc/munge/munge.key /etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key
sudo systemctl restart munge
sudo systemctl restart slurmd
```

---

### slurmd Won't Start on Burst Node

**Symptom:** Burst node instance is running but node stays in CLOUD* state. SSM into the node shows:

```
systemctl status slurmd → failed
```

**Check 1: SLURM_NODENAME not set**

```bash
sudo journalctl -u slurmd --no-pager | grep NODENAME
```

If slurmd starts without a node name, it does not know which node it is and cannot register. The cloud-init script should have set the node name from the IMDS tag. Check:

```bash
curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/tags/instance/Name
```

If this returns 404: `InstanceMetadataTags=enabled` is not set in the launch template, or the `Name` tag was never set by `resume.py`.

**Check 2: slurm.conf not found**

```bash
sudo journalctl -u slurmd | grep "configuration file"
```

If `slurm.conf` is not found, EFS is probably not mounted:
```bash
mountpoint /opt/slurm || echo "NOT MOUNTED"
```

---

### slurmctld Won't Start

**Symptom:** After deploy, `systemctl status slurmctld` shows failed.

```bash
journalctl -u slurmctld --no-pager -n 50
```

**Common cause 1: slurmdbd not running**

`slurmctld` requires `slurmdbd` to be running before it starts (when `AccountingStorageType=accounting_storage/slurmdbd` is set). Check:

```bash
systemctl status slurmdbd
journalctl -u slurmdbd --no-pager -n 20
```

Most common reason slurmdbd fails: MariaDB is not running or the `slurm` database does not exist:
```bash
systemctl status mariadb
mysql -u root -e "show databases;" | grep slurm_acct_db
```

**Common cause 2: serializer/json plugin not found**

```
slurmctld: fatal: plugin serializer/json not found
```

This affects some Slurm 22.05 builds where the JSON serializer was not compiled in. The BurstLab Packer AMI compiles Slurm with the JSON plugin included. If you see this error on a customer cluster (not BurstLab), the fix is to rebuild Slurm with `--with-json` or provide the `serializer_json.so` library separately.

This was the specific failure at TCU that prevented their cluster from starting.

**Common cause 3: slurm.conf not found or SLURM_CONF wrong**

```bash
systemctl cat slurmctld | grep SLURM_CONF
ls -la $SLURM_CONF
```

---

### "Invalid configuration" Error

```
slurmctld: error: validate node cloud-burst-0: Invalid configuration
```

Or on the burst node:
```
slurmd: error: Unable to connect to Slurm daemon, slurm_load_ctl_conf error: Invalid configuration
```

**Cause:** The `PartitionName` or `NodeGroupName` in `partitions.json` contains hyphens or underscores. Node names derived from them do not match the pre-enumerated names in `slurm.conf`.

**Fix:** Ensure both names are strictly alphanumeric. Run the validation check:

```bash
python3 -c "
import json, re, sys
data = json.load(open('/opt/slurm/etc/aws/partitions.json'))
for p in data['Partitions']:
    if not re.match(r'^[a-zA-Z0-9]+\$', p['PartitionName']):
        print(f'INVALID PartitionName: {p[\"PartitionName\"]}')
        sys.exit(1)
    for ng in p['NodeGroups']:
        if not re.match(r'^[a-zA-Z0-9]+\$', ng['NodeGroupName']):
            print(f'INVALID NodeGroupName: {ng[\"NodeGroupName\"]}')
            sys.exit(1)
print('OK')
"
```

---

### Node Goes DOWN Immediately After Registering

The burst node registered with slurmctld, briefly appeared as IDLE, then immediately went DOWN.

**Cause 1: ReturnToService not set to 2**

If the node was previously marked DOWN (e.g., due to a ResumeTimeout on a previous attempt), it needs `ReturnToService=2` to automatically return to service when it re-registers. With `ReturnToService=0` or `ReturnToService=1`, the node goes back to DOWN immediately.

Verify: `grep ReturnToService /opt/slurm/etc/slurm.conf`

**Cause 2: slurmd cannot reach slurmctld**

After registering, slurmd pings slurmctld regularly. If communication is lost (security group blocking traffic, routing issue), the node goes DOWN:

```bash
# From the burst node, test connectivity to slurmctld:
nc -zv 10.0.0.10 6817
```

If this fails, check the head node security group allows inbound traffic on port 6817 from the burst subnet CIDRs.

**Cause 3: cgroup configuration mismatch**

If `cgroup.conf` is not present or differs on the burst node, slurmd may fail to initialize cgroup tracking and exit. Check:

```bash
ls -la /opt/slurm/etc/cgroup.conf
```

If missing, this file should be on EFS. If it exists, check for errors in the slurmd log related to cgroup initialization.

---

## Cross-References

- Architecture and IAM design: [architecture.md](architecture.md)
- slurm.conf directive explanations: [slurm-gen1-deep-dive.md](slurm-gen1-deep-dive.md)
- Deploy steps: [quickstart.md](quickstart.md)
- SA demo flow: [sa-guide.md](sa-guide.md)
