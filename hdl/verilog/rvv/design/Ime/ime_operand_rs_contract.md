# IME operand register snapshot contract

This opt-in source integration carries C1 operand fragments through the ordinary RVV dispatch path, collects the required A, B and old-C register image, and sends one complete image to the existing IME fetch/compute path. `IME_OPERAND_RS` remains disabled by default. The bounded source scope is the accepted integer, non-MX IME profile; FP/MX and unsupported/illegal encodings retain their existing paths.

The scalar-age bridge exports the current registered scalar retirement head valid/tag and checks that tag together with the local vector IME head before each architectural IME write beat. The existing accepted write/fire path gates vector register writes, flags updates, beat advance and final completion. Whole destination/consumer locks and the snapshot barrier remain in force. No early writeback, sticky permission, extra VRF port, or change to global flush priority is part of this integration.

The C1 collector replaces the two-entry IME command FIFO while enabled. It stores a complete snapshot before issue, including old-C registers and bytes that may have zero write strobes. This changes buffering and overlap capacity; the measured mechanism result covers the whole collector/dispatch/old-C/retirement integration, not an isolated RS optimization.

## Evidence scope

The 132-cycle accepted backend fixture is a fixed zero-data S5/V0 sequence. It checks fragment collection, one final ROB allocation, four destination write enables, commit/completion/retirement order and cancellation at a ready handoff before engine acceptance. It does not establish numeric MAC correctness, global-tag wrap, simultaneous permitted write and flush, engine/completion backpressure, broad reset recovery, or full-Core behavior. The twenty rejected traces are checker mutation controls, not twenty RTL scenarios.

The accepted 24-IME result is limited to its fixed window and the whole mechanism: commit gap 25 to 21 cycles and tile batch 658 to 561 cycles. It does not isolate RS from the FIFO-depth change, prove strict interior overlap, or establish application/full-platform performance.

Matched OFF/ON DC covers `rvv_backend` only with the same frozen generated RTL and 2 ns setup. It reports +3.052246928% area and setup slack/TNS met for that boundary. Hold violations remain; this is not full-platform area closure, timing signoff, or the 20% full-platform area requirement.

Global-tag wrap/reuse is not dynamically covered by the accepted fixed cases. A simultaneous permitted write/flush collision is not exercised. FP flag behavior is not covered by the integer-only evidence. These profiles remain unqualified. Current Core generation is separately blocked at the `local_config_xcode` aquery edge; historical generated models do not qualify current Core source.

Evidence identities are recorded in the owner read-only review package `ime_mainline_readonly_review_20261011_a1`: `SOURCE_SET.json`, `EVIDENCE_PINS.json`, and `REVIEW.json`. The source import is not a new whole-Core certification.
