# =============================================================================
# BurstLab Gen 6 — Packer AMI Template
# Amazon Linux 2023 + Slurm 25.11.x + AWS deps
#
# Why this generation: AWS ParallelCluster 3.15.x and AWS PCS ship Slurm 25.11
# on Amazon Linux 2023 / RHEL 9. Gen 6 matches that managed-AWS-Slurm target,
# which the five earlier generations (Rocky 8/9/10, Ubuntu 22.04/24.04; Slurm
# 22.05/23.11/24.05) don't cover. See issue #7.
#
# Key differences from Gen 3 (Rocky 10 + 24.05):
#   - Amazon Linux 2023 (RHEL-adjacent, dnf-based) instead of Rocky:
#       * SSH user is 'ec2-user' (not 'rocky')
#       * base AMI is Amazon's own (owner alias 'amazon'), resolved via SSM
#         parameter for the latest AL2023 x86_64 image
#       * NO CRB repo and NO EPEL by default — AL2023 does not officially
#         support EPEL. All -devel packages used here are in the AL2023 repos
#         (gcc, munge-devel, openssl-devel, pam-devel, readline-devel,
#         dbus-devel, lua-devel, mariadb105-devel). We do NOT add EPEL.
#       * mariadb package is 'mariadb105-server' / 'mariadb105-devel'
#   - Slurm 25.11: same cgroup v2 + cloud_reg_addrs recipe as Gen 3/5
#     (obol built 25.11.1 from source on Rocky 9 with the gen2/3 recipe
#     unchanged, so the configure/build deps carry over; AL2023 packaging is
#     the new variable). cgroup v2 only.
#   - iptables: AL2023 ships iptables-nft; install it (with nftables) so the
#     existing NAT init scripts run unmodified, same as Gen 3.
#   - Python: AL2023 default python3 (3.9); boto3 installed to system python3.
#
# NOTE on the workload overlay (obol GATE / Lua socket): AL2023 has no
# lua-socket package, no EPEL, and no luarocks by default. The base generation
# (this file) does not need a Lua socket backend; the obol overlay does, and
# that is tracked separately (obol#137). This template builds job_submit/lua
# and burst_buffer/lua (lua-devel is present) but not luasocket.
#
# Build: packer build alinux2023-slurm2511.pkr.hcl
# =============================================================================

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to build the AMI in."
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for Packer API calls."
  default     = "aws"
}

variable "slurm_version" {
  description = "Slurm version to build from source. Must be a 25.11.x release."
  default     = "25.11.4"
}

variable "instance_type" {
  description = "EC2 instance type for the build."
  default     = "m7a.xlarge"
}

# -----------------------------------------------------------------------------
# Source: Amazon EBS-backed Amazon Linux 2023 instance
#
# AL2023 latest AMI is resolved from the public SSM parameter Amazon publishes,
# which is more reliable than a name filter (Amazon rotates AL2023 minor
# versions frequently). ssm_parameter reads it at build time.
# -----------------------------------------------------------------------------

source "amazon-ebs" "al2023" {
  profile = var.aws_profile
  region  = var.aws_region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  instance_type = var.instance_type
  ssh_username  = "ec2-user"

  user_data = <<-EOF
    #cloud-config
    package_update: false
    package_upgrade: false
    package_reboot_if_required: false
  EOF

  ssh_timeout             = "25m"
  ssh_keep_alive_interval = "10s"
  ssh_read_write_timeout  = "15m"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  imds_support = "v2.0"

  ami_name        = "burstlab-gen6-alinux2023-slurm${var.slurm_version}-{{timestamp}}"
  ami_description = "BurstLab Gen 6: Amazon Linux 2023 + Slurm ${var.slurm_version} from source. All node roles."

  tags = {
    Name         = "burstlab-gen6-alinux2023-slurm${var.slurm_version}"
    Project      = "burstlab"
    Generation   = "gen6"
    SlurmVersion = var.slurm_version
    OS           = "AmazonLinux2023"
    BuildDate    = "{{timestamp}}"
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

build {
  sources = ["source.amazon-ebs.al2023"]

  provisioner "shell" {
    timeout = "60m"

    inline = [
      # =======================================================================
      # STEP 1: Repository setup
      #
      # Amazon Linux 2023 uses dnf but has NO CRB and NO EPEL. AL2023 does not
      # officially support EPEL, and every -devel package this build needs is
      # already in the AL2023 core repos — so we deliberately do NOT enable EPEL.
      # =======================================================================
      "echo '==> [1/12] Refreshing Amazon Linux 2023 repos'",
      "sudo dnf makecache --refresh -y",

      # =======================================================================
      # STEP 2: System packages
      #
      # AL2023 package-name notes vs Rocky:
      #   - MariaDB is 'mariadb105-server' / 'mariadb105-devel' (versioned)
      #   - iptables-nft provides the /sbin/iptables nft-backed compat wrappers
      #   - http-parser-devel is not available (no EPEL) → slurmrestd NOT built,
      #     same as Gen 3
      # =======================================================================
      "echo '==> [2/12] Installing build dependencies and runtime packages'",

      "sudo dnf install -y gcc gcc-c++ make autoconf automake libtool pkgconfig",
      "sudo dnf install -y munge munge-devel munge-libs openssl openssl-devel",
      "sudo dnf install -y pam-devel readline-devel perl",
      "sudo dnf install -y rpm-build",

      # MariaDB (slurmdbd accounting) — AL2023 uses the versioned mariadb105 packages.
      "sudo dnf install -y mariadb105-server mariadb105-devel",

      # iptables compatibility: iptables-nft provides /sbin/iptables and the
      # save/restore wrappers over the nftables backend, so the existing BurstLab
      # NAT init scripts run unchanged. burstlab-nat.service handles persistence.
      "sudo dnf install -y iptables-nft nftables || sudo dnf install -y iptables nftables",

      # Python (AL2023 default python3 = 3.9) + pip
      "sudo dnf install -y python3 python3-pip",

      # slurmrestd is NOT built on AL2023: http-parser-devel requires EPEL, which
      # AL2023 doesn't support. slurmrestd is optional and unused by the BurstLab
      # demo (job submission and bursting don't need it). Omitted by not passing
      # --enable-slurmrestd (configure defaults to --disable-slurmrestd).
      # json-c-devel: optional, for slurmdbd JSON log output.
      "sudo dnf install -y json-c-devel || true",

      # lua-devel: enables Slurm's job_submit/lua and burst_buffer/lua plugins.
      # configure auto-detects Lua and builds job_submit_lua.so + burst_buffer_lua.so.
      # Without it, JobSubmitPlugins=lua fatals at controller start and the
      # burst_buffer/lua lifecycle approach (workloads Scenario 4-C) cannot run.
      # See issue #6. (A Lua *socket* backend, needed by the obol overlay, is a
      # separate concern — see the header note and obol#137.)
      "sudo dnf install -y lua-devel",

      # cgroup/v2 plugin build dependencies:
      #   dbus-devel: D-Bus IPC headers for systemd cgroup v2 management
      # AL2023 is cgroup v2 only, so cgroup_v2.so must be built or slurmd fails
      # at startup. Same requirement as Gen 3/5.
      "sudo dnf install -y dbus-devel",
      #
      # Kernel UAPI headers for the cgroup/v2 eBPF device constraints
      # (<linux/bpf.h>): on AL2023 these ship in the base `kernel-headers` package,
      # which is ALREADY installed (glibc-headers depends on it) and provides the
      # sanitized UAPI headers under /usr/include/linux. We deliberately do NOT
      # `dnf install kernel-headers` or `kernel6.12-headers`: the bare metapackage
      # resolves to the newest kernel line and conflicts with the running kernel's
      # headers (the AL2023 base AMI floats between 6.1 and 6.12 kernels), and the
      # per-kernel *-headers packages are out-of-tree module build headers we don't
      # need. Just verify the UAPI header Slurm's configure looks for is present.
      "test -f /usr/include/linux/bpf.h && echo 'UAPI bpf.h present' || (echo 'ERROR: /usr/include/linux/bpf.h missing' && sudo dnf install -y kernel-headers && test -f /usr/include/linux/bpf.h)",

      # NOTE (AL2023-specific): do NOT install `curl` — AL2023 ships `curl-minimal`,
      # and `dnf install curl` fails with a file conflict against it. curl-minimal
      # already provides the /usr/bin/curl the AWS CLI installer and init scripts use,
      # so we simply omit curl here. (The `|| true` also keeps this non-fatal.)
      "sudo dnf install -y git wget jq rsync nfs-utils stunnel || true",

      # AWS Systems Manager agent — SSM Session Manager fallback access.
      # AL2023 ships amazon-ssm-agent in its repos (no external RPM needed).
      "sudo dnf install -y amazon-ssm-agent || sudo dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm 2>&1 | tail -3 || true",
      "sudo systemctl enable amazon-ssm-agent || true",

      # =======================================================================
      # STEP 3: Users (pinned UID/GID, identical to all other generations)
      # =======================================================================
      "echo '==> [3/12] Creating slurm and munge users with pinned UID/GID'",

      "getent group munge  >/dev/null 2>&1 || sudo groupadd -g 985 munge",
      "getent passwd munge >/dev/null 2>&1 || sudo useradd -u 985 -g munge -s /sbin/nologin -d /var/lib/munge -r munge",

      "getent group slurm  >/dev/null 2>&1 || sudo groupadd -g 1001 slurm",
      "getent passwd slurm >/dev/null 2>&1 || sudo useradd -u 1001 -g slurm -s /sbin/nologin -d /var/lib/slurm -r slurm",

      # alice: demo HPC user. Home is /home/alice (on EFS, created at runtime).
      "getent group alice  >/dev/null 2>&1 || sudo groupadd -g 2000 alice",
      "getent passwd alice >/dev/null 2>&1 || sudo useradd -u 2000 -g alice -s /bin/bash -d /home/alice -M alice",

      # =======================================================================
      # STEP 4: Download Slurm 25.11.x source
      # =======================================================================
      "echo '==> [4/12] Downloading Slurm ${var.slurm_version} source tarball'",

      "cd /tmp && sudo wget -q https://download.schedmd.com/slurm/slurm-${var.slurm_version}.tar.bz2",
      "cd /tmp && sudo tar -xjf slurm-${var.slurm_version}.tar.bz2",

      # =======================================================================
      # STEP 5: Build Slurm from source
      #
      # Same configure line as Gen 3 — cgroup v2 is auto-detected, slurmrestd is
      # left disabled (no http-parser). obol confirmed 25.11.x builds cleanly with
      # this recipe; AL2023 only changes the package provenance, not the flags.
      # =======================================================================
      "echo '==> [5/12] Configuring Slurm 25.11 build'",

      "cd /tmp/slurm-${var.slurm_version} && sudo ./configure --prefix=/opt/slurm-baked --sysconfdir=/opt/slurm-baked/etc --with-munge --with-pam_dir=/usr/lib64/security --enable-pam 2>&1 | tail -20",

      "echo '==> [5/12] Compiling Slurm (this takes ~5 minutes on m7a.xlarge)'",
      "cd /tmp/slurm-${var.slurm_version} && sudo make -j$(nproc) 2>&1 | tail -5",

      "echo '==> [5/12] Installing Slurm to /opt/slurm-baked'",
      "cd /tmp/slurm-${var.slurm_version} && sudo make install 2>&1 | tail -5",

      # =======================================================================
      # STEP 6: Write systemd unit files
      # =======================================================================
      "echo '==> [6/12] Writing systemd unit files'",

      "sudo tee /etc/systemd/system/slurmctld.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm controller daemon\nAfter=network.target munge.service slurmdbd.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmctld\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmctld $SLURMCTLD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmctld.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm node daemon\nAfter=network.target munge.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmd $SLURMD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmdbd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm DBD accounting daemon\nAfter=network.target mariadb.service munge.service\nRequires=munge.service mariadb.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmdbd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmdbd $SLURMDBD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmdbd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      # slurmrestd.service is not written — slurmrestd was not built (see Step 5 note).
      "sudo systemctl daemon-reload",

      # =======================================================================
      # STEP 7: Install AWS CLI v2
      # =======================================================================
      "echo '==> [7/12] Installing AWS CLI v2'",

      "cd /tmp && sudo curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip",
      "cd /tmp && sudo unzip -q awscliv2.zip",
      "cd /tmp && sudo ./aws/install --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin",
      "aws --version",

      # =======================================================================
      # STEP 8: NFS client (already installed)
      # =======================================================================
      "echo '==> [8/12] NFS client verify'",
      "rpm -q nfs-utils",

      # =======================================================================
      # STEP 9: Install boto3 on system Python 3
      # =======================================================================
      "echo '==> [9/12] Installing boto3 on system python3'",

      "python3 --version",
      "sudo python3 -m pip install boto3 --break-system-packages 2>/dev/null || sudo python3 -m pip install boto3",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",

      # =======================================================================
      # STEP 10: SELinux
      #
      # AL2023 ships SELinux in permissive mode by default (not enforcing), but
      # we set it explicitly so the AMI is deterministic regardless of the base.
      # AL2023 uses the DEFAULT crypto policy; burstlab-key is Ed25519 and is not
      # affected by any RSA size minimum, so no crypto-policy change is needed.
      # =======================================================================
      "echo '==> [10/12] Setting SELinux to permissive'",
      "sudo setenforce 0 2>/dev/null || true",
      "sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true",

      # =======================================================================
      # STEP 11: Disable firewalld
      #
      # AL2023 does not install firewalld by default; disable defensively.
      # =======================================================================
      "echo '==> [11/12] Disabling firewalld (if present)'",
      "sudo systemctl disable --now firewalld 2>/dev/null || true",

      # =======================================================================
      # STEP 12: Create required directories
      # =======================================================================
      "echo '==> [12/12] Creating required directories'",

      "sudo mkdir -p /var/log/slurm",
      "sudo chown slurm:slurm /var/log/slurm",
      "sudo chmod 755 /var/log/slurm",

      "sudo mkdir -p /var/spool/slurm/ctld /var/spool/slurm/d",
      "sudo chown slurm:slurm /var/spool/slurm /var/spool/slurm/ctld /var/spool/slurm/d",
      "sudo chmod 755 /var/spool/slurm /var/spool/slurm/ctld /var/spool/slurm/d",

      "sudo mkdir -p /opt/slurm/etc",
      "sudo chown slurm:slurm /opt/slurm /opt/slurm/etc",

      "sudo mkdir -p /u && sudo chmod 755 /u",

      "sudo mkdir -p /etc/slurm && sudo chown slurm:slurm /etc/slurm",

      "sudo mkdir -p /var/lib/slurm && sudo chown slurm:slurm /var/lib/slurm",

      "sudo mkdir -p /var/lib/munge && sudo chown munge:munge /var/lib/munge && sudo chmod 700 /var/lib/munge",
      "sudo mkdir -p /var/run/munge && sudo chown munge:munge /var/run/munge",

      "sudo mkdir -p /opt/slurm-baked/etc",
      "sudo chown -R slurm:slurm /opt/slurm-baked",

      # Clean up
      "sudo rm -rf /tmp/slurm-${var.slurm_version} /tmp/slurm-${var.slurm_version}.tar.bz2",
      "sudo rm -rf /tmp/awscliv2.zip /tmp/aws",
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf",

      # =======================================================================
      # VERIFICATION
      # =======================================================================
      "echo '==> Verification: Slurm version'",
      "/opt/slurm-baked/sbin/slurmd -V",
      "/opt/slurm-baked/sbin/slurmctld -V",
      "echo '==> Verification: slurmrestd NOT built (no http-parser-devel; EPEL unsupported on AL2023)'",
      "echo '==> Verification: cgroup/v2 plugin built'",
      "ls -la /opt/slurm-baked/lib/slurm/cgroup_v2.so",
      "echo '==> Verification: AWS CLI version'",
      "aws --version",
      "echo '==> Verification: Python + boto3'",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",
      "echo '==> Verification: iptables (via nft compat)'",
      "iptables --version",
      "echo '==> Verification: user IDs'",
      "id slurm && id munge && id alice",
      "echo '==> Verification: SELinux'",
      "getenforce",

      "echo '==> Gen 6 AMI build complete.'",
    ]
  }
}
