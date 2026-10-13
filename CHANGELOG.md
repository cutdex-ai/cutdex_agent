# Changelog

## 0.2.0 — 2026-10-13

### Added

- Model-directed child and grandchild agents, with durable messages, task continuation, waiting, interruption and result delivery to the parent.
- Persistent user decisions for conflicting goals, including resuming the same run after a choice or free-text answer.
- Local resource commit guards and durable remote write leases, with online authorization and cancellation admission checks to reject stale agent writes.
- `SKILL.md` YAML front matter parsing and automatic directory scanning through `DirectorySkillProvider`.
- Summary-first skill discovery through `list_skills` and `load_skill`. Activation checks input budgets and required tools; instructions survive history compaction and session restart.
- Offline and environment-configured live skill examples, editing/color selection checks, and single-level and nested-agent validation with actual FFmpeg media processing.
- Regression coverage for skill leakage, incorrect result aggregation, resource conflicts, cancellation, service crashes and recovery.

### Fixed

- Cancellation now propagates synchronously through active child and grandchild agent trees.
- Service references remain compatible with Dart SDK flow analysis.

### Validation and scope

- 392 local tests passed, with clean static analysis and formatting.
- The live nested-agent media scenario passed 42 checks across 28 model requests: workers selected only their relevant skill, both result handoffs were verified, and the final video preserved audio while applying the requested duration, exposure and white balance.
- Media validation uses synthetic source footage and actual file processing. FFmpeg and ffprobe are required for media tests; live model checks run explicitly with host-provided configuration.
- Requires Dart `^3.12.0`. Distribution remains through GitHub Releases and Git dependencies; `publish_to: none` is retained.
