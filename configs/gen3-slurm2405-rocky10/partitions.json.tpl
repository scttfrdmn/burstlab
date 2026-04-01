{
  "_comment": "AWS Plugin for Slurm v2 — partitions.json for BurstLab Gen 3",
  "_comment2": "IMPORTANT: PartitionName and NodeGroupName must match ^[a-zA-Z0-9]+$ (no hyphens/underscores). Node names will be: {PartitionName}-{NodeGroupName}-{index} => aws-burst-0 through aws-burst-N",

  "Partitions": [
    {
      "PartitionName": "aws",
      "NodeGroups": [
        {
          "NodeGroupName": "burst",
          "MaxNodes": ${max_burst_nodes},
          "Region": "${aws_region}",

          "SlurmSpecifications": {
            "CPUs": "8",
            "RealMemory": "31000",
            "Weight": "1",
            "State": "CLOUD"
          },

          "PurchasingOption": "on-demand",
          "OnDemandOptions": {
            "AllocationStrategy": "lowest-price"
          },

          "LaunchTemplateSpecification": {
            "LaunchTemplateId": "${launch_template_id}",
            "Version": "$Latest"
          },

          "LaunchTemplateOverrides": [
            { "InstanceType": "${burst_instance_type}" }
          ],

          "SubnetIds": [
            "${cloud_subnet_a_id}",
            "${cloud_subnet_b_id}"
          ],

          "Tags": [
            { "Key": "Project",    "Value": "burstlab" },
            { "Key": "Generation", "Value": "gen3" },
            { "Key": "Cluster",    "Value": "${cluster_name}" }
          ]
        }
      ],

      "PartitionOptions": {
        "Default": "No",
        "MaxTime": "4:00:00",
        "State": "UP"
      }
    }
  ]
}
