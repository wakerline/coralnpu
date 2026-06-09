# CoralNPU Instruction Cycle Counter

This directory contains micro-benchmarks for measuring single-instruction cycle
counts on the CoralNPU RV32IMF_Zve32x_Zicsr_Zifencei_Zbb core.

The scalar and RVV benchmarks intentionally execute an unrolled dependent chain
of the same instruction many times and report:

* raw cycles measured around the chain,
* raw retired instructions measured around the chain,
* the measured CSR-read overhead,
* adjusted cycles per instruction.

The dependent chain keeps four-way scalar and two-way vector dispatch from
turning the result into a throughput measurement. Use the adjusted CPI as a
first-order latency estimate for the execution unit.

Run with:

```sh
bazel test //tests/cocotb/cycle_counter/scalar:cocotb_scalar_cycle_counter_test --test_output=streamed
bazel test //tests/cocotb/cycle_counter/rvv:cocotb_rvv_cycle_counter_test --test_output=streamed
```

Each cocotb test also writes CSV and Markdown tables into
`$TEST_UNDECLARED_OUTPUTS_DIR`:

* `scalar_instruction_cycles.csv`
* `scalar_instruction_cycles.md`
* `rvv_instruction_cycles.csv`
* `rvv_instruction_cycles.md`
