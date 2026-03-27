// =============================================================================
// vpc.go — BurstLab VPC construct
//
// Models the full network topology for the "mock on-prem" HPC cluster.
// Uses L1 (CfnXxx) constructs throughout for exact control over subnet
// and route table configuration — the L2 ec2.Vpc abstraction does not
// give sufficient control over individual route tables per subnet.
//
// Topology produced:
//   VPC 10.0.0.0/16
//   ├── management  10.0.0.0/24  (us-west-2a)  head node, EIP
//   ├── on-prem     10.0.1.0/24  (us-west-2a)  compute nodes (private)
//   ├── cloud-a     10.0.2.0/24  (us-west-2a)  burst nodes (private)
//   └── cloud-b     10.0.3.0/24  (us-west-2b)  burst nodes (private)
//
// Route tables:
//   - management:  0.0.0.0/0 → IGW  (added here)
//   - on-prem:     0.0.0.0/0 → head node ENI  (added by head_node.go)
//   - cloud:       0.0.0.0/0 → head node ENI  (added by head_node.go, shared)
// =============================================================================

package constructs

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2/awsec2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// BurstlabVpcProps holds configuration for the VPC construct.
type BurstlabVpcProps struct {
	// ClusterName is the name prefix applied to all resources.
	// Must be short and DNS-safe (lowercase alphanumeric + hyphens).
	ClusterName string

	// VpcCidr is the CIDR for the entire VPC. Default: 10.0.0.0/16.
	VpcCidr string

	// ManagementSubnetCidr is the CIDR for the head-node subnet. Default: 10.0.0.0/24.
	ManagementSubnetCidr string

	// OnpremSubnetCidr is the CIDR for the simulated on-prem compute subnet. Default: 10.0.1.0/24.
	OnpremSubnetCidr string

	// CloudSubnetACidr is the CIDR for cloud burst subnet A (us-west-2a). Default: 10.0.2.0/24.
	CloudSubnetACidr string

	// CloudSubnetBCidr is the CIDR for cloud burst subnet B (us-west-2b). Default: 10.0.3.0/24.
	CloudSubnetBCidr string

	// AzA is the primary availability zone. Default: us-west-2a.
	AzA string

	// AzB is the secondary availability zone. Default: us-west-2b.
	AzB string
}

// BurstlabVpc is the CDK construct that creates the BurstLab network topology.
// All subnet IDs and security group IDs are exposed as fields for use by
// downstream constructs.
type BurstlabVpc struct {
	constructs.Construct

	// VpcId is the ID of the created VPC.
	VpcId *string

	// VpcCidr is the CIDR block of the created VPC (echoed back for consumers).
	VpcCidr string

	// ManagementSubnetId is the subnet ID where the head node lives.
	ManagementSubnetId *string

	// OnpremSubnetId is the subnet ID for simulated on-prem compute nodes.
	OnpremSubnetId *string

	// CloudSubnetAId is the subnet ID for cloud burst nodes in AZ-A.
	CloudSubnetAId *string

	// CloudSubnetBId is the subnet ID for cloud burst nodes in AZ-B.
	CloudSubnetBId *string

	// OnpremRouteTableId is the ID of the on-prem route table.
	// The head-node construct adds 0.0.0.0/0 → head ENI here.
	OnpremRouteTableId *string

	// CloudRouteTableId is the ID of the shared cloud route table.
	// The head-node construct adds 0.0.0.0/0 → head ENI here.
	CloudRouteTableId *string

	// HeadNodeSgId is the security group ID for the head node.
	HeadNodeSgId *string

	// ComputeNodeSgId is the security group ID for on-prem compute nodes.
	ComputeNodeSgId *string

	// BurstNodeSgId is the security group ID for cloud burst nodes.
	BurstNodeSgId *string

	// EfsSgId is the security group ID for EFS mount targets.
	EfsSgId *string
}

// NewBurstlabVpc creates the full BurstLab VPC topology.
func NewBurstlabVpc(scope constructs.Construct, id string, props *BurstlabVpcProps) *BurstlabVpc {
	this := &BurstlabVpc{}
	constructs.NewConstruct_Override(this, scope, id)

	// Apply defaults
	if props.VpcCidr == "" {
		props.VpcCidr = "10.0.0.0/16"
	}
	if props.ManagementSubnetCidr == "" {
		props.ManagementSubnetCidr = "10.0.0.0/24"
	}
	if props.OnpremSubnetCidr == "" {
		props.OnpremSubnetCidr = "10.0.1.0/24"
	}
	if props.CloudSubnetACidr == "" {
		props.CloudSubnetACidr = "10.0.2.0/24"
	}
	if props.CloudSubnetBCidr == "" {
		props.CloudSubnetBCidr = "10.0.3.0/24"
	}
	if props.AzA == "" {
		props.AzA = "us-west-2a"
	}
	if props.AzB == "" {
		props.AzB = "us-west-2b"
	}

	cn := props.ClusterName

	// -------------------------------------------------------------------------
	// VPC
	// enable_dns_support + enable_dns_hostnames: both required for EFS mount
	// targets to be reachable by DNS name inside the VPC.
	// -------------------------------------------------------------------------
	vpc := awsec2.NewCfnVPC(this, jsii.String("Vpc"), &awsec2.CfnVPCProps{
		CidrBlock:          jsii.String(props.VpcCidr),
		EnableDnsSupport:   jsii.Bool(true),
		EnableDnsHostnames: jsii.Bool(true),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-vpc", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.VpcId = vpc.Ref()
	this.VpcCidr = props.VpcCidr

	// -------------------------------------------------------------------------
	// Internet Gateway + attachment
	// Required so the management subnet can reach the internet (SSH, AWS API,
	// yum repos). Only attached to this VPC.
	// -------------------------------------------------------------------------
	igw := awsec2.NewCfnInternetGateway(this, jsii.String("Igw"), &awsec2.CfnInternetGatewayProps{
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-igw", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})

	awsec2.NewCfnVPCGatewayAttachment(this, jsii.String("IgwAttachment"), &awsec2.CfnVPCGatewayAttachmentProps{
		VpcId:             vpc.Ref(),
		InternetGatewayId: igw.Ref(),
	})

	// -------------------------------------------------------------------------
	// Subnets
	// -------------------------------------------------------------------------

	// Management subnet — head node lives here. map_public_ip_on_launch=false
	// because the head node gets a static EIP; auto-assigned IPs would break
	// DNS-based access every time the instance is replaced.
	mgmtSubnet := awsec2.NewCfnSubnet(this, jsii.String("ManagementSubnet"), &awsec2.CfnSubnetProps{
		VpcId:               vpc.Ref(),
		CidrBlock:           jsii.String(props.ManagementSubnetCidr),
		AvailabilityZone:    jsii.String(props.AzA),
		MapPublicIpOnLaunch: jsii.Bool(false),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-mgmt-subnet", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
			{Key: jsii.String("Role"), Value: jsii.String("management")},
		},
	})
	this.ManagementSubnetId = mgmtSubnet.Ref()

	// On-prem subnet — simulates a private HPC compute network.
	// No public IPs; internet access flows through the head node NAT.
	onpremSubnet := awsec2.NewCfnSubnet(this, jsii.String("OnpremSubnet"), &awsec2.CfnSubnetProps{
		VpcId:               vpc.Ref(),
		CidrBlock:           jsii.String(props.OnpremSubnetCidr),
		AvailabilityZone:    jsii.String(props.AzA),
		MapPublicIpOnLaunch: jsii.Bool(false),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-onprem-subnet", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
			{Key: jsii.String("Role"), Value: jsii.String("onprem-compute")},
		},
	})
	this.OnpremSubnetId = onpremSubnet.Ref()

	// Cloud burst subnet A — us-west-2a. Burst nodes land here or in B.
	cloudSubnetA := awsec2.NewCfnSubnet(this, jsii.String("CloudSubnetA"), &awsec2.CfnSubnetProps{
		VpcId:               vpc.Ref(),
		CidrBlock:           jsii.String(props.CloudSubnetACidr),
		AvailabilityZone:    jsii.String(props.AzA),
		MapPublicIpOnLaunch: jsii.Bool(false),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-cloud-a-subnet", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
			{Key: jsii.String("Role"), Value: jsii.String("cloud-burst")},
		},
	})
	this.CloudSubnetAId = cloudSubnetA.Ref()

	// Cloud burst subnet B — us-west-2b. Second AZ roughly doubles burst
	// capacity availability since EC2 spot/on-demand pools are per-AZ.
	cloudSubnetB := awsec2.NewCfnSubnet(this, jsii.String("CloudSubnetB"), &awsec2.CfnSubnetProps{
		VpcId:               vpc.Ref(),
		CidrBlock:           jsii.String(props.CloudSubnetBCidr),
		AvailabilityZone:    jsii.String(props.AzB),
		MapPublicIpOnLaunch: jsii.Bool(false),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-cloud-b-subnet", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
			{Key: jsii.String("Role"), Value: jsii.String("cloud-burst")},
		},
	})
	this.CloudSubnetBId = cloudSubnetB.Ref()

	// -------------------------------------------------------------------------
	// Route Tables
	// -------------------------------------------------------------------------

	// Management route table — default route → IGW so the head node can
	// reach the internet (SSH ingress, AWS API, yum repos).
	mgmtRtb := awsec2.NewCfnRouteTable(this, jsii.String("ManagementRouteTable"), &awsec2.CfnRouteTableProps{
		VpcId: vpc.Ref(),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-mgmt-rtb", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})

	// Default route via IGW for the management subnet.
	awsec2.NewCfnRoute(this, jsii.String("ManagementDefaultRoute"), &awsec2.CfnRouteProps{
		RouteTableId:        mgmtRtb.Ref(),
		DestinationCidrBlock: jsii.String("0.0.0.0/0"),
		GatewayId:           igw.Ref(),
	})

	awsec2.NewCfnSubnetRouteTableAssociation(this, jsii.String("ManagementRtbAssoc"), &awsec2.CfnSubnetRouteTableAssociationProps{
		SubnetId:     mgmtSubnet.Ref(),
		RouteTableId: mgmtRtb.Ref(),
	})

	// On-prem route table — created empty; head_node.go adds the NAT default
	// route after the head node EC2 instance is created (its ENI ID is needed).
	onpremRtb := awsec2.NewCfnRouteTable(this, jsii.String("OnpremRouteTable"), &awsec2.CfnRouteTableProps{
		VpcId: vpc.Ref(),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-onprem-rtb", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.OnpremRouteTableId = onpremRtb.Ref()

	awsec2.NewCfnSubnetRouteTableAssociation(this, jsii.String("OnpremRtbAssoc"), &awsec2.CfnSubnetRouteTableAssociationProps{
		SubnetId:     onpremSubnet.Ref(),
		RouteTableId: onpremRtb.Ref(),
	})

	// Cloud route table — shared by both burst subnets; also empty initially.
	// The head-node construct adds the NAT default route after EC2 launch.
	cloudRtb := awsec2.NewCfnRouteTable(this, jsii.String("CloudRouteTable"), &awsec2.CfnRouteTableProps{
		VpcId: vpc.Ref(),
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-cloud-rtb", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.CloudRouteTableId = cloudRtb.Ref()

	awsec2.NewCfnSubnetRouteTableAssociation(this, jsii.String("CloudARtbAssoc"), &awsec2.CfnSubnetRouteTableAssociationProps{
		SubnetId:     cloudSubnetA.Ref(),
		RouteTableId: cloudRtb.Ref(),
	})

	awsec2.NewCfnSubnetRouteTableAssociation(this, jsii.String("CloudBRtbAssoc"), &awsec2.CfnSubnetRouteTableAssociationProps{
		SubnetId:     cloudSubnetB.Ref(),
		RouteTableId: cloudRtb.Ref(),
	})

	// -------------------------------------------------------------------------
	// Security Groups
	// -------------------------------------------------------------------------

	// Head node SG — SSH from anywhere (lab access) + all VPC traffic.
	// All-VPC-traffic rule covers: Slurm (6817/6818/6819), Munge, EFS (2049),
	// srun I/O forwarding, and ICMP for connectivity testing.
	headNodeSg := awsec2.NewCfnSecurityGroup(this, jsii.String("HeadNodeSg"), &awsec2.CfnSecurityGroupProps{
		GroupDescription: jsii.String("Head node: SSH from internet + all VPC traffic for Slurm/Munge/EFS"),
		VpcId:            vpc.Ref(),
		SecurityGroupIngress: &[]*awsec2.CfnSecurityGroup_IngressProperty{
			{
				Description: jsii.String("SSH from anywhere — lab access (restrict in production)"),
				IpProtocol:  jsii.String("tcp"),
				FromPort:    jsii.Number(22),
				ToPort:      jsii.Number(22),
				CidrIp:      jsii.String("0.0.0.0/0"),
			},
			{
				Description: jsii.String("All traffic from within VPC — Slurm, Munge, EFS, srun forwarding"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String(props.VpcCidr),
			},
		},
		SecurityGroupEgress: &[]*awsec2.CfnSecurityGroup_EgressProperty{
			{
				Description: jsii.String("All outbound — AWS API, yum repos, EFS, internet for updates"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String("0.0.0.0/0"),
			},
		},
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-head-node-sg", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.HeadNodeSgId = headNodeSg.Ref()

	// Compute node SG — on-prem simulated nodes, VPC-internal traffic only.
	// Covers slurmd (6818), Munge auth, EFS (2049), srun I/O.
	// No internet-facing rules — nodes have no public IPs.
	computeNodeSg := awsec2.NewCfnSecurityGroup(this, jsii.String("ComputeNodeSg"), &awsec2.CfnSecurityGroupProps{
		GroupDescription: jsii.String("On-prem compute nodes: all VPC traffic only (no public ingress)"),
		VpcId:            vpc.Ref(),
		SecurityGroupIngress: &[]*awsec2.CfnSecurityGroup_IngressProperty{
			{
				Description: jsii.String("All traffic from VPC — Slurmd (6818), Munge, EFS, job I/O"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String(props.VpcCidr),
			},
		},
		SecurityGroupEgress: &[]*awsec2.CfnSecurityGroup_EgressProperty{
			{
				Description: jsii.String("All outbound — internet via head node NAT for yum/updates"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String("0.0.0.0/0"),
			},
		},
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-compute-node-sg", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.ComputeNodeSgId = computeNodeSg.Ref()

	// Burst node SG — cloud burst nodes, VPC-internal only.
	// Same logic as compute nodes: talk to slurmctld, mount EFS, Munge auth.
	// External internet access goes through head node NAT via the cloud RTB.
	burstNodeSg := awsec2.NewCfnSecurityGroup(this, jsii.String("BurstNodeSg"), &awsec2.CfnSecurityGroupProps{
		GroupDescription: jsii.String("Cloud burst nodes: all VPC traffic only, internet via head-node NAT"),
		VpcId:            vpc.Ref(),
		SecurityGroupIngress: &[]*awsec2.CfnSecurityGroup_IngressProperty{
			{
				Description: jsii.String("All traffic from VPC — Slurmd, Munge, EFS, srun I/O"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String(props.VpcCidr),
			},
		},
		SecurityGroupEgress: &[]*awsec2.CfnSecurityGroup_EgressProperty{
			{
				Description: jsii.String("All outbound — goes through head node NAT for external access"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String("0.0.0.0/0"),
			},
		},
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-burst-node-sg", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.BurstNodeSgId = burstNodeSg.Ref()

	// EFS SG — accepts NFS (TCP 2049) from VPC CIDR only.
	// Applied to all four EFS mount targets (one per subnet).
	efsSg := awsec2.NewCfnSecurityGroup(this, jsii.String("EfsSg"), &awsec2.CfnSecurityGroupProps{
		GroupDescription: jsii.String("EFS mount targets: NFS (2049) from VPC CIDR only"),
		VpcId:            vpc.Ref(),
		SecurityGroupIngress: &[]*awsec2.CfnSecurityGroup_IngressProperty{
			{
				Description: jsii.String("NFS from VPC — all nodes mount EFS for /home and /opt/slurm"),
				IpProtocol:  jsii.String("tcp"),
				FromPort:    jsii.Number(2049),
				ToPort:      jsii.Number(2049),
				CidrIp:      jsii.String(props.VpcCidr),
			},
		},
		SecurityGroupEgress: &[]*awsec2.CfnSecurityGroup_EgressProperty{
			{
				Description: jsii.String("All outbound (standard AWS SG requirement; EFS does not initiate connections)"),
				IpProtocol:  jsii.String("-1"),
				FromPort:    jsii.Number(-1),
				ToPort:      jsii.Number(-1),
				CidrIp:      jsii.String("0.0.0.0/0"),
			},
		},
		Tags: &[]*awsec2.CfnTag{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-efs-sg", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.EfsSgId = efsSg.Ref()

	return this
}
