# openzl-agent

Format-aware compression without the compression expertise. Point Claude Code at your
data - it identifies the structure, writes the data description, trains an
[OpenZL](https://openzl.org) compressor, verifies the round-trip byte-for-byte, and
reports what you'd actually save versus zstd and gzip.

OpenZL (Meta, open-sourced Oct 2025) compresses structured data far better than generic
compressors by decomposing it into typed streams - *if* someone describes the data's
structure in its SDDL language or a C++ parser. That description step is the adoption
barrier. This project makes an LLM do it.

## Measured results

Real datasets, `zli` 0.2.4, every result decompressed and `cmp`-verified byte-identical
(full logs in [`results/`](results/)):

| Dataset | Path | vs `zstd -3` | vs `zstd -19` |
|---|---|---|---|
| NYC 311 CSV (87.5 MB) | `csv` profile, trained | **−50.0%** | −11.7% |
| Binary tick feed (65.6 MB) | **LLM-written SDDL** | **−48.7%** | −34.5% |
| PyTorch checkpoint (46.8 MB) | `pytorch` profile | −10.0% | −10.0% |
| GH Archive JSONL (80 MB) | `serial`, trained | −6.0% | loses |

The second row is the interesting one: a binary format no OpenZL profile covers, with the
data description written zero-shot by the LLM from a hexdump - and it beats `zstd -19` by
a third while compressing 22x faster. The last two rows are why the agent benchmarks
honestly instead of overselling: checkpoints win on throughput and bytes removed, not
ratio, and JSON/JSONL is currently weak (OpenZL has no JSON profile).

Decompression needs no trained compressor and no description - the `.zl` frame is
self-describing, so there's no lock-in.

## Install the skill

```sh
git clone https://github.com/avionicharshit-byte/openzl-agent.git
cp -r openzl-agent/skill/openzl ~/.claude/skills/
```

You'll need `zli` built from [facebook/openzl](https://github.com/facebook/openzl)
(v0.2.4+ recommended) - the skill locates it, or offers to build it for you. Then just
ask Claude Code for compression work, e.g.:

- "Compress this directory of CSVs and show me what it saves."
- "We store 40 TB/month of these event logs. Is there anything better than zstd?"
- "Here's a binary file from our trading feed - write an SDDL description for it."

See [`skill/openzl/README.md`](skill/openzl/README.md) for full docs, including the list
of execution-verified gotchas the skill knows that the public docs don't (two mutually
incompatible SDDL dialects, silent fallback without `--strict`, training-budget overruns,
and more).

## What's in this repo

| Path | What |
|---|---|
| [`skill/openzl/`](skill/openzl/) | The Claude Code skill: playbook, verified `zli` cheatsheet, SDDL1/SDDL2 guides, detect + benchmark scripts |
| [`results/`](results/) | Benchmark logs from the validation spike, plus the LLM-written SDDL descriptions |

## Roadmap

1. **Claude Code skill** - shipped (this repo)
2. Standalone CLI (no Claude Code dependency, calls the Claude API directly)
3. GitHub Action, MCP server
4. Hosted storage-savings audit - only if users pull for it

## License

[MIT](LICENSE)
