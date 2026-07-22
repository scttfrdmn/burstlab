# BurstLab Support Matrix

**This page is the single source of truth for what works on which generation.**
Every other document (README, quickstart, generation guides, workload scenarios,
Ubuntu guide) links here rather than restating capability claims in prose. If a
capability claim anywhere else disagrees with this table, this table wins — please
open an issue.

Status legend:

| Status | Meaning |
|--------|---------|
| ✅ **Validated** | Exercised end-to-end on a live cluster and confirmed working |
| 🧪 **Experimental** | Implemented and expected to work; not yet validated end-to-end |
| ⛔ **Blocked** | Cannot work with the current code/AMIs; see note |
| — **Not tested** | No validation attempted yet |

---

## Generations

| Gen | OS | Slurm | Plugin | Base nodes | Max burst nodes |
|-----|----|----|----|----|----|
| **Gen 1** | Rocky 8 | 22.05.x | AWS Plugin for Slurm v2 | 1 head + 4 compute | 10 |
| **Gen 2** | Rocky 9 | 23.11.x | AWS Plugin for Slurm v2 | 1 head + 4 compute | 10 |
| **Gen 3** | Rocky 10 | 24.05.x | AWS Plugin for Slurm v2 | 1 head + 4 compute | 10 |
| **Gen 4** | Ubuntu 22.04 | 23.11.x | AWS Plugin for Slurm v2 | 1 head + 4 compute | 10 |
| **Gen 5** | Ubuntu 24.04 | 24.05.x | AWS Plugin for Slurm v2 | 1 head + 4 compute | 10 |

The base cluster is 5 always-on instances (1 head + 4 compute). Burst nodes launch
on demand up to `max_burst_nodes` (default **10**, set per generation in
`terraform/generations/<gen>/variables.tf`). All node roles default to
`m7a.2xlarge` (8 vCPU); with all 10 burst nodes active a cluster uses **120 vCPUs**
(15 instances × 8). Size your **Running On-Demand Standard vCPU** quota accordingly —
see [prerequisites.md](prerequisites.md).

---

## Storage and workloads

| Capability | Gen 1 | Gen 2 | Gen 3 | Gen 4 | Gen 5 |
|------------|:-----:|:-----:|:-----:|:-----:|:-----:|
| Core cluster + cloud bursting | ✅ | ✅ | ✅ | ✅ | ✅ |
| EFS workloads (Scenario 1–3) | ✅ | ✅ | ✅ | ✅ | ✅ |
| FSx Lustre client available | ✅ | ✅ | 🧪 | 🧪 | 🧪 |
| FSx workloads end-to-end (Scenario 4) | ✅ | 🧪 | 🧪 | 🧪 | 🧪 |
| Lifecycle 0 — Chain | ✅ | — | — | — | — |
| Lifecycle A — Wrapper | ✅ | — | — | — | — |
| Lifecycle B — Prolog/Epilog | ✅ | ✅ | ✅ (EFS) | — | — |
| Lifecycle C — Burst Buffer | 🧪 | 🧪 | 🧪 | 🧪 | 🧪 |

### Notes

**FSx Lustre client (Gen 3–5).** AWS does not publish Lustre client packages for
Rocky 10 or Ubuntu LTS. As of the [burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre)
v1.0.0 integration, the head, compute, and burst node init scripts **automatically
install** a matching client at boot (Lustre 2.17.0 on Rocky 10, 2.17.53 on Ubuntu).
This is marked 🧪 rather than ✅ because the client install is automated and the
client itself is FSx-verified, but the full Scenario 4 workload has not yet been
re-validated on Gen 3–5 since the integration. Gen 1 (el8) and Gen 2 (el9) use the
native AWS FSx client repo.

**FSx workloads end-to-end.** Only Gen 1 has been run through the complete Scenario 4
create → hydrate → compute → export → destroy cycle. Gen 2–5 share the same
`fsx-lifecycle.sh` library and are expected to work, but are not yet validated.

**Lifecycle C — Burst Buffer.** Requires `burst_buffer_lua.so`, which needs `lua-devel`
(Rocky) / `liblua5.4-dev` (Ubuntu) present at Slurm `./configure` time. This build
dependency was **added to all AMI recipes** (issue #6) but is **not present in
already-built AMIs** — Burst Buffer works only after rebuilding the AMI from the
current Packer templates. Until you rebuild, use Lifecycle B (Prolog/Epilog) instead.

**`scontrol update Environment=`** is not supported on Slurm 22.05 or 23.11; the
Prolog/Epilog approach uses a deterministic state-file path on those versions. See
[transparent-lifecycle.md](workloads/transparent-lifecycle.md) for per-version detail.

---

## Last validated

| Generation | Last validated | AMI |
|------------|----------------|-----|
| Gen 1 (Rocky 8 / Slurm 22.05) | Core + bursting + Scenario 1–4, Lifecycle 0/A/B | — |
| Gen 2 (Rocky 9 / Slurm 23.11) | Core + bursting + Lifecycle B (FSx + EFS) | `ami-069e41e072fedcf8e` |
| Gen 3 (Rocky 10 / Slurm 24.05) | Core + bursting + Lifecycle B (EFS only) | `ami-0e6d8478ca888e22d` |
| Gen 4 (Ubuntu 22.04 / Slurm 23.11) | Core + bursting | `ami-0b0c1d1a248632a4e` |
| Gen 5 (Ubuntu 24.04 / Slurm 24.05) | Core + bursting + `cloud_reg_addrs` | `ami-072b0d10402ab6d51` |

Values here come from live test results. When you validate a new capability on a
generation, update this table in the same change.
