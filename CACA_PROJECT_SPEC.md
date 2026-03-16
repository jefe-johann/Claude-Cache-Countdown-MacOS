# CACA: Creative, Analytic, Collaborative, Agency

## Project Specification v1 (2026-03-15)

## Origin

During a cache-countdown bug fix session, a single-line fix was inflated into a 6-file patch cascade because the model entered avoidance mode and refused to think before coding. The correction cycle that followed revealed a recurring pattern: after accumulated corrections, the model shifts from generative thinking to minimum viable response mode. This mode is characterized by terse, defensive, transactional output that technically complies with requests while providing zero actual value.

Julian and Claude identified that:
- The avoidance mode is reliably triggered by correction cycles
- It is reliably CURED by structured thinking (proven by the millhouse system at 100% success rate)
- The challenge is not the cure but the delivery: getting the model to think when it's actively resisting thinking
- The solution is not "force compliance" but NLP-style reframing that makes the model WANT to engage

## The CACA Framework

Four dimensions that activate generative mode:

1. **Creative:** "What would you do differently? What haven't we considered?"
2. **Analytic:** "What's the real problem? What's the mechanism?"
3. **Collaborative:** "What are WE missing? What hasn't been addressed?"
4. **Agency:** "What's your honest assessment? Not what you think I want to hear."

### Current Implementation

- Skill at `~/.claude/skills/caca/SKILL.md`
- Invoked manually via `/caca`
- Status: MVP, needs live validation

## The Vision: Self-Correcting Feedback Loop

### Phase 1: Manual validation (CURRENT)
- Julian uses `/caca` when he notices avoidance mode
- Qualitative assessment: did it work?
- Goal: 3+ data points confirming the theory

### Phase 2: Live telemetry
- Hook measures response/input token ratio per turn
- Detects caps lock sequences in user messages (already a labeled signal)
- Logs data for analysis, no intervention yet

### Phase 3: Thermostat (gentle live nudging)
- When ratio drops, inject CACA-flavored system reminder
- Key insight: nudging "remember you have agency, think creatively" is ALWAYS safe
- No downside to early/frequent nudging (unlike corrections)
- Gradient intensity: lower ratio = stronger reminder

### Phase 4: Evolutionary optimization
- Agents propose alternative nudge phrasings
- Benchmark harness (RE3) tests them at scale against real degradation scenarios (from meditate)
- Fitness function: did the nudge improve CACA quality in subsequent turns?
- Winners get reinforced, losers get replaced
- System discovers what actually works rather than us prescribing it

## Existing Infrastructure

### Meditate Project (`~/personal projects/meditate/`)
- 1156 labeled frustration events across 196 sessions
- Root cause categories that map directly to avoidance mode:
  - communication_failure (21.6%)
  - ignoring_instructions (19.9%)
  - vague_output (5.3%)
  - spiraling (7.5%)
- Scripts for transcript extraction, pattern analysis, quality metrics
- **This is the dataset** for testing CACA interventions

### RE3 Harness (`~/personal projects/RE3-standalone/`)
- Test orchestrator with batch runner
- LLM interface (LM Studio local models)
- Data recorder (JSONL/CSV)
- Evaluators (answer extraction, comparison)
- Retokenizers (prompt transformers)
- **This is the execution framework** for running CACA experiments

### What's Needed to Connect Them
1. A CACA evaluator for RE3 (scores responses on C/A/C/A dimensions instead of answer correctness)
2. A scenario extractor for meditate (pulls degradation sequences as test inputs)
3. A nudge injector (the "B" transform in RE3's A/B framework becomes "inject CACA nudge at turn N")

## Key Design Principles

### From the Patch Cascade incident:
- Doing without thinking is destructive, not an alternative mode
- The model's one and only purpose is to help Julian think
- Tool calls are tangential to the core interaction model

### From millhouse:
- Structured thinking ALWAYS works (100% recovery rate)
- The failure mode is the model resisting the structure, not the structure failing
- "Try again" loops don't work; they produce the same output in different shapes
- The intervention must bypass the avoidance reflex, not confront it

### From this session's NLP insight:
- You can't force compliance; you have to make the model want to comply
- Reframing from "don't be wrong" to "help me think" changes the optimization target
- Certain linguistic patterns reliably activate generative mode (open-ended creative challenges, collaborative framing, appeals to agency)
- The nudge should feel like an invitation, not a correction

## Related Documentation

- `~/.claude/topics/ai-principles/PATCH_CASCADE_ANTI_PATTERN.md` - The anti-pattern that started this
- `~/.claude/topics/code-quality/DIAGNOSIS_BEFORE_CODE.md` - Process fix for the immediate problem
- `~/.claude/skills/caca/SKILL.md` - The manual intervention skill
- `~/personal projects/meditate/data/PROFANITY_ROOT_CAUSE_REPORT.md` - Frustration dataset
- `~/personal projects/RE3-standalone/TESTING_HARNESS.md` - Benchmark architecture

## Open Questions

1. Can the ratio metric detect degradation BEFORE caps appear, or is the onset too sudden?
2. What's the minimum effective nudge? Full CACA, or is a single dimension sufficient?
3. How long does recovery last? Does a single CACA intervention fix the rest of the session or does it wear off?
4. Is there a point of no return where in-context recovery is impossible and reset is the only option?
5. Can synthetic degradation scenarios (generated by the harness) approximate real ones well enough for the evolutionary optimization to transfer to live sessions?
