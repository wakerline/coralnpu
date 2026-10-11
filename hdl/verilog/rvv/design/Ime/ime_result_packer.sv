// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Sequentially packs completed accumulator cells into the architectural C
// register layout.  Processing one cell per cycle replaces the previous
// MAX_M*MAX_M combinational finalize network.  Untouched bytes retain the
// captured C data and have a clear write strobe.
module ime_result_packer #(
  parameter int MAX_M = 16,
  parameter int MAX_C_REGS = 16,
  parameter int DIRECT_LANES = 1,
  parameter bit DIRECT_OPT = 1'b0,
  parameter bit DIRECT_INDEX_PREMAPPED = 1'b0,
  localparam int MAX_CELLS = MAX_M * MAX_M,
  localparam int ACC_INDEX_WIDTH = $clog2(MAX_CELLS),
  localparam int C_INDEX_WIDTH = $clog2(MAX_C_REGS * `VLENB),
  localparam int RESULT_INDEX_WIDTH =
      (ACC_INDEX_WIDTH > C_INDEX_WIDTH) ? ACC_INDEX_WIDTH : C_INDEX_WIDTH,
  localparam int DATA_INDEX_WIDTH = $clog2(MAX_C_REGS * `VLEN),
  localparam int STROBE_INDEX_WIDTH = $clog2(MAX_C_REGS * `VLENB)
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              flush_i,
  input  logic                              start_i,
  input  logic [`VL_WIDTH-1:0]              m_i,
  input  logic [`VL_WIDTH-1:0]              n_i,
  input  logic [2:0]                        sew_i,
  input  logic [6:0]                        lambda_i,
  input  logic [4:0]                        emul_c_i,
  input  logic [MAX_C_REGS*`VLEN-1:0]       c_data_i,
  output logic                              busy_o,
  output logic                              done_o,
  output logic [ACC_INDEX_WIDTH-1:0]        acc_read_index_o,
  input  logic [31:0]                       acc_read_data_i,
  // Ordinary-integer OPT reuses this same non-architectural result buffer.
  // The first K step is seeded directly from c_data_i; each last-K PE result
  // writes its architectural C position without a sequential PACK walk.
  input  logic                              direct_start_i,
  input  logic                              direct_write_valid_i,
  input  logic [DIRECT_LANES-1:0]           direct_lane_active_i,
  input  logic                              direct_index_is_physical_i,
  input  logic [DIRECT_LANES-1:0]
               [RESULT_INDEX_WIDTH-1:0]     direct_cell_index_i,
  input  logic [DIRECT_LANES-1:0][31:0]     direct_write_data_i,
  output logic [MAX_C_REGS*`VLEN-1:0]       result_data_o,
  output logic [MAX_C_REGS*`VLENB-1:0]      result_strobe_o
);
  logic active_q;
  logic empty_pending_q;
  logic [`VL_WIDTH-1:0] m_limit_q;
  logic [`VL_WIDTH-1:0] n_limit_q;
  logic [`VL_WIDTH-1:0] m_index_q;
  logic [`VL_WIDTH-1:0] n_index_q;
  logic [2:0] sew_q;
  logic [6:0] lambda_q;
  logic [4:0] emul_c_q;
  logic [MAX_C_REGS*`VLEN-1:0] result_data_q;
  logic [MAX_C_REGS*`VLENB-1:0] result_strobe_q;
  logic [MAX_C_REGS*`VLEN-1:0] result_data_d;
  logic [MAX_C_REGS*`VLENB-1:0] result_strobe_d;
  logic result_update;
  logic [C_INDEX_WIDTH-1:0] c_flat_index;
  logic [15:0] sequential_index;
  logic [8:0] elements_per_register;
  logic [DATA_INDEX_WIDTH-1:0] data_bit_index;
  logic [STROBE_INDEX_WIDTH-1:0] strobe_index;
  logic [DIRECT_LANES-1:0][C_INDEX_WIDTH-1:0] direct_c_flat_index;
  logic [DIRECT_LANES-1:0][DATA_INDEX_WIDTH-1:0]
      direct_data_bit_index;
  logic [DIRECT_LANES-1:0][STROBE_INDEX_WIDTH-1:0]
      direct_strobe_index;

  assign busy_o = active_q || empty_pending_q;
  assign done_o = empty_pending_q ||
      (active_q && (m_index_q == (m_limit_q - 1'b1)) &&
       (n_index_q == (n_limit_q - 1'b1)));
  assign acc_read_index_o = (ACC_INDEX_WIDTH)'(
      ime_pkg::ime_row_major_index(
          16'(m_index_q), 16'(n_index_q), 16'(MAX_M)));
  assign result_data_o = result_data_q;
  assign result_strobe_o = result_strobe_q;

  always_comb begin
    elements_per_register = 9'(`VLEN >> (3 + sew_q));
    // Freeze 13.9.2: the architectural C object is a physical M-by-M tile.
    // n_limit_q selects active columns but never changes the row stride.
    sequential_index = ime_pkg::ime_row_major_index(
        16'(m_index_q), 16'(n_index_q), 16'(m_limit_q));
    c_flat_index = C_INDEX_WIDTH'(ime_pkg::ime_tile_reg_index(
        sequential_index, emul_c_q, lambda_q, elements_per_register));
    data_bit_index = '0;
    strobe_index = '0;
    direct_c_flat_index = '0;
    direct_data_bit_index = '0;
    direct_strobe_index = '0;
    unique case (sew_q)
      3'd0: begin
        data_bit_index = DATA_INDEX_WIDTH'(c_flat_index) << 3;
        strobe_index = STROBE_INDEX_WIDTH'(c_flat_index);
      end
      3'd1: begin
        data_bit_index = DATA_INDEX_WIDTH'(c_flat_index) << 4;
        strobe_index = STROBE_INDEX_WIDTH'(c_flat_index) << 1;
      end
      3'd2: begin
        data_bit_index = DATA_INDEX_WIDTH'(c_flat_index) << 5;
        strobe_index = STROBE_INDEX_WIDTH'(c_flat_index) << 2;
      end
      default: ;
    endcase

    for (int lane = 0; lane < DIRECT_LANES; lane++) begin
      automatic int unsigned cell_index =
          int'(direct_cell_index_i[lane]);
      automatic logic [15:0] direct_sequential_index =
          ime_pkg::ime_row_major_index(
              16'(cell_index / MAX_M), 16'(cell_index % MAX_M),
              16'(m_limit_q));
      if (DIRECT_INDEX_PREMAPPED && direct_index_is_physical_i)
        direct_c_flat_index[lane] = C_INDEX_WIDTH'(direct_cell_index_i[lane]);
      else
        direct_c_flat_index[lane] = C_INDEX_WIDTH'(
            ime_pkg::ime_tile_reg_index(
                direct_sequential_index, emul_c_q, lambda_q,
                elements_per_register));
      unique case (sew_q)
        3'd0: begin
          direct_data_bit_index[lane] =
              DATA_INDEX_WIDTH'(direct_c_flat_index[lane]) << 3;
          direct_strobe_index[lane] =
              STROBE_INDEX_WIDTH'(direct_c_flat_index[lane]);
        end
        3'd1: begin
          direct_data_bit_index[lane] =
              DATA_INDEX_WIDTH'(direct_c_flat_index[lane]) << 4;
          direct_strobe_index[lane] =
              STROBE_INDEX_WIDTH'(direct_c_flat_index[lane]) << 1;
        end
        3'd2: begin
          direct_data_bit_index[lane] =
              DATA_INDEX_WIDTH'(direct_c_flat_index[lane]) << 5;
          direct_strobe_index[lane] =
              STROBE_INDEX_WIDTH'(direct_c_flat_index[lane]) << 2;
        end
        default: ;
      endcase
    end
  end

  // The direct path may update several dynamic C locations in one cycle.  A
  // next-state vector gives every result bit one common clock enable; coding
  // each variable slice as a nonblocking assignment instead makes the slice
  // decoder part of thousands of individual ICG enable paths.
  always_comb begin
    result_data_d = result_data_q;
    result_strobe_d = result_strobe_q;
    if (start_i || direct_start_i) begin
      result_data_d = c_data_i;
      result_strobe_d = '0;
    end else begin
      if (active_q) begin
        unique case (sew_q)
          3'd0: begin
            result_data_d[data_bit_index +: 8] = acc_read_data_i[7:0];
            result_strobe_d[strobe_index +: 1] = 1'b1;
          end
          3'd1: begin
            result_data_d[data_bit_index +: 16] = acc_read_data_i[15:0];
            result_strobe_d[strobe_index +: 2] = 2'b11;
          end
          3'd2: begin
            result_data_d[data_bit_index +: 32] = acc_read_data_i;
            result_strobe_d[strobe_index +: 4] = 4'hf;
          end
          default: ;
        endcase
      end
      if (direct_write_valid_i) begin
        for (int lane = 0; lane < DIRECT_LANES; lane++) begin
          if (direct_lane_active_i[lane]) begin
            unique case (sew_q)
              3'd0: begin
                result_data_d[direct_data_bit_index[lane] +: 8] =
                    direct_write_data_i[lane][7:0];
                result_strobe_d[direct_strobe_index[lane] +: 1] = 1'b1;
              end
              3'd1: begin
                result_data_d[direct_data_bit_index[lane] +: 16] =
                    direct_write_data_i[lane][15:0];
                result_strobe_d[direct_strobe_index[lane] +: 2] = 2'b11;
              end
              3'd2: begin
                result_data_d[direct_data_bit_index[lane] +: 32] =
                    direct_write_data_i[lane];
                result_strobe_d[direct_strobe_index[lane] +: 4] = 4'hf;
              end
              default: ;
            endcase
          end
        end
      end
    end
  end
  assign result_update = start_i || direct_start_i || active_q ||
                         direct_write_valid_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_q <= 1'b0;
      empty_pending_q <= 1'b0;
      m_limit_q <= '0;
      n_limit_q <= '0;
      m_index_q <= '0;
      n_index_q <= '0;
      sew_q <= '0;
      lambda_q <= '0;
      emul_c_q <= '0;
    end else if (flush_i) begin
      active_q <= 1'b0;
      empty_pending_q <= 1'b0;
      m_index_q <= '0;
      n_index_q <= '0;
    end else if (start_i || direct_start_i) begin
      active_q <= start_i && (m_i != '0) && (n_i != '0);
      empty_pending_q <= start_i && ((m_i == '0) || (n_i == '0));
      m_limit_q <= m_i;
      n_limit_q <= n_i;
      m_index_q <= '0;
      n_index_q <= '0;
      sew_q <= sew_i;
      lambda_q <= lambda_i;
      emul_c_q <= emul_c_i;
    end else begin
      if (empty_pending_q)
        empty_pending_q <= 1'b0;
      if (active_q) begin
        if (done_o) begin
          active_q <= 1'b0;
        end else if (n_index_q == (n_limit_q - 1'b1)) begin
          n_index_q <= '0;
          m_index_q <= m_index_q + 1'b1;
        end else begin
          n_index_q <= n_index_q + 1'b1;
        end
      end
    end
  end

  if (DIRECT_OPT) begin : gen_common_result_enable
    always_ff @(posedge clk) begin
      if (result_update) begin
        result_data_q <= result_data_d;
        result_strobe_q <= result_strobe_d;
      end
    end
  end else begin : gen_reference_result_enable
    // Preserve the REF partial-write coding so the default architecture and
    // its synthesis baseline remain unchanged.
    always_ff @(posedge clk) begin
      if (start_i || direct_start_i) begin
        result_data_q <= c_data_i;
        result_strobe_q <= '0;
      end else begin
        if (active_q) begin
          unique case (sew_q)
            3'd0: begin
              result_data_q[data_bit_index +: 8] <= acc_read_data_i[7:0];
              result_strobe_q[strobe_index +: 1] <= 1'b1;
            end
            3'd1: begin
              result_data_q[data_bit_index +: 16] <= acc_read_data_i[15:0];
              result_strobe_q[strobe_index +: 2] <= 2'b11;
            end
            3'd2: begin
              result_data_q[data_bit_index +: 32] <= acc_read_data_i;
              result_strobe_q[strobe_index +: 4] <= 4'hf;
            end
            default: ;
          endcase
        end
        if (direct_write_valid_i) begin
          for (int lane = 0; lane < DIRECT_LANES; lane++) begin
            if (direct_lane_active_i[lane]) begin
              unique case (sew_q)
                3'd0: begin
                  result_data_q[direct_data_bit_index[lane] +: 8] <=
                      direct_write_data_i[lane][7:0];
                  result_strobe_q[direct_strobe_index[lane] +: 1] <= 1'b1;
                end
                3'd1: begin
                  result_data_q[direct_data_bit_index[lane] +: 16] <=
                      direct_write_data_i[lane][15:0];
                  result_strobe_q[direct_strobe_index[lane] +: 2] <= 2'b11;
                end
                3'd2: begin
                  result_data_q[direct_data_bit_index[lane] +: 32] <=
                      direct_write_data_i[lane];
                  result_strobe_q[direct_strobe_index[lane] +: 4] <= 4'hf;
                end
                default: ;
              endcase
            end
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
      assert (!(start_i && busy_o))
          else $error("IME result packer restarted while busy");
      assert (!(start_i && direct_start_i))
          else $error("IME REF and OPT result paths started together");
      if (start_i || direct_start_i) begin
        assert ((sew_i <= 3'd2) &&
                ime_pkg::ime_is_power_of_two({2'b0, lambda_i}) &&
                ime_pkg::ime_is_power_of_two({4'b0, emul_c_i}) &&
                ime_pkg::ime_is_power_of_two(
                    9'(`VLEN >> (3 + sew_i))))
            else $error("IME result packer received non-power-of-two geometry");
      end
      if (active_q) begin
        assert ((m_index_q < m_limit_q) && (n_index_q < n_limit_q))
            else $error("IME result packer cell index out of range");
      end
      if (direct_write_valid_i) begin
        assert (!active_q && !empty_pending_q)
            else $error("IME direct result write overlapped sequential PACK");
        assert (direct_index_is_physical_i == DIRECT_INDEX_PREMAPPED)
            else $error("IME direct result index semantic mismatch");
        for (int lane = 0; lane < DIRECT_LANES; lane++) begin
          if (direct_lane_active_i[lane]) begin
            if (direct_index_is_physical_i) begin
              assert (direct_cell_index_i[lane] < MAX_C_REGS * `VLENB)
                  else $error("IME physical result index out of range");
            end else begin
              assert (direct_cell_index_i[lane] < MAX_CELLS)
                  else $error("IME logical result index out of range");
            end
          end
          for (int rhs = lane + 1; rhs < DIRECT_LANES; rhs++) begin
            assert (!(direct_lane_active_i[lane] &&
                      direct_lane_active_i[rhs] &&
                      (direct_c_flat_index[lane] ==
                       direct_c_flat_index[rhs])))
                else $error("IME direct result write collision");
          end
        end
      end
    end
  end
`endif
endmodule
