# colibri-portable-ssd

**GLM-5.2 (744B MoE) on a portable SSD: plug into any capable machine, run one command, unplug when done.**

Built on upstream [JustVugg/colibri](https://github.com/JustVugg/colibri) (Apache-2.0) — a pure-C inference engine that keeps GLM-5.2's routed experts (int4, ~370GB) on disk and streams them in on demand. This repo packages that engine into a **plug-and-play portable SSD**: engine binaries, model, launchers, and self-checks all live on the drive; every path resolves relative to the launcher, so `./start.sh` works on any machine that meets the requirements.

> Why this works: colibri opens model shards **read-only** and `pread`s experts on demand (`c/st.h`), and the model path is entirely runtime-configured via `COLI_MODEL` — no absolute paths baked into the container. This project doesn't modify the engine; it externalizes the engine's own design premise.

## Quick start

### Build the SSD (once, needs network + gcc)

```bash
git clone https://github.com/DannyFish-11/colibri-portable-ssd
cd colibri-portable-ssd

scripts/coli-ssd build --ssd /mnt/myssd       # build engine + assemble SSD layout
scripts/coli-ssd download --ssd /mnt/myssd    # ~370GB model, resumable
scripts/coli-ssd doctor --ssd /mnt/myssd      # engine + model + MTP heads + disk speed
```

### Daily use (any machine)

```bash
/mnt/myssd/start.sh                # interactive chat
/mnt/myssd/start.sh run "prompt"   # one-shot generation
/mnt/myssd/start.sh serve          # OpenAI-compatible API
/mnt/myssd/start.sh --readonly     # zero writes to the SSD (KVSAVE=0)
```

Windows 11: run `start.bat` (requires Python 3.10+). Exit cleanly, then eject.

## Hard requirements

| Requirement | Minimum | Notes |
|---|---|---|
| Host free RAM | **16GB, 25GB recommended** | The SSD moves storage, not memory. Dense weights ~9.9GB resident, chat peak RSS ~20GB |
| Host CPU | x86_64 with **AVX2**, or Apple Silicon | Portable-build baseline |
| SSD | **≥500GB NVMe** (model ~370GB) | No HDDs, no network mounts |
| Interface | **USB 3.2 Gen2 (10Gbps) minimum, USB4/Thunderbolt recommended** | 10Gbps ≈ upstream author's proven baseline (~1 GB/s random read → 0.05–0.1 tok/s cold) |
| Filesystem | **NTFS (Windows-first) or ext4 (Linux-first)** | FAT32 impossible (4GB/file), exFAT loses O_DIRECT/io_uring |
| Host software | Python 3.10+ | Engine is C, CLI is Python |

## SSD layout

```
<SSD>/
├── start.sh / start.bat        # self-locating launchers, cwd-independent
├── model/glm52_i4/             # 370GB int4 container (read-only shards)
│   ├── .coli_kv                #   session KV cache (~182KB/token, crash-safe)
│   └── .coli_usage             #   learning cache: travels with the SSD, gets faster with use
├── engine/{linux-x86_64,darwin-arm64,windows-x86_64}/   # pinned-commit builds + PROVENANCE
├── bin/iobench                 # disk benchmark matching the engine's I/O pattern
└── scripts/
```

## Honest limits

This is a **"744B that answers correctly" engineering rig**, not a pocket chat assistant. Cold decode is 0.05–0.1 tok/s at the proven baseline — first answers take minutes. Warm cache + MTP speculative decoding + learned hot-expert pinning improve subsequent turns considerably. Good for: long reasoning tasks, offline/private inference, MoE research. Bad for: quick Q&A, demos.

## Tests

```bash
tests/e2e_tiny.sh    # 11-check suite: real conversion + real inference on a ~170MB fixture
```

See [docs/TESTING.md](docs/TESTING.md) for full results and the tested/untested boundary. Chinese documentation: [README.md](README.md), [docs/](docs/).

## License

Scripts and docs in this repo: **Apache-2.0** (same as upstream). Upstream engine license and provenance ship with each assembled engine (`LICENSE.upstream`, `PROVENANCE`). GLM-5.2 weights follow their [model card license](https://huggingface.co/zai-org/GLM-5.2).
