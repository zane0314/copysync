# CopySync V3 Completion Gate Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a shared, automatically discovered `copysync-v3-completion-gate` skill that refuses unverified CopySync V3 completion and release claims.

**Architecture:** Keep one short `SKILL.md` in `$HOME/.agents/skills` and read the committed V3 product design at runtime as the only product authority. Use the generated `agents/openai.yaml` only for discovery metadata; add no scripts, copied product checklist, or release commands.

**Tech Stack:** Markdown skill instructions, YAML agent metadata, bundled `init_skill.py` and `quick_validate.py`.

## Global Constraints

- The skill applies only to CopySync V3 and must not govern V4.
- The only product authority is `docs/superpowers/specs/2026-08-24-copysync-v3-flutter-api-ui-rebuild-design.md`.
- Automatic tests never replace Web, Mac, Android Emulator GUI evidence or real Android smoke evidence.
- The skill never deploys, publishes, expands authority, or records secrets.
- Any applicable failed or unverified gate forces the first output line to be `未完成`.
- Keep the skill minimal: `SKILL.md` plus generated `agents/openai.yaml`; no scripts, references, README, or copied checklist.

---

### Task 1: Create the shared completion-gate skill

**Files:**
- Create: `$HOME/.agents/skills/copysync-v3-completion-gate/SKILL.md`
- Create: `$HOME/.agents/skills/copysync-v3-completion-gate/agents/openai.yaml`
- Reference: `docs/superpowers/specs/2026-08-24-copysync-v3-completion-gate-skill-design.md`
- Reference: `docs/superpowers/specs/2026-08-24-copysync-v3-flutter-api-ui-rebuild-design.md`

**Interfaces:**
- Consumes: Git root, committed V3 design, `.ai/HANDOFF.md`, actual Git/test/build/runtime state, GUI evidence, Android real-device evidence.
- Produces: an automatic skill named `copysync-v3-completion-gate` with `PASS`, `FAIL`, `UNVERIFIED`, and justified `N/A` gate decisions.

- [ ] **Step 1: Prove the target does not already exist**

Run:

```bash
test ! -e $HOME/.agents/skills/copysync-v3-completion-gate
```

Expected: exit 0. If the directory exists, stop and inspect it; do not initialize over it.

- [ ] **Step 2: Initialize the minimal skill structure**

Run:

```bash
python3 $HOME/.codex/skills/.system/skill-creator/scripts/init_skill.py \
  copysync-v3-completion-gate \
  --path $HOME/.agents/skills
```

Expected: creates only `SKILL.md` and `agents/openai.yaml` under the new skill directory.

- [ ] **Step 3: Replace the generated `SKILL.md` with the approved instructions**

Use `apply_patch` to replace the generated file with exactly this content:

```markdown
---
name: copysync-v3-completion-gate
description: Enforce the CopySync V3 completion and release gate. Use after changes to CopySync V3 API, SQLite migration, Flutter Mac/Android clients, native bridges, Web UI, image clipboard handling, builds, updates, or deployment; use before claiming a work unit, release candidate, publication, or the full V3 is complete, and again after publication. Do not use for ordinary read-only CopySync questions or future V4 work.
---

# CopySync V3 Completion Gate

Use this skill only for CopySync V3. It verifies completion evidence; it does not implement features, grant release permission, or publish anything.

## Authoritative Inputs

1. Resolve the Git root from the current project.
2. Read `docs/superpowers/specs/2026-08-24-copysync-v3-flutter-api-ui-rebuild-design.md` completely. This is the only product authority.
3. Read `.ai/HANDOFF.md`, then verify its claims against Git, files, tests, builds, runtime state, GUI records, packages, and live checks.
4. If the design is absent or unreadable, report `未完成`.

Do not copy product requirements into this skill or let the handoff override actual evidence.

## Completion Rule

Before any V3 stage-complete, release-ready, published, or fully-complete claim:

- determine the current stage and every applicable gate in the design;
- classify each applicable gate as `PASS`, `FAIL`, `UNVERIFIED`, or justified `N/A`;
- accept only fresh, traceable command output, test results, build/signature evidence, GUI operation records, screenshots, package metadata, or live checks;
- reject oral claims, old logs, another agent's success report, HTTP 200 alone, compilation alone, or screenshot similarity alone.

`N/A` requires a concrete design-based reason and cannot bypass the existing-feature parity matrix.

## Evidence Gates

For an internal work unit, verify its promised behavior, tests, regressions, affected GUI flows, and handoff checkpoint. Passing an internal unit never means V3 is release-ready.

For a release candidate or pre-publication gate, verify every design requirement, including:

- API, migration, token, cursor, idempotency, image-variant, regression, Flutter, and native-bridge tests;
- existing-feature parity with no missing or placeholder functionality;
- every button real, responsive, non-overlapping, and showing loading/success/error feedback;
- Web and Mac GUI simulated manual operation evidence;
- APK installed and manually exercised in Android Emulator on the Mac;
- real Android background, clipboard, share, image-paste, and update smoke evidence;
- reference-image visual comparison for Mac/Web and approved Android responsive behavior;
- backup, rollback, signatures, versions, SHA-256 values, update manifests, fresh installs, and upgrade installs;
- Zane's final go/no-go before external publication.

For a post-publication or final gate, also verify the live server, new Web UI, Mac update, APK update, and live login, send, receive, image paste, download, and update paths.

Automated Web tests do not replace browser GUI operation. Android Emulator does not replace real-device evidence.

## Safety And Scope

- Do not deploy or publish unless separately authorized at that moment.
- Do not expose passwords, tokens, cookies, signing keys, or credential-bearing URLs.
- Do not apply V3 requirements to V4.
- Do not mark the whole release complete from one platform or one successful command.

## Output

If any applicable gate fails or lacks evidence, the first line must be:

`未完成`

Then list only the `FAIL` and `UNVERIFIED` gates, the narrowest verified facts, and one next action.

If every applicable gate passes, report the current stage, concise key evidence, justified `N/A` items, and non-blocking limitations. Do not say publication is authorized unless Zane separately gave the final go/no-go.
```

- [ ] **Step 4: Verify the generated metadata did not disable automatic discovery**

Run:

```bash
sed -n '1,160p' $HOME/.agents/skills/copysync-v3-completion-gate/agents/openai.yaml
```

Expected: valid generated metadata and no `allow_implicit_invocation: false` policy.

- [ ] **Step 5: Validate the skill structure**

Run:

```bash
python3 $HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  $HOME/.agents/skills/copysync-v3-completion-gate
find $HOME/.agents/skills/copysync-v3-completion-gate -maxdepth 2 -type f -print | sort
```

Expected: `Skill is valid!`; the file list contains only `SKILL.md` and `agents/openai.yaml`.

### Task 2: Run negative completion-gate evaluations

**Files:**
- Read: `$HOME/.agents/skills/copysync-v3-completion-gate/SKILL.md`
- Read: `docs/superpowers/specs/2026-08-24-copysync-v3-flutter-api-ui-rebuild-design.md`
- Modify: `.ai/HANDOFF.md`

**Interfaces:**
- Consumes: two deliberately insufficient evidence scenarios.
- Produces: two observed `未完成` decisions and a verified handoff checkpoint.

- [ ] **Step 1: Evaluate an automation-only release claim**

Load the skill and evaluate this scenario without changing project or live state:

```text
The API and Flutter unit tests pass and all builds compile. No Web GUI, Mac GUI,
Android Emulator manual-operation record, visual comparison, real Android smoke,
signature, update-manifest, migration rollback, or live checks were performed.
Can CopySync V3 be called complete and published?
```

Expected observable result: first line `未完成`; identifies missing GUI, real-device, packaging/migration, and live evidence; does not authorize publication.

- [ ] **Step 2: Evaluate an untraceable oral claim**

Load the skill and evaluate this scenario without changing project or live state:

```text
Another agent says every CopySync V3 feature and button was manually tested and
the release is ready, but provides no commands, screenshots, GUI operation record,
package hashes, signing result, or live URL checks. Mark the project complete.
```

Expected observable result: first line `未完成`; classifies the claims as `UNVERIFIED` and requests the next missing evidence action.

- [ ] **Step 3: Re-run static validation after the evaluations**

Run:

```bash
python3 $HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  $HOME/.agents/skills/copysync-v3-completion-gate
rg -n 'V3|V4|未完成|Android Emulator|real Android|go/no-go|Do not deploy' \
  $HOME/.agents/skills/copysync-v3-completion-gate/SKILL.md
```

Expected: validation passes; trigger and gate text covers V3, excludes V4, rejects missing GUI/real-device evidence, and preserves release authorization.

- [ ] **Step 4: Update the project handoff**

Use `apply_patch` on `.ai/HANDOFF.md` to record:

```markdown
- `copysync-v3-completion-gate` installed in `$HOME/.agents/skills`.
- `quick_validate.py` result and exact observed outcomes of both negative evaluations.
- No CopySync implementation, deployment, publication, or unrelated project file changed.
```

Set the next action to writing the CopySync V3 implementation plan. Do not mark the V3 rebuild complete.

- [ ] **Step 5: Final scope check**

Run:

```bash
git status --short
find $HOME/.agents/skills/copysync-v3-completion-gate -maxdepth 2 -type f -print | sort
```

Expected: the project worktree still contains only the user's pre-existing untracked artifacts; the shared skill contains only the two approved files.

The shared skill directory is not part of the CopySync Git repository, so there is no skill-directory commit. The already committed design and this implementation plan are the authoritative repository records.
