{
  "_comment": "AWS Plugin for Slurm v2 — config.json for BurstLab Gen 1",
  "_comment2": "Values under SlurmConf MUST match slurm.conf exactly. common.py validates them.",

  "LogLevel": "INFO",
  "LogFileName": "/var/log/slurm/aws_plugin.log",

  "SlurmBinPath": "/opt/slurm/bin",

  "SlurmConf": {
    "PrivateData": "CLOUD",
    "ResumeProgram": "/opt/slurm/etc/aws/resume.py",
    "SuspendProgram": "/opt/slurm/etc/aws/suspend.py",
    "ResumeRate": 100,
    "SuspendRate": 100,
    "ResumeTimeout": 300,
    "SuspendTime": 350,
    "TreeWidth": 60000
  }
}
