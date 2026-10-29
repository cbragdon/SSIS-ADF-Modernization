# SSIS assessment batch orchestration

Copy `config\assessment-targets.example.json` outside the repository, add real private targets, and validate it before execution:

```powershell
.\scripts\orchestration\01_Invoke-SsisAssessmentBatch.ps1 -ConfigPath 'D:\Private\assessment-targets.json' -ValidateOnly
```

The batch runs each target in isolation and writes summary CSV, JSON, and Markdown under the configured output root. A required target marked `Production` blocks the batch if its assessment fails or reports errors.
