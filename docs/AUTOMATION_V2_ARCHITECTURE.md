# Helper System Automation v2 — Architecture Baseline

Date: 2026-09-23

## Goal

Turn Helper System into the personal control center for AgentChayanun:

iPhone/PWA <-> Helper System/Supabase <-> AgentChayanun on Windows <-> work systems

The user should not need to manually tell the agent every step. Scheduled workflows should start automatically, pause only at explicit human gates such as ThaiD/OTP/approval, and resume automatically after the gate is satisfied.

## Verified production baseline

- Live site: https://amazing-maamoul-a50664.netlify.app/
- Live index.html matches the local tracked index.html after normalizing line endings and the comment Netlify injects.
- Git branch: main
- HEAD: 5c44d71f740e54b2bf992069d55c2fc64c647eea
- HEAD subject: เพิ่มกล่องตรวจงานใหม่จากระบบสารบัญ
- Frontend is a static single-page index.html hosted by Netlify.
- Supabase JS v2 is loaded directly in the browser.
- Supabase table `tasks` is the current frontend data source.
- Supabase Storage bucket `attachments` is used for task attachments.
- Existing status values include active/completed plus inbox/rejected for documents coming from the document-registry workflow.
- Existing inbox UI already supports confirm -> active and reject -> rejected.
- Existing AI Superbot supports remote AI keys and Local Qwen/Ollama with a Supabase-hosted tunnel URL.
- No PWA manifest or service worker currently exists.
- Google Apps Script files are present; the current frontend CRUD path is Supabase, while GAS should be treated as legacy/auxiliary until separately proven active.
- gas-smart-notification.js contains Morning Brief / Evening Summary logic but also contains a LINE Notify path that is obsolete.

## Important security baseline

The current supabase-setup.sql grants public RLS policies for select/insert/update/delete on tasks and public storage operations on attachments.

Before adding iPhone remote-control actions or Agent commands:
1. Add Supabase Auth.
2. Restrict tasks and automation tables to the owner's authenticated user.
3. Restrict Storage to the owner's authenticated user.
4. Keep service-role credentials server-side only.
5. Never commit local AI/API key files.
6. Separate read-only monitoring permissions from mutation/approval permissions.

## Reuse from AgentChayanun

Do not build a second agent engine.

Existing AgentChayanun runtime already contains production composition for:
- MCP HTTP server
- durable goal/task persistence
- ScheduledContinuationService
- GoalMutationFenceService
- CodingTaskMonitorService
- BoundedMonitorService / runtime coordinator
- Windows capabilities and native notifications

Integration should therefore be an adapter/control-plane layer rather than a new automation runtime.

## Target data model

Keep `tasks` for human work items and add dedicated automation/control-plane entities:

- automation_jobs
  - id
  - name
  - workflow_key
  - enabled
  - schedule
  - timezone
  - next_run_at
  - missed_run_policy
  - approval_policy

- agent_runs
  - id
  - automation_job_id
  - agent_id
  - state
  - current_step
  - progress
  - started_at
  - heartbeat_at
  - completed_at
  - result_summary
  - error_code
  - retry_count

- human_gates
  - id
  - run_id
  - gate_type
  - state
  - message
  - created_at
  - satisfied_at

- agent_status
  - agent_id
  - online
  - version
  - last_seen_at
  - current_run_id

- notifications
  - id
  - severity
  - title
  - body
  - run_id
  - read_at

## Run state machine

SCHEDULED
-> STARTING
-> RUNNING
-> WAITING_FOR_HUMAN (ThaiD / OTP / explicit approval)
-> RUNNING
-> COMPLETED

Failure path:
RUNNING -> RETRYING -> RUNNING
RUNNING -> RECOVERING -> RUNNING
RUNNING -> NEEDS_USER
RUNNING -> FAILED

Rules:
- Every run has a unique run id.
- Workflows must be idempotent.
- Restart recovery resumes from durable state.
- The agent must never require the user to type "continue" after a satisfied human gate.
- High-impact actions remain explicitly approval-gated.

## Initial workflow

JOB-001: Morning document registry

1. Schedule starts the run.
2. Agent opens/checks the document registry.
3. If authentication is still valid, continue.
4. If ThaiD is required:
   - set run state WAITING_FOR_HUMAN
   - show the ThaiD page
   - notify the user
   - detect successful login and resume automatically
5. Detect documents not previously processed.
6. Download the source document and attachments.
7. Extract/summarize metadata.
8. Create Helper System items with status inbox.
9. User can confirm/reject in Helper System.
10. Finish the run with counts and a summary.

## Implementation order

1. Security baseline: Auth + RLS design/migration + secret hygiene.
2. Mobile/PWA shell: manifest, service worker, installable iPhone UI.
3. Automation schema and run-state UI.
4. AgentChayanun adapter using existing HTTP MCP/runtime services.
5. Scheduler and restart/missed-run policy.
6. Human gate / ThaiD resume mechanism.
7. JOB-001 end-to-end acceptance with a safe test target first.
8. Production document-registry workflow.
9. Push notifications and iPhone approvals.
10. Extend to HDC, KPI, PMQA, meeting preparation, morning/evening briefs.
