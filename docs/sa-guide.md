# SA Guide: Using BurstLab with Customers

This guide is for AWS Solutions Architects using BurstLab in customer engagements. It covers preparation, the demo flow, tailoring to specific customers, and how to handle common questions.

---

## Before the Meeting

### Deploy the Cluster in Advance

BurstLab takes 10-15 minutes to build the AMI and 5-10 minutes to deploy via Terraform. Do not start this during the meeting. Build the AMI ahead of time and keep the Packer-produced AMI available in your account. You can deploy the Terraform cluster in about 5 minutes the morning of the meeting.

```bash
# Build AMI (one-time, ~15 min)
cd ami/
packer build -var "aws_profile=aws" rocky8-slurm2205.pkr.hcl

# Deploy cluster (~5 min, morning of)
cd terraform/generations/gen1-slurm2205-rocky8/
terraform apply -auto-approve
```

After deploy, run the validation script to confirm everything is healthy before the call:

```bash
ssh -i ~/.ssh/your-key.pem rocky@<head_node_public_ip>
bash /opt/slurm/etc/validate-cluster.sh
```

You should see all PASSes. Fix any failures before the meeting. A non-functional cluster during a demo is worse than no demo at all.

### Choose the Right Generation

All three generations are fully built and tested. Match the customer's environment:

| Customer Environment | Use | Why |
|---|---|---|
| CentOS 8, Rocky 8, RHEL 8 — Slurm 22.x | **Gen 1** | Exact match — same OS, same Slurm, same Python 3.6 boto3 shim they need |
| Rocky 9, AlmaLinux 9, RHEL 9 — Slurm 23.x | **Gen 2** | Exact match — Python 3.9 native, cgroup v2 |
| Rocky 10, RHEL 10 — Slurm 24.05+ | **Gen 3** | Exact match — `cloud_reg_addrs`, cgroup v2 only |
| Not sure / first contact | **Gen 1** | Covers the largest installed base; most relatable config problems |
| CentOS 7 or older RHEL | **Gen 1** as reference | Note the OS differences; the Slurm and Plugin v2 config is identical |

For TCU specifically: Gen 1 is exactly right — CentOS 8, Slurm 22.05, Plugin v2.

See [generations.md](generations.md) for the full narrative on each generation.

### Have These Open in Separate Windows

- Terminal: SSH session to head node
- Browser: AWS EC2 console, filtered to your BurstLab cluster region and account
- Browser: The plugin-v2-setup.md and slurm-gen1-deep-dive.md docs in this repo
- Text editor: Open copies of `slurm.conf` and `partitions.json` for side-by-side comparison

---

## The Demo Flow

Run through this in sequence. Each step has a talking point. Adjust the depth based on the customer's technical level.

### 1. Show the Cluster is Running

```bash
ssh -i ~/.ssh/your-key.pem rocky@<head_node_public_ip>
```

**Talking point:** "We're SSH'd into the head node — this is where slurmctld runs, the Slurm controller daemon. Think of it as the scheduler brain."

```bash
systemctl is-active munge slurmctld slurmdbd
```

**Talking point:** "Three services need to be running: munge for authentication, slurmctld as the controller, and slurmdbd for accounting. Plugin v2 requires all three."

```bash
sinfo
```

Expected output:
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
local*       up   infinite      4   idle compute[01-04]
aws          up    4:00:00      8  idle~ aws-burst-[0-7]
```

**Talking point:** "Two partitions. The `local` partition has four static compute nodes that are always running — these simulate your on-prem cluster. The `aws` partition has eight burst nodes in `idle~` state — powered off, ready to launch. The `*` on local means it is the default partition."

If the customer's sinfo looks different (nodes in DOWN, no cloud partition), this is actually a useful teaching moment — it means the current cluster has a configuration problem and BurstLab shows what the correct state looks like.

### 2. Show slurm.conf — Point Out the Power Save Section

```bash
cat /opt/slurm/etc/slurm.conf
```

Point to these directives specifically:

```ini
PrivateData=CLOUD
ResumeProgram=/opt/slurm/etc/aws/resume.py
SuspendProgram=/opt/slurm/etc/aws/suspend.py
ResumeTimeout=600
SuspendTime=650
ReturnToService=2
DebugFlags=NO_CONF_HASH
```

**Talking point:** "The power-save section is the Slurm side of cloud bursting. `ResumeProgram` is called when a job needs a cloud node — it's a Python script that calls EC2 CreateFleet. `SuspendProgram` is called when the node has been idle long enough — it calls TerminateInstances. The rest of the directives control timing and recovery behavior."

If the customer had a diverged slurm.conf: "One thing we see regularly is these directives being inconsistent between nodes — or missing entirely from the controller's config. For example, at some sites the controller config has the burst directives commented out but the login node config has them active. BurstLab uses EFS to share a single slurm.conf across all nodes, which makes this class of problem impossible."

### 3. Show partitions.json — Explain the Fleet Request

```bash
cat /opt/slurm/etc/aws/partitions.json
```

**Talking point:** "This is the AWS side of the bursting config. When `resume.py` is called with a node name like `aws-burst-0`, it looks up this file, finds the right partition and node group, and constructs an EC2 CreateFleet request. The subnet IDs here span two AZs — the Fleet API will pick whichever AZ has available capacity."

Point out `PartitionName` and `NodeGroupName`:

**Talking point:** "One gotcha that trips people up: these names must be strictly alphanumeric — no hyphens, no underscores. The plugin constructs node names by concatenating `{PartitionName}-{NodeGroupName}-{index}`. If either name has a hyphen, the parsing breaks. We validate this explicitly in our cluster checks."

### 4. Submit a Local Job

```bash
sbatch --partition=local --wrap="hostname && sleep 10"
squeue
```

Expected output:
```
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
    1     local     wrap    alice  R       0:03      1 compute01
```

**Talking point:** "A local job runs immediately — the compute nodes are always idle and ready. This is your guaranteed on-prem allocation. The job ran on `compute01`, one of the four simulated on-prem nodes."

```bash
cat slurm-1.out
# compute01
```

**Talking point:** "The output confirms it ran on a local node. Now let's do the interesting part."

### 5. Submit a Burst Job

```bash
sbatch --partition=aws --wrap="hostname && sleep 60"
```

Immediately open a second terminal (or use `tmux`) and run:

```bash
watch -n 5 sinfo
```

**Walk through the state transitions out loud:**

**T+0s** (immediately after submit):
```
aws          up    4:00:00      1  alloc~   aws-burst-0
aws          up    4:00:00      7  idle~    aws-burst-[1-7]
```

"Slurm immediately called `resume.py` for `aws-burst-0`. The `~` suffix means the node is in a power-saving transition. Right now, EC2 CreateFleet is being called."

**T+30s** (instance pending):
"The EC2 console should show a new instance spinning up." (Switch to browser, show EC2 console with the `aws-burst-0` instance in pending state, tagged `Project=burstlab`.)

**T+90s** (instance running, cloud-init running):
"The instance is running. Cloud-init is now mounting EFS, copying the munge key, and starting slurmd. This takes about 60-90 seconds."

**T+120s** (node registers):
```
aws          up    4:00:00      1  alloc    aws-burst-0
```

"The `~` dropped — `aws-burst-0` is now fully online and the job is running on it."

**Check the job output after it finishes:**
```bash
cat slurm-2.out
# aws-burst-0
```

**Talking point:** "The job ran on a cloud burst node. From the user's perspective, they submitted a job to the aws partition and it ran. They did not need to provision anything, configure anything, or know anything about EC2. This is transparent HPC cloud bursting."

### 6. Watch the Node Power Down

After the job finishes (hostname + sleep 60, so about 70 seconds), continue watching `sinfo`:

```
# Immediately after job completion (node idle):
aws          up    4:00:00      1  idle     aws-burst-0

# After SuspendTime=650 seconds (~11 minutes later):
aws          up    4:00:00      1  power_down  aws-burst-0

# After termination completes:
aws          up    4:00:00      8  idle~    aws-burst-[0-7]
```

**Talking point:** "After `SuspendTime` seconds with no jobs (650 in our config), Slurm automatically calls `suspend.py`, which terminates the EC2 instance. The node goes back to `idle~` state, ready for the next burst."

(Show EC2 console — the `aws-burst-0` instance should be terminated or shutting-down.)

**Talking point:** "No manual cleanup required. This is the full lifecycle: job submitted → node launched → job runs → node powers down. The customer only pays for the EC2 instance while the job is running."

---

## Tailoring to the Customer

### Changing the Slurm Version

To demonstrate with a Slurm version that matches the customer:

1. Open `ami/rocky8-slurm2205.pkr.hcl`
2. Change `default = "22.05.11"` in the `slurm_version` variable to the target version
3. Update the download URL in the build steps if the version is significantly different
4. Rebuild the AMI with Packer

For a version in the same 22.x family (22.05.7, 22.05.9, etc.), the only change needed is the version number. For a major version change (22.x to 23.x), review the slurm.conf directives — some power-save parameters changed semantics in Slurm 23.

### Changing the OS

BurstLab Gen 1 already uses Rocky Linux 8 as the base AMI. To demonstrate on a different OS
(e.g., Rocky 9 or AlmaLinux 8):

- Update the `source_ami_filter` in `ami/rocky8-slurm2205.pkr.hcl` to target the desired OS AMI
- Adjust any OS-specific package names or repo setup steps in the Packer provisioner
- Python 3 and other dependencies are available in Rocky/Alma 8/9 baserepos without EPEL

### Changing the Burst Instance Type

Edit `terraform.tfvars`:
```hcl
burst_instance_type = "c5.xlarge"   # for compute-heavy demos
# or
burst_instance_type = "r5.xlarge"   # for memory-heavy demos
```

Also update `SlurmSpecifications.CPUs` and `SlurmSpecifications.RealMemory` in `partitions.json.tpl` to match the new instance type's specs.

### Demonstrating Spot Instances

Edit `configs/gen1-slurm2205-rocky8/partitions.json.tpl`:

```json
"PurchasingOption": "spot",
"SpotOptions": {
  "AllocationStrategy": "capacity-optimized",
  "InstanceInterruptionBehavior": "terminate"
}
```

Remove the `"OnDemandOptions"` block. Redeploy and rerun `generate_conf.py`. This demonstrates to price-sensitive customers how to significantly reduce burst node costs.

---

## Handing Over the IaC

At the end of the engagement, the customer may want the IaC for their own use. What to tell them:

**What they need to change for real use:**
1. The VPC CIDR and subnet ranges to match their network
2. The Slurm version and OS to match their existing cluster
3. The `SlurmctldHost` IP to match their actual controller
4. Instance types for burst nodes based on their workloads
5. The munge key to match their existing cluster's key (do not generate a new one)
6. `AccountingStorageHost` to point to their existing slurmdbd
7. IAM roles — they may need to add permissions to an existing role rather than creating new ones
8. Security groups — they may need to allow traffic from their existing cluster's CIDR

**What they do NOT need to change:**
- The power save directives (ResumeTimeout, SuspendTime, ReturnToService, DebugFlags=NO_CONF_HASH) — these values are correct for any cloud bursting setup
- The EFS design — unless they already have NFS infrastructure, EFS is the right choice
- The Plugin v2 setup — the scripts, the config.json structure, the cron setup

**What to emphasize:** The most valuable part of BurstLab is not the Terraform — it is the known-good `slurm.conf` and `partitions.json` for their Slurm version. Those two files, properly configured, will work on any Slurm cluster. The IaC is just scaffolding to make demonstrating them repeatable.

---

## The TCU Talking Points

For customers in situations similar to TCU, these are the specific problems BurstLab documents and solves. Reference them directly when the context matches:

**"Our slurmctld won't start"**
Common cause in 22.05: the `serializer/json` plugin is missing. Check `journalctl -u slurmctld | grep serial`. BurstLab's Packer build compiles Slurm with the JSON plugin included. If the customer built from RPMs, they may need to install the `slurm-serializer` package or rebuild.

**"Our slurm.conf is different between nodes"**
This is the most common root cause of confusing Slurm behavior. The `DebugFlags=NO_CONF_HASH` directive suppresses the hash check error, but the real fix is getting to a single source of truth (NFS, EFS, Puppet, Ansible). Point to BurstLab's EFS design as the simplest approach.

**"Burst nodes launch but never join the cluster"**
Most likely causes in order: (1) munge key mismatch, (2) slurmd cannot reach slurmctld (security group / routing), (3) SLURM_NODENAME not set correctly (InstanceMetadataTags not enabled in launch template). Walk through plugin-v2-setup.md#debugging-common-failures.

**"SelectType is different between nodes"**
`slurmctld` accepts connections from slurmd instances with different SelectType but the scheduler's behavior becomes undefined. This is a silent failure — no obvious error, just wrong scheduling decisions. `cons_tres` with `CR_Core_Memory` is the current best practice for any cluster that does cloud bursting.

**"Burst jobs never run / cloud partition always empty"**
Check `slurmdbd` status first. Plugin v2 requires accounting. Then check that `generate_conf.py` was run and its output appended to `slurm.conf`, and that `scontrol reconfig` was run afterwards.

---

## Common Customer Questions

**"What does this cost to run?"**

For a BurstLab Gen 1 cluster at idle (no burst jobs running):
- Head node (m7a.2xlarge): ~$0.36/hr = ~$8.64/day
- 4 compute nodes (m7a.2xlarge × 4): ~$1.44/hr = ~$34.56/day
- EFS storage (~1 GB): negligible
- Data transfer: negligible for a lab

Total idle cost: **~$1.80/hr or ~$43/day**

When bursting (10 × m7a.2xlarge running for 1 hour): ~$3.60 additional

For a full-day demo with 2-3 burst cycles: **~$50-60 total**

Remind customers to run `terraform destroy` when done. BurstLab is ephemeral by design.

**"Can we use Spot instances for burst?"**

Yes. Change `PurchasingOption` in `partitions.json` to `"spot"` and add a `SpotOptions` block. Spot can reduce burst node cost by 60-90% for common instance types. The tradeoff is potential interruption — if the Spot instance is reclaimed, the job fails and needs to be requeued. For batch workloads that checkpoint, this is acceptable. For interactive or latency-sensitive workloads, on-demand is safer.

Plugin v2 does not natively handle Spot interruption notifications. For production Spot bursting, customers should add the Spot interruption handler (two-minute warning via IMDS) to their burst node cloud-init, which can send a `scancel` or `scontrol` command before the instance terminates.

**"What about jobs already running on-prem — will cloud bursting affect them?"**

No. The `cloud` partition is entirely separate from the `local` partition. Jobs submitted to `--partition=local` never touch cloud nodes. The only overlap is if the customer uses a hybrid partition (`--partition=all`) that spans both — and even then, Slurm's weight-based scheduling fills local nodes first.

The cloud partition nodes cannot "steal" jobs from the local partition. Job routing is entirely partition-based and controlled by the user's submission flags.

**"How do we handle software licensing?"**

Floating licenses (FLEXlm, RLM, etc.) are the main complexity for cloud bursting. The burst node needs to reach the license server. Options:

1. **VPN/Direct Connect**: The cloud subnet routes license server traffic through the customer's network. This is the cleanest solution but requires network connectivity between the cloud subnet and on-prem.

2. **License in the VPC**: Run the license server in AWS (EC2 instance in the management subnet or a dedicated subnet). Burst nodes can reach it directly. Some license vendors support AWS deployments; check the vendor's terms.

3. **Slurm license plugin**: Slurm has a built-in license tracking mechanism (`Licenses=` in `slurm.conf`) that limits job submission based on license availability. This does not enforce license server connections but prevents submission when the declared pool is exhausted.

Point customers to the [Slurm license documentation](https://slurm.schedmd.com/licenses.html) for the Slurm-native approach.

**"Can burst nodes access our campus storage (GPFS, Lustre, etc.)?"**

This depends on network connectivity. For a VPN or Direct Connect customer with sufficient bandwidth:
- Burst nodes in the cloud subnet can route to campus storage IPs
- The campus storage must allow connections from the cloud subnet CIDR
- For GPFS: the burst nodes need the GPFS client installed in the AMI (add to Packer build)
- For Lustre: same — the Lustre client needs to be in the AMI

For customers without Direct Connect, EFS is the practical solution for shared storage. It is not as performant as Lustre but supports standard POSIX file operations and is immediately available to burst nodes via the EFS mount.

**"How do burst nodes authenticate as campus users?"**

LDAP/AD integration needs to be in the burst node AMI. If the customer uses SSSD + LDAP, add the SSSD configuration to the Packer build and ensure:
- The burst node can reach the LDAP server (requires routing, firewall rules)
- The SSSD configuration uses the same UID/GID mapping as on-prem

For BurstLab demos, local users (UIDs match across all nodes because all nodes use the same AMI) are sufficient. For production, LDAP/AD in the AMI is the correct approach.

---

## After the Meeting

1. Share the BurstLab repo link with the customer
2. Point them to `configs/gen1-slurm2205-rocky8/` for the canonical config files
3. Run `terraform destroy` to clean up the BurstLab cluster
4. Deregister the Packer AMI if you do not have a near-term follow-up meeting
5. File a brief note in the engagement tracker: which Gen, which customer pain points were addressed, what questions came up

For TCU specifically: the `DebugFlags=NO_CONF_HASH`, `ReturnToService=2`, and the correct `slurmdbd` configuration are the three directives that unlock bursting for them. If you hand over only one document, hand over `slurm-gen1-deep-dive.md`.

---

## Cross-References

- Deploy steps: [quickstart.md](quickstart.md)
- Architecture: [architecture.md](architecture.md)
- Plugin v2 troubleshooting: [plugin-v2-setup.md](plugin-v2-setup.md#debugging-common-failures)
- slurm.conf directives: [slurm-gen1-deep-dive.md](slurm-gen1-deep-dive.md)
