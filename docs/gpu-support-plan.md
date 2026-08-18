# Full GPU support: remaining considerations and plan

Where this picks up: EEVEE works on AMD via patch `0009` (a stencil-gate
bypass), and Cycles GPU measurably does not (5 h compile, empty film). "Full
GPU support" from here means three different things, and they deserve
different budgets:

1. Making the EEVEE fix *understood and optimal*, not just working.
2. Rounding out the claim — every GPU-adjacent subsystem, not just EEVEE.
3. Cycles.

## Considerations not yet on the table

**Patch `0009` has an unmeasured cost.** With the stencil gate bypassed, every
deferred lighting variant dispatches full-screen instead of only over its
classified pixels. Correct, but the cost has never been measured — and on a
5500M it is the difference between "shippable" and "technically works".

**The bypass may be fixable properly, and cheaply.** EEVEE already contains a
per-bit fallback for hardware without shader stencil export: classical
stencil-REPLACE writes, one full-screen pass per bit
(`state_stencil(bit, 0xFF, 0xFF)`). Our earlier test of it was confounded — at
the time we did not know the combine pass carried a second stencil gate, so
"still black" did not actually condemn the fallback. If classical stencil
writes work on AMD where shader export does not, the *proper* fix is "force
the fallback classify on AMD" — which restores fully masked lighting and
retires the bypass. That question is answerable in an afternoon.

**Nobody has ever read the stencil buffer itself.** Every experiment so far
read colour or radiance textures. Metal can blit the stencil plane out
(`MTLBlitOptionStencilFromDepthStencil`). Reading it directly after the
classify pass splits the failure into exactly one of: shader stencil export
broken, classical stencil write broken, or stencil *test* broken. That is the
missing measurement behind the whole EEVEE story.

**The two bugs are probably unrelated.** EEVEE's failure lives in render
encoders (stencil); Cycles runs compute encoders. Assuming a common root would
repeat the mistake of chasing one theory across different machinery.

**Cycles has a fresh, specific suspect.** `MetalDevice` on macOS 15+ creates an
`MTLResidencySet` and — when creation succeeds — *skips the per-encoder
`useResource:` path entirely*. The gate checks OS version and a debug flag,
never the vendor. That is an Apple-Silicon-era API running on a frozen AMD
driver; if it silently fails to make resources resident, the observed result
is precisely "command buffers complete, no errors, film empty". Cycles' own
error check (`queue.mm:590`) stayed silent for 5 hours, which fits.

**Iteration cost is the real Cycles gate.** Kernel archives are refused for
non-Apple vendors, but `CYCLES_METAL_DISABLE_BINARY_ARCHIVES=0` skips that
vendor check (the env branch returns early, bypassing the vendor branch). If
archives actually work on AMD, the edit-test cycle collapses from 5 hours to
minutes after one paid compile. If they are broken — which is presumably why
the vendor check exists — Cycles work is impractical on this machine
regardless of correctness, and that alone decides the question.

**The Intel UHD 630 is an unused control.** Same machine, second vendor.
Whether the stencil failure reproduces there separates "AMD driver bug" from
"Blender Metal-backend assumption". Patch `0009` already covers Intel iGPUs;
it has never been exercised on one.

**Second-order GPU users are untested.** The GPU compositor, OpenSubdiv GPU
subdivision, and Grease Pencil all run GPU work that is neither Workbench nor
EEVEE's deferred path. Cheap smoke tests, and "full GPU support" is an empty
phrase until they pass.

**Everything here is permanent local carry.** The AMD driver is frozen; fixes
are ours to maintain. (Patch `0009` is Apple-Silicon-neutral by construction if
upstreaming is ever wanted — noted, not planned.)

## The plan

### Phase 0 — Consolidate what is shipped (~half a day)

* Benchmark `0009`: heavier scene, viewport fps and F12 time, against the
  forward-rendered (`Blended`) path as reference. Record numbers in the README.
* Smoke-test GPU compositor, OpenSubdiv GPU, Grease Pencil, material preview.
* Run the EEVEE validation scene on the Intel UHD 630.

*Exit: the release's claims are measured, on both vendors.*

### Phase 1 — Root-cause the stencil failure (1–2 days, highest value)

1. Instrument a stencil-plane readback (blit with
   `MTLBlitOptionStencilFromDepthStencil`) after the classify pass.
2. Run three configurations: stock shader-export classify; per-bit fallback
   forced consistently (host **and** shader — they select independently, a
   latent upstream bug in itself); classify disabled.
3. Known-constant probe inside the classify fragment to prove execution,
   using the established method — never count nonzero bytes, write a constant
   and look for it.
4. Repeat the decisive case on the Intel iGPU.

*Outcomes:* fallback works → replace the bypass with forced fallback classify;
masked lighting restored at near-zero cost; `0009` retired. Classical stencil
also broken → `0009` is already optimal; document the driver defect precisely.
Either way the fix stops resting on an unexplained bypass.

### Phase 2 — Cycles feasibility spike (time-boxed: 2 days, hard gate)

Order chosen so the cheapest disqualifier runs first:

1. `CYCLES_METAL_DISABLE_BINARY_ARCHIVES=0`, pay one full compile, then
   verify a second render starts in minutes. **If archives are broken on AMD,
   stop here** — no correctness result can survive a 5-hour iteration loop.
2. Disable the residency set (debug flag / small patch) so the per-encoder
   `useResource:` fallback runs. Re-render. This is the empty-film prime
   suspect.
3. If still empty: known-constant probe from a trivial compute kernel into an
   output buffer — does *any* compute write land through Cycles' queue?
4. Metal validation layers over the Cycles queue specifically.

*Gate to Phase 3: a non-empty film (or constants landing plus a identified,
fixable break), and working archives. Otherwise: write it down, close the
question, keep the two-line device gate out of the patch series.*

### Phase 3 — Cycles restoration (3–7 days, only on a Phase 2 pass)

Not a revert. New code, informed by `cycles-amd-revert-analysis.md`:

* Device admission (the two-line gate) plus vendor detection already in tree.
* `PSO_GENERIC` forced for AMD; MNEE off on AMD; archives on for AMD.
* Keep `Shared` storage initially — it functions on discrete GPUs, just
  slower over PCIe; `Managed`+synchronisation is a later optimisation, not a
  prerequisite (the old sync calls no longer exist to restore).
* Fix whatever Phase 2 identified; validate against CPU Cycles renders;
  benchmark honestly.
* Ship as `0010`, separate and clearly experimental.

*Honest expectation:* a Navi 14 mobile part may land near — possibly below —
the 8-core CPU on real scenes. Phase 3 is only worth it if Phase 2 is clean
and the benchmark beats CPU by a margin users would feel.

## Recommendation

Commit to Phases 0 and 1 — they improve what is already shipped and may
convert the workaround into a real fix. Run Phase 2 as a strict time-box,
letting step 1 kill it early if archives are broken. Decide Phase 3 on
evidence, with no sunk-cost pull from the five hours already burned: the
EEVEE fix was four lines because the diagnosis was right, and Phase 1 is where
that can happen again.
