# =============================================================================
# BurstLab Gen 5 — Packer AMI Template
# Ubuntu 24.04 LTS + Slurm 24.05.x + AWS deps
#
# Key differences from Gen 3 (Rocky 10 + 24.05):
#   - Ubuntu 24.04 LTS (Noble Numbat): uses 'apt' package manager (not dnf),
#     package names use -dev suffix (not -devel), AppArmor (not SELinux),
#     ufw firewall (not firewalld), Python 3.12 default, cgroup v2 only
#   - Slurm 24.05: same version as Gen 3, adds SlurmctldParameters=cloud_reg_addrs
#     for dynamic IP registration, improved cgroup v2 integration, slurmrestd v0.0.40+
#   - PAM modules: /usr/lib/x86_64-linux-gnu/security (not /usr/lib64/security)
#   - FSx Lustre: BLOCKED (AWS repo has no Ubuntu packages, like Gen 3/Gen 4)
#   - EFS: fully functional (standard NFS4)
#
# Build: packer build ubuntu2404-slurm2405.pkr.hcl
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
  description = "Slurm version to build from source. Must be a 24.05.x release."
  default     = "24.05.5"
}

variable "instance_type" {
  description = "EC2 instance type for the build. m7a.xlarge (4 vCPUs) speeds up 'make -j$(nproc)'."
  default     = "m7a.xlarge"
}

# -----------------------------------------------------------------------------
# Source: Amazon EBS-backed Ubuntu 24.04 LTS instance
# -----------------------------------------------------------------------------

source "amazon-ebs" "ubuntu2404" {
  profile = var.aws_profile
  region  = var.aws_region

  # Ubuntu 24.04 LTS official AMI publisher: 099720109477 (Canonical)
  # Naming convention: ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*
  # NOTE: Ubuntu 24.04 AMIs use gp3 in the name pattern (unlike 22.04 which uses hvm-ssd).
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"]
    most_recent = true
  }

  instance_type = var.instance_type
  ssh_username  = "ubuntu"

  # Disable cloud-init package upgrade to prevent first-boot reboot.
  # Ubuntu cloud-init can trigger package updates and a reboot on first boot,
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

  ami_name        = "burstlab-gen5-ubuntu2404-slurm${var.slurm_version}-{{timestamp}}"
  ami_description = "BurstLab Gen 5: Ubuntu 24.04 LTS + Slurm ${var.slurm_version} from source. All node roles."

  tags = {
    Name         = "burstlab-gen5-ubuntu2404-slurm${var.slurm_version}"
    Project      = "burstlab"
    Generation   = "gen5"
    SlurmVersion = var.slurm_version
    OS           = "Ubuntu2404"
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
  sources = ["source.amazon-ebs.ubuntu2404"]

  provisioner "shell" {
    timeout = "60m"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]

    inline = [
      # =======================================================================
      # STEP 1: Repository setup and system update
      #
      # Ubuntu 24.04 uses apt/apt-get. Enable universe repo for build tools.
      # =======================================================================
      "echo '==> [1/12] Enabling universe repo and updating apt cache'",
      "sudo add-apt-repository universe -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get update -y",

      # =======================================================================
      # STEP 2: System packages
      #
      # Package name mappings from Rocky/RHEL to Ubuntu:
      #   gcc, gcc-c++, make, autoconf, automake, libtool, pkgconfig
      #     → gcc, g++, make, autoconf, automake, libtool, pkg-config
      #   munge, munge-devel, munge-libs
      #     → munge, libmunge-dev
      #   openssl, openssl-devel
      #     → openssl, libssl-dev
      #   pam-devel
      #     → libpam0g-dev
      #   readline-devel
      #     → libreadline-dev
      #   perl
      #     → perl
      #   rpm-build, rpmlint
      #     → (not applicable; Ubuntu uses deb; omit)
      #   mariadb, mariadb-server, mariadb-devel
      #     → mariadb-client, mariadb-server, libmariadb-dev
      #   iptables, nftables
      #     → iptables, nftables (iptables-persistent for rule saving)
      #   python3, python3-pip
      #     → python3, python3-pip
      #   http-parser-devel
      #     → libhttp-parser-dev
      #   json-c-devel
      #     → libjson-c-dev
      #   dbus-devel
      #     → libdbus-1-dev
      #   kernel-headers
      #     → linux-headers-generic
      #   git, curl, wget, jq, rsync, nfs-utils, stunnel
      #     → git, curl, wget, jq, rsync, nfs-common, stunnel4
      # =======================================================================
      "echo '==> [2/12] Installing build dependencies and runtime packages'",

      # Core build tools
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gcc g++ make autoconf automake libtool pkg-config",

      # Slurm build dependencies
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y munge libmunge-dev openssl libssl-dev",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libpam0g-dev libreadline-dev perl",

      # MariaDB (slurmdbd accounting — head node only, enabled at runtime)
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-client mariadb-server libmariadb-dev",

      # iptables/nftables: Ubuntu 24.04 uses nftables by default
      # iptables provided as compatibility wrapper (iptables-nft backend)
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent nftables",

      # Python 3.12 (Ubuntu 24.04 default) with pip
      # boto3 installs to system python3 directly.
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip",

      # slurmrestd build dependencies:
      #   libhttp-parser-dev: HTTP/1.1 parser library used by slurmrestd
      #   libjson-c-dev: JSON library for REST API response serialisation
      # Without these, 'configure --enable-slurmrestd' exits with a fatal error
      # and no Makefile is created, causing the entire Slurm build to fail.
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libhttp-parser-dev libjson-c-dev",

      # liblua5.4-dev: enables Slurm's job_submit/lua and burst_buffer/lua plugins.
      # configure auto-detects Lua and builds job_submit_lua.so + burst_buffer_lua.so.
      # Without it, JobSubmitPlugins=lua fatals at controller start and the
      # burst_buffer/lua lifecycle approach (workloads Scenario 4-C) cannot run. See issue #6.
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y liblua5.4-dev",

      # cgroup/v2 plugin build dependencies:
      #   libdbus-1-dev: D-Bus IPC library headers for systemd cgroup v2 management
      #   linux-headers-generic: provides include/linux/bpf.h for eBPF device constraints
      # Without these, 'configure' only builds the cgroup/v1 plugin and
      # cgroup_v2.so is not produced. Ubuntu 24.04 uses cgroup v2 exclusively,
      # so slurmd will fail at startup with "cgroup namespace not found" if
      # only cgroup/v1 is compiled.
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libdbus-1-dev linux-headers-generic",

      # Development tools
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget jq rsync nfs-common stunnel4 unzip",

      # AWS Systems Manager agent — enables SSM Session Manager as a fallback
      # access path when SSH is unavailable (e.g., sshd misconfiguration, key issues).
      # The agent requires no open inbound ports; it connects outbound to SSM endpoints.
      # Requires AmazonSSMManagedInstanceCore IAM policy on the instance role (added
      # to head node and burst node roles in the IAM Terraform module).
      "sudo snap install amazon-ssm-agent --classic",
      "sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service",

      # =======================================================================
      # STEP 3: Pin munge and slurm users/groups to consistent UID/GID
      # Same IDs as Gen 1-4 to ensure EFS ownership is consistent if a site
      # ever mixes generations or upgrades.
      # =======================================================================
      "echo '==> [3/12] Creating slurm and munge users with pinned UID/GID'",

      "getent group munge  >/dev/null 2>&1 || sudo groupadd -g 985 munge",
      "getent passwd munge >/dev/null 2>&1 || sudo useradd -u 985 -g munge -s /usr/sbin/nologin -d /var/lib/munge -r munge",

      "getent group slurm  >/dev/null 2>&1 || sudo groupadd -g 1001 slurm",
      "getent passwd slurm >/dev/null 2>&1 || sudo useradd -u 1001 -g slurm -s /usr/sbin/nologin -d /var/lib/slurm -r slurm",

      # alice: demo HPC user (UID/GID 2000). -M prevents home dir creation
      # during AMI build (/home is not mounted until EFS attaches at runtime).
      # Home is /home/alice on EFS — cloud-init creates the directory at first boot.
      "getent group alice  >/dev/null 2>&1 || sudo groupadd -g 2000 alice",
      "getent passwd alice >/dev/null 2>&1 || sudo useradd -u 2000 -g alice -s /bin/bash -d /home/alice -M alice",

      # =======================================================================
      # STEP 4: Download Slurm 24.05.x source
      # =======================================================================
      "echo '==> [4/12] Downloading Slurm ${var.slurm_version} source tarball'",

      "cd /tmp && sudo wget -q https://download.schedmd.com/slurm/slurm-${var.slurm_version}.tar.bz2",
      "cd /tmp && sudo tar -xjf slurm-${var.slurm_version}.tar.bz2",

      # =======================================================================
      # STEP 5: Build Slurm from source
      #
      # Same prefix strategy as Gen 1-4:
      #   --prefix=/opt/slurm-baked : baked into AMI, rsync'd to EFS on first boot
      #   --sysconfdir=/opt/slurm-baked/etc : placeholder, overridden by SLURM_CONF
      #   --with-munge : required for inter-node auth
      #   --enable-slurmrestd : build the Slurm REST API daemon
      #   --with-pam_dir=/usr/lib/x86_64-linux-gnu/security : Ubuntu PAM path
      #
      # slurmrestd is included but NOT started automatically. Start it on the
      # head node with:
      #   SLURM_CONF=/opt/slurm/etc/slurm.conf /opt/slurm-baked/sbin/slurmrestd \
      #     -a rest/local -s openapi/v0.0.40 -u slurm
      # =======================================================================
      "echo '==> [5/12] Configuring Slurm build'",

      "cd /tmp/slurm-${var.slurm_version} && sudo ./configure --prefix=/opt/slurm-baked --sysconfdir=/opt/slurm-baked/etc --with-munge --with-pam_dir=/usr/lib/x86_64-linux-gnu/security --enable-pam --enable-slurmrestd 2>&1 | tail -20",

      "echo '==> [5/12] Compiling Slurm (this takes ~5 minutes on m7a.xlarge)'",
      "cd /tmp/slurm-${var.slurm_version} && sudo make -j$(nproc) 2>&1 | tail -5",

      "echo '==> [5/12] Installing Slurm to /opt/slurm-baked'",
      "cd /tmp/slurm-${var.slurm_version} && sudo make install 2>&1 | tail -5",

      # =======================================================================
      # STEP 6: Write systemd unit files
      #
      # Same units as Gen 3. All point SLURM_CONF to the EFS path.
      # Units are NOT enabled — cloud-init enables per role.
      # Ubuntu uses EnvironmentFile=-/etc/default/<service> (not /etc/sysconfig/<service>).
      # =======================================================================
      "echo '==> [6/12] Writing systemd unit files'",

      "sudo tee /etc/systemd/system/slurmctld.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm controller daemon\nAfter=network.target munge.service slurmdbd.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/default/slurmctld\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmctld $SLURMCTLD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmctld.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm node daemon\nAfter=network.target munge.service\nRequires=munge.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/default/slurmd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmd $SLURMD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      "sudo tee /etc/systemd/system/slurmdbd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm DBD accounting daemon\nAfter=network.target mariadb.service munge.service\nRequires=munge.service mariadb.service\n\n[Service]\nType=forking\nEnvironmentFile=-/etc/default/slurmdbd\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nExecStart=/opt/slurm-baked/sbin/slurmdbd $SLURMDBD_OPTIONS\nExecReload=/bin/kill -HUP $MAINPID\nPIDFile=/var/run/slurmdbd.pid\nKillMode=process\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

      # slurmrestd: not started automatically but unit available for demos.
      # Uses local socket auth (no JWT required). The -u slurm runs it as the
      # Slurm user so it can query the controller.
      "sudo tee /etc/systemd/system/slurmrestd.service > /dev/null << 'UNIT'\n[Unit]\nDescription=Slurm REST API daemon\nAfter=network.target slurmctld.service\nRequires=munge.service\n\n[Service]\nType=simple\nEnvironment=SLURM_CONF=/opt/slurm/etc/slurm.conf\nEnvironment=SLURMRESTD_SECURITY=disable_unshare_syslog\nExecStart=/opt/slurm-baked/sbin/slurmrestd -a rest/local -s openapi/v0.0.40 -u slurm -g slurm\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\nUNIT",

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
      # STEP 8: Install NFS client (nfs-common already installed in step 2)
      # =======================================================================
      "echo '==> [8/12] NFS client (installed in step 2, verifying)'",
      "dpkg -l | grep nfs-common",

      # =======================================================================
      # STEP 9: Install Python packages (boto3)
      #
      # Ubuntu 24.04 ships Python 3.12 as the default python3. boto3 is installed
      # to the system Python directly.
      #
      # PEP 668 note: Ubuntu 24.04 enforces "externally managed environment"
      # and blocks 'pip install' without --break-system-packages. We use that flag.
      # =======================================================================
      "echo '==> [9/12] Installing Python packages (boto3) on system python3'",

      "python3 --version",
      "sudo python3 -m pip install boto3 --break-system-packages 2>/dev/null || sudo python3 -m pip install boto3",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",

      # =======================================================================
      # STEP 10: AppArmor (leave enabled, permissive profiles not needed)
      #
      # Ubuntu uses AppArmor (not SELinux). AppArmor profiles for Slurm
      # don't exist by default, so no enforcement. Leave AppArmor enabled
      # for system daemons; Slurm runs unconfined.
      # =======================================================================
      "echo '==> [10/12] AppArmor status (no action needed)'",
      "sudo aa-status | head -5 || echo 'AppArmor not loaded'",

      # =======================================================================
      # STEP 11: Disable ufw firewall
      #
      # Ubuntu uses ufw (Uncomplicated Firewall) as the default firewall.
      # Disable for BurstLab (VPC security groups handle filtering).
      # =======================================================================
      "echo '==> [11/12] Disabling ufw firewall'",

      "sudo systemctl disable --now ufw 2>/dev/null || true",
      "sudo ufw disable 2>/dev/null || true",

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
      "sudo DEBIAN_FRONTEND=noninteractive apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",

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
      "echo '==> Verification: AppArmor'",
      "sudo aa-status | head -5 || echo 'AppArmor not loaded'",

      "echo '==> Gen 5 AMI build complete.'",
    ]
  }
}
