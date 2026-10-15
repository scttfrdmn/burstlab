#!/bin/bash
# =============================================================================
# push-config.sh — run apply-config.sh on the head node via SSM Run Command
#
# Called by Terraform (null_resource.config_push in each generation root) on the
# machine running `terraform apply`, whenever the rendered configs change. Uses
# SSM rather than SSH so no key path is needed in the generation root: the head
# node role already has AmazonSSMManagedInstanceCore and s3:GetObject on the
# scripts bucket.
#
# Required env: INSTANCE_ID, REGION, BUCKET. AWS_PROFILE is honoured if set.
# =============================================================================

set -euo pipefail

: "${INSTANCE_ID:?}" "${REGION:?}" "${BUCKET:?}"

# On first apply the instance has only just launched. Its init writes the same
# configs, so there is nothing to push until SSM sees it online.
PING=$(aws ssm describe-instance-information --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
if [ "$PING" != "Online" ]; then
  echo "config push: head node $INSTANCE_ID not online in SSM yet (first apply?) — init applies this config itself; skipping."
  exit 0
fi

CMD="aws s3 cp --quiet --region $REGION s3://$BUCKET/apply-config.sh /tmp/burstlab-apply-config.sh && bash /tmp/burstlab-apply-config.sh $BUCKET $REGION"
CMD_ID=$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "BurstLab config push" \
  --parameters "{\"commands\":[\"$CMD\"]}" \
  --query 'Command.CommandId' --output text)
echo "config push: SSM command $CMD_ID sent to $INSTANCE_ID"

# Poll (up to 5 min) rather than `aws ssm wait`, whose ~100 s cap is too short
# when slurmctld is slow to restart.
STATUS=Pending
for _ in $(seq 1 60); do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
done

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null || true

if [ "$STATUS" != "Success" ]; then
  echo "config push: FAILED (status $STATUS). The head node restored its previous config if it got that far." >&2
  exit 1
fi
echo "config push: applied."
