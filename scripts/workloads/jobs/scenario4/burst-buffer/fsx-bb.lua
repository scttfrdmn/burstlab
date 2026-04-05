--[[
================================================================================
fsx-bb.lua — burst_buffer/lua lifecycle script for ephemeral FSx Lustre

Deployed to /opt/slurm/etc/fsx-bb.lua
Referenced in burstbuffer.conf (loaded automatically by burst_buffer/lua plugin).

Implements the Slurm burst buffer lifecycle for FSx SCRATCH_2 filesystems.
All heavyweight work (create, wait, flush, destroy) is delegated to bash via
fsx-lifecycle.sh so the Lua script stays thin.

Slurm lifecycle stages:

  slurm_bb_pools()          Called periodically. Returns available pool info.
  slurm_bb_job_process()    Validate #BB directives at job submit time.
  slurm_bb_data_in()        Called before job starts. Creates FSx. Job shows
                            as "stage-in" (BF) in squeue while waiting.
  slurm_bb_pre_run()        Called just before job runs. Injects FSX_STATE_FILE.
  slurm_bb_post_run()       Called after job ends. Flushes output to S3.
  slurm_bb_data_out()       Called after stage-out. Destroys FSx.

User job script:
  #BB create_persistent name=myfsx capacity=1200GB access=striped type=scratch
  #SBATCH --partition=aws

squeue output during job:
  5  aws  myjob  alice  BF   0:00  1  (stage-in)    ← FSx provisioning
  5  aws  myjob  alice  R    3:21  1  aws-burst-0   ← running
  5  aws  myjob  alice  CG   0:12  1  (stage-out)   ← S3 flush

SA talking point: "This is the burst buffer abstraction — the same mechanism
DataWarp uses on Cray XC systems, GPFS Burst Buffer on IBM Spectrum LSF, and
Lustre HSM on most Tier 1 HPC centers. We're just implementing the lifecycle
hooks against FSx instead of on-prem hardware. The #BB directive is industry
standard. Any job script from another HPC center that uses burst buffers can
run here with minimal changes."
================================================================================
--]]

local LIB  = "/opt/slurm/etc/workloads/lib/fsx-lifecycle.sh"
local STATE_BASE = "/home/alice/.fsx-state"

-- ---------------------------------------------------------------------------
-- Helper: run a bash command, return ok, exit_code, stdout
-- ---------------------------------------------------------------------------
local function run_bash(cmd)
  local full = string.format(
    "source %s && export AWS_REGION BURST_SUBNET_ID FSX_SG_ID S3_DATA_BUCKET && %s 2>&1",
    LIB, cmd)
  local h = io.popen(full)
  if not h then return false, 1, "io.popen failed" end
  local out = h:read("*a")
  local ok, reason, code = h:close()
  return ok, (code or 1), (out or "")
end

-- ---------------------------------------------------------------------------
-- Helper: read a sysconfig file into a table
-- ---------------------------------------------------------------------------
local function read_sysconfig(path)
  local vars = {}
  local f = io.open(path, "r")
  if not f then return vars end
  for line in f:lines() do
    local k, v = line:match("^([A-Z_][A-Z0-9_]*)=(.+)$")
    if k then vars[k] = v:gsub('^"(.*)"$', '%1') end
  end
  f:close()
  return vars
end

-- ---------------------------------------------------------------------------
-- Helper: parse #BB directives from job script content
-- Returns: capacity_gb (number) or nil
-- ---------------------------------------------------------------------------
local function parse_bb_capacity(script)
  -- Look for: #BB create_persistent ... capacity=1200GB ...
  local cap = script:match("#BB%s+create_persistent[^\n]*capacity=(%d+)GB")
  if cap then return tonumber(cap) end
  return nil
end

-- ---------------------------------------------------------------------------
-- Helper: state file path for a given job_id
-- ---------------------------------------------------------------------------
local function state_file(job_id)
  return string.format("%s/job-%s.env", STATE_BASE, job_id)
end

-- ---------------------------------------------------------------------------
-- slurm_bb_pools — return pool info (called ~every 60s by slurmctld)
-- FSx is on-demand, so we advertise a large dummy pool.
-- ---------------------------------------------------------------------------
function slurm_bb_pools()
  return 0, {{
    name       = "fsx",
    count      = 9999,   -- on-demand; no physical limit
    granularity = 1200 * 1024 * 1024 * 1024,  -- 1200 GB in bytes
    occupied   = 0,
    free       = 9999 * 1200 * 1024 * 1024 * 1024,
  }}
end

-- ---------------------------------------------------------------------------
-- slurm_bb_job_process — validate #BB directives at submit time
-- ---------------------------------------------------------------------------
function slurm_bb_job_process(job_id, uid, script)
  if not script:match("#BB%s+create_persistent") then
    return 0  -- no #BB directive — not our job
  end

  local cap = parse_bb_capacity(script)
  if not cap then
    slurm.log_error("fsx-bb: job %d: #BB create_persistent missing capacity=<N>GB", job_id)
    return slurm.ERROR
  end

  if cap < 1200 then
    slurm.log_error("fsx-bb: job %d: capacity %d GB is below FSx SCRATCH_2 minimum (1200 GB)",
      job_id, cap)
    return slurm.ERROR
  end

  slurm.log_info("fsx-bb: job %d validated: FSx SCRATCH_2 %d GB", job_id, cap)
  return 0
end

-- ---------------------------------------------------------------------------
-- slurm_bb_data_in — create FSx, wait for AVAILABLE
-- Job shows as BF (stage-in) in squeue during this call.
-- ---------------------------------------------------------------------------
function slurm_bb_data_in(job_id, uid, script)
  if not script:match("#BB%s+create_persistent") then
    return 0
  end

  local cap = parse_bb_capacity(script)
  if not cap then return slurm.ERROR end

  -- Load cluster config
  local cfg = read_sysconfig("/etc/sysconfig/burstlab-workloads")
  local region       = cfg.AWS_REGION or "us-west-2"
  local subnet_id    = cfg.BURST_SUBNET_ID or ""
  local sg_id        = cfg.FSX_SG_ID or ""
  local s3_bucket    = cfg.S3_DATA_BUCKET or ""
  local s3_prefix    = string.format("jobs/%d", job_id)

  if subnet_id == "" or sg_id == "" or s3_bucket == "" then
    slurm.log_error("fsx-bb: job %d: burstlab-workloads config missing required vars", job_id)
    return slurm.ERROR
  end

  slurm.log_info("fsx-bb: job %d: creating FSx SCRATCH_2 %d GB", job_id, cap)

  -- Create FSx (prints FSX_ID to stdout)
  local create_cmd = string.format(
    "FSX_STORAGE_GB=%d S3_DATA_PREFIX=%s fsx_create %d %s %s %s %s %d 2>/dev/null",
    cap, s3_prefix, job_id, s3_bucket, s3_prefix, subnet_id, sg_id, cap)

  -- Use a wrapper script so env vars flow correctly
  local script_path = string.format("/tmp/fsx-bb-create-%d.sh", job_id)
  local f = io.open(script_path, "w")
  if not f then
    slurm.log_error("fsx-bb: job %d: cannot write create script", job_id)
    return slurm.ERROR
  end
  f:write(string.format([[
#!/bin/bash
set -euo pipefail
export AWS_REGION=%s
export BURST_SUBNET_ID=%s
export FSX_SG_ID=%s
export S3_DATA_BUCKET=%s
export FSX_STORAGE_GB=%d
export S3_DATA_PREFIX=%s
source %s
FSX_ID=$(fsx_create %d %s %s %s %s %d)
fsx_wait_available "$FSX_ID"
FSX_DNS=$(fsx_get_dns "$FSX_ID")
FSX_MOUNT_NAME=$(aws fsx describe-file-systems \
  --file-system-ids "$FSX_ID" \
  --region "%s" \
  --query 'FileSystems[0].LustreConfiguration.MountName' \
  --output text)
mkdir -p %s
cat > %s << EOF
FSX_ID=$FSX_ID
FSX_DNS=$FSX_DNS
FSX_MOUNT_NAME=$FSX_MOUNT_NAME
S3_DATA_BUCKET=%s
S3_PREFIX=%s
AWS_REGION=%s
CREATED_BY_JOB=%d
GRANULARITY=per-job
CAMPAIGN_NAME=default
EOF
echo "$FSX_ID"
]],
    region, subnet_id, sg_id, s3_bucket, cap, s3_prefix,
    LIB,
    job_id, s3_bucket, s3_prefix, subnet_id, sg_id, cap,
    region,
    STATE_BASE, state_file(job_id),
    s3_bucket, s3_prefix, region, job_id
  ))
  f:close()

  local ok, code, out = run_bash(string.format("bash %s", script_path))
  os.remove(script_path)

  if not ok or code ~= 0 then
    slurm.log_error("fsx-bb: job %d: FSx creation failed: %s", job_id, out)
    return slurm.ERROR
  end

  slurm.log_info("fsx-bb: job %d: FSx AVAILABLE, state file written", job_id)
  return 0
end

-- ---------------------------------------------------------------------------
-- slurm_bb_pre_run — inject FSX_STATE_FILE into job environment
-- ---------------------------------------------------------------------------
function slurm_bb_pre_run(job_id, uid)
  local sf = state_file(job_id)
  local f = io.open(sf, "r")
  if not f then
    -- No state file — not an FSx job (slurm_bb_data_in was a no-op)
    return 0
  end
  f:close()

  -- slurm.job_environment_set is the Lua burst buffer API for env injection
  local rc = slurm.job_environment_set(job_id, "FSX_STATE_FILE", sf)
  if rc ~= 0 then
    slurm.log_error("fsx-bb: job %d: failed to set FSX_STATE_FILE in environment", job_id)
    return slurm.ERROR
  end

  slurm.log_info("fsx-bb: job %d: FSX_STATE_FILE=%s injected", job_id, sf)
  return 0
end

-- ---------------------------------------------------------------------------
-- slurm_bb_post_run — flush output directory to S3
-- ---------------------------------------------------------------------------
function slurm_bb_post_run(job_id, uid)
  local sf = state_file(job_id)
  local f = io.open(sf, "r")
  if not f then return 0 end

  -- Read FSX_ID and AWS_REGION from state file
  local fsx_id, region
  for line in f:lines() do
    local k, v = line:match("^([A-Z_]+)=(.+)$")
    if k == "FSX_ID"    then fsx_id = v end
    if k == "AWS_REGION" then region  = v end
  end
  f:close()

  if not fsx_id then return 0 end

  slurm.log_info("fsx-bb: job %d: flushing output to S3", job_id)

  local flush_script = string.format("/tmp/fsx-bb-flush-%d.sh", job_id)
  local fw = io.open(flush_script, "w")
  if not fw then return slurm.ERROR end
  fw:write(string.format([[
#!/bin/bash
set -euo pipefail
export AWS_REGION=%s
source %s
TASK_ID=$(fsx_flush_to_s3 %s "output/")
if [ -n "$TASK_ID" ]; then
  fsx_wait_export %s "$TASK_ID" || echo "WARNING: export did not complete cleanly" >&2
fi
]], region, LIB, fsx_id, fsx_id))
  fw:close()

  local ok, code, out = run_bash(string.format("bash %s", flush_script))
  os.remove(flush_script)

  if not ok or code ~= 0 then
    slurm.log_error("fsx-bb: job %d: S3 flush warning: %s", job_id, out)
    -- Don't fail the job over a flush error — proceed to data_out / destroy
  end

  return 0
end

-- ---------------------------------------------------------------------------
-- slurm_bb_data_out — destroy FSx filesystem
-- ---------------------------------------------------------------------------
function slurm_bb_data_out(job_id, uid)
  local sf = state_file(job_id)
  local f = io.open(sf, "r")
  if not f then return 0 end

  local fsx_id, region
  for line in f:lines() do
    local k, v = line:match("^([A-Z_]+)=(.+)$")
    if k == "FSX_ID"    then fsx_id = v end
    if k == "AWS_REGION" then region  = v end
  end
  f:close()

  if not fsx_id then
    os.remove(sf)
    return 0
  end

  slurm.log_info("fsx-bb: job %d: destroying %s", job_id, fsx_id)

  local destroy_script = string.format("/tmp/fsx-bb-destroy-%d.sh", job_id)
  local dw = io.open(destroy_script, "w")
  if not dw then return slurm.ERROR end
  dw:write(string.format([[
#!/bin/bash
set -euo pipefail
export AWS_REGION=%s
source %s
fsx_destroy %s
]], region, LIB, fsx_id))
  dw:close()

  local ok, code, out = run_bash(string.format("bash %s", destroy_script))
  os.remove(destroy_script)
  os.remove(sf)

  if not ok or code ~= 0 then
    slurm.log_error("fsx-bb: job %d: destroy error: %s", job_id, out)
    return slurm.ERROR
  end

  slurm.log_info("fsx-bb: job %d: %s destroyed", job_id, fsx_id)
  return 0
end
