# =============================================================================
# BurstLab Gen 3 — Packer AMI Template
# Rocky Linux 10 + Slurm 24.05.x + AWS deps
#
# Key differences from Gen 2 (Rocky 9 + 23.11):
#   - Rocky Linux 10 (RHEL 10 based): cgroup v2 only (no v1 support),
#     Python 3.12 default, nftables replaces iptables-services
#   - Slurm 24.05: SlurmctldParameters=cloud_reg_addrs enables dynamic IP
#     registration for burst nodes (no pre-configured NodeAddr needed),
#     improved cgroup v2 integration, slurmrestd v0.0.40+
#   - iptables: RHEL 10 removes iptables-services; install iptables-nft
#     (provides /sbin/iptables as an nftables compatibility wrapper) so the
#     existing NAT init scripts work without modification
#   - Python: 3.12 default; boto3 installed directly to system python3
#
# Build: packer build rocky10-slurm2405.pkr.hcl
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
  description = "EC2 instance type for the build."
  default     = "m7a.xlarge"
}

# -----------------------------------------------------------------------------
# Source: Amazon EBS-backed Rocky Linux 10 instance
# -----------------------------------------------------------------------------

source "amazon-ebs" "rocky10" {
  profile = var.aws_profile
  region  = var.aws_region

  # Rocky Linux 10 official AMI publisher: 792107900819 (RESF)
  # NOTE: Rocky 10 is relatively new. If this filter returns no results,
  # verify the AMI name pattern with:
  #   AWS_PROFILE=aws aws ec2 describe-images --owners 792107900819 \
  #     --filters 'Name=name,Values=Rocky-10*' --query 'Images[*].Name'
  source_ami_filter {
    filters = {
      name                = "Rocky-10-EC2-Base-10.*x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["792107900819"]
    most_recent = true
  }

  instance_type = var.instance_type
  ssh_username  = "rocky"

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

  ami_name        = "burstlab-gen3-rocky10-slurm${var.slurm_version}-{{timestamp}}"
  ami_description = "BurstLab Gen 3: Rocky Linux 10 + Slurm ${var.slurm_version} from source. All node roles."

  tags = {
    Name         = "burstlab-gen3-rocky10-slurm${var.slurm_version}"
    Project      = "burstlab"
    Generation   = "gen3"
    SlurmVersion = var.slurm_version
    OS           = "Rocky10"
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
  sources = ["source.amazon-ebs.rocky10"]

  provisioner "shell" {
    timeout = "60m"

    inline = [
      # =======================================================================
      # STEP 1: Repository setup
      #
      # Rocky 10 (RHEL 10) uses 'crb' (CodeReady Linux Builder) for -devel
      # packages, same as Rocky 9. Some package names differ from RHEL 9.
      # =======================================================================
      "echo '==> [1/12] Setting up Rocky Linux 10 repos'",
      "sudo dnf config-manager --set-enabled crb 2>/dev/null || sudo dnf config-manager --enable crb",
      # EPEL 10: provides http-parser-devel (needed for slurmrestd) and other -devel packages
      # not in base Rocky 10 or CRB.
      "sudo dnf install -y epel-release",
      "sudo dnf makecache --refresh -y",

      # =======================================================================
      # STEP 2: System packages
      #
      # Notable Rocky 10 differences from Rocky 9:
      #   - iptables-services removed: replaced by iptables-nft (nftables backend)
      #   - mariadb package versions updated (MariaDB 10.11+)
      #   - python3 = 3.12 (RHEL 10 default)
      # =======================================================================
      "echo '==> [2/12] Installing build dependencies and runtime packages'",

      "sudo dnf install -y gcc gcc-c++ make autoconf automake libtool pkgconfig",
      "sudo dnf install -y munge munge-devel munge-libs openssl openssl-devel",
      "sudo dnf install -y pam-devel readline-devel perl",
      "sudo dnf install -y rpm-build",

      # MariaDB (slurmdbd accounting)
      "sudo dnf install -y mariadb mariadb-server mariadb-devel",

      # iptables compatibility for Rocky 10:
      # iptables-nft provides /sbin/iptables, /sbin/iptables-save, and
      # /sbin/iptables-restore as wrappers over the nftables backend.
      # This lets the existing BurstLab NAT init scripts run unchanged.
      # iptables-services (the old systemd service) is NOT available on RHEL 10
      # — our burstlab-nat.service handles persistence instead.
      "sudo dnf install -y iptables-nft nftables || sudo dnf install -y iptables nftables",

      # Python 3.12 (Rocky 10 default)
      "sudo dnf install -y python3 python3-pip",

      # NOTE: slurmrestd is NOT built on Rocky 10.
      # http-parser-devel (required for slurmrestd) was removed from EPEL 10
      # because the upstream http-parser library is unmaintained (archived on GitHub).
      # EPEL 10 and Rocky 10 base/CRB do not ship http-parser-devel.
      # slurmrestd is omitted by not passing --enable-slurmrestd to configure
      # (the default is --disable-slurmrestd). This has no impact on the BurstLab
      # demo — slurmrestd is an optional REST API interface, not required for
      # job submission or bursting.
      # json-c-devel: needed for slurmdbd JSON log format output (optional)
      "sudo dnf install -y json-c-devel || true",

      # cgroup/v2 plugin build dependencies:
      #   dbus-devel: D-Bus IPC library headers for systemd cgroup v2 management
      #   kernel-headers: provides include/linux/bpf.h for eBPF device constraints
      # Without these, 'configure' only builds the cgroup/v1 plugin and
      # cgroup_v2.so is not produced. Rocky 10 (RHEL 10) removed cgroup v1
      # from the kernel entirely, so slurmd will fail at startup if only
      # cgroup/v1 is compiled.
      "sudo dnf install -y dbus-devel kernel-headers",

      "sudo dnf install -y git curl wget jq rsync nfs-utils stunnel || true",

      # =======================================================================
      # STEP 3: Users
      # =======================================================================
      "echo '==> [3/12] Creating slurm and munge users with pinned UID/GID'",

      "getent group munge  >/dev/null 2>&1 || sudo groupadd -g 985 munge",
      "getent passwd munge >/dev/null 2>&1 || sudo useradd -u 985 -g munge -s /sbin/nologin -d /var/lib/munge -r munge",

      "getent group slurm  >/dev/null 2>&1 || sudo groupadd -g 1001 slurm",
      "getent passwd slurm >/dev/null 2>&1 || sudo useradd -u 1001 -g slurm -s /sbin/nologin -d /var/lib/slurm -r slurm",

      "getent group alice  >/dev/null 2>&1 || sudo groupadd -g 2000 alice",
      "getent passwd alice >/dev/null 2>&1 || sudo useradd -u 2000 -g alice -s /bin/bash -d /u/home/alice -M alice",

      # =======================================================================
      # STEP 4: Download Slurm 24.05.x source
      # =======================================================================
      "echo '==> [4/12] Downloading Slurm ${var.slurm_version} source tarball'",

      "cd /tmp && sudo wget -q https://download.schedmd.com/slurm/slurm-${var.slurm_version}.tar.bz2",
      "cd /tmp && sudo tar -xjf slurm-${var.slurm_version}.tar.bz2",

      # =======================================================================
      # STEP 5: Build Slurm from source
      #
      # Slurm 24.05 notable configure changes:
      #   cgroup v2 is detected automatically; RHEL 10 requires cgroup/v2
      #   in cgroup.conf since v1 support was removed from the kernel
      #
      # NOTE: --enable-slurmrestd is NOT passed. slurmrestd requires http-parser,
      # which was dropped from EPEL 10 as unmaintained. The REST API daemon is
      # optional and not needed for the BurstLab demo workflow.
      # =======================================================================
      "echo '==> [5/12] Configuring Slurm 24.05 build'",

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
      # STEP 9: Install boto3 on system Python 3.12
      # =======================================================================
      "echo '==> [9/12] Installing boto3 on system python3 (3.12)'",

      "python3 --version",
      "sudo python3 -m pip install boto3 --break-system-packages 2>/dev/null || sudo python3 -m pip install boto3",
      "python3 -c \"import boto3; print('boto3', boto3.__version__)\"",

      # =======================================================================
      # STEP 10: SELinux permissive + crypto policy
      #
      # Rocky 10 (RHEL 10) DEFAULT crypto policy sets minimum RSA key length
      # to 3072 bits. Standard EC2 key pairs are 2048-bit RSA and are rejected
      # by sshd under the DEFAULT policy. Set to LEGACY to allow 2048-bit RSA
      # (same behavior as RHEL 9 DEFAULT). This ensures existing EC2 key pairs
      # work without requiring the user to create a new 4096-bit or Ed25519 key.
      # =======================================================================
      "echo '==> [10/12] Setting SELinux to permissive + crypto policy to LEGACY'",
      "sudo setenforce 0 || true",
      "sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config",
      # Set crypto policy to LEGACY. This writes /etc/crypto-policies/config.
      # sshd picks it up at next boot — no restart needed here during the Packer
      # build (restarting sshd would terminate Packer's SSH connection).
      "sudo update-crypto-policies --set LEGACY",

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
      "echo '==> Verification: slurmrestd NOT built (http-parser-devel not in EPEL 10)'",
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
      "echo '==> Verification: crypto policy'",
      "update-crypto-policies --show",

      "echo '==> Gen 3 AMI build complete.'",
    ]
  }
}
