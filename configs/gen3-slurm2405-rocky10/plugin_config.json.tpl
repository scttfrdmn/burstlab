{
  "_comment": "AWS Plugin for Slurm v2 — config.json for BurstLab Gen 3",
  "_comment2": "SlurmConf values MUST match slurm.conf exactly. common.py validates them on startup.",

  "LogLevel": "INFO",
  "LogFileName": "/var/log/slurm/aws_plugin.log",

  "SlurmBinPath": "/opt/slurm/bin",

  "SlurmConf": {
    "PrivateData": "CLOUD",
    "ResumeProgram": "/opt/slurm/etc/aws/resume.py",
    "SuspendProgram": "/opt/slurm/etc/aws/suspend.py",
    "ResumeRate": 100,
    "SuspendRate": 100,
    "ResumeTimeout": 600,
    "SuspendTime": 650,
    "TreeWidth": 60000
  }
}
