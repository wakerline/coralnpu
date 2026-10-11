// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

// Captures complete A, B, C and optional v0.scale snapshots before execution.
// This is the mechanism that makes architecturally legal A/B/C overlap safe.
module ime_operand_fetch #(
  parameter int MAX_LMUL = 8,
  parameter int MAX_C_REGS = 16,
  parameter bit FETCH_PIPELINE = `IME_FETCH_PIPELINE
) (
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            flush_i,
`ifdef IME_OPERAND_RS
  input logic snapshot_valid_i,
  input logic [MAX_LMUL*`VLEN-1:0] snapshot_a_i, snapshot_b_i,
  input logic [MAX_C_REGS*`VLEN-1:0] snapshot_c_i,
`endif
  input  logic                            start_i,
  input  logic [4:0]                      vs1_i,
  input  logic [4:0]                      vs2_i,
  input  logic [4:0]                      vd_i,
  input  logic [3:0]                      lmul_i,
  input  logic [4:0]                      emul_c_i,
  input  logic                            capture_scale_i,
  output logic                            busy_o,
  output logic                            done_o,

  output logic                            vrf_read_req_valid_o,
  input  logic                            vrf_read_req_ready_i,
  output logic [`REGFILE_INDEX_WIDTH-1:0] vrf_read_index_o,
  output logic [1:0]                      vrf_read_operand_o,
  output logic [4:0]                      vrf_read_group_o,
  input  logic                            vrf_read_rsp_valid_i,
  output logic                            vrf_read_rsp_ready_o,
  input  logic [`VLEN-1:0]                vrf_read_data_i,
  input  logic [1:0]                      vrf_read_rsp_operand_i,
  input  logic [4:0]                      vrf_read_rsp_group_i,

  output logic [MAX_LMUL*`VLEN-1:0]       a_data_o,
  output logic [MAX_LMUL*`VLEN-1:0]       b_data_o,
  output logic [MAX_C_REGS*`VLEN-1:0]     c_data_o,
  output logic [`VLEN-1:0]                scale_data_o
);
  typedef enum logic [2:0] {
    FETCH_IDLE,
    FETCH_A,
    FETCH_B,
    FETCH_C,
    FETCH_SCALE
  } fetch_state_e;

  fetch_state_e state_q;
  logic [4:0] vs1_q;
  logic [4:0] vs2_q;
  logic [4:0] vd_q;
  logic [3:0] lmul_q;
  logic [4:0] emul_c_q;
  logic capture_scale_q;
  logic [4:0] group_q;
  logic response_pending_q;
  fetch_state_e request_state;
  logic [4:0] request_group;
  logic request_available;
  logic request_fire;
  logic response_fire;
  logic [MAX_LMUL*`VLEN-1:0] a_data_q;
  logic [MAX_LMUL*`VLEN-1:0] b_data_q;
  logic [MAX_C_REGS*`VLEN-1:0] c_data_q;
  logic [`VLEN-1:0] scale_data_q;

  assign busy_o = state_q != FETCH_IDLE;
  assign response_fire = vrf_read_rsp_valid_i && response_pending_q;
  assign request_fire = vrf_read_req_valid_o && vrf_read_req_ready_i;
`ifdef IME_OPERAND_RS
  logic snapshot_done_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) snapshot_done_q <= 1'b0;
    else if (flush_i) snapshot_done_q <= 1'b0;
    else snapshot_done_q <= start_i && snapshot_valid_i;
  end
`endif
  assign done_o =
`ifdef IME_OPERAND_RS
      snapshot_done_q ||
`endif
      response_fire &&
      (((state_q == FETCH_C) && (group_q == (emul_c_q - 1'b1)) &&
        !capture_scale_q) || (state_q == FETCH_SCALE));
  assign a_data_o = a_data_q;
  assign b_data_o = b_data_q;
  assign c_data_o = c_data_q;
  assign scale_data_o = scale_data_q;

  always_comb begin
    request_state = state_q;
    request_group = group_q;
    request_available = state_q != FETCH_IDLE;
    if (FETCH_PIPELINE && response_fire) begin
      unique case (state_q)
        FETCH_A: begin
          if (group_q == (lmul_q - 1'b1)) begin
            request_state = FETCH_B;
            request_group = '0;
          end else begin
            request_group = group_q + 1'b1;
          end
        end
        FETCH_B: begin
          if (group_q == (lmul_q - 1'b1)) begin
            request_state = FETCH_C;
            request_group = '0;
          end else begin
            request_group = group_q + 1'b1;
          end
        end
        FETCH_C: begin
          if (group_q == (emul_c_q - 1'b1)) begin
            request_state = capture_scale_q ? FETCH_SCALE : FETCH_IDLE;
            request_group = '0;
            request_available = capture_scale_q;
          end else begin
            request_group = group_q + 1'b1;
          end
        end
        FETCH_SCALE: begin
          request_state = FETCH_IDLE;
          request_group = '0;
          request_available = 1'b0;
        end
        default: request_available = 1'b0;
      endcase
    end

    vrf_read_req_valid_o = 1'b0;
    vrf_read_index_o = '0;
    vrf_read_operand_o = '0;
    vrf_read_group_o = request_group;
    unique case (request_state)
      FETCH_A: begin
        vrf_read_req_valid_o = request_available &&
            (!response_pending_q || (FETCH_PIPELINE && response_fire));
        vrf_read_index_o = vs1_q + request_group;
        vrf_read_operand_o = 2'd0;
      end
      FETCH_B: begin
        vrf_read_req_valid_o = request_available &&
            (!response_pending_q || (FETCH_PIPELINE && response_fire));
        vrf_read_index_o = vs2_q + request_group;
        vrf_read_operand_o = 2'd1;
      end
      FETCH_C: begin
        vrf_read_req_valid_o = request_available &&
            (!response_pending_q || (FETCH_PIPELINE && response_fire));
        vrf_read_index_o = vd_q + request_group;
        vrf_read_operand_o = 2'd2;
      end
      FETCH_SCALE: begin
        vrf_read_req_valid_o = request_available &&
            (!response_pending_q || (FETCH_PIPELINE && response_fire));
        vrf_read_index_o = '0;
        vrf_read_operand_o = 2'd3;
        vrf_read_group_o = '0;
      end
      default: ;
    endcase
  end
  // The backend VRF owns a one-entry response skid, so this consumer always
  // drains it and validates the echoed operand/group tags below.
  assign vrf_read_rsp_ready_o = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= FETCH_IDLE;
      vs1_q <= '0;
      vs2_q <= '0;
      vd_q <= '0;
      lmul_q <= '0;
      emul_c_q <= '0;
      capture_scale_q <= 1'b0;
      group_q <= '0;
      response_pending_q <= 1'b0;
    end else if (flush_i) begin
      state_q <= FETCH_IDLE;
      group_q <= '0;
      response_pending_q <= 1'b0;
    end else begin
      if (start_i) begin
        vs1_q <= vs1_i;
        vs2_q <= vs2_i;
        vd_q <= vd_i;
        lmul_q <= lmul_i;
        emul_c_q <= emul_c_i;
        capture_scale_q <= capture_scale_i;
        group_q <= '0;
        response_pending_q <= 1'b0;
        state_q <= FETCH_A;
`ifdef IME_OPERAND_RS
        if (snapshot_valid_i) begin
          state_q <= FETCH_IDLE;
          // Preserve out-of-domain storage exactly as serial FETCH does.
          // Every active C register is copied, including zero-strobe bytes.
          for (int g=0; g<MAX_LMUL; g++)
            if (g<lmul_i) begin
              a_data_q[g*`VLEN +: `VLEN] <= snapshot_a_i[g*`VLEN +: `VLEN];
              b_data_q[g*`VLEN +: `VLEN] <= snapshot_b_i[g*`VLEN +: `VLEN];
            end
          for (int g=0; g<MAX_C_REGS; g++)
            if (g<emul_c_i)
              c_data_q[g*`VLEN +: `VLEN] <= snapshot_c_i[g*`VLEN +: `VLEN];
        end
`endif
      end else begin
        unique case ({request_fire, response_fire})
          2'b10, 2'b11: response_pending_q <= 1'b1;
          2'b01: response_pending_q <= 1'b0;
          default: ;
        endcase

        if (response_fire) begin
          unique case (state_q)
            FETCH_A: begin
              a_data_q[vrf_read_rsp_group_i*`VLEN +: `VLEN] <=
                  vrf_read_data_i;
              if (group_q == (lmul_q - 1'b1)) begin
                group_q <= '0;
                state_q <= FETCH_B;
              end else begin
                group_q <= group_q + 1'b1;
              end
            end
            FETCH_B: begin
              b_data_q[vrf_read_rsp_group_i*`VLEN +: `VLEN] <=
                  vrf_read_data_i;
              if (group_q == (lmul_q - 1'b1)) begin
                group_q <= '0;
                state_q <= FETCH_C;
              end else begin
                group_q <= group_q + 1'b1;
              end
            end
            FETCH_C: begin
              c_data_q[vrf_read_rsp_group_i*`VLEN +: `VLEN] <=
                  vrf_read_data_i;
              if (group_q == (emul_c_q - 1'b1)) begin
                group_q <= '0;
                state_q <= capture_scale_q ? FETCH_SCALE : FETCH_IDLE;
              end else begin
                group_q <= group_q + 1'b1;
              end
            end
            FETCH_SCALE: begin
              scale_data_q <= vrf_read_data_i;
              group_q <= '0;
              state_q <= FETCH_IDLE;
            end
            default: ;
          endcase
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
      assert (!(start_i && busy_o))
          else $error("IME operand fetch restarted while busy");
      if (response_fire) begin
        assert (vrf_read_rsp_group_i ==
                ((state_q == FETCH_SCALE) ? 5'd0 : group_q))
            else $error("IME VRF response group tag mismatch");
        unique case (state_q)
          FETCH_A: assert (vrf_read_rsp_operand_i == 2'd0);
          FETCH_B: assert (vrf_read_rsp_operand_i == 2'd1);
          FETCH_C: assert (vrf_read_rsp_operand_i == 2'd2);
          FETCH_SCALE: assert (vrf_read_rsp_operand_i == 2'd3);
          default: assert (1'b0)
              else $error("IME consumed a VRF response outside capture");
        endcase
      end
      assert (!(request_fire && response_pending_q && !response_fire))
          else $error("IME operand fetch exceeded one logical outstanding request");
    end
  end
`endif
endmodule
