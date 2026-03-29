// =============================================================================
// gen1.go — BurstLab Gen 1 stack
//
// Assembles all BurstLab constructs into a single CloudFormation stack that
// produces IDENTICAL infrastructure to the Terraform implementation under
// terraform/generations/gen1-slurm2205-rocky8/.
//
// Infrastructure created:
//   VPC (10.0.0.0/16) with 4 subnets and 3 route tables
//   ├── management subnet (head node, EIP, IGW route)
//   ├── on-prem subnet    (compute01-04, NAT via head node)
//   ├── cloud subnet A    (burst nodes, NAT via head node)
//   └── cloud subnet B    (burst nodes, NAT via head node)
//
//   EFS file system with 4 mount targets (/home and /opt/slurm exports)
//   IAM roles for head node and burst nodes
//   Head node EC2 (m7a.large, static IP 10.0.0.10, src/dst check disabled, EIP)
//   4× compute node EC2 (m7a.large, static IPs 10.0.1.10-13)
//   EC2 launch template for burst nodes (IMDSv2, InstanceMetadataTags)
//
// Assembly order note:
//   The burst config launch template is created before the head node so its
//   CloudFormation token ID can be embedded into partitions.json (which is
//   written to the head node's EFS path by the init script UserData).
//
// Config templates are read from configs/gen1-slurm2205-rocky8/ and rendered
// with the actual subnet IDs, cluster name, and other deploy-time values.
//
// CloudFormation Outputs:
//   HeadNodePublicIP  — EIP for SSH access
//   HeadNodePrivateIP — private IP for Slurm config validation
//   ClusterName       — cluster name passed at deploy time
//   EfsDnsName        — EFS DNS name for manual mount commands
//   LaunchTemplateId  — burst node launch template ID (for partitions.json)
// =============================================================================

package stacks

import (
	"fmt"
	"os"
	"strings"

	blconstructs "burstlab/cdk/lib/constructs"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// Gen1StackProps holds the top-level configuration for the Gen 1 stack.
type Gen1StackProps struct {
	awscdk.StackProps

	// ClusterName is the name prefix for all resources. Default: "burstlab".
	ClusterName string

	// KeyName is the EC2 key pair name for all instances.
	KeyName string

	// HeadNodeAmi is the AMI ID for all nodes (head + compute + burst).
	// Must be the BurstLab Gen 1 CentOS 8 / Slurm 22.05 AMI.
	HeadNodeAmi string
}

// NewGen1Stack creates the complete BurstLab Gen 1 CloudFormation stack.
func NewGen1Stack(scope constructs.Construct, id string, props *Gen1StackProps) awscdk.Stack {
	stack := awscdk.NewStack(scope, &id, &props.StackProps)

	cn := props.ClusterName
	if cn == "" {
		cn = "burstlab"
	}

	// -------------------------------------------------------------------------
	// Hard-coded cluster parameters (matching Terraform defaults).
	// These match the values in terraform/modules/vpc/variables.tf.
	// -------------------------------------------------------------------------
	const (
		vpcCidr          = "10.0.0.0/16"
		mgmtCidr         = "10.0.0.0/24"
		onpremCidr       = "10.0.1.0/24"
		cloudACidr       = "10.0.2.0/24"
		cloudBCidr       = "10.0.3.0/24"
		azA              = "us-west-2a"
		azB              = "us-west-2b"
		instanceType     = "m7a.large"
		computeCount     = 4
		maxBurstNodes    = 10
		awsRegion        = "us-west-2"
		burstInstType    = "m7a.xlarge"
		headNodeStaticIP = "10.0.0.10" // must match SlurmctldHost in slurm.conf
	)

	// -------------------------------------------------------------------------
	// 1. VPC
	// -------------------------------------------------------------------------
	vpc := blconstructs.NewBurstlabVpc(stack, "Vpc", &blconstructs.BurstlabVpcProps{
		ClusterName:          cn,
		VpcCidr:              vpcCidr,
		ManagementSubnetCidr: mgmtCidr,
		OnpremSubnetCidr:     onpremCidr,
		CloudSubnetACidr:     cloudACidr,
		CloudSubnetBCidr:     cloudBCidr,
		AzA:                  azA,
		AzB:                  azB,
	})

	// -------------------------------------------------------------------------
	// 2. IAM
	// -------------------------------------------------------------------------
	iam := blconstructs.NewBurstlabIam(stack, "Iam", &blconstructs.BurstlabIamProps{
		ClusterName: cn,
	})

	// -------------------------------------------------------------------------
	// 3. Shared Storage (EFS)
	// -------------------------------------------------------------------------
	storage := blconstructs.NewBurstlabSharedStorage(stack, "SharedStorage", &blconstructs.BurstlabSharedStorageProps{
		ClusterName:        cn,
		VpcId:              vpc.VpcId,
		EfsSgId:            vpc.EfsSgId,
		ManagementSubnetId: vpc.ManagementSubnetId,
		OnpremSubnetId:     vpc.OnpremSubnetId,
		CloudSubnetAId:     vpc.CloudSubnetAId,
		CloudSubnetBId:     vpc.CloudSubnetBId,
	})

	// -------------------------------------------------------------------------
	// 4. Burst Node Launch Template (created BEFORE head node)
	//
	// The launch template must be created first so its CloudFormation token ID
	// can be embedded in partitions.json, which is written to the head node
	// by the UserData init script.
	//
	// The LT UserData needs head node IP and EFS DNS name. Since we use the
	// static headNodeStaticIP constant (not a CFn token), this is safe.
	// EfsDnsName is a CFn token that resolves at deploy time — it is embedded
	// as a literal token string in the UserData base64 blob. CloudFormation
	// handles token resolution inside UserData automatically.
	// -------------------------------------------------------------------------
	burstConfig := blconstructs.NewBurstlabBurstConfig(stack, "BurstConfig", &blconstructs.BurstlabBurstConfigProps{
		ClusterName:                  cn,
		AmiId:                        props.HeadNodeAmi,
		KeyName:                      props.KeyName,
		BurstNodeSgId:                vpc.BurstNodeSgId,
		BurstNodeInstanceProfileName: iam.BurstNodeInstanceProfile.Ref(),
		HeadNodePrivateIp:            jsii.String(headNodeStaticIP),
		EfsDnsName:                   storage.EfsDnsName,
		UserDataTemplatePath:         "../../scripts/userdata/burst-node-init.sh.tpl",
	})

	// -------------------------------------------------------------------------
	// 5. Render config templates
	//
	// Templates are read from configs/gen1-slurm2205-rocky8/.
	// At CDK synth time, CFn token values (subnet IDs, LT ID) are embedded as
	// token strings; CloudFormation resolves them before the instance launches.
	// -------------------------------------------------------------------------
	configDir := findConfigDir()

	// slurm.conf: burst_node_conf is empty here; generate_conf.py fills it at
	// runtime after the Plugin v2 clone and partitions.json are in place.
	slurmConf := renderTemplate(configDir+"/slurm.conf.tpl", map[string]string{
		"${cluster_name}":       cn,
		"${head_node_ip}":       headNodeStaticIP,
		"${compute_node_count}": fmt.Sprintf("%d", computeCount),
		"${burst_node_conf}":    "", // populated at runtime by generate_conf.py
	})

	// slurmdbd.conf: DB password is generated fresh at synth time and embedded
	// in UserData. For a demo cluster this is acceptable; in production use
	// AWS Secrets Manager.
	slurmdbdDbPass := randomPassword(24)
	slurmdbdConf := renderTemplate(configDir+"/slurmdbd.conf.tpl", map[string]string{
		"${slurmdbd_db_password}": slurmdbdDbPass,
	})

	// cgroup.conf: static file, no template variables.
	cgroupConf := readFile(configDir + "/cgroup.conf")

	// plugin_config.json: all values are static constants matching slurm.conf.
	pluginConfigJSON := readFile(configDir + "/plugin_config.json.tpl")

	// partitions.json: launch template ID is a CFn token (resolved at deploy
	// time). Subnet IDs are also CFn tokens. Both are embedded as token strings
	// in the shell heredoc inside UserData — CloudFormation resolves them before
	// the EC2 instance is launched.
	partitionsJSON := renderTemplate(configDir+"/partitions.json.tpl", map[string]string{
		"${max_burst_nodes}":      fmt.Sprintf("%d", maxBurstNodes),
		"${aws_region}":           awsRegion,
		"${launch_template_id}":   *burstConfig.LaunchTemplateId, // CFn token string
		"${burst_instance_type}":  burstInstType,
		"${cloud_subnet_a_id}":    *vpc.CloudSubnetAId, // CFn token string
		"${cloud_subnet_b_id}":    *vpc.CloudSubnetBId, // CFn token string
		"${cluster_name}":         cn,
	})

	// -------------------------------------------------------------------------
	// 6. Head Node
	// Static private IP: 10.0.0.10 — must match SlurmctldHost in slurm.conf
	// and /etc/hosts entries written by compute/burst node init scripts.
	// -------------------------------------------------------------------------
	headNode := blconstructs.NewBurstlabHeadNode(stack, "HeadNode", &blconstructs.BurstlabHeadNodeProps{
		ClusterName:                 cn,
		AmiId:                       props.HeadNodeAmi,
		InstanceType:                instanceType,
		KeyName:                     props.KeyName,
		ManagementSubnetId:          vpc.ManagementSubnetId,
		HeadNodeSgId:                vpc.HeadNodeSgId,
		HeadNodeInstanceProfileName: iam.HeadNodeInstanceProfile.Ref(),
		OnpremRouteTableId:          vpc.OnpremRouteTableId,
		CloudRouteTableId:           vpc.CloudRouteTableId,
		OnpremCidr:                  onpremCidr,
		CloudCidrA:                  cloudACidr,
		CloudCidrB:                  cloudBCidr,
		EfsDnsName:                  storage.EfsDnsName,
		ComputeNodeCount:            computeCount,
		StaticPrivateIp:             headNodeStaticIP,
		SlurmConf:                   slurmConf,
		SlurmdbdConf:                slurmdbdConf,
		CgroupConf:                  cgroupConf,
		PluginConfigJSON:            pluginConfigJSON,
		PartitionsJSON:              partitionsJSON,
		SlurmdbdDbPassword:          slurmdbdDbPass,
		UserDataTemplatePath:        "../../scripts/userdata/head-node-init.sh.tpl",
	})

	// -------------------------------------------------------------------------
	// 7. Compute Nodes (on-prem)
	// -------------------------------------------------------------------------
	blconstructs.NewBurstlabComputeNodes(stack, "ComputeNodes", &blconstructs.BurstlabComputeNodesProps{
		ClusterName:          cn,
		AmiId:                props.HeadNodeAmi,
		InstanceType:         instanceType,
		KeyName:              props.KeyName,
		OnpremSubnetId:       vpc.OnpremSubnetId,
		ComputeNodeSgId:      vpc.ComputeNodeSgId,
		Count:                computeCount,
		OnpremCidr:           onpremCidr,
		HeadNodePrivateIp:    jsii.String(headNodeStaticIP),
		EfsDnsName:           storage.EfsDnsName,
		UserDataTemplatePath: "../../scripts/userdata/compute-node-init.sh.tpl",
	})

	// -------------------------------------------------------------------------
	// CloudFormation Outputs
	// -------------------------------------------------------------------------

	// HeadNodePublicIP — EIP for SSH: ssh centos@<ip>
	awscdk.NewCfnOutput(stack, jsii.String("HeadNodePublicIP"), &awscdk.CfnOutputProps{
		Description: jsii.String("Head node Elastic IP — SSH access: ssh centos@<ip>"),
		Value:       headNode.PublicIp,
		ExportName:  jsii.String(fmt.Sprintf("%s-head-node-public-ip", cn)),
	})

	// HeadNodePrivateIP — for validating Slurm config and /etc/hosts entries.
	awscdk.NewCfnOutput(stack, jsii.String("HeadNodePrivateIP"), &awscdk.CfnOutputProps{
		Description: jsii.String("Head node private IP — must match SlurmctldHost in slurm.conf"),
		Value:       headNode.PrivateIp,
		ExportName:  jsii.String(fmt.Sprintf("%s-head-node-private-ip", cn)),
	})

	// ClusterName — for reference in post-deploy scripts.
	awscdk.NewCfnOutput(stack, jsii.String("ClusterName"), &awscdk.CfnOutputProps{
		Description: jsii.String("Slurm cluster name (ClusterName in slurm.conf)"),
		Value:       jsii.String(cn),
		ExportName:  jsii.String(fmt.Sprintf("%s-cluster-name", cn)),
	})

	// EfsDnsName — for manual mount commands or debugging.
	awscdk.NewCfnOutput(stack, jsii.String("EfsDnsName"), &awscdk.CfnOutputProps{
		Description: jsii.String("EFS DNS name — used in /etc/fstab on all cluster nodes"),
		Value:       storage.EfsDnsName,
		ExportName:  jsii.String(fmt.Sprintf("%s-efs-dns-name", cn)),
	})

	// LaunchTemplateId — referenced in partitions.json by the Slurm plugin.
	awscdk.NewCfnOutput(stack, jsii.String("LaunchTemplateId"), &awscdk.CfnOutputProps{
		Description: jsii.String("Burst node launch template ID — referenced in partitions.json"),
		Value:       burstConfig.LaunchTemplateId,
		ExportName:  jsii.String(fmt.Sprintf("%s-launch-template-id", cn)),
	})

	// LaunchTemplateName — human-readable identifier for the launch template.
	awscdk.NewCfnOutput(stack, jsii.String("LaunchTemplateName"), &awscdk.CfnOutputProps{
		Description: jsii.String("Burst node launch template name"),
		Value:       burstConfig.LaunchTemplateName,
		ExportName:  jsii.String(fmt.Sprintf("%s-launch-template-name", cn)),
	})

	return stack
}

// -------------------------------------------------------------------------
// Template rendering helpers
// -------------------------------------------------------------------------

// findConfigDir returns the path to configs/gen1-slurm2205-rocky8.
// Tries several relative paths from the CDK app root (cdk/).
func findConfigDir() string {
	candidates := []string{
		"../../configs/gen1-slurm2205-rocky8",
		"../configs/gen1-slurm2205-rocky8",
		"configs/gen1-slurm2205-rocky8",
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	// Return the expected path even if not found; error surfaces at ReadFile time.
	return "../../configs/gen1-slurm2205-rocky8"
}

// renderTemplate reads a template file and replaces all keys in vars.
func renderTemplate(path string, vars map[string]string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("# ERROR: could not read template %s: %v\n", path, err)
	}
	s := string(raw)
	for k, v := range vars {
		s = strings.ReplaceAll(s, k, v)
	}
	return s
}

// readFile reads a file and returns its contents, or an error comment on failure.
func readFile(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("# ERROR: could not read file %s: %v\n", path, err)
	}
	return string(raw)
}

// randomPassword generates a random alphanumeric password of length n
// using /dev/urandom as the entropy source.
func randomPassword(n int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	f, err := os.Open("/dev/urandom")
	if err != nil {
		// Fallback for environments without /dev/urandom (e.g. some CI).
		return "BurstLabDefaultPass01X"
	}
	defer f.Close()
	_, _ = f.Read(b)
	for i := range b {
		b[i] = charset[int(b[i])%len(charset)]
	}
	return string(b)
}
