---
name: nr-colour-assessment
description: "Assess CSX neural-rendering colour fidelity, retained detail, temporal stability and stereo consistency from attributed native HMD images. Use for automated NR colour comparisons with blinded image review; keep this separate from performance campaigns."
---

# NR colour assessment

Use the colour campaign implementation in the task's selected CSX checkout.
Resolve that checkout from the user's branch/build context without switching
branches. Record its absolute path and source commit. Read these files there:

- `docs/development/nr-colour-hmd-assessment.md` for the evidence protocol.
- `tools/nr-color/hmd_workflow.md` for plan, capture and analysis contracts.
- `tools/nr-color/hmd-review.prompt.md` before blinded visual review.

The executable dependencies are `tools/nr-color/hmd_capture.py`,
`hmd_assess.py`, their adjacent schemas and `hmd_requirements.txt` in that
checkout. Verify they exist and use the task's validated Python environment.
Report a missing dependency instead of substituting another checkout or
inventing an equivalent runner. The plugin routes to these canonical CSX
tools; it does not bundle a second copy of the colour analyser.

## Admission and transport

Read the bundled `devbench-control`, `mo2-control` and
`capture-interaction-control` skills before live work. Retain the exact
prepared-session ownership and physical DLL/build receipts. A running game
or an enabled mod name alone does not establish either identity or ownership.

Select one live transport before the first call. Callable direct DevBench MCP
tools take precedence. Require their exact typed NR status/configure,
exposure-diagnostics, recording and screenshot actions. A stale catalogue or
missing action is a tooling gap: do not hide it through a generic dispatcher
or change transport. Recheck availability after the Codex host reload.

The CSX `hmd_capture.py` live runner implements the controller lane only.
Use it only when discovery found no callable direct DevBench tools. With the
direct lane, retain the same frozen plan, ownership guards, provenance and
campaign-index contract through the available typed actions; do not launch
the controller in parallel. Offline planning and analysis are transport-free.

## Image campaign

1. Start from the owned, settled scene. Keep camera, scene, graphics settings
   and NR ROI/FOV/mask policy fixed. Choose corresponding native-pixel skin,
   material, shadow, highlight and background regions separately for each eye
   before reviewing candidates. Record reasons for absent region classes.
2. Preserve repeated unchanged baselines first. Measure camera/animation and
   exposure drift; reject confounded comparisons without alignment, automatic
   white balance, histogram matching or independent normalization.
3. Freeze anonymous candidate IDs and randomized/counterbalanced order. Keep
   NR-off, Raw NR, Managed identity, Preserve Source and justified conversions
   distinct. Also compare display-only source with inference still running.
   Conversion hypotheses require producer evidence, not appearance alone.
4. Require `communityshaders.screenshot` native left/right PNG sequences with
   `source=hmd_submission`, `fallback=reject` and identical `sdr_srgb` encoding.
   Verify committed artifacts, hashes, dimensions, matching eye identity,
   camera/frame/configuration provenance and fresh effective applied state.
5. Analyse original images and fixed identical crops. Compare each eye with
   its own reference. Measure signed colour shifts, shadow/highlight changes,
   local contrast and stereo consistency, calibrated against baseline variation.
   Retained neural detail is a separate assessment from source fidelity.
6. Include short temporal/exposure-recovery sequences. Report actual sampling
   cadence and its limits: sparse PNG sequences do not qualify HMD frame-rate
   flicker. Keep exposure observations distinct from inference bindings.
7. Give a fresh review context only anonymous originals/crops and the review
   prompt/schema. Preserve its assessments before revealing the separate
   settings-to-ID mapping. The user does not judge a winning colour mode.
8. Retain originals, manifests, anonymous crops, regional/repeatability data,
   annotations, blinded assessment, private mapping, technical diagnostics,
   excluded/failed captures and untested conditions. Restore only settings and
   capture state whose ownership remains proven.

Do not select NR-off as the best neural result because its RGB error is zero.
Do not infer NVIDIA's colour contract from appearance or change production
colour code/defaults to favour one screenshot. Broad FOV remains the FOV route;
qualify general NR and character-mask routes separately when implemented.
