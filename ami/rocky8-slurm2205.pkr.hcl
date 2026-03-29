# =============================================================================
# BurstLab Gen 1 — Packer AMI Template
# Rocky Linux 8 + Slurm 22.05.11 + AWS deps
#
# This AMI is the base for ALL node roles: head, compute, and burst.
# Node-role differentiation happens at cloud-init / boot time, not here.
#
# Key design decisions baked into this image:
#   - Slurm binaries live at /opt/slurm-baked/   (always available, read-only)
#   - /opt/slurm/ is RESERVED for the EFS mount  (shared config + libs at runtime)
#   - On head node first boot: rsync /opt/slurm-baked/ → EFS, then mount EFS at /opt/slurm
#   - On compute/burst nodes: EFS is mounted at /opt/slurm at boot (no local copy needed)
#
# Build: packer build rocky8-slurm2205.pkr.hcl
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
# Variables — override on CLI with -var or via a .pkrvars.hcl file
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to build the AMI in. Must match where you run BurstLab."
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for Packer API calls."
  default     = "aws"
}

variable "slurm_version" {
  description = "Slurm version to build from source. Changing this requires updating the download URL below."
  default     = "22.05.11"
}

variable "instance_type" {
  description = "EC2 instance type used for the build. m7a.xlarge gives 4 vCPUs which speeds up 'make -j$(nproc)'."
  default     = "m7a.xlarge"
}

# -----------------------------------------------------------------------------
# Source: Amazon EBS-backed instance
# -----------------------------------------------------------------------------

source "amazon-ebs" "rocky8" {
  profile = var.aws_profile
  region  = var.aws_region

  # ---------------------------------------------------------------------------
  # Source AMI: Rocky Linux 8 (CentOS 8 compatible)
  #
  # CentOS 8 reached EOL December 2021 and the official CentOS AWS account
  # (125523088429) no longer publishes CentOS 8 AMIs — only Stream 9/10.
  # Rocky Linux 8 is the direct community successor: binary-compatible with
  # RHEL 8, same package versions, same kernel series (4.18.x), same systemd.
  # For BurstLab purposes it is functionally identical to CentOS 8.
  #
  # What this means for TCU simulations:
  # - The Slurm 22.05.11 build process is identical
  # - All Slurm directives in slurm.conf are identical
  # - The vault.centos.org repo fix documented in the UserData scripts applies
  #   to TCU's actual CentOS 8 machines — not needed here since Rocky 8 repos
  #   are actively maintained (the fix is documented but gated by OS check)
  # - SSH user is "rocky" instead of "centos"
  #
  # Rocky Linux 8 official AMI publisher: 792107900819
  # ---------------------------------------------------------------------------
  source_ami_filter {
    filters = {
      name                = "Rocky-8-EC2-Base-8.*x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["792107900819"]
    most_recent = true
  }

  instance_type = var.instance_type
  ssh_username  = "rocky"

  # Rocky Linux 8 8.10 cloud-init reboot issue:
  #   The base AMI runs `dnf update` on first boot via cloud-init modules:config,
  #   installs a kernel update, and reboots the instance. SSH opens briefly during
  #   first boot, then drops when the reboot hits. Packer gets a connection mid-
  #   provisioning and dies with "Error uploading script: i/o timeout".
  #
  #   Fix: user_data with #cloud-config to disable package updates before they run.
  #   cloud-config is processed in cloud-init's early (init) stage, before
  #   modules:config where package_upgrade runs, so this prevents the update/reboot.
  user_data = <<-EOF
    #cloud-config
    package_update: false
    package_upgrade: false
    package_reboot_if_required: false
  EOF

  ssh_timeout              = "25m"
  ssh_keep_alive_interval  = "10s"
  ssh_read_write_timeout   = "15m"

  # ---------------------------------------------------------------------------
  # IMDSv2 enforcement
  #
  # http_tokens = "required" forces IMDSv2 on the build instance AND is baked
  # into the AMI's default metadata options, so every instance launched from
  # this AMI also requires IMDSv2 by default.
  #
  # hop_limit = 2 is safe for bare metal and containers; 1 would also work for
  # plain EC2 instances but 2 gives headroom if any containerized workload ever
  # queries IMDS from inside the instance.
  #
  # imds_support = "v2.0" sets the AMI-level attribute (separate from the
  # instance-level metadata_options block above).
  # ---------------------------------------------------------------------------
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  imds_support = "v2.0"

  # AMI naming: timestamp suffix prevents name collisions on repeated builds
  ami_name        = "burstlab-gen1-rocky8-slurm${var.slurm_version}-{{timestamp}}"
  ami_description = "BurstLab Gen 1: Rocky Linux 8 (CentOS 8 compatible) + Slurm ${var.slurm_version} from source. All node roles."

  tags = {
    Name         = "burstlab-gen1-rocky8-slurm${var.slurm_version}"
    Project      = "burstlab"
    Generation   = "gen1"
    SlurmVersion = var.slurm_version
    OS           = "Rocky8"
    BuildDate    = "{{timestamp}}"
  }

  # ---------------------------------------------------------------------------
  # Root volume: 30 GB gp3
  #
  # CentOS 8 default is 10 GB. We need extra space for:
  #   - Build toolchain (gcc, rpm-devel, etc.) ~2 GB
  #   - Slurm source + build tree ~1 GB
  #   - /opt/slurm-baked install ~500 MB
  #   - AWS CLI v2 ~500 MB
  #   - General headroom
  # 30 GB is comfortable. gp3 is cheaper than gp2 at the same or better IOPS.
  # ---------------------------------------------------------------------------
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
  sources = ["source.amazon-ebs.rocky8"]

  provisioner "shell" {
    # Longer timeout for the Slurm compile step on slower instance types
    timeout = "60m"

    inline = [
      # =======================================================================
      # STEP 1: Repository setup
      #
      # We build on Rocky Linux 8 (binary-compatible CentOS 8 successor) since
      # CentOS 8 is no longer published to AWS. Rocky 8 repos are actively
      # maintained — no vault redirect needed.
      #
      # NOTE for TCU simulations: TCU's actual machines run CentOS 8 and DO
      # need the vault.centos.org fix. The UserData scripts document and apply
      # that fix when running on CentOS 8 (detected via /etc/os-release).
      #
      # Enable PowerTools (needed for -devel packages) — on Rocky 8 it is
      # called "powertools" (lowercase).
      # =======================================================================
      "echo '==> [1/13] Setting up Rocky Linux 8 repos'",
      "sudo dnf config-manager --set-enabled powertools 2>/dev/null || sudo dnf config-manager --set-enabled PowerTools 2>/dev/null || true",
      "sudo dnf makecache --refresh -y",

      # =======================================================================
      # STEP 2: System update + install build dependencies and runtime packages
      #
      # We do NOT run a full 'dnf upgrade' to keep the image deterministic.
      # Security patches are handled by instance-level patching policies.
      # =======================================================================
      "echo '==> [2/13] Installing build dependencies and runtime packages'",

      # Core build tools
      "sudo dnf install -y gcc gcc-c++ make autoconf automake libtool pkgconfig",

      # Slurm build dependencies
      "sudo dnf install -y munge munge-devel munge-libs openssl openssl-devel",
      "sudo dnf install -y pam-devel readline-devel perl",
      "sudo dnf install -y rpm-build rpmlint",  # needed even for source builds (rpmbuild used in some configure checks)

      # MariaDB — required on head node for slurmdbd accounting database.
      # Installed on ALL nodes so the AMI is universal; slurmdbd only runs
      # on the head node (controlled by systemd unit enable/disable at boot).
      "sudo dnf install -y mariadb mariadb-server mariadb-devel",

      # iptables + iptables-services: needed for head node NAT masquerade rules.
      # Rocky 8 defaults to nftables; iptables is not installed by default.
      "sudo dnf install -y iptables iptables-services",

      # Python 3 and pip
      "sudo dnf install -y python3 python3-pip",

      # Git (used by cloud-init scripts and ops tooling)
      "sudo dnf install -y git",

      # Utilities needed by init scripts and Slurm burst plugin
      "sudo dnf install -y curl wget jq rsync",

      # NFS client — needed to mount EFS (amazon-efs-utils uses NFS under the hood)
      "sudo dnf install -y nfs-utils",

      # =======================================================================
      # STEP 3: Pin munge and slurm users/groups to consistent UID/GID
      #
      # Consistent IDs across all nodes are REQUIRED for:
      #   - Munge authentication (munge key file ownership)
      #   - Slurm spool directory ownership across EFS
      #   - NFS/EFS mounted directories showing correct ownership
      #
      # munge: UID/GID 985  (matches typical CentOS 8 systemd-assigned default;
      #                       we pin it to survive potential dnf install order changes)
      # slurm: UID/GID 1001 (above typical system range, below normal user range)
      #
      # We check before creating to be idempotent (munge may already exist from
      # the dnf install above).
      # =======================================================================
      "echo '==> [3/13] Creating slurm and munge users with pinned UID/GID'",

      # Munge group and user (UID 985 / GID 985)
      "getent group munge  >/dev/null 2>&1 || sudo groupadd -g 985 munge",
      "getent passwd munge >/dev/null 2>&1 || sudo useradd -u 985 -g munge -s /sbin/nologin -d /var/lib/munge -r munge",

      # Slurm group and user (UID 1001 / GID 1001)
      # Shell is /sbin/nologin — Slurm daemons run as this user but no interactive login needed
      "getent group slurm  >/dev/null 2>&1 || sudo groupadd -g 1001 slurm",
      "getent passwd slurm >/dev/null 2>&1 || sudo useradd -u 1001 -g slurm -s /sbin/nologin -d /var/lib/slurm -r slurm",

      # alice — demo HPC cluster user (UID/GID 2000)
      # Home is /u/home/alice (on EFS), created at runtime by head-node-init.
      # We pre-create the user here with a consistent UID/GID so that files
      # alice writes on EFS show the same ownership on ALL nodes (head, compute, burst).
      # No -m flag: /u does not exist during AMI build (it's an EFS mount point at runtime).
      # head-node-init creates /u/home/alice on EFS on first boot.
      "getent group alice  >/dev/null 2>&1 || sudo groupadd -g 2000 alice",
      "getent passwd alice >/dev/null 2>&1 || sudo useradd -u 2000 -g alice -s /bin/bash -d /u/home/alice alice",

      # =======================================================================
      # STEP 4: Download Slurm 22.05.11 source
      # =======================================================================
      "echo '==> [4/13] Downloading Slurm 22.05.11 source tarball'",

      "cd /tmp && sudo wget -q https://download.schedmd.com/slurm/slurm-22.05.11.tar.bz2",
      "cd /tmp && sudo tar -xjf slurm-22.05.11.tar.bz2",

      # =======================================================================
      # STEP 5: Build Slurm from source
      #
      # --prefix=/opt/slurm-baked          : install destination baked into AMI
      # --sysconfdir=/opt/slurm-baked/etc  : default config dir (overridden at
      #                                       runtime via SLURM_CONF env var pointing
      #                                       to the EFS-mounted /opt/slurm/etc/)
      # --with-munge                        : use munge for auth (mandatory in HPC)
      # --with-pam_dir                      : use the system PAM module dir.
      #                                       Must be the OS system dir, NOT under
      #                                       our custom prefix — PAM loads modules
      #                                       from a fixed system path at runtime.
      #                                       On Rocky/CentOS 8 x86_64: /usr/lib64/security
      # --enable-pam                        : build the PAM module
      #
      # make -j$(nproc) uses all available vCPUs. On m7a.xlarge (4 vCPUs) this
      # cuts compile time from ~15 min to ~5 min.
      # =======================================================================
      "echo '==> [5/13] Configuring Slurm build'",

      "cd /tmp/slurm-22.05.11 && sudo ./configure --prefix=/opt/slurm-baked --sysconfdir=/opt/slurm-baked/etc --with-munge --with-pam_dir=/usr/lib64/security --enable-pam 2>&1 | tail -20",

      "echo '==> [5/13] Compiling Slurm (this takes ~5 minutes on m7a.xlarge)'",
      "cd /tmp/slurm-22.05.11 && sudo make -j$(nproc) 2>&1 | tail -5",

      "echo '==> [5/13] Installing Slurm to /opt/slurm-baked'",
      "cd /tmp/slurm-22.05.11 && sudo make install 2>&1 | tail -5",

      # =======================================================================
      # STEP 6: Install systemd unit files and patch paths
      #
      # Slurm ships unit files in contribs/systemd/. They reference the default
      # install paths (/usr/sbin/...) which do not apply to our custom prefix.
      # We copy the files then sed-patch the ExecStart and SLURM_CONF paths.
      #
      # SLURM_CONF points to the EFS path (/opt/slurm/etc/slurm.conf) because:
      #   - At runtime, /opt/slurm IS the EFS mount (contains slurm.conf)
      #   - /opt/slurm-baked/etc/ contains a placeholder only
      # =======================================================================
      "echo '==> [6/13] Writing systemd unit files'",

      # In Slurm 22.05, unit files are not in contribs/systemd/ — we write them
      # directly. SLURM_CONF points to the EFS path so all nodes share one config.
      # Units are NOT enabled here; cloud-init enables the right set per role.

      "sudo tee /etc/systemd/system/slurmctld.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm controller daemon\nAfter=network.target munge.service slurmdbd.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmctld\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmctld $SLURMCTLD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmctld.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm node daemon\nAfter=network.target munge.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmd $SLURMD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmdbd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm DBD accounting daemon\nAfter=network.target mariadb.service munge.service\nRequires=munge.service mariadb.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmdbd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmdbd $SLURMDBD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmdbd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo systemctl daemon-reload",

      # =======================================================================
      # STEP 7: Install AWS CLI v2
      #
      # Required by:
      #   - Burst node cloud-init (registers/deregisters with Slurm)
      #   - Head node init scripts (reads SSM parameters, tags instances)
      #   - Slurm burst plugin (aws ec2 run-instances calls)
      #
      # We use the official AWS bundled installer rather than dnf to get v2.
      # dnf would give us v1 from EPEL.
      # =======================================================================
      "echo '==> [7/13] Installing AWS CLI v2'",

      "cd /tmp && sudo curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip",
      "cd /tmp && sudo unzip -q awscliv2.zip",
      "cd /tmp && sudo ./aws/install --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin",
      "aws --version",  # Verify install

      # =======================================================================
      # STEP 8: Install amazon-efs-utils
      #
      # Required to mount EFS with TLS encryption (mount -t efs).
      # We build from source since it's not in base CentOS 8 repos.
      # The package provides /sbin/mount.efs which is called by fstab entries
      # using 'type efs'.
      # =======================================================================
      "echo '==> [8/13] Installing NFS client for EFS mounts'",

      # BurstLab mounts EFS via plain NFSv4.1 (no TLS). amazon-efs-utils is only
      # available on Amazon Linux; for Rocky/CentOS we use nfs-utils directly.
      # In production you would add TLS via stunnel + amazon-efs-utils or VPC
      # private link. For a demo cluster inside a private subnet this is fine.
      # nfs-utils was already installed in step 2, but ensure stunnel is present
      # for documentation completeness (not used with plain NFS4).
      "sudo dnf install -y stunnel || true",  # optional, for reference only
      "sudo dnf install -y stunnel",

      # =======================================================================
      # STEP 9: Install Python packages
      #
      # boto3: used by Slurm burst scripts (NodeDown, ResumeProgram, SuspendProgram)
      # =======================================================================
      "echo '==> [9/13] Installing Python packages (boto3)'",

      # Use Python 3.8 (Rocky 8 AppStream) for boto3 — avoids Python 3.6 pip
      # incompatibilities. pip3 --upgrade installs pip 23+ which drops Python 3.6
      # support and causes ImportError: cannot import name 'PROTOCOL_TLS' at runtime.
      # Python 3.8 also ensures cloud-init (which uses system Python 3.6) is not
      # affected by boto3's urllib3 version.
      "sudo dnf module enable -y python38",
      "sudo dnf install -y python38 python38-pip",
      "sudo python3.8 -m pip install boto3",
      # Create a wrapper at /usr/local/bin/python3 that invokes python3.8.
      # The plugin scripts (generate_conf.py etc.) use '#!/usr/bin/env python3'.
      # /usr/local/bin takes precedence over /usr/bin in PATH, so they get 3.8.
      # We do NOT change the 'alternatives' symlink because cloud-init's SELinux
      # bindings (libselinux-python3) are compiled only for system Python 3.6;
      # changing the alternative to 3.8 breaks cloud-init SSH key injection.
      "sudo tee /usr/local/bin/python3 > /dev/null << 'PYEOF'\n#!/bin/bash\nexec /usr/bin/python3.8 \"$@\"\nPYEOF",
      "sudo chmod +x /usr/local/bin/python3",

      # =======================================================================
      # STEP 10: Disable SELinux (set to permissive mode)
      #
      # Running Slurm under enforcing SELinux requires a custom policy module
      # to allow Slurm's inter-process communication, cgroups management, and
      # PAM interactions. Writing and maintaining that policy is out of scope
      # for BurstLab Gen 1.
      #
      # Permissive mode: SELinux logs denials but does NOT block them.
      # This preserves audit trails while avoiding operational breakage.
      #
      # We set both the runtime state and the persistent config so it survives
      # reboots (though AMI instances don't reboot between provisioning and
      # snapshot; this is defense-in-depth for instances launched from the AMI).
      # =======================================================================
      "echo '==> [10/13] Setting SELinux to permissive'",

      "sudo setenforce 0 || true",  # runtime (non-fatal if already permissive)
      "sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config",
      "sudo sed -i 's/^SELINUX=disabled/SELINUX=permissive/' /etc/selinux/config || true",

      # =======================================================================
      # STEP 11: Disable firewalld
      #
      # BurstLab uses Security Groups for network access control, not host
      # firewalls. firewalld on CentOS 8 conflicts with Slurm's ephemeral port
      # usage and adds operational complexity without security benefit in a
      # VPC-isolated cluster.
      #
      # Any intra-cluster firewall rules (e.g., restricting burst node egress)
      # are applied via Security Groups and VPC NACLs in Terraform.
      # =======================================================================
      "echo '==> [11/13] Disabling firewalld'",

      "sudo systemctl disable --now firewalld 2>/dev/null || true",

      # =======================================================================
      # STEP 12: Create required directories and set ownership
      #
      # These directories must exist before daemons start. They are created here
      # (not in cloud-init) to reduce first-boot latency.
      #
      # /var/log/slurm         : daemon log files (slurmctld.log, slurmd.log)
      # /var/spool/slurm/ctld  : slurmctld state save location (StateSaveLocation)
      # /var/spool/slurm/d     : slurmd job spool (SlurmdSpoolDir)
      # /opt/slurm/etc         : placeholder; real contents come from EFS mount
      # /etc/slurm             : some tools look here; we may symlink slurm.conf here
      # /var/lib/slurm         : slurm user home (consistent with useradd -d)
      # /var/lib/munge         : munge key storage
      # =======================================================================
      "echo '==> [12/13] Creating required directories'",

      # Slurm log directory
      "sudo mkdir -p /var/log/slurm",
      "sudo chown slurm:slurm /var/log/slurm",
      "sudo chmod 755 /var/log/slurm",

      # Slurm spool directories
      "sudo mkdir -p /var/spool/slurm/ctld",
      "sudo mkdir -p /var/spool/slurm/d",
      "sudo chown slurm:slurm /var/spool/slurm /var/spool/slurm/ctld /var/spool/slurm/d",
      "sudo chmod 755 /var/spool/slurm /var/spool/slurm/ctld /var/spool/slurm/d",

      # /opt/slurm/etc: directory that will be overlaid by EFS mount at runtime.
      # Creating it here means the mount point exists even before EFS is attached.
      "sudo mkdir -p /opt/slurm/etc",
      "sudo chown slurm:slurm /opt/slurm /opt/slurm/etc",

      # /u: EFS mount point for cluster user home directories.
      # Cluster users (e.g. alice) have homes at /u/home/<username>.
      # Rocky's /home stays local so SSH access is never EFS-dependent.
      "sudo mkdir -p /u",
      "sudo chmod 755 /u",

      # /etc/slurm: some Slurm utilities and RPM-era tools default to looking here.
      # We create it so that cloud-init can optionally symlink slurm.conf here.
      "sudo mkdir -p /etc/slurm",
      "sudo chown slurm:slurm /etc/slurm",

      # Slurm user home
      "sudo mkdir -p /var/lib/slurm",
      "sudo chown slurm:slurm /var/lib/slurm",

      # Munge key directory (munge user home is set in useradd -d)
      "sudo mkdir -p /var/lib/munge",
      "sudo chown munge:munge /var/lib/munge",
      "sudo chmod 700 /var/lib/munge",

      # Munge run directory (needed for munge socket)
      "sudo mkdir -p /var/run/munge",
      "sudo chown munge:munge /var/run/munge",

      # /opt/slurm-baked/etc: placeholder config dir from the build --sysconfdir.
      # Actual slurm.conf lives on EFS; this dir is a fallback reference only.
      "sudo mkdir -p /opt/slurm-baked/etc",
      "sudo chown -R slurm:slurm /opt/slurm-baked",

      # =======================================================================
      # STEP 13: Clean up build artifacts to reduce AMI size
      #
      # The Slurm source tree (~500 MB compiled) and AWS CLI zip are not needed
      # in the final AMI. efs-utils source can also be removed.
      # We keep /opt/slurm-baked (the install) and remove the build inputs.
      # =======================================================================
      "echo '==> [13/13] Cleaning up build artifacts'",

      "sudo rm -rf /tmp/slurm-22.05.11 /tmp/slurm-22.05.11.tar.bz2",
      "sudo rm -rf /tmp/awscliv2.zip /tmp/aws",
      # (efs-utils installed via dnf/epel, no source tree to clean)

      # Clear dnf cache to reduce AMI footprint
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf",

      # =======================================================================
      # VERIFICATION: Confirm key artifacts are in place
      # =======================================================================
      "echo '==> Verification: listing /opt/slurm-baked/sbin/'",
      "ls -la /opt/slurm-baked/sbin/",

      "echo '==> Verification: listing /opt/slurm-baked/bin/'",
      "ls -la /opt/slurm-baked/bin/",

      "echo '==> Verification: slurmd -V'",
      "/opt/slurm-baked/sbin/slurmd -V",

      "echo '==> Verification: slurmctld -V'",
      "/opt/slurm-baked/sbin/slurmctld -V",

      "echo '==> Verification: AWS CLI version'",
      "aws --version",

      "echo '==> Verification: Python + boto3'",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",

      "echo '==> Verification: systemd unit files'",
      "ls -la /etc/systemd/system/slurm*.service",

      "echo '==> Verification: user IDs'",
      "id slurm",
      "id munge",
      "id alice",

      "echo '==> Verification: directory ownership'",
      "ls -la /var/log/slurm /var/spool/slurm/ /opt/slurm/",

      "echo '==> Verification: SELinux mode'",
      "getenforce",

      "echo '==> Build complete. AMI is ready for Packer snapshot.'",
    ]
  }
}
