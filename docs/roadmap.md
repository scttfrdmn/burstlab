# BurstLab Roadmap

Planned future scenarios, not yet implemented. Entries here track work that is
either blocked on external readiness (service GA, project maturity) or on-deck
for the next development cycle.

---

## Scenario 5A — objectFS (S3-backed POSIX scratch)

**Status:** Planned — blocked on objectFS demo-stable maturity

**What it is:** [objectFS](https://github.com/scttfrdmn/objectfs) is a POSIX-compliant
FUSE filesystem over S3, targeting research computing workloads. It provides standard
file semantics (open/read/write/seek) against an S3 bucket with no separate filesystem
provisioning step.

**BurstLab demo angle:**
- Zero provisioning time vs FSx (~10 min) or EFS (~60s)
- Pay-per-request pricing instead of per-GB-provisioned
- No infrastructure to tear down — the bucket is the filesystem
- Ideal for read-heavy workloads accessing large datasets already in S3

**SA talking point:** "The cost model is completely inverted — instead of paying for
the capacity you provision, you pay only for the I/O you do. For a burst workload
that reads 50 GB of input data once and writes 10 GB of results, objectFS may be
dramatically cheaper than FSx even at a fraction of the bandwidth."

**What needs to happen before implementation:**
- objectFS reaches demo-stable release with Rocky 8/9 package or build instructions
- Performance characterization on HPC-typical access patterns (large sequential reads)
- Mount/unmount lifecycle compatible with Slurm prolog/epilog or wrapper approach

**Scenario design:** Likely replaces or supplements Scenario 4 FSx as a lifecycle
variant. The same prolog/epilog or wrapper framework applies — only the storage
create/mount/destroy steps change.

---

## Scenario 5B — AWS S3 Files (native file-protocol on S3)

**Status:** Planned — blocked on service GA + HPC client documentation

**What it is:** AWS S3 Files is a new AWS service providing file-protocol access
(NFS/POSIX semantics) directly on S3 buckets. Unlike FSx, there is no separate
filesystem instance to provision — you mount the S3 bucket directly via a file
protocol endpoint. Unlike EFS, the data lives natively in S3.

**BurstLab demo angle:**
- Native S3 data without FSx provisioning overhead
- File semantics (NFS-compatible) without a separate EFS filesystem
- Cleanest cloud-native storage story for HPC: "your data is in S3, your jobs
  read it as files, results go back to S3 — no intermediate filesystem layer"

**SA talking point:** "This is what customers have been asking for since the
beginning — S3 with file semantics. No separate filesystem, no provisioning,
no teardown. The bucket is the filesystem. S3 Files removes the last reason
to provision FSx or EFS for data staging."

**What needs to happen before implementation:**
- Service reaches GA in us-west-2
- NFS/POSIX client compatibility documented for Rocky 8/9 (mount options, client packages)
- Performance characteristics published for HPC sequential I/O patterns
- Data consistency model clarified for concurrent multi-node access

**Scenario design:** Likely a new Scenario 5B lifecycle path that reuses the existing
wrapper/prolog/epilog framework. The storage create/mount/destroy calls replace the
EFS or FSx API calls with S3 Files service API calls (TBD when service API is published).

---

## Notes on Ordering

- Scenario 5A (objectFS) and 5B (S3 Files) are independent — either can be implemented first
- Both reuse the existing lifecycle framework (Approaches 0/A/B/C from `transparent-lifecycle.md`)
- Neither requires changes to the cluster generation Terraform or AMIs
- The transparent-lifecycle.md testing status table will be updated when each scenario is validated
