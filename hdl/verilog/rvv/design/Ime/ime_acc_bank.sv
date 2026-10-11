// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Non-architectural IME accumulator storage.  The data array intentionally has
// no reset: validity is owned by ime_ctrl and every active cell is initialized
// from the captured C snapshot before the scheduler starts.
module ime_acc_bank #(
  parameter int MAX_M = 16,
  parameter int READ_PORTS = 1,
  parameter int WRITE_PORTS = 1,
  localparam int MAX_CELLS = MAX_M * MAX_M,
  localparam int INDEX_WIDTH = $clog2(MAX_CELLS)
) (
  input  logic                                  clk,
  input  logic [READ_PORTS-1:0][INDEX_WIDTH-1:0] read_index_i,
  output logic [READ_PORTS-1:0][31:0]            read_data_o,
  input  logic [WRITE_PORTS-1:0]                 write_valid_i,
  input  logic [WRITE_PORTS-1:0][INDEX_WIDTH-1:0] write_index_i,
  input  logic [WRITE_PORTS-1:0][31:0]           write_data_i
);
  logic [MAX_CELLS-1:0][31:0] data_q;

  generate
    for (genvar r = 0; r < READ_PORTS; r++) begin : gen_read
      assign read_data_o[r] = data_q[read_index_i[r]];
    end
  endgenerate

  always_ff @(posedge clk) begin
    for (int w = 0; w < WRITE_PORTS; w++) begin
      if (write_valid_i[w])
        data_q[write_index_i[w]] <= write_data_i[w];
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    for (int first = 0; first < WRITE_PORTS; first++) begin
      for (int second = first + 1; second < WRITE_PORTS; second++) begin
        if (write_valid_i[first] && write_valid_i[second]) begin
          assert (write_index_i[first] != write_index_i[second])
              else $error("Two IME lanes wrote the same accumulator cell");
        end
      end
    end
  end
`endif
endmodule
