# Selected-element Tile LSU candidate

The production `LsuSuperSlot` Tile path uses the frozen A15 selected-element
address generator. The instruction retains base, leading dimension, line shift,
SEW and transpose. The current logical byte index selects the element address;
the leading-dimension multiplication remains. Tile cells no longer each retain
an eagerly calculated address. Ordinary scalar/vector address paths are unchanged.

Request masks use that selected address. Response data uses the captured outgoing
byte offset and first logical byte, so a response is not indexed using the next
element's address. Existing request holding, one-outstanding exact transaction,
mask/vstart selection, fault/restart and pipeline-flush controls are retained.
ISA encodings, register layout and the existing four-byte optimized window are
unchanged. `ImeTileSharedLsuOptTop` keeps `imeTileExactWindowOpt=true`; this merge
does not change any Core feature or capacity configuration.

## Validation and identity

The merged `Lsu.scala` is byte-identical to the tested A15 source:
`ef477b6130e996daac6d9a2d3b400527d3f8f9ecb85599404ab3df4c0fdd2838`.
Its retained generated shared-LSU RTL is:
`aa03238b2e9483516a4cfb5c39079187412d45638c165ec3cb398899fe17f2f4`.
The accepted A14/A15 raw comparison is:
`a5a557dce81b2499bdf53f74e8466f5601260b85fb56f38e5aac8c21e4a3d2a2`.

Reuse the existing generation and RTL simulation: 12 functional and 20 restart
cases, ordered/transposed loads/stores, SEW 8/16/32, LMUL 1/2/4/8, lambda 1/2/4,
always-ready and bounded-backpressure profiles. Raw case records match A14.
The original test wrapper exited 1 during XML reporting; retained Cocotb passed,
report-only recovery exited 0, and the A15 continuation Pool receipt exited 0.
These facts are not rewritten as a clean original test-wrapper exit.

The current Main changes to scalar-head wiring in RetirementBuffer, SCore and
RvvCore/RvvCoreIO are retained. They do not change the shared-LSU boundary types;
full-Core simulation combining those changes with this candidate remains unproven.
The experiment emitter's `--selected-agu=true` guard is metadata, not a hardware
parameter, and is not copied into the production emitter.

## Candidate decision and PPA limits

The user selected this local candidate using the A14 WLM checkpoint AREA 810048.6,
raw WNS column 0.20 and setup cost 230.5, versus A15 final total cell area
329755.859203 library units. Both use the same shared-LSU top, synthesis options,
library and 2 ns constraints. A14 was user-stopped and has no final PPA result.
The checkpoint columns are not final path STA or a completed paired comparison.

A15 reports zero setup violating paths/TNS, but 9567 hold violations, worst
-0.127 ns, and 728 partially constrained input ports. This is a local candidate,
not timing signoff, whole-platform area qualification or a platform 20% result.
Raw evidence stays in the D2 A14/A15 report directories; no new DC is implied.
