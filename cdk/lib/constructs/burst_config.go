// =============================================================================
// burst_config.go — BurstLab burst node launch template construct
//
// Creates the EC2 Launch Template used by the AWS Plugin for Slurm v2
// (resume.py) when it calls CreateFleet to provision burst nodes.
//
// Key launch template settings:
//   - IMDSv2 required (HttpTokens=required): security best practice.
//   - InstanceMetadataTags=enabled: allows the burst node init script to read
//     the EC2 Name tag from IMDS (step 2 in burst-node-init.sh.tpl) to
//     determine SLURM_NODENAME without needing the AWS CLI.
//   - IAM instance profile: burst-node-profile (ec2:DescribeTags + SSM).
//   - Security group: burst-node-sg (VPC-internal only).
//   - UserData: burst-node-init.sh.tpl with ${VAR} substitutions.
//   - Tags: cluster membership tags propagated to burst instances.
//
// The launch template version referenced in partitions.json is "$Latest" so
// any update to this template is automatically picked up by the next burst.
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

// BurstlabBurstConfigProps holds configuration for the launch template construct.
type BurstlabBurstConfigProps struct {
	// ClusterName is the name prefix for the launch template.
	ClusterName string

	// AmiId is the AMI for burst nodes (same CentOS 8 / Slurm AMI).
	AmiId string

	// KeyName is the EC2 key pair for SSH access to burst nodes.
	KeyName string

	// BurstNodeSgId is the security group ID for burst nodes.
	BurstNodeSgId *string

	// BurstNodeInstanceProfileName is the IAM instance profile name for burst nodes.
	BurstNodeInstanceProfileName *string

	// HeadNodePrivateIp is the head node private IP, written to /etc/hosts.
	HeadNodePrivateIp *string

	// EfsDnsName is the EFS DNS name written to /etc/fstab.
	EfsDnsName *string

	// UserDataTemplatePath is the path to burst-node-init.sh.tpl.
	UserDataTemplatePath string
}

// BurstlabBurstConfig is the CDK construct that creates the EC2 launch template
// for burst nodes managed by the AWS Plugin for Slurm v2.
type BurstlabBurstConfig struct {
	constructs.Construct

	// LaunchTemplateId is the ID of the created launch template.
	// Referenced in partitions.json under LaunchTemplateSpecification.
	LaunchTemplateId *string

	// LaunchTemplateName is the human-readable name of the launch template.
	LaunchTemplateName *string
}

// NewBurstlabBurstConfig creates the EC2 launch template for burst nodes.
func NewBurstlabBurstConfig(scope constructs.Construct, id string, props *BurstlabBurstConfigProps) *BurstlabBurstConfig {
	this := &BurstlabBurstConfig{}
	constructs.NewConstruct_Override(this, scope, id)

	cn := props.ClusterName

	userData := buildBurstNodeUserData(props)
	userDataB64 := base64.StdEncoding.EncodeToString([]byte(userData))

	ltName := fmt.Sprintf("%s-burst-node-lt", cn)

	lt := awsec2.NewCfnLaunchTemplate(this, jsii.String("LaunchTemplate"), &awsec2.CfnLaunchTemplateProps{
		LaunchTemplateName: jsii.String(ltName),
		LaunchTemplateData: &awsec2.CfnLaunchTemplate_LaunchTemplateDataProperty{
			ImageId: jsii.String(props.AmiId),

			// Key pair for emergency SSH access to burst nodes.
			KeyName: jsii.String(props.KeyName),

			// IAM instance profile — grants ec2:DescribeTags + SSM access.
			IamInstanceProfile: &awsec2.CfnLaunchTemplate_IamInstanceProfileProperty{
				Name: props.BurstNodeInstanceProfileName,
			},

			// Security group — VPC-internal only (no public ingress).
			SecurityGroupIds: &[]*string{props.BurstNodeSgId},

			// IMDS configuration:
			//   HttpTokens=required: forces IMDSv2 (PUT token before GET).
			//   InstanceMetadataTags=enabled: exposes EC2 tags via IMDS.
			//   The burst node init reads the Name tag to get SLURM_NODENAME.
			MetadataOptions: &awsec2.CfnLaunchTemplate_MetadataOptionsProperty{
				HttpTokens:              jsii.String("required"),
				HttpEndpoint:            jsii.String("enabled"),
				InstanceMetadataTags:    jsii.String("enabled"),
				HttpPutResponseHopLimit: jsii.Number(2),
			},

			// UserData: base64-encoded init script for burst nodes.
			UserData: jsii.String(userDataB64),

			// Tags propagated to the burst node instances and their volumes.
			TagSpecifications: &[]*awsec2.CfnLaunchTemplate_TagSpecificationProperty{
				{
					ResourceType: jsii.String("instance"),
					Tags: &[]*awsec2.CfnTag{
						{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
						{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
						{Key: jsii.String("Cluster"), Value: jsii.String(cn)},
						{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
						{Key: jsii.String("Role"), Value: jsii.String("burst-node")},
					},
				},
				{
					ResourceType: jsii.String("volume"),
					Tags: &[]*awsec2.CfnTag{
						{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
						{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
						{Key: jsii.String("Cluster"), Value: jsii.String(cn)},
						{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
					},
				},
			},
		},
	})

	this.LaunchTemplateId = lt.Ref()
	this.LaunchTemplateName = jsii.String(ltName)

	return this
}

// buildBurstNodeUserData loads and substitutes the burst node UserData template.
func buildBurstNodeUserData(props *BurstlabBurstConfigProps) string {
	templatePath := props.UserDataTemplatePath
	if templatePath == "" {
		templatePath = "../../scripts/userdata/burst-node-init.sh.tpl"
	}

	raw, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Sprintf("#!/bin/bash\necho 'ERROR: could not load burst-node UserData template: %v'\n", err)
	}

	ud := string(raw)

	// Burst node template has no for-loops — only scalar substitutions.
	ud = strings.ReplaceAll(ud, "${head_node_ip}", *props.HeadNodePrivateIp)
	ud = strings.ReplaceAll(ud, "${efs_dns_name}", *props.EfsDnsName)

	return ud
}
