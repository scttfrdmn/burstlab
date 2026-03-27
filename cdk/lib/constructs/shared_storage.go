// =============================================================================
// shared_storage.go — BurstLab EFS construct
//
// Creates the shared storage layer used by all cluster nodes:
//   - EFS file system (encrypted, GeneralPurpose performance mode, Bursting
//     throughput — appropriate for a demo cluster with bursty I/O patterns).
//   - 4 EFS mount targets: one per subnet (management, on-prem, cloud-a, cloud-b).
//     Each mount target gets the EFS security group which allows TCP 2049 from
//     the VPC CIDR.
//   - 2 EFS access points:
//       /      → /home     (user home directories, uid/gid 0 = root, not enforced)
//       /slurm → /opt/slurm (Slurm binaries, configs, plugin)
//
// All nodes mount both paths on boot via /etc/fstab entries written in their
// respective init scripts.
// =============================================================================

package constructs

import (
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/aws-cdk-go/awscdk/v2/awsefs"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// BurstlabSharedStorageProps holds configuration for the EFS construct.
type BurstlabSharedStorageProps struct {
	// ClusterName is the name prefix for EFS resources.
	ClusterName string

	// VpcId is the ID of the VPC where mount targets are created.
	VpcId *string

	// EfsSgId is the security group ID applied to all mount targets.
	// Must allow inbound TCP 2049 from the VPC CIDR.
	EfsSgId *string

	// ManagementSubnetId is the subnet for the management mount target.
	ManagementSubnetId *string

	// OnpremSubnetId is the subnet for the on-prem compute mount target.
	OnpremSubnetId *string

	// CloudSubnetAId is the subnet for the cloud-a mount target.
	CloudSubnetAId *string

	// CloudSubnetBId is the subnet for the cloud-b mount target.
	CloudSubnetBId *string
}

// BurstlabSharedStorage is the CDK construct that creates the EFS file system.
type BurstlabSharedStorage struct {
	constructs.Construct

	// FileSystemId is the EFS file system ID.
	FileSystemId *string

	// EfsDnsName is the DNS name used by nodes in /etc/fstab mount entries.
	// Format: <fs-id>.efs.<region>.amazonaws.com
	EfsDnsName *string
}

// NewBurstlabSharedStorage creates the EFS file system and mount targets.
func NewBurstlabSharedStorage(scope constructs.Construct, id string, props *BurstlabSharedStorageProps) *BurstlabSharedStorage {
	this := &BurstlabSharedStorage{}
	constructs.NewConstruct_Override(this, scope, id)

	cn := props.ClusterName

	// -------------------------------------------------------------------------
	// EFS File System
	// Encrypted at rest — good practice even for a demo cluster.
	// GeneralPurpose performance mode: lowest latency per operation, suitable
	// for Slurm config reads and user home directory access.
	// BurstingThroughput: automatically scales with file system size, which is
	// fine for a demo workload.
	// -------------------------------------------------------------------------
	fs := awsefs.NewCfnFileSystem(this, jsii.String("FileSystem"), &awsefs.CfnFileSystemProps{
		Encrypted:       jsii.Bool(true),
		PerformanceMode: jsii.String("generalPurpose"),
		ThroughputMode:  jsii.String("bursting"),
		FileSystemTags: &[]*awsefs.CfnFileSystem_ElasticFileSystemTagProperty{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-efs", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.FileSystemId = fs.Ref()

	// EFS DNS name — used in /etc/fstab on every cluster node.
	// Format: <fs-id>.efs.<region>.amazonaws.com
	// We use Fn::Join to concatenate the file system ID (a CFn Ref token),
	// the region pseudo-parameter, and the static suffix into a single string
	// that CloudFormation resolves at deploy time.
	this.EfsDnsName = awscdk.Fn_Join(jsii.String("."), &[]*string{
		fs.Ref(),
		jsii.String("efs"),
		awscdk.Fn_Sub(jsii.String("${AWS::Region}"), nil),
		jsii.String("amazonaws.com"),
	})

	// -------------------------------------------------------------------------
	// EFS Mount Targets — one per subnet
	// Each mount target is an ENI in the subnet. Nodes in that subnet mount EFS
	// by connecting to that ENI's IP (or the file system's DNS name, which
	// resolves to the closest mount target IP via AZ-aware DNS).
	// -------------------------------------------------------------------------

	mgmtMt := awsefs.NewCfnMountTarget(this, jsii.String("MountTargetManagement"), &awsefs.CfnMountTargetProps{
		FileSystemId:   fs.Ref(),
		SubnetId:       props.ManagementSubnetId,
		SecurityGroups: &[]*string{props.EfsSgId},
	})

	onpremMt := awsefs.NewCfnMountTarget(this, jsii.String("MountTargetOnprem"), &awsefs.CfnMountTargetProps{
		FileSystemId:   fs.Ref(),
		SubnetId:       props.OnpremSubnetId,
		SecurityGroups: &[]*string{props.EfsSgId},
	})

	cloudAMt := awsefs.NewCfnMountTarget(this, jsii.String("MountTargetCloudA"), &awsefs.CfnMountTargetProps{
		FileSystemId:   fs.Ref(),
		SubnetId:       props.CloudSubnetAId,
		SecurityGroups: &[]*string{props.EfsSgId},
	})

	cloudBMt := awsefs.NewCfnMountTarget(this, jsii.String("MountTargetCloudB"), &awsefs.CfnMountTargetProps{
		FileSystemId:   fs.Ref(),
		SubnetId:       props.CloudSubnetBId,
		SecurityGroups: &[]*string{props.EfsSgId},
	})

	// Suppress unused-variable warnings — mount targets are side-effecting
	// resources; their IDs are not consumed downstream.
	_ = mgmtMt
	_ = onpremMt
	_ = cloudAMt
	_ = cloudBMt

	// -------------------------------------------------------------------------
	// EFS Access Points
	//
	// Access Point for / (home directories):
	//   Path: / on the EFS file system → mounted at /home on cluster nodes.
	//   No POSIX uid/gid enforcement — Slurm creates user accounts with the
	//   same UID on every node, so standard POSIX permissions apply.
	//
	// Access Point for /slurm:
	//   Path: /slurm on the EFS file system → mounted at /opt/slurm on nodes.
	//   This directory holds Slurm binaries, configs, plugin scripts, and the
	//   munge key. Written by the head node on first boot, read-only by compute
	//   and burst nodes (in practice — not enforced at the access point level).
	// -------------------------------------------------------------------------
	awsefs.NewCfnAccessPoint(this, jsii.String("AccessPointHome"), &awsefs.CfnAccessPointProps{
		FileSystemId: fs.Ref(),
		RootDirectory: &awsefs.CfnAccessPoint_RootDirectoryProperty{
			Path: jsii.String("/"),
			CreationInfo: &awsefs.CfnAccessPoint_CreationInfoProperty{
				OwnerUid:    jsii.String("0"),
				OwnerGid:    jsii.String("0"),
				Permissions: jsii.String("0755"),
			},
		},
		AccessPointTags: &[]*awsefs.CfnAccessPoint_AccessPointTagProperty{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-efs-home-ap", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})

	awsefs.NewCfnAccessPoint(this, jsii.String("AccessPointSlurm"), &awsefs.CfnAccessPointProps{
		FileSystemId: fs.Ref(),
		RootDirectory: &awsefs.CfnAccessPoint_RootDirectoryProperty{
			Path: jsii.String("/slurm"),
			CreationInfo: &awsefs.CfnAccessPoint_CreationInfoProperty{
				OwnerUid:    jsii.String("0"),
				OwnerGid:    jsii.String("0"),
				Permissions: jsii.String("0755"),
			},
		},
		AccessPointTags: &[]*awsefs.CfnAccessPoint_AccessPointTagProperty{
			{Key: jsii.String("Name"), Value: jsii.String(fmt.Sprintf("%s-efs-slurm-ap", cn))},
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})

	return this
}
