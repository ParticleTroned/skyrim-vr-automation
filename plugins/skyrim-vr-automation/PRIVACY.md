# Privacy

The plugin has no hosted service, account system, telemetry, advertising, or
analytics. Its PowerShell tools operate locally. DevBench communication is
restricted to the loopback endpoint described by the user-supplied runtime
metadata.

The tools can read local configuration, process state, MO2 metadata, SteamVR
settings, profiler samples, and preserved shader-cache files when invoked.
They write only the configured transaction backups, receipts, session evidence,
reports, or per-user configuration requested by the workflow. Nothing is sent
to this project's maintainer.

Automation feedback is stored in a local queue. Reports may contain free text,
local evidence paths, task identifiers, profile context, and sanitized command
parameters. The feedback controller does not transmit them. Explicit export
omits paths and task/session context by default, but every export still requires
review before it is shared.

Codex and GitHub operate under their own privacy terms. Review generated
evidence before sharing it because it may contain local paths or machine names.
