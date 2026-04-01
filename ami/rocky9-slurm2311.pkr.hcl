# =============================================================================
# BurstLab Gen 2 — Packer AMI Template
# Rocky Linux 9 + Slurm 23.11.x + AWS deps
#
# Key differences from Gen 1 (Rocky 8 + 22.05):
#   - Rocky Linux 9 (RHEL 9 based): uses 'crb' instead of 'powertools',
#     python3.9 by default, cgroup v2 as the primary hierarchy
#   - Slurm 23.11: adds SlurmctldParameters=idle_on_node_suspend (cloud nodes
#     show IDLE not IDLE~ in sinfo), slurmrestd daemon, partition-level
#     ResumeTimeout/SuspendTime support
#   - Python: system python3.9 has pip; boto3 installed directly — no wrapper
#     needed. The /usr/local/bin/python3 shim from Gen 1 is NOT created here.
#   - slurmrestd: built and available; start manually with
#       slurmrestd -a rest/local -s openapi/v0.0.38 -u slurm
#
# Build: packer build rocky9-slurm2311.pkr.hcl
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
  description = "Slurm version to build from source. Must be a 23.11.x release."
  default     = "23.11.10"
}

variable "instance_type" {
  description = "EC2 instance type for the build. m7a.xlarge (4 vCPUs) speeds up 'make -j$(nproc)'."
  default     = "m7a.xlarge"
}

# -----------------------------------------------------------------------------
# Source: Amazon EBS-backed Rocky Linux 9 instance
# -----------------------------------------------------------------------------

source "amazon-ebs" "rocky9" {
  profile = var.aws_profile
  region  = var.aws_region

  # Rocky Linux 9 official AMI publisher: 792107900819 (Rocky Enterprise Software Foundation)
  # Same publisher as Rocky 8. Naming convention: Rocky-9-EC2-Base-9.x.YYYYMMDD.x86_64
  source_ami_filter {
    filters = {
      name                = "Rocky-9-EC2-Base-9.*x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["792107900819"]
    most_recent = true
  }

  instance_type = var.instance_type
  ssh_username  = "rocky"

  # Disable cloud-init package upgrade to prevent first-boot reboot.
  # Rocky 9 cloud-init can trigger package updates and a reboot on first boot,
  # which drops the SSH connection mid-provisioning. This user_data prevents it.
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

  ami_name        = "burstlab-gen2-rocky9-slurm${var.slurm_version}-{{timestamp}}"
  ami_description = "BurstLab Gen 2: Rocky Linux 9 + Slurm ${var.slurm_version} from source. All node roles."

  tags = {
    Name         = "burstlab-gen2-rocky9-slurm${var.slurm_version}"
    Project      = "burstlab"
    Generation   = "gen2"
    SlurmVersion = var.slurm_version
    OS           = "Rocky9"
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
  sources = ["source.amazon-ebs.rocky9"]

  provisioner "shell" {
    timeout = "60m"

    inline = [
      # =======================================================================
      # STEP 1: Repository setup
      #
      # Rocky Linux 9 uses 'crb' (CodeReady Linux Builder) — the RHEL 9 name
      # for the repo formerly called 'powertools' on RHEL 8 / Rocky 8.
      # CRB provides -devel packages required for Slurm's build dependencies.
      # =======================================================================
      "echo '==> [1/12] Setting up Rocky Linux 9 repos'",
      "sudo dnf config-manager --set-enabled crb",
      # EPEL9: provides http-parser-devel (required for --enable-slurmrestd) which
      # is not available in base repos or CRB.
      "sudo dnf install -y epel-release",
      "sudo dnf makecache --refresh -y",

      # =======================================================================
      # STEP 2: System packages
      # =======================================================================
      "echo '==> [2/12] Installing build dependencies and runtime packages'",

      # Core build tools
      "sudo dnf install -y gcc gcc-c++ make autoconf automake libtool pkgconfig",

      # Slurm build dependencies
      "sudo dnf install -y munge munge-devel munge-libs openssl openssl-devel",
      "sudo dnf install -y pam-devel readline-devel perl",
      "sudo dnf install -y rpm-build rpmlint",

      # MariaDB (slurmdbd accounting — head node only, enabled at runtime)
      "sudo dnf install -y mariadb mariadb-server mariadb-devel",

      # iptables: Rocky 9 supports both iptables (legacy) and nftables.
      # We install iptables-services for compatibility with the NAT init script.
      # nftables is also installed for completeness.
      "sudo dnf install -y iptables iptables-services nftables",

      # Python 3.9 (Rocky 9 default) with pip
      # boto3 installs to system python3 directly — no module shim needed.
      "sudo dnf install -y python3 python3-pip",

      # slurmrestd build dependencies (from EPEL9):
      #   http-parser-devel: HTTP/1.1 parser library used by slurmrestd
      #   json-c-devel: JSON library for REST API response serialisation
      # Without these, 'configure --enable-slurmrestd' exits with a fatal error
      # and no Makefile is created, causing the entire Slurm build to fail.
      "sudo dnf install -y http-parser-devel json-c-devel",

      # cgroup/v2 plugin build dependencies:
      #   dbus-devel: D-Bus IPC library headers for systemd cgroup v2 management
      #   kernel-headers: provides include/linux/bpf.h for eBPF device constraints
      # Without these, 'configure' only builds the cgroup/v1 plugin and
      # cgroup_v2.so is not produced. Rocky 9 EC2 uses cgroup v2 exclusively,
      # so slurmd will fail at startup with "cgroup namespace not found" if
      # only cgroup/v1 is compiled.
      "sudo dnf install -y dbus-devel kernel-headers",

      # Development tools
      "sudo dnf install -y git curl wget jq rsync nfs-utils stunnel || true",

      # =======================================================================
      # STEP 3: Pin munge and slurm users/groups to consistent UID/GID
      # Same IDs as Gen 1 to ensure EFS ownership is consistent if a site
      # ever mixes generations or upgrades.
      # =======================================================================
      "echo '==> [3/12] Creating slurm and munge users with pinned UID/GID'",

      "getent group munge  >/dev/null 2>&1 || sudo groupadd -g 985 munge",
      "getent passwd munge >/dev/null 2>&1 || sudo useradd -u 985 -g munge -s /sbin/nologin -d /var/lib/munge -r munge",

      "getent group slurm  >/dev/null 2>&1 || sudo groupadd -g 1001 slurm",
      "getent passwd slurm >/dev/null 2>&1 || sudo useradd -u 1001 -g slurm -s /sbin/nologin -d /var/lib/slurm -r slurm",

      # alice: demo HPC user (UID/GID 2000). -M prevents home dir creation
      # during AMI build (/u does not exist until EFS is mounted at runtime).
      "getent group alice  >/dev/null 2>&1 || sudo groupadd -g 2000 alice",
      "getent passwd alice >/dev/null 2>&1 || sudo useradd -u 2000 -g alice -s /bin/bash -d /u/home/alice -M alice",

      # =======================================================================
      # STEP 4: Download Slurm 23.11.x source
      # =======================================================================
      "echo '==> [4/12] Downloading Slurm ${var.slurm_version} source tarball'",

      "cd /tmp && sudo wget -q https://download.schedmd.com/slurm/slurm-${var.slurm_version}.tar.bz2",
      "cd /tmp && sudo tar -xjf slurm-${var.slurm_version}.tar.bz2",

      # =======================================================================
      # STEP 5: Build Slurm from source
      #
      # Same prefix strategy as Gen 1:
      #   --prefix=/opt/slurm-baked : baked into AMI, rsync'd to EFS on first boot
      #   --sysconfdir=/opt/slurm-baked/etc : placeholder, overridden by SLURM_CONF
      #   --with-munge : required for inter-node auth
      #   --enable-slurmrestd : build the Slurm REST API daemon (new in Gen 2)
      #
      # slurmrestd is included but NOT started automatically. Start it on the
      # head node with:
      #   SLURM_CONF=/opt/slurm/etc/slurm.conf /opt/slurm-baked/sbin/slurmrestd \
      #     -a rest/local -s openapi/v0.0.38 -u slurm
      # =======================================================================
      "echo '==> [5/12] Configuring Slurm build'",

      "cd /tmp/slurm-${var.slurm_version} && sudo ./configure --prefix=/opt/slurm-baked --sysconfdir=/opt/slurm-baked/etc --with-munge --with-pam_dir=/usr/lib64/security --enable-pam --enable-slurmrestd 2>&1 | tail -20",

      "echo '==> [5/12] Compiling Slurm (this takes ~5 minutes on m7a.xlarge)'",
      "cd /tmp/slurm-${var.slurm_version} && sudo make -j$(nproc) 2>&1 | tail -5",

      "echo '==> [5/12] Installing Slurm to /opt/slurm-baked'",
      "cd /tmp/slurm-${var.slurm_version} && sudo make install 2>&1 | tail -5",

      # =======================================================================
      # STEP 6: Write systemd unit files
      #
      # Same units as Gen 1 plus slurmrestd. All point SLURM_CONF to the
      # EFS path. Units are NOT enabled — cloud-init enables per role.
      # =======================================================================
      "echo '==> [6/12] Writing systemd unit files'",

      "sudo tee /etc/systemd/system/slurmctld.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm controller daemon\nAfter=network.target munge.service slurmdbd.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmctld\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmctld $SLURMCTLD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmctld.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm node daemon\nAfter=network.target munge.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmd $SLURMD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmdbd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm DBD accounting daemon\nAfter=network.target mariadb.service munge.service\nRequires=munge.service mariadb.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/sysconfig/slurmdbd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmdbd $SLURMDBD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmdbd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      # slurmrestd: not started automatically but unit available for demos.
      # Uses local socket auth (no JWT required). The -u slurm runs it as the
      # Slurm user so it can query the controller.
      "sudo tee /etc/systemd/system/slurmrestd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm REST API daemon\nAfter=network.target slurmctld.service\nRequires=munge.service\n\n[Service]\nType=simple\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nEnvironment=SLURMRESTD_SECURITY=disable_unshare_syslog\nExecStart=/opt/slurm-baked/sbin/slurmrestd -a rest/local -s openapi/v0.0.38 -u slurm -g slurm\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

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
      # STEP 8: Install NFS client (nfs-utils already installed in step 2)
      # =======================================================================
      "echo '==> [8/12] NFS client (installed in step 2, verifying)'",
      "rpm -q nfs-utils",

      # =======================================================================
      # STEP 9: Install Python packages (boto3)
      #
      # Rocky 9 ships Python 3.9 as the default python3. boto3 is installed
      # to the system Python directly — no module wrapper needed.
      #
      # PEP 668 note: Some distributions enforce "externally managed environment"
      # and block 'pip install' without --break-system-packages. We try that flag
      # first (pip >= 23.0) and fall back to plain install for older pip versions.
      # =======================================================================
      "echo '==> [9/12] Installing Python packages (boto3) on system python3'",

      "python3 --version",
      "sudo python3 -m pip install boto3 --break-system-packages 2>/dev/null || sudo python3 -m pip install boto3",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",

      # Verify: no /usr/local/bin/python3 shim needed on Rocky 9.
      # The plugin scripts use #!/usr/bin/env python3 or #!/usr/bin/python3,
      # both of which resolve to /usr/bin/python3 (3.9 with boto3) on Rocky 9.

      # =======================================================================
      # STEP 10: Disable SELinux (permissive for BurstLab)
      # =======================================================================
      "echo '==> [10/12] Setting SELinux to permissive'",

      "sudo setenforce 0 || true",
      "sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config",

      # =======================================================================
      # STEP 11: Disable firewalld
      # =======================================================================
      "echo '==> [11/12] Disabling firewalld'",

      "sudo systemctl disable --now firewalld 2>/dev/null || true",

      # =======================================================================
      # STEP 12: Create required directories
      # =======================================================================
      "echo '==> [12/12] Creating required directories'",

      "sudo mkdir -p /var/log/slurm",
      "sudo chown slurm:slurm /var/log/slurm",
      "sudo chmod 755 /var/log/slurm",

      "sudo mkdir -p /var/spool/slurm/ctld",
      "sudo mkdir -p /var/spool/slurm/d",
      "sudo chown slurm:slurm /var/spool/slurm /var/spool/slurm/ctld /var/spool/slurm/d",
      "sudo chmod 755 /var/spool/slurm /var/spool/slurm/ctld /var/spool/slurm/d",

      "sudo mkdir -p /opt/slurm/etc",
      "sudo chown slurm:slurm /opt/slurm /opt/slurm/etc",

      "sudo mkdir -p /u",
      "sudo chmod 755 /u",

      "sudo mkdir -p /etc/slurm",
      "sudo chown slurm:slurm /etc/slurm",

      "sudo mkdir -p /var/lib/slurm",
      "sudo chown slurm:slurm /var/lib/slurm",

      "sudo mkdir -p /var/lib/munge",
      "sudo chown munge:munge /var/lib/munge",
      "sudo chmod 700 /var/lib/munge",

      "sudo mkdir -p /var/run/munge",
      "sudo chown munge:munge /var/run/munge",

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
      "echo '==> Verification: slurmrestd built'",
      "ls -la /opt/slurm-baked/sbin/slurmrestd",
      "echo '==> Verification: cgroup/v2 plugin built'",
      "ls -la /opt/slurm-baked/lib/slurm/cgroup_v2.so",
      "echo '==> Verification: AWS CLI version'",
      "aws --version",
      "echo '==> Verification: Python + boto3'",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",
      "echo '==> Verification: user IDs'",
      "id slurm && id munge && id alice",
      "echo '==> Verification: SELinux'",
      "getenforce",

      "echo '==> Gen 2 AMI build complete.'",
    ]
  }
}
