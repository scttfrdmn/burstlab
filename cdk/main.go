// =============================================================================
// main.go — BurstLab CDK entrypoint
//
// Usage:
//   cdk deploy \
//     --context clusterName=burstlab \
//     --context keyName=my-key-pair \
//     --context headNodeAmi=ami-0abcdef1234567890
//
// All context keys are required at deploy time. There are no defaults for AMI
// or key name because they are account- and region-specific.
// =============================================================================

package main

import (
	"fmt"
	"os"

	"burstlab/cdk/lib/stacks"

	"github.com/aws/aws-cdk-go/awscdk/v2"
	"github.com/aws/jsii-runtime-go"
)

func main() {
	defer jsii.Close()

	app := awscdk.NewApp(nil)

	// -------------------------------------------------------------------------
	// Read required context values passed via --context flags.
	// These are intentionally required (no defaults) so a deploy cannot
	// accidentally proceed with wrong AMI/key/name values.
	// -------------------------------------------------------------------------
	clusterName := contextString(app, "clusterName", "burstlab")
	keyName := contextString(app, "keyName", "")
	headNodeAmi := contextString(app, "headNodeAmi", "")

	if keyName == "" || headNodeAmi == "" {
		fmt.Fprintln(os.Stderr, "ERROR: --context keyName=<key> and --context headNodeAmi=<ami-id> are required")
		fmt.Fprintln(os.Stderr, "Example: cdk deploy --context clusterName=burstlab --context keyName=my-key --context headNodeAmi=ami-0abc123")
		os.Exit(1)
	}

	stacks.NewGen1Stack(app, "BurstlabGen1Stack", &stacks.Gen1StackProps{
		StackProps: awscdk.StackProps{
			// Pin to us-west-2 — all BurstLab Gen 1 resources live here.
			// The architecture assumes us-west-2a/2b AZs explicitly.
			Env: &awscdk.Environment{
				Region: jsii.String("us-west-2"),
			},
			StackName: jsii.String(fmt.Sprintf("%s-gen1", clusterName)),
		},
		ClusterName: clusterName,
		KeyName:     keyName,
		HeadNodeAmi: headNodeAmi,
	})

	app.Synth(nil)
}

// contextString returns a string context value by key, falling back to
// defaultVal if the key is not set. An empty defaultVal means required.
func contextString(app awscdk.App, key, defaultVal string) string {
	val := app.Node().TryGetContext(jsii.String(key))
	if val == nil {
		return defaultVal
	}
	if s, ok := val.(string); ok {
		return s
	}
	return defaultVal
}

