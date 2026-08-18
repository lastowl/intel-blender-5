# Where things stand

Snapshot of the project after the build-out session, written so work can be
resumed cold. Everything below is measured, not assumed.

## Working

| | State |
| --- | --- |
| x86_64 dependency stack | Built, verified, **published** |
| Blender 5.2.0 x86_64 | Builds locally and in CI, runs, tested |
| EEVEE on AMD | **Fixed** (patch `0009`) — viewport and F12 renders |
| Workbench viewport | Was already fine |
| CI end to end | **Green** — run 8, 1 h 40 m, 325 MB `.dmg` |
| Signing | Implemented and locally verified; **not enabled in CI** |
| Notarization | Implemented; **never exercised** |
| Cycles GPU | Not reachable — see below |

## Key artefacts

* Dependency stack release: tag `deps-x64-c17b7766d42d6499`, keyed on a hash of
  `versions.cmake`, so any Blender revision with the same dependency versions
  reuses it.
* Patch series `patches/0001`–`0009`. Applies cleanly to `v5.2.0`.
* `logs/eevee-amd-black-lighting.gputrace` (636 MB, git-ignored) — Metal frame
  capture of the original EEVEE failure.
* Standalone Metal reproducers in `docs/` including
  `metal-blender-shader-harness.mm`, which compiles Blender's own captured MSL
  against a hand-built pipeline.

## The EEVEE fix, in one paragraph

EEVEE's deferred pipeline classifies pixels by closure count into the stencil
buffer, then gates later passes on those bits. On AMD and Intel Metal the bits
never arrive, so every stencil-gated pass is culled on every pixel — lit
surfaces render black while emissive and forward-rendered materials are fine,
because neither goes through the deferred passes. Patch `0009` bypasses the
gate on both the eval and combine passes, gated on `GPU_type_matches` so Apple
Silicon keeps the masked path. Four lines.

The measurement that settled it: writing a known constant unconditionally at
the top of `light_eval_frag` and reading the target textures back gave 0 of
40000 pixels with the stencil test in place, and 35825 of 40000 with it
bypassed.

**Why the stencil write itself fails is still unknown.** Patch `0009` routes
around it. Forcing the per-bit fallback path does not help — and note that the
host and the shader select that path independently, which is a latent bug of
its own worth fixing regardless.

## Cycles GPU: measured, not viable

Opening the two-line vendor filter in `intern/cycles/device/metal/util.mm`
makes Cycles accept the Radeon Pro 5500M and compile every kernel. The render
then completes in **5 h 10 m** and produces an **entirely empty film** (RGBA
0,0,0,0 across the frame). Kernel caching is disabled for non-Apple vendors, so
that cost repeats on every render.

The full revert of `c8340cf7541` is not viable: 12 conflicted files, several of
which cannot be resolved toward the old code because it depended on structures
since removed. Full detail in `cycles-amd-revert-analysis.md`.

## Resuming

Highest value first:

1. **Signing.** Export a Developer ID `.p12` from Keychain Access, then
   `./scripts/setup-signing-secrets.sh <file.p12> [AuthKey_XXXX.p8]`. Run
   `--check` first. Notarization has never been submitted, so expect the first
   attempt to surface something.
2. **Publish a release.** Prefer CI's artifact over a local build — it comes
   from a clean checkout at a known commit and is therefore reproducible.
3. **Diagnose the stencil write** if the EEVEE fix's full-screen fallback ever
   proves too slow. It is a correctness-neutral optimisation, so there is no
   urgency.
4. **Cycles** only with appetite for days of work: restoring discrete-GPU
   support across storage modes and their synchronisation, MNEE gating,
   specialization gating and binary archives.

## Things that bit us, worth remembering

Every one of these was an untested path that looked fine until exercised:

* `git-lfs` must exist *before* cloning Blender, or configure fails on an
  incomplete `startup.blend`.
* `CMAKE_INSTALL_PREFIX` must be passed explicitly; Blender only defaults it on
  a fresh cache, so one failed configure poisons every later build.
* macOS ships bash 3.2, where `"${arr[@]}"` on an empty array is an error under
  `set -u`.
* A step's own `env:` block is not visible to that step's `if:` in GitHub
  Actions.
* Running Blender after signing writes `__pycache__` into the bundle and breaks
  the seal — `package-dmg.sh` used to trigger this itself by asking the binary
  for its version.
* `git remote get-url` can return a `user@` form that naive `sed` parsing
  leaves intact.

And the methodological one: counting non-zero bytes in a readback is not
evidence. Undefined padding in a 3-channel format read as 4 produced convincing
but meaningless numbers twice. Writing a **known constant** and checking for
that exact value is what finally gave trustworthy signal.
