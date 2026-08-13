# openzl-agent

AI agent that makes OpenZL's format-aware compression usable by people with zero
compression expertise: point it at data → it infers structure, writes SDDL, trains a
compressor via `zli train`, benchmarks vs zstd/gzip, returns a `.zlc` + savings report.

Owner: Harshit (GitHub: `avionicharshit-byte`, email avionicharshit@gmail.com). Uses Zed.

## Why this exists (validated context — don't re-research)

- OpenZL (https://openzl.org, Meta, OSS Oct 2025) compresses structured data ~2x better
  than zstd by decomposing it into typed streams. Universal decompressor — no lock-in.
- Its adoption barrier: users must describe their data's structure (SDDL language, or a
  C++ parser). This is the most-discussed obstacle in community threads (HN 45492803,
  LWN https://lwn.net/Articles/1053018/, encode.su thread 4439).
- Yann Collet (creator) says LLM-written SDDL "actually works". Meta ships an
  LLM-targeted SDDL spec: https://openzl.org/sddl/north-star/sddl-for-llm/
  (repo: doc/mkdocs/doc/sddl/north-star/sddl-for-llm.md). NOTE: old URL
  /sddl/sddl-for-llm/ 404s — docs moved under /north-star/.
- Nobody has shipped the agent around this yet (as of Jul 2026). Window is open but
  OpenZL team may absorb it — ship small and fast, open source.

## Target users (NOT small apps — compression pain starts at scale)

Data/platform engineers who own storage bills: analytics teams (CSV/JSONL exports),
observability/log pipelines, ML infra (datasets, checkpoints). They can code; they lack
compression domain expertise. Product = expertise substitute, not typing-saver.

## Roadmap (each stage gated on the previous one succeeding)

0. ~~Validation spike~~ **DONE 2026-07-31, PASSED** — 2 of 3 dataset classes cleared 30%:
   CSV −50.0% vs zstd -3, LLM-SDDL binary ticks −48.7% (also beats zstd -19 by 34%);
   JSONL failed (−6%), pytorch floats −10% (known-hard). Full numbers:
   results/benchmarks.md (old build) + results/benchmarks-upstream.md (v0.2.4).
1. **Claude Code skill `/openzl` — LAUNCH-READY 2026-08-04 (CURRENT).** Live at
   https://github.com/avionicharshit-byte/openzl-agent (main @ eeec64f). Commit style:
   conventional (feat/docs/chore), short, author = avionicharshit-byte, NO co-author
   trailers (Harshit's explicit preference).
   DONE 2026-08-04: MIT LICENSE; root README landing page; benchmarks consolidated into
   single v0.2.4-only results/benchmarks.md (old-build comparison file deleted —
   Harshit's call, old data in git history); .gitignore allowlists results/ (only
   benchmarks*.md + *.sddl tracked; binaries + issue drafts stay out).
   FRESH-DATA TEST PASSED 2026-08-04: skill installed to ~/.claude/skills/openzl, Opus
   subagent given only the raw user request on unseen 72 MB Chicago crimes CSV (embedded
   newlines, 250k records / 750k lines) → −53.9% vs zstd -3 (6,262,695 B vs 13,594,200 B),
   beat zstd -19 by 19.6% at 31x speed, independently cmp-verified. detect_zli/--strict/
   benchmark.sh all worked cold. Weakness found+fixed (eeec64f): SKILL.md now leads CSV
   sampling with lines-vs-records check + quote-aware byte-offset fallback.
   Track 3 POSTED 2026-08-04 (gh CLI now installed+authed as avionicharshit-byte):
   ACE --max-time-secs overrun = facebook/openzl#930 (3 datasets incl. Chicago 543 s on
   120 s budget) + comment offering a PR if maintainers state a direction; Syntax.md
   comma bug = #931 (follow-up to #159, which fixed only the website) + FIX PR #932
   ("Fixes #931", branch fix/sddl1-syntax-md-records on fork, all examples
   compile-verified incl. semicolon separators). Don't build the #930 code fix
   unprompted — Meta often supersedes external PRs internally (see #280).
   Still unposted: --strict UX suggestion (post-launch), benchmark Discussion (HOLD
   until launch).
   REMAINING = LAUNCH POSTS ONLY. Agreed plan: OpenZL repo Discussion + r/dataengineering
   the same day, cross-linked; HN Show HN recommended; Medium dropped (low reach, reads
   as content marketing). Tone: numbers-first, failures prominent (JSONL weak, 9-min
   training overrun), short, no AI-sounding filler. Chicago −53.9% is launch material
   (second unseen dataset). Harshit reviews ALL public posts before publishing.
2. Standalone CLI (no Claude Code dependency, calls Claude API directly)
3. Integrations: GitHub Action, MCP server
4. Only if pulled by users: hosted "storage savings audit" (read-only S3 → report)

## Local setup

- OpenZL clone: `~/Documents/OpenSource/openzl` (branch `dev`, fork remote `origin` =
  avionicharshit-byte/openzl, `upstream` = facebook/openzl). SYNCED to upstream HEAD
  a9de25e on 2026-07-31 (fork pushed). Its build/cli/zli binary is still the OLD v0.1.
- PRIMARY zli binary: `~/Documents/OpenSource/openzl-upstream/build/cli/zli` — v0.2.4
  built from HEAD a9de25e in a detached git worktree. SDDL compilers:
  same tree, build/tools/sddl{,2}/. Use skill/openzl/scripts/detect_zli.sh to locate.
- Harshit IS a merged OpenZL contributor (verified 2026-07-31 via GitHub API): PRs #220
  (typo) and #229 (N-to-N graph routing) were MERGED as commits d307013 and 65ee002,
  authored by avionicharshit-byte — GitHub shows the PRs "closed" only because Meta's
  codesync imports PRs and merges internally. Yann Collet (Cyan4973) personally reviewed
  and merged #229. #280 (strict int parsing) was superseded ("functionality available in
  next release" — Victor-C-Zhang). Claiming "OpenZL contributor" in marketing is fair.

## zli syntax gotchas (v0.1-era notes — SUPERSEDED by skill/openzl/references/zli-cheatsheet.md, which is execution-verified on both versions; read that first. Biggest post-v0.1 changes: `--strict` exists and is MANDATORY for sddl work, sddl2 takes source not bytecode, `--chunk-size 20M` not `--chunk-size-mb`, dict training opt-in via -O)

- `zli train` takes a sample DIRECTORY (positional), not a file:
  `zli train --profile csv <dir> --output out.zlc --max-time-secs N -f`
  Defaults: 150MiB max file size, 300MiB max total, greedy trainer, all cores.
- `zli compress <input> -o out.zl` with either `--profile <p>` or `-c trained.zlc`.
  `--train-inline` exists (train+compress in one shot).
- Profiles: csv, parquet (canonical/uncompressed only), pytorch (no training),
  le-{i,u}{16,32,64}, sao, serial, sddl (--profile-arg <description file>),
  sddl2 (--profile-arg <pre-compiled bytecode>).
- Known limits (HN thread): 2GB file limit (chunking WIP as of launch); default
  profiles sometimes LOSE to zip/flac — always benchmark, never assume.

## Spike status (2026-07-31) — 3 datasets DONE, full numbers in results/benchmarks.md

- Data layout: `data/nyc311/`, `data/gharchive/`, `data/pytorch/` (one dir per dataset —
  `zli train` takes a directory, so datasets must not share one).
- CSV (NYC 311, 87.5MB): **PASS** — trained csv profile 15.75x vs zstd -3's 9.7x
  (38.6% smaller), 0.8s compress vs zstd -19's 14.6s for a similar ratio. Round-trip ✓.
- JSONL (GH Archive, 80MB): **FAIL** — trained serial profile only 13.9% over zstd -3
  and loses to zstd -19 (6.6x vs 8.4x). No json profile exists even in upstream
  (checked 2026-07-30 tree via git grep).
- PyTorch (ResNet18 46.8MB, zip-format .pth): **MISS vs 30% bar but unique** — 10.1%
  smaller than zstd -3 at 1.5 GB/s; removes 2.3x the bytes. Legacy pre-1.6 non-zip
  .pth (e.g. mobilenet_v2-b0353104) FAILS with "EOCD not found" — detect format vintage.
- Training gotchas (agent must handle): default ACE stage overran --max-time-secs 90 to
  4 min and wrote a **0-byte .zlc** with exit info lost in progress-bar spam;
  `--no-ace-successors` fixed it. Always check .zlc size > 0 and verify round-trip
  with `cmp` before reporting success.
- Score vs kill criterion: 1 of 3 passed. Decision: run **Stage 0b** before honoring
  the kill — the untested core hypothesis is LLM-written SDDL on a format with no
  profile (binary telemetry/log format, or columnarizing JSONL). If LLM-SDDL can't
  materially beat zstd there either, the product reduces to "CSV + checkpoints only" —
  probably not enough. That test decides the project.
- **Stage 0b RESULT (2026-07-31 02:18): PASS — project lives.** Binary tick feed:
  1.6M real Binance BTCUSDT trades (2026-07-28) packed as 16B header + 41B records
  (i64 id, f64 price/qty/quote, i64 ts_us, u8 flags) = `data/ticks/btcusdt.bin`, 65.6MB.
  LLM-written SDDL (`results/ticks.oldv1.sddl`, written zero-shot, one syntax retry) →
  **10.85x: 48.5% smaller than zstd -3 AND 34.4% smaller than zstd -19**, 122 MB/s
  compress / 876 MB/s decompress (zstd -19 took 12s). Untrained serial = 6.19x.
  Round-trip ✓ (`cmp`). Repro: `curl data.binance.vision/data/spot/daily/trades/
  BTCUSDT/BTCUSDT-trades-2026-07-28.zip`, pack per above.
- SDDL SYNTAX GOTCHA: built zli v0.1 rejects the documented v0.5/v0.6 syntax (shipped
  `examples/sddl/sao_silesia.sddl` itself fails!). It implements the undocumented
  "oldv1" SDDL1 dialect — see `examples/sddl/sao_silesia.oldv1.sddl`: bare unnamed
  types in `Name = { Int64LE ... }`, `: Type[n]` root fields, `_rem`, `sizeof Name`.
  Syntax-check fast via `build/tools/sddl/sddl_compiler < desc.sddl` (stdin only).
  The skill must probe/detect which dialect the user's build accepts.

## Conventions

- `data/` and `results/*.zlc` are gitignored; keep datasets reproducible via curl
  commands documented here.
- Benchmarks: report ratio vs zstd -3 (the realistic incumbent), not vs raw size only.
