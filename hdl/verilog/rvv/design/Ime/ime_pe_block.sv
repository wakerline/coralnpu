// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

// IME counterpart of zvt_pe_block.  One copied mulbulk and one copied adder
// are shared by integer, floating-point, and MX cells.  MX time-multiplexes
// the same mulbulk for dot-product and scale multiplication, minimizing area.
module ime_pe_block #(
  parameter int M_PAR = 1,
  parameter int N_PAR = 1,
  parameter int K_PAR = 1,
  parameter int FP_LANES = 1,
  parameter bit INT_STREAM = 1'b0,
  parameter bit INT_PREEXT_OPT = 1'b0,
  parameter bit FP_ORDERED = 1'b0,
  parameter int SCALE_QUEUE_DEPTH = 4,
  parameter type TAG_TYPE = logic,
  localparam int CELLS = M_PAR * N_PAR,
  localparam int SCALE_PTR_WIDTH = SCALE_QUEUE_DEPTH > 1 ?
                                   $clog2(SCALE_QUEUE_DEPTH) : 1,
  localparam int SCALE_COUNT_WIDTH = $clog2(SCALE_QUEUE_DEPTH + 1)
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  input  logic [M_PAR-1:0][K_PAR-1:0][31:0]    a_i,
  input  logic [N_PAR-1:0][K_PAR-1:0][31:0]    b_i,
  input  logic [K_PAR-1:0]                      term_active_i,
  input  logic [CELLS-1:0]                      lane_active_i,
  input  logic [CELLS-1:0][31:0]                accumulator_i,
  input  logic                                  int_first_k_i,
  input  logic                                  is_fp_i,
  input  logic                                  ordered_fp_i,
  input  logic                                  scaled_i,
  input  logic [CELLS-1:0][31:0]                scale_i,
  input  fpnew_pkg::status_t [CELLS-1:0]        scale_status_i,
  input  logic [CELLS-1:0]                      scale_nan_i,
  input  logic [CELLS-1:0][1:0][63:0]           fp_operands_i,
  input  logic [CELLS-1:0][7:0]                 fp_mask_i,
  input  fpnew_pkg::roundmode_e                 rnd_mode_i,
  input  fpnew_pkg::roundmode_e                 final_rnd_mode_i,
  input  fpnew_pkg::fp_format_e                 fp_src_fmt_i,
  input  fpnew_pkg::fp_format_e                 fp_dst_fmt_i,
  input  logic                                  signed_a_i,
  input  logic                                  signed_b_i,
  input  logic [2:0]                            eew_log2_i,
  input  logic [2:0]                            sew_i,
  input  TAG_TYPE                               in_tag_i,
  input  logic                                  in_valid_i,
  output logic                                  in_ready_o,
  input  logic                                  flush_i,
  output logic [CELLS-1:0][31:0]                result_o,
  output fpnew_pkg::status_t [CELLS-1:0]        status_o,
  output TAG_TYPE                               out_tag_o,
  output logic                                  forced_scale_nan_o,
  output logic                                  out_valid_o,
  input  logic                                  out_ready_i,
  output logic                                  busy_o
);
  typedef struct packed {
    TAG_TYPE                         user;
    logic [CELLS-1:0][31:0]          accumulator;
    logic [2:0]                      sew;
    logic                            is_fp;
    logic                            ordered_fp;
    logic                            int_first_k;
    logic                            scaled;
    logic                            scale_phase;
    fpnew_pkg::roundmode_e           rnd_mode;
    logic [CELLS-1:0]                lane_active;
    logic [CELLS-1:0][31:0]          scale;
    fpnew_pkg::status_t [CELLS-1:0]  scale_status;
    logic [CELLS-1:0]                scale_nan;
    fpnew_pkg::status_t [CELLS-1:0]  accrued_status;
  } mul_tag_t;

  typedef struct packed {
    mul_tag_t                         tag;
    logic [CELLS-1:0][31:0]           partial;
  } scale_entry_t;

  typedef struct packed {
    TAG_TYPE            user;
    logic               forced_scale_nan;
  } add_tag_t;

  logic [M_PAR-1:0][K_PAR-1:0][31:0] mul_a;
  logic [N_PAR-1:0][K_PAR-1:0][31:0] mul_b;
  logic [K_PAR-1:0]                   mul_term_active;
  logic [CELLS-1:0]                   mul_lane_active;
  logic                               mul_is_fp;
  logic [CELLS-1:0][1:0][63:0]        mul_fp_operands;
  logic [CELLS-1:0][7:0]              mul_fp_mask;
  fpnew_pkg::roundmode_e              mul_rnd_mode;
  fpnew_pkg::fp_format_e              mul_src_fmt;
  fpnew_pkg::fp_format_e              mul_dst_fmt;
  logic                               mul_signed_a;
  logic                               mul_signed_b;
  logic [2:0]                         mul_eew;
  logic [2:0]                         mul_sew;
  mul_tag_t                           mul_tag_in;
  mul_tag_t                           mul_tag_out;
  logic                               mul_in_valid;
  logic                               mul_in_ready;
  logic [CELLS-1:0][31:0]             mul_partial;
  fpnew_pkg::status_t [CELLS-1:0]     mul_status;
  logic                               mul_out_valid;
  logic                               mul_out_ready;
  logic                               mul_busy;
  logic                               block_active_q;

  logic                               stream_int_input;
  logic                               stream_int_output;
  logic                               stream_out_valid_q;
  logic                               stream_out_ready;
  logic [CELLS-1:0][31:0]             stream_acc_q;
  logic [CELLS-1:0][31:0]             stream_sum;
  logic [CELLS-1:0][31:0]             stream_result_q;
  TAG_TYPE                            stream_tag_q;

  mul_tag_t scale_pending_q;
  logic [CELLS-1:0][31:0] scale_partial_q;
  logic scale_pending_valid_q;
  scale_entry_t scale_queue_q [SCALE_QUEUE_DEPTH];
  logic [SCALE_PTR_WIDTH-1:0] scale_head_q;
  logic [SCALE_PTR_WIDTH-1:0] scale_tail_q;
  logic [SCALE_COUNT_WIDTH-1:0] scale_count_q;
  logic [SCALE_COUNT_WIDTH-1:0] scale_reserved_q;
  scale_entry_t scale_head_entry;

  logic needs_scale;
  logic ordered_fp_input;
  logic ordered_scale_output;
  logic ordered_scale_credit;
  logic select_ordered_scale;
  logic select_reference_scale;
  logic select_scale;
  logic external_fire;
  logic ordered_scale_issue_fire;
  logic ordered_scale_enqueue_fire;
  logic external_idle;
  logic add_in_valid;
  logic add_in_ready;
  logic [CELLS-1:0][31:0] add_accumulator;
  fpnew_pkg::status_t [CELLS-1:0] add_partial_status;
  add_tag_t add_tag_in;
  add_tag_t add_tag_out;
  logic [CELLS-1:0][31:0] add_result;
  fpnew_pkg::status_t [CELLS-1:0] add_status;
  logic add_out_valid;
  logic add_out_ready;
  logic add_busy;

`ifdef ZVVFMM_ON
  // FP/MX commands continue through the reference adder even when ordinary
  // integer streaming is enabled in the same build.
  localparam bit NEED_REFERENCE_ADDER = 1'b1;
`else
  // In an integer-only streaming build every legal command completes in the
  // modulo-SEW recurrence below.  Express that feature boundary statically so
  // synthesis does not retain the unreachable three-stage reference adder.
  localparam bit NEED_REFERENCE_ADDER = !INT_STREAM;
`endif

  assign stream_int_input = INT_STREAM && !is_fp_i;
  assign stream_int_output = INT_STREAM && mul_out_valid &&
                             !mul_tag_out.is_fp;
  assign needs_scale = mul_tag_out.is_fp && mul_tag_out.scaled &&
                       !mul_tag_out.scale_phase;
  assign ordered_fp_input = FP_ORDERED && ordered_fp_i && is_fp_i;
  assign ordered_scale_output = needs_scale && mul_tag_out.ordered_fp;
  assign ordered_scale_credit = !scaled_i ||
      (scale_reserved_q < SCALE_COUNT_WIDTH'(SCALE_QUEUE_DEPTH));
  assign select_ordered_scale = FP_ORDERED && (scale_count_q != '0);
  assign select_reference_scale = scale_pending_valid_q;
  assign select_scale = select_ordered_scale || select_reference_scale;
  assign external_idle = !block_active_q;
  assign in_ready_o = !select_scale && mul_in_ready &&
      (ordered_fp_input ? ordered_scale_credit :
       (stream_int_input ? !scale_pending_valid_q : external_idle));
  assign external_fire = in_valid_i && in_ready_o;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      block_active_q <= 1'b0;
    end else if (flush_i) begin
      block_active_q <= 1'b0;
    end else begin
      if (in_valid_i && in_ready_o && !stream_int_input && !ordered_fp_input)
        block_active_q <= 1'b1;
      if (block_active_q && out_valid_o && out_ready_i)
        block_active_q <= 1'b0;
    end
  end

  always_comb begin
    mul_a = a_i;
    mul_b = b_i;
    mul_term_active = term_active_i;
    mul_lane_active = lane_active_i;
    mul_is_fp = is_fp_i;
    mul_fp_operands = fp_operands_i;
    mul_fp_mask = fp_mask_i;
    mul_rnd_mode = rnd_mode_i;
    mul_src_fmt = fp_src_fmt_i;
    mul_dst_fmt = fp_dst_fmt_i;
    mul_signed_a = signed_a_i;
    mul_signed_b = signed_b_i;
    mul_eew = eew_log2_i;
    mul_sew = sew_i;
    mul_in_valid = !select_scale &&
        (ordered_fp_input ? ordered_scale_credit :
         (stream_int_input ? !scale_pending_valid_q : external_idle)) &&
        in_valid_i;

    mul_tag_in = '0;
    mul_tag_in.user = in_tag_i;
    mul_tag_in.accumulator = accumulator_i;
    mul_tag_in.sew = sew_i;
    mul_tag_in.is_fp = is_fp_i;
    mul_tag_in.ordered_fp = ordered_fp_input;
    mul_tag_in.int_first_k = int_first_k_i;
    mul_tag_in.scaled = scaled_i;
    mul_tag_in.scale_phase = 1'b0;
    mul_tag_in.rnd_mode = final_rnd_mode_i;
    mul_tag_in.lane_active = lane_active_i;
    mul_tag_in.scale = scale_i;
    mul_tag_in.scale_status = scale_status_i;
    mul_tag_in.scale_nan = scale_nan_i;
    mul_tag_in.accrued_status = '0;

    if (select_scale) begin
      automatic mul_tag_t selected_tag = select_ordered_scale ?
          scale_head_entry.tag : scale_pending_q;
      automatic logic [CELLS-1:0][31:0] selected_partial =
          select_ordered_scale ? scale_head_entry.partial : scale_partial_q;
      mul_a = '0;
      mul_b = '0;
      mul_term_active = '0;
      mul_lane_active = selected_tag.lane_active;
      mul_is_fp = 1'b1;
      mul_fp_operands = '0;
      mul_fp_mask = '0;
      mul_rnd_mode = selected_tag.rnd_mode;
      mul_src_fmt = fpnew_pkg::FP32;
      mul_dst_fmt = fpnew_pkg::FP32;
      mul_signed_a = 1'b0;
      mul_signed_b = 1'b0;
      mul_eew = 3'd5;
      mul_sew = selected_tag.sew;
      mul_tag_in = selected_tag;
      mul_in_valid = 1'b1;
      for (int lane = 0; lane < CELLS; lane++) begin
        mul_fp_operands[lane][0][31:0] =
            selected_tag.scale_nan[lane] ? 32'h3f80_0000 :
                                           selected_partial[lane];
        mul_fp_operands[lane][1][31:0] = selected_tag.scale[lane];
        mul_fp_mask[lane][3:0] =
            {4{selected_tag.lane_active[lane]}};
      end
    end
  end

  ime_pe_mulbulk #(
    .M_PAR(M_PAR),
    .N_PAR(N_PAR),
    .K_PAR(K_PAR),
    .FP_LANES(FP_LANES),
    .INT_PREEXT_OPT(INT_PREEXT_OPT),
    .TAG_TYPE(mul_tag_t)
  ) u_mulbulk (
    .clk(clk), .rst_n(rst_n),
    .a_i(mul_a), .b_i(mul_b),
    .term_active_i(mul_term_active),
    .lane_active_i(mul_lane_active),
    .is_fp_i(mul_is_fp),
    .fp_operands_i(mul_fp_operands),
    .fp_mask_i(mul_fp_mask),
    .rnd_mode_i(mul_rnd_mode),
    .fp_src_fmt_i(mul_src_fmt),
    .fp_dst_fmt_i(mul_dst_fmt),
    .signed_a_i(mul_signed_a), .signed_b_i(mul_signed_b),
    .eew_log2_i(mul_eew), .sew_i(mul_sew),
    .in_tag_i(mul_tag_in),
    .in_valid_i(mul_in_valid), .in_ready_o(mul_in_ready),
    .flush_i(flush_i),
    .partial_o(mul_partial), .status_o(mul_status),
    .out_tag_o(mul_tag_out),
    .out_valid_o(mul_out_valid), .out_ready_i(mul_out_ready),
    .busy_o(mul_busy)
  );

  // A dot result that requires MX scaling is captured before re-entering the
  // same mulbulk.  This register removes a ready-loop around the pipeline.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scale_pending_valid_q <= 1'b0;
    end else if (flush_i) begin
      scale_pending_valid_q <= 1'b0;
    end else begin
      if (mul_out_valid && mul_out_ready && needs_scale &&
          !mul_tag_out.ordered_fp) begin
        scale_pending_valid_q <= 1'b1;
        scale_pending_q <= mul_tag_out;
        scale_pending_q.scale_phase <= 1'b1;
        scale_partial_q <= mul_partial;
        for (int lane = 0; lane < CELLS; lane++) begin
          scale_pending_q.accrued_status[lane] <=
              mul_tag_out.scale_nan[lane] ?
                  mul_tag_out.scale_status[lane] :
                  (mul_status[lane] | mul_tag_out.scale_status[lane]);
          // Scale NaN terminates the output cell.  Do not evaluate C or
          // expose flags from the physically speculative dot computation.
          if (mul_tag_out.scale_nan[lane])
            scale_pending_q.accumulator[lane] <= 32'h0000_0000;
        end
      end
      if (select_reference_scale && mul_in_valid && mul_in_ready)
        scale_pending_valid_q <= 1'b0;
    end
  end

  assign scale_head_entry = scale_queue_q[scale_head_q];
  assign ordered_scale_issue_fire = select_ordered_scale &&
                                    mul_in_valid && mul_in_ready;
  assign ordered_scale_enqueue_fire = mul_out_valid && mul_out_ready &&
                                      ordered_scale_output;

  // Ordered FP/MX reserves one queue credit when a scaled dot is accepted.
  // The returned dot therefore cannot be blocked behind a full queue, while
  // the tagged FIFO decouples multiple scale phases from the shared mulbulk.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scale_head_q <= '0;
      scale_tail_q <= '0;
      scale_count_q <= '0;
      scale_reserved_q <= '0;
    end else if (flush_i) begin
      scale_head_q <= '0;
      scale_tail_q <= '0;
      scale_count_q <= '0;
      scale_reserved_q <= '0;
    end else begin
      if (ordered_scale_enqueue_fire) begin
        scale_queue_q[scale_tail_q].tag <= mul_tag_out;
        scale_queue_q[scale_tail_q].tag.scale_phase <= 1'b1;
        scale_queue_q[scale_tail_q].partial <= mul_partial;
        for (int lane = 0; lane < CELLS; lane++) begin
          scale_queue_q[scale_tail_q].tag.accrued_status[lane] <=
              mul_tag_out.scale_nan[lane] ?
                  mul_tag_out.scale_status[lane] :
                  (mul_status[lane] | mul_tag_out.scale_status[lane]);
          if (mul_tag_out.scale_nan[lane])
            scale_queue_q[scale_tail_q].tag.accumulator[lane] <= '0;
        end
        scale_tail_q <= scale_tail_q == SCALE_PTR_WIDTH'(
                            SCALE_QUEUE_DEPTH - 1) ? '0 :
                        scale_tail_q + 1'b1;
      end
      if (ordered_scale_issue_fire) begin
        scale_head_q <= scale_head_q == SCALE_PTR_WIDTH'(
                            SCALE_QUEUE_DEPTH - 1) ? '0 :
                        scale_head_q + 1'b1;
      end
      unique case ({ordered_scale_enqueue_fire, ordered_scale_issue_fire})
        2'b10: scale_count_q <= scale_count_q + 1'b1;
        2'b01: scale_count_q <= scale_count_q - 1'b1;
        default: ;
      endcase
      unique case ({external_fire && ordered_fp_input && scaled_i,
                    ordered_scale_issue_fire})
        2'b10: scale_reserved_q <= scale_reserved_q + 1'b1;
        2'b01: scale_reserved_q <= scale_reserved_q - 1'b1;
        default: ;
      endcase
    end
  end

  assign stream_out_ready = !stream_out_valid_q || out_ready_i;
  assign add_in_valid = mul_out_valid && !needs_scale && !stream_int_output;
  assign mul_out_ready = needs_scale ?
                         (mul_tag_out.ordered_fp ?
                          (scale_count_q < SCALE_COUNT_WIDTH'(
                              SCALE_QUEUE_DEPTH)) :
                          !scale_pending_valid_q) :
                         (stream_int_output ? stream_out_ready : add_in_ready);
  always_comb begin
    add_accumulator = mul_tag_out.accumulator;
    add_partial_status = '0;
    for (int lane = 0; lane < CELLS; lane++) begin
      add_partial_status[lane] = mul_status[lane] |
                                         mul_tag_out.accrued_status[lane];
    end
    add_tag_in.user = mul_tag_out.user;
    add_tag_in.forced_scale_nan =
        mul_tag_out.scale_phase &&
        (|(mul_tag_out.scale_nan & mul_tag_out.lane_active));
  end

  // Ordinary integer streaming bypasses the three-stage adder.  Products
  // remain in issue order in mulbulk, so this one-entry elastic stage can
  // perform the modulo-SEW recurrence at one accepted product per cycle.
  // first_k selects the C snapshot carried by that packet and therefore makes
  // stale local accumulator bits after flush or a block boundary irrelevant.
  always_comb begin
    stream_sum = '0;
    for (int lane = 0; lane < CELLS; lane++) begin
      automatic logic [31:0] base = mul_tag_out.int_first_k ?
                                    mul_tag_out.accumulator[lane] :
                                    stream_acc_q[lane];
      unique case (mul_tag_out.sew)
        3'd0: stream_sum[lane] =
            {24'b0, base[7:0] + mul_partial[lane][7:0]};
        3'd1: stream_sum[lane] =
            {16'b0, base[15:0] + mul_partial[lane][15:0]};
        3'd2: stream_sum[lane] = base + mul_partial[lane];
        default: stream_sum[lane] = '0;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stream_out_valid_q <= 1'b0;
    end else if (flush_i) begin
      stream_out_valid_q <= 1'b0;
    end else begin
      if (stream_out_ready) begin
        stream_out_valid_q <= mul_out_valid && stream_int_output;
        if (mul_out_valid && stream_int_output) begin
          stream_result_q <= stream_sum;
          stream_tag_q <= mul_tag_out.user;
        end
      end
      if (mul_out_valid && mul_out_ready && stream_int_output) begin
        for (int lane = 0; lane < CELLS; lane++) begin
          if (mul_tag_out.lane_active[lane])
            stream_acc_q[lane] <= stream_sum[lane];
        end
      end
    end
  end

  if (NEED_REFERENCE_ADDER) begin : gen_reference_adder
    ime_pe_adder #(
      .CELLS(CELLS),
      .FP_LANES(FP_LANES),
      .TAG_TYPE(add_tag_t)
    ) u_adder (
      .clk(clk), .rst_n(rst_n),
      .accumulator_i(add_accumulator),
      .partial_i(mul_partial),
      .partial_status_i(add_partial_status),
      .lane_active_i(mul_tag_out.lane_active),
      .is_fp_i(mul_tag_out.is_fp),
      .rnd_mode_i(mul_tag_out.rnd_mode),
      .sew_i(mul_tag_out.sew),
      .in_tag_i(add_tag_in),
      .in_valid_i(add_in_valid), .in_ready_o(add_in_ready),
      .flush_i(flush_i),
      .result_o(add_result), .status_o(add_status),
      .out_tag_o(add_tag_out),
      .out_valid_o(add_out_valid), .out_ready_i(add_out_ready),
      .busy_o(add_busy)
    );
  end else begin : gen_no_reference_adder
    assign add_in_ready = 1'b0;
    assign add_result = '0;
    assign add_status = '0;
    assign add_tag_out = '0;
    assign add_out_valid = 1'b0;
    assign add_busy = 1'b0;
  end

  assign add_out_ready = out_ready_i && !stream_out_valid_q;
  assign result_o = stream_out_valid_q ? stream_result_q : add_result;
  assign status_o = stream_out_valid_q ? '0 : add_status;
  assign out_tag_o = stream_out_valid_q ? stream_tag_q : add_tag_out.user;
  assign out_valid_o = stream_out_valid_q || add_out_valid;
  assign forced_scale_nan_o = add_out_valid &&
                              add_tag_out.forced_scale_nan;
  assign busy_o = block_active_q ||
      (INT_STREAM && (mul_busy || stream_out_valid_q)) ||
      (FP_ORDERED && (mul_busy || add_busy || (scale_count_q != '0) ||
                      (scale_reserved_q != '0)));

`ifndef SYNTHESIS
  initial begin
    assert (FP_LANES >= 1 && FP_LANES <= CELLS);
    assert (SCALE_QUEUE_DEPTH >= 1 && SCALE_QUEUE_DEPTH <= 8);
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else if (!flush_i) begin
      assert (!(scale_pending_valid_q && external_idle));
      assert (scale_count_q <= SCALE_COUNT_WIDTH'(SCALE_QUEUE_DEPTH));
      assert (scale_reserved_q <= SCALE_COUNT_WIDTH'(SCALE_QUEUE_DEPTH));
      assert (!(ordered_scale_enqueue_fire &&
                (scale_count_q == SCALE_COUNT_WIDTH'(SCALE_QUEUE_DEPTH))))
          else $error("IME ordered FP/MX scale queue overflow");
      assert (!(ordered_scale_issue_fire && (scale_count_q == '0)))
          else $error("IME ordered FP/MX scale queue underflow");
      assert (!(forced_scale_nan_o && !out_valid_o));
      assert (!(stream_out_valid_q && add_out_valid))
          else $error("IME stream and reference adders produced together");
      if (FP_ORDERED && mul_out_valid && ordered_scale_output) begin
        assert (scale_count_q < SCALE_COUNT_WIDTH'(SCALE_QUEUE_DEPTH))
            else $error("IME ordered FP/MX reserved scale credit was lost");
      end
      if (!INT_STREAM && !FP_ORDERED) begin
        assert (!((mul_busy || scale_pending_valid_q || add_busy) &&
                  !block_active_q));
      end else if (!FP_ORDERED || block_active_q) begin
        assert (!((scale_pending_valid_q || add_busy) && !block_active_q));
      end
    end
  end
`endif
endmodule
