// =============================================================================
// compute_nodes.go — BurstLab static compute node construct
//
// Creates the "on-prem" compute nodes — static EC2 instances that simulate
// a private HPC cluster's compute network. These nodes:
//   - Are always running (not managed by Slurm power save).
//   - Run slurmd and register with slurmctld on the head node.
//   - Mount /home and /opt/slurm from EFS.
//   - Have no public IP; internet access goes through the head node NAT.
//   - Get predictable private IPs: 10.0.1.10 (compute01) through .13 (compute04).
//     The exact IPs depend on AWS DHCP assignment — we request specific IPs
//     via PrivateIpAddress in the CfnInstance props to match Slurm's NodeAddr.
//
// UserData is loaded from scripts/userdata/compute-node-init.sh.tpl with the
// same ${VAR} substitution approach used by the head node construct.
// The Terraform for-loops in the template are expanded in Go.
// =============================================================================

package constructs

import (
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// BurstlabComputeNodesProps holds configuration for the compute node construct.
type BurstlabComputeNodesProps struct {
	// ClusterName is the name prefix for all compute node resources.
	ClusterName string

	// AmiId is the AMI for compute nodes (same CentOS 8 AMI as the head node).
	AmiId string

	// InstanceType is the EC2 instance type. Default: m7a.large.
	InstanceType string

	// KeyName is the EC2 key pair for SSH access (useful for debugging).
	KeyName string

	// OnpremSubnetId is the subnet where all compute nodes are placed.
	OnpremSubnetId *string

	// ComputeNodeSgId is the security group for compute nodes.
	ComputeNodeSgId *string

	// Count is the number of compute nodes to create. Default: 4.
	Count int

	// OnpremCidr is the CIDR of the on-prem subnet.
	// Compute node IPs are assigned as: base+10, base+11, ...
	OnpremCidr string

	// HeadNodePrivateIp is the head node's private IP for /etc/hosts and routing.
	HeadNodePrivateIp *string

	// EfsDnsName is the EFS DNS name for /etc/fstab entries.
	EfsDnsName *string

	// UserDataTemplatePath is the path to compute-node-init.sh.tpl.
	UserDataTemplatePath string
}

// BurstlabComputeNodes is the CDK construct that creates all on-prem compute nodes.
type BurstlabComputeNodes struct {
	constructs.Construct

	// InstanceIds holds the EC2 instance IDs in order (compute01, compute02, ...).
	InstanceIds []*string

	// PrivateIps holds the private IP addresses in order.
	PrivateIps []*string
}

// NewBurstlabComputeNodes creates Count compute node EC2 instances.
func NewBurstlabComputeNodes(scope constructs.Construct, id string, props *BurstlabComputeNodesProps) *BurstlabComputeNodes {
	this := &BurstlabComputeNodes{}
	constructs.NewConstruct_Override(this, scope, id)

	if props.InstanceType == "" {
		props.InstanceType = "m7a.large"
	}
	if props.Count == 0 {
		props.Count = 4
	}

	cn := props.ClusterName

	// Derive the subnet base IP (first 3 octets) for static IP assignment.
	// 10.0.1.0/24 → prefix = "10.0.1"
	subnetPrefix := cidrPrefix(props.OnpremCidr)

	for i := 0; i < props.Count; i++ {
		nodeIndex := i + 1
		nodeName := fmt.Sprintf("compute%02d", nodeIndex)
		// Static private IP: 10.0.1.10 for compute01, .11 for compute02, etc.
		// Offset of 10 leaves room for gateway (.1), DNS (.2), and reserved (.3-.9).
		privateIP := fmt.Sprintf("%s.%d", subnetPrefix, 10+i)

		userData := buildComputeNodeUserData(props, nodeIndex)

		instance := awsec2.NewCfnInstance(this, jsii.String(fmt.Sprintf("ComputeNode%02d", nodeIndex)), &awsec2.CfnInstanceProps{
			ImageId:          jsii.String(props.AmiId),
			InstanceType:     jsii.String(props.InstanceType),
			KeyName:          jsii.String(props.KeyName),
			SubnetId:         props.OnpremSubnetId,
			SecurityGroupIds: &[]*string{props.ComputeNodeSgId},
			PrivateIpAddress: jsii.String(privateIP),
			// Compute nodes do not need an IAM profile for the basic use case.
			// If SSM access is required, add a profile with SSMManagedInstanceCore.
			UserData: jsii.String(base64.StdEncoding.EncodeToString([]byte(userData))),
			Tags: &[]*awsec2.CfnTag{
				{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-%s", cn, nodeName))},
				{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
				{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
				{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
				{Key: jsii.String("Role"), Value: jsii.String("compute-node")},
				{Key: jsii.String("NodeIndex"), Value: jsii.String(fmt.Sprintf("%d", nodeIndex))},
			},
		})

		this.InstanceIds = append(this.InstanceIds, instance.Ref())
		this.PrivateIps = append(this.PrivateIps, instance.AttrPrivateIp())
	}

	return this
}

// buildComputeNodeUserData loads and substitutes the compute node UserData template.
func buildComputeNodeUserData(props *BurstlabComputeNodesProps, nodeIndex int) string {
	templatePath := props.UserDataTemplatePath
	if templatePath == "" {
		templatePath = "../../scripts/userdata/compute-node-init.sh.tpl"
	}

	raw, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Sprintf("#!/bin/bash\necho 'ERROR: could not load compute-node UserData template: %v'\n", err)
	}

	ud := string(raw)

	// Expand the for-loop block for /etc/hosts entries (same as head node).
	hostsBlock := buildHostsBlock(props.OnpremCidr, props.Count)
	ud = replaceForBlock(ud, hostsBlock)

	// Substitute scalar variables.
	ud = strings.ReplaceAll(ud, "${node_index}", fmt.Sprintf("%d", nodeIndex))
	ud = strings.ReplaceAll(ud, "${head_node_ip}", *props.HeadNodePrivateIp)
	ud = strings.ReplaceAll(ud, "${efs_dns_name}", *props.EfsDnsName)
	ud = strings.ReplaceAll(ud, "${onprem_cidr}", props.OnpremCidr)

	return ud
}

// cidrPrefix returns the first three octets of a CIDR (e.g. "10.0.1.0/24" → "10.0.1").
func cidrPrefix(cidr string) string {
	parts := strings.Split(cidr, "/")
	if len(parts) < 1 {
		return "10.0.1"
	}
	octets := strings.Split(parts[0], ".")
	if len(octets) < 3 {
		return "10.0.1"
	}
	return strings.Join(octets[:3], ".")
}
