# Security policy for SSIS-ADF-Modernization

## Supported versions

Only the latest commit on `main` is supported. Fixes are made there; older copies are not patched separately.

## Reporting a vulnerability

This repository is private, so GitHub's private vulnerability reporting is not available for it. Report a security problem to the repository owner directly rather than in an issue, which every collaborator can read. Describe the problem, the affected script, how to reproduce it, and what an attacker could gain.

Never include a generated sprint backlog, an assessment workbook, a connection string or a password in a report: they contain real server names or credentials.

## What to expect

There is no guaranteed response time. Reports are read and answered as soon as possible, and you will be told when a fix is merged.

## What counts as a security problem

Anything that lets the code expose data or a secret, change a server it was not asked to change, or run something it was not asked to run. The project's design already commits to the following, and a way around any of them is a security problem:

- The assessment never changes a server; the deploy script changes SSISDB only on a server you confirm as Development.
- Connection-string passwords are masked and sensitive SSISDB variables are never logged. The routing test fails if a planted secret appears in any output file.
- Generated backlogs and workbooks are never committed.

## Out of scope

- Vulnerabilities in SQL Server or Windows themselves: report them to Microsoft through the [Microsoft Security Response Center](https://msrc.microsoft.com/report).
