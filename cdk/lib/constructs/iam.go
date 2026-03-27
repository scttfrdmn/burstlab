// =============================================================================
// iam.go — BurstLab IAM construct
//
// Creates IAM roles and instance profiles for:
//   - Head node: needs EC2 Fleet/RunInstances/Terminate for cloud bursting,
//     plus iam:PassRole to attach the burst-node instance profile to instances
//     launched by the plugin.
//   - Burst node: needs ec2:DescribeTags so the init script can read the
//     EC2 Name tag via IMDS to determine SLURM_NODENAME.
//
// Both roles get AmazonSSMManagedInstanceCore so they are reachable via
// AWS Systems Manager Session Manager — useful for debugging without SSH.
//
// Circular dependency note: the head node role's PassRole policy needs the
// burst node role ARN. Because both roles are created in the same construct,
// we reference the burst role's ARN directly without circularity.
// =============================================================================

package constructs

import (
	"encoding/json"
	"fmt"

	"github.com/aws/aws-cdk-go/awscdk/v2/awsiam"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
)

// BurstlabIamProps holds configuration for the IAM construct.
type BurstlabIamProps struct {
	// ClusterName is the name prefix for all IAM resources.
	ClusterName string
}

// BurstlabIam is the CDK construct that creates IAM roles and instance profiles.
type BurstlabIam struct {
	constructs.Construct

	// HeadNodeInstanceProfile is the instance profile attached to the head node.
	HeadNodeInstanceProfile awsiam.CfnInstanceProfile

	// BurstNodeInstanceProfile is the instance profile attached to burst nodes
	// (referenced in the launch template).
	BurstNodeInstanceProfile awsiam.CfnInstanceProfile

	// BurstNodeRoleArn is the ARN of the burst node IAM role.
	// Needed by the head node's PassRole policy and the launch template.
	BurstNodeRoleArn *string
}

// policyDocument builds a minimal IAM policy document JSON string.
type policyDoc struct {
	Version   string        `json:"Version"`
	Statement []policyStmt  `json:"Statement"`
}

type policyStmt struct {
	Effect   string   `json:"Effect"`
	Action   []string `json:"Action"`
	Resource string   `json:"Resource"`
}

// NewBurstlabIam creates IAM roles and instance profiles for BurstLab.
func NewBurstlabIam(scope constructs.Construct, id string, props *BurstlabIamProps) *BurstlabIam {
	this := &BurstlabIam{}
	constructs.NewConstruct_Override(this, scope, id)

	cn := props.ClusterName

	// Trust policy — allows EC2 instances to assume the role.
	ec2TrustPolicy := map[string]interface{}{
		"Version": "2012-10-17",
		"Statement": []map[string]interface{}{
			{
				"Effect": "Allow",
				"Principal": map[string]interface{}{
					"Service": "ec2.amazonaws.com",
				},
				"Action": "sts:AssumeRole",
			},
		},
	}
	trustPolicyJSON, _ := json.Marshal(ec2TrustPolicy)

	// -------------------------------------------------------------------------
	// Burst node role (created first so its ARN can be referenced by head role)
	// -------------------------------------------------------------------------
	// The burst node only needs to read its own EC2 tags via IMDS. The Name tag
	// set by resume.py is the SLURM_NODENAME — without it the node cannot
	// register with slurmctld.
	burstNodeRole := awsiam.NewCfnRole(this, jsii.String("BurstNodeRole"), &awsiam.CfnRoleProps{
		RoleName:                 jsii.String(fmt.Sprintf("%s-burst-node-role", cn)),
		AssumeRolePolicyDocument: jsii.String(string(trustPolicyJSON)),
		ManagedPolicyArns: &[]*string{
			jsii.String("arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"),
		},
		Policies: &[]*awsiam.CfnRole_PolicyProperty{
			{
				PolicyName: jsii.String(fmt.Sprintf("%s-burst-node-policy", cn)),
				PolicyDocument: jsii.String(mustMarshal(policyDoc{
					Version: "2012-10-17",
					Statement: []policyStmt{
						{
							// ec2:DescribeTags — needed so the init script can read
							// the EC2 Name tag via the IMDS tags endpoint to determine
							// the Slurm node name (SLURM_NODENAME).
							Effect:   "Allow",
							Action:   []string{"ec2:DescribeTags"},
							Resource: "*",
						},
					},
				})),
			},
		},
		Tags: &[]*awsiam.CfnTag{
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})
	this.BurstNodeRoleArn = burstNodeRole.AttrArn()

	burstNodeProfile := awsiam.NewCfnInstanceProfile(this, jsii.String("BurstNodeInstanceProfile"), &awsiam.CfnInstanceProfileProps{
		InstanceProfileName: jsii.String(fmt.Sprintf("%s-burst-node-profile", cn)),
		Roles:               &[]*string{jsii.String(fmt.Sprintf("%s-burst-node-role", cn))},
	})
	burstNodeProfile.AddDependency(burstNodeRole)
	this.BurstNodeInstanceProfile = burstNodeProfile

	// -------------------------------------------------------------------------
	// Head node role
	// -------------------------------------------------------------------------
	// The head node runs the AWS Plugin for Slurm v2 (resume.py / suspend.py).
	// resume.py calls ec2:CreateFleet (or ec2:RunInstances) to launch burst
	// nodes, attaches the burst-node instance profile, and tags instances.
	// suspend.py calls ec2:TerminateInstances.
	//
	// iam:PassRole scoped to the burst node role ARN: required so EC2 Fleet
	// can attach the burst-node instance profile without privilege escalation.
	headNodeRole := awsiam.NewCfnRole(this, jsii.String("HeadNodeRole"), &awsiam.CfnRoleProps{
		RoleName:                 jsii.String(fmt.Sprintf("%s-head-node-role", cn)),
		AssumeRolePolicyDocument: jsii.String(string(trustPolicyJSON)),
		ManagedPolicyArns: &[]*string{
			jsii.String("arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"),
		},
		Policies: &[]*awsiam.CfnRole_PolicyProperty{
			{
				PolicyName: jsii.String(fmt.Sprintf("%s-head-node-policy", cn)),
				PolicyDocument: jsii.String(mustMarshal(map[string]interface{}{
					"Version": "2012-10-17",
					"Statement": []map[string]interface{}{
						{
							// EC2 Fleet and direct RunInstances for burst node launch.
							"Effect": "Allow",
							"Action": []string{
								"ec2:CreateFleet",
								"ec2:RunInstances",
								"ec2:TerminateInstances",
								"ec2:CreateTags",
								"ec2:DescribeInstances",
								"ec2:DescribeInstanceStatus",
								"ec2:ModifyInstanceAttribute",
								"ec2:DescribeInstanceTypes",
								"ec2:DescribeLaunchTemplates",
								"ec2:DescribeLaunchTemplateVersions",
							},
							"Resource": "*",
						},
						{
							// iam:CreateServiceLinkedRole — EC2 Fleet requires this the
							// first time it is called in an account/region.
							"Effect":   "Allow",
							"Action":   []string{"iam:CreateServiceLinkedRole"},
							"Resource": "arn:aws:iam::*:role/aws-service-role/ec2fleet.amazonaws.com/*",
						},
						{
							// iam:PassRole — scoped to the burst node role so the head
							// node can attach it to instances launched by the plugin.
							"Effect":   "Allow",
							"Action":   []string{"iam:PassRole"},
							"Resource": burstNodeRole.AttrArn(),
						},
					},
				})),
			},
		},
		Tags: &[]*awsiam.CfnTag{
			{Key: jsii.String("Project"), Value: jsii.String("burstlab")},
			{Key: jsii.String("Generation"), Value: jsii.String("gen1")},
			{Key: jsii.String("ManagedBy"), Value: jsii.String("cdk")},
		},
	})

	headNodeProfile := awsiam.NewCfnInstanceProfile(this, jsii.String("HeadNodeInstanceProfile"), &awsiam.CfnInstanceProfileProps{
		InstanceProfileName: jsii.String(fmt.Sprintf("%s-head-node-profile", cn)),
		Roles:               &[]*string{jsii.String(fmt.Sprintf("%s-head-node-role", cn))},
	})
	headNodeProfile.AddDependency(headNodeRole)
	this.HeadNodeInstanceProfile = headNodeProfile

	return this
}

// mustMarshal serialises v to JSON and panics on error.
// Used only with static data structures that are known-good.
func mustMarshal(v interface{}) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(fmt.Sprintf("iam: mustMarshal: %v", err))
	}
	return string(b)
}
