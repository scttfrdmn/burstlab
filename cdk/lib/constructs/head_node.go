// =============================================================================
// head_node.go — BurstLab head node construct
//
// The head node is the most important component of the cluster:
//   - Runs slurmctld (job scheduler), slurmdbd (accounting), munge (auth).
//   - Runs the AWS Plugin for Slurm v2 (resume.py / suspend.py / change_state.py).
//   - Acts as a NAT router: src/dst check disabled, iptables masquerade in
//     UserData. All on-prem and cloud subnet traffic leaves via this node.
//   - Has a static EIP for predictable SSH access and AWS API endpoint routing.
//   - Assigned a static private IP (10.0.0.10) via PrivateIpAddress so that
//     slurm.conf SlurmctldHost and compute node /etc/hosts entries are stable.
//
// After the EC2 instance is created, this construct adds CfnRoute entries to
// the on-prem and cloud route tables pointing 0.0.0.0/0 at the head node's
// primary ENI — the "NAT routes". This is intentionally done here (not in
// the VPC construct) because the ENI ID is only known after instance launch.
//
// UserData is loaded from scripts/userdata/head-node-init.sh.tpl and the
// Terraform-style for-loops are expanded in Go. All ${VAR} placeholders
// are replaced with actual values before upload.
// =============================================================================

package constructs

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// BurstlabHeadNodeProps holds all inputs required to create the head node.
type BurstlabHeadNodeProps struct {
	// ClusterName is the cluster name prefix.
	ClusterName string

	// AmiId is the AMI ID for the head node (CentOS 8 with Slurm pre-baked).
	AmiId string

	// InstanceType is the EC2 instance type. Default: m7a.large.
	InstanceType string

	// KeyName is the EC2 key pair name for SSH access.
	KeyName string

	// ManagementSubnetId is the subnet where the head node is placed.
	ManagementSubnetId *string

	// HeadNodeSgId is the security group applied to the head node.
	HeadNodeSgId *string

	// HeadNodeInstanceProfileName is the IAM instance profile name.
	HeadNodeInstanceProfileName *string

	// OnpremRouteTableId — NAT route is added here pointing to head ENI.
	OnpremRouteTableId *string

	// CloudRouteTableId — NAT route is added here pointing to head ENI.
	CloudRouteTableId *string

	// OnpremCidr is the CIDR of the on-prem compute subnet (for iptables rules).
	OnpremCidr string

	// CloudCidrA is the CIDR of cloud burst subnet A (for iptables rules).
	CloudCidrA string

	// CloudCidrB is the CIDR of cloud burst subnet B (for iptables rules).
	CloudCidrB string

	// EfsDnsName is the DNS name of the EFS file system (used in /etc/fstab).
	EfsDnsName *string

	// ComputeNodeCount is the number of on-prem compute nodes (for /etc/hosts).
	ComputeNodeCount int

	// StaticPrivateIp is the private IP to assign to the head node.
	// Should be the first usable IP in the management subnet (e.g. "10.0.0.10").
	// Must match SlurmctldHost in slurm.conf and /etc/hosts entries on all nodes.
	// If empty, AWS assigns an IP dynamically (not recommended for the head node).
	StaticPrivateIp string

	// SlurmConf is the rendered slurm.conf content.
	SlurmConf string

	// SlurmdbdConf is the rendered slurmdbd.conf content.
	SlurmdbdConf string

	// CgroupConf is the cgroup.conf content (static, no templating needed).
	CgroupConf string

	// PluginConfigJSON is the rendered plugin config.json content.
	PluginConfigJSON string

	// PartitionsJSON is the rendered partitions.json content.
	PartitionsJSON string

	// SlurmdbdDbPassword is the MariaDB password for slurmdbd.
	// If empty, a random 24-character password is generated.
	SlurmdbdDbPassword string

	// UserDataTemplatePath is the path to head-node-init.sh.tpl.
	// Relative paths are resolved from the CDK app root.
	UserDataTemplatePath string
}

// BurstlabHeadNode is the CDK construct for the BurstLab head node.
type BurstlabHeadNode struct {
	constructs.Construct

	// InstanceId is the EC2 instance ID.
	InstanceId *string

	// PrivateIp is the private IP address of the head node.
	PrivateIp *string

	// PublicIp is the Elastic IP address associated with the head node.
	PublicIp *string

	// PrimaryEniId is the ID of the primary network interface.
	PrimaryEniId *string
}

// NewBurstlabHeadNode creates the head node EC2 instance, EIP, and NAT routes.
func NewBurstlabHeadNode(scope constructs.Construct, id string, props *BurstlabHeadNodeProps) *BurstlabHeadNode {
	this := &BurstlabHeadNode{}
	constructs.NewConstruct_Override(this, scope, id)

	if props.InstanceType == "" {
		props.InstanceType = "m7a.large"
	}
	if props.ComputeNodeCount == 0 {
		props.ComputeNodeCount = 4
	}
	if props.SlurmdbdDbPassword == "" {
		props.SlurmdbdDbPassword = generatePassword(24)
	}

	cn := props.ClusterName

	// -------------------------------------------------------------------------
	// Build UserData
	// Load the shell template and substitute all variables. The template uses
	// Terraform-style ${VAR} syntax with some for-loop constructs. We expand
	// the for-loop (compute node /etc/hosts entries) in Go.
	// -------------------------------------------------------------------------
	userData := buildHeadNodeUserData(props)

	// -------------------------------------------------------------------------
	// EC2 Instance
	// SourceDestCheck=false: the head node forwards packets for other subnets
	// (NAT). AWS drops forwarded packets by default unless this is disabled.
	// PrivateIpAddress: pinned so SlurmctldHost in slurm.conf stays stable
	// across stack replacements.
	// -------------------------------------------------------------------------
	var privateIpPtr *string
	if props.StaticPrivateIp != "" {
		privateIpPtr = jsii.String(props.StaticPrivateIp)
	}

	instance := awsec2.NewCfnInstance(this, jsii.String("Instance"), &awsec2.CfnInstanceProps{
		ImageId:            jsii.String(props.AmiId),
		InstanceType:       jsii.String(props.InstanceType),
		KeyName:            jsii.String(props.KeyName),
		SubnetId:           props.ManagementSubnetId,
		SecurityGroupIds:   &[]*string{props.HeadNodeSgId},
		IamInstanceProfile: props.HeadNodeInstanceProfileName,
		SourceDestCheck:    jsii.Bool(false), // CRITICAL: required for NAT/forwarding
		PrivateIpAddress:   privateIpPtr,
		UserData:           jsii.String(base64.StdEncoding.EncodeToString([]byte(userData))),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-headnode", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
			{Key: jsii.String("Role"), Value: jsii.String("head-node")},
		},
	})
	this.InstanceId = instance.Ref()
	this.PrivateIp = instance.AttrPrivateIp()
	this.PrimaryEniId = instance.AttrNetworkInterfaceId()

	// -------------------------------------------------------------------------
	// Elastic IP + Association
	// The EIP provides a stable public IP for SSH access and is the source IP
	// for all outbound traffic (since all nodes NAT through the head node).
	// -------------------------------------------------------------------------
	eip := awsec2.NewCfnEIP(this, jsii.String("Eip"), &awsec2.CfnEIPProps{
		Domain: jsii.String("vpc"),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-headnode-eip", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.PublicIp = eip.Ref()

	awsec2.NewCfnEIPAssociation(this, jsii.String("EipAssoc"), &awsec2.CfnEIPAssociationProps{
		InstanceId:   instance.Ref(),
		AllocationId: eip.AttrAllocationId(),
	})

	// -------------------------------------------------------------------------
	// NAT Routes
	//
	// Add default routes (0.0.0.0/0 → head node ENI) to the on-prem and cloud
	// route tables. These routes make private subnets reach the internet through
	// the head node's iptables masquerade rules.
	//
	// CloudFormation requires NetworkInterfaceId for instance-based routes.
	// AttrNetworkInterfaceId() returns the primary ENI ID.
	// -------------------------------------------------------------------------
	awsec2.NewCfnRoute(this, jsii.String("OnpremNatRoute"), &awsec2.CfnRouteProps{
		RouteTableId:         props.OnpremRouteTableId,
		DestinationCidrBlock: jsii.String("0.0.0.0/0"),
		NetworkInterfaceId:   instance.AttrNetworkInterfaceId(),
	})

	awsec2.NewCfnRoute(this, jsii.String("CloudNatRoute"), &awsec2.CfnRouteProps{
		RouteTableId:         props.CloudRouteTableId,
		DestinationCidrBlock: jsii.String("0.0.0.0/0"),
		NetworkInterfaceId:   instance.AttrNetworkInterfaceId(),
	})

	return this
}

// buildHeadNodeUserData loads the UserData template and performs all variable
// substitutions. Terraform for-loop constructs are expanded in Go.
func buildHeadNodeUserData(props *BurstlabHeadNodeProps) string {
	templatePath := props.UserDataTemplatePath
	if templatePath == "" {
		templatePath = "../../scripts/userdata/head-node-init.sh.tpl"
	}

	raw, err := os.ReadFile(templatePath)
	if err != nil {
		// Fall back to an inline minimal script that logs the error.
		return fmt.Sprintf("#!/bin/bash\necho 'ERROR: could not load UserData template: %v' | tee /var/log/burstlab-init.log\n", err)
	}

	ud := string(raw)

	// -------------------------------------------------------------------------
	// Expand Terraform-style for-loop for /etc/hosts entries.
	//
	// Original template:
	//   %{ for i in range(compute_node_count) ~}
	//   echo "${cidrhost(onprem_cidr, i + 10)} compute0${i + 1}" >> /etc/hosts
	//   %{ endfor ~}
	//
	// We replace the entire for-loop block with pre-expanded shell lines.
	// Compute node IPs: 10.0.1.10, 10.0.1.11, ..., 10.0.1.(9+count)
	// -------------------------------------------------------------------------
	hostsBlock := buildHostsBlock(props.OnpremCidr, props.ComputeNodeCount)
	ud = replaceForBlock(ud, hostsBlock)

	// -------------------------------------------------------------------------
	// Simple ${VAR} substitutions.
	// Order: longest/most-specific names first to avoid partial matches.
	// -------------------------------------------------------------------------
	efsDNS := ""
	if props.EfsDnsName != nil {
		efsDNS = *props.EfsDnsName
	}

	ud = strings.ReplaceAll(ud, "${cluster_name}", props.ClusterName)
	ud = strings.ReplaceAll(ud, "${onprem_cidr}", props.OnpremCidr)
	ud = strings.ReplaceAll(ud, "${cloud_cidr_a}", props.CloudCidrA)
	ud = strings.ReplaceAll(ud, "${cloud_cidr_b}", props.CloudCidrB)
	ud = strings.ReplaceAll(ud, "${efs_dns_name}", efsDNS)
	ud = strings.ReplaceAll(ud, "${munge_key_b64}", generateMungeKeyB64())
	ud = strings.ReplaceAll(ud, "${slurm_conf}", props.SlurmConf)
	ud = strings.ReplaceAll(ud, "${slurmdbd_conf}", props.SlurmdbdConf)
	ud = strings.ReplaceAll(ud, "${cgroup_conf}", props.CgroupConf)
	ud = strings.ReplaceAll(ud, "${slurmdbd_db_password}", props.SlurmdbdDbPassword)
	ud = strings.ReplaceAll(ud, "${plugin_config_json}", props.PluginConfigJSON)
	ud = strings.ReplaceAll(ud, "${partitions_json}", props.PartitionsJSON)

	return ud
}

// buildHostsBlock generates the /etc/hosts echo lines for compute nodes.
// onpremCidr is expected to be "10.0.1.0/24"; nodes get .10, .11, ...
func buildHostsBlock(onpremCidr string, count int) string {
	parts := strings.Split(onpremCidr, "/")
	if len(parts) < 1 {
		return ""
	}
	octets := strings.Split(parts[0], ".")
	if len(octets) != 4 {
		return ""
	}
	prefix := strings.Join(octets[:3], ".")

	var lines []string
	for i := 0; i < count; i++ {
		ip := fmt.Sprintf("%s.%d", prefix, 10+i)
		name := fmt.Sprintf("compute%02d", i+1)
		lines = append(lines, fmt.Sprintf("echo \"%s %s\" >> /etc/hosts", ip, name))
	}
	return strings.Join(lines, "\n")
}

// replaceForBlock replaces the Terraform %{ for ... } ... %{ endfor } block
// in the template with the pre-expanded Go-generated lines.
func replaceForBlock(template, replacement string) string {
	lines := strings.Split(template, "\n")
	var out []string
	inBlock := false
	replaced := false

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !replaced && strings.HasPrefix(trimmed, "%{") && strings.Contains(trimmed, "for") {
			inBlock = true
			continue
		}
		if inBlock {
			if strings.HasPrefix(trimmed, "%{") && strings.Contains(trimmed, "endfor") {
				inBlock = false
				out = append(out, replacement)
				replaced = true
			}
			// Skip lines inside the for block
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// generatePassword creates a random alphanumeric password of length n.
func generatePassword(n int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = charset[int(b[i])%len(charset)]
	}
	return string(b)
}

// generateMungeKeyB64 generates a random 1024-byte munge key encoded as base64.
// The munge key is written to /etc/munge/munge.key on the head node and then
// copied to EFS for compute and burst nodes to pick up.
func generateMungeKeyB64() string {
	key := make([]byte, 1024)
	_, _ = rand.Read(key)
	return base64.StdEncoding.EncodeToString(key)
}
