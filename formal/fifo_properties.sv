// -----------------------------------------------------------------------------
// fifo_properties.sv — formal properties for sync_fifo (white-box).
//
// `include`d at the end of sync_fifo under `ifdef FORMAL, so the properties
// see internal state (needed to make k-induction converge). Synthesis never
// defines FORMAL. Immediate SVA assertions + $past: supported by Yosys
// (read_verilog -formal) and Verilator (+define+FORMAL in simulation).
//
// Reference model: a SHIFT-REGISTER queue (structurally different from the
// DUT's circular buffer) with its own legality rules.
//
// Proven:
//   P1 occupancy never exceeds DEPTH (no logical overflow)
//   P2 full/empty flags agree with occupancy
//   P3 occupancy equals the reference model's
//   P4 pointer/count consistency: wptr - rptr == count (mod DEPTH)
//   P5 head equals the oldest element (ordering + data integrity)
//   P6 every live entry equals the model (strengthening invariant)
//   P7 push while full changes nothing; pop while empty changes nothing
//   P8 legal simultaneous push+pop keeps the count
// Reachability goals (must be FOUND by the bounded search): full, wrap-around
// of the write pointer while non-empty, simultaneous push+pop while full.
// -----------------------------------------------------------------------------

  logic f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // ---- Reference model -----------------------------------------------------------
  logic [WIDTH-1:0] f_q [0:DEPTH-1];
  logic [AW:0]      f_n = '0;
  logic             f_push;
  logic             f_pop;

  assign f_push = push && (f_n != DEPTH_C);
  assign f_pop  = pop  && (f_n != '0);

  always_ff @(posedge clk) begin
    if (rst) begin
      f_n <= '0;
    end else begin
      if (f_pop) begin
        for (int k = 0; k < DEPTH-1; k++) f_q[k] <= f_q[k+1];
      end
      if (f_push) f_q[AW'(f_n - {{AW{1'b0}}, f_pop})] <= wdata;   // < DEPTH when pushing; later NBA wins
      f_n <= f_n + {{AW{1'b0}}, f_push} - {{AW{1'b0}}, f_pop};
    end
  end

  // ---- State invariants (every cycle) ---------------------------------------------
  always_comb begin
    assert (cnt <= DEPTH_C);                                   // P1
    assert (full  == (cnt == DEPTH_C));                        // P2
    assert (empty == (cnt == '0));                             // P2
    assert (cnt == f_n);                                       // P3
    assert ((wptr - rptr) == cnt[AW-1:0]);                     // P4
    if (!empty) assert (rdata == f_q[0]);                      // P5
  end

  for (genvar k = 0; k < DEPTH; k++) begin : g_f_live
    logic [AW-1:0] f_idx;
    assign f_idx = rptr + AW'(k);
    always_comb if (AW'(k) < cnt[AW-1:0] || full) assert (mem[f_idx] == f_q[k]);   // P6
  end

  // ---- Transition properties ---------------------------------------------------------
  always_ff @(posedge clk) begin
    if (f_past_valid && !$past(rst)) begin
      if ($past(push && full && !pop))
        assert (cnt == $past(cnt) && wptr == $past(wptr) && rptr == $past(rptr));    // P7
      if ($past(pop && empty && !push))
        assert (cnt == $past(cnt) && wptr == $past(wptr) && rptr == $past(rptr));    // P7
      if ($past(push && pop && !full && !empty))
        assert (cnt == $past(cnt));                                                   // P8
    end
  end

  // ---- Reachability goals (non-vacuity) ------------------------------------------------
  logic [AW-1:0] f_wptr_q = '0;
  always_ff @(posedge clk) f_wptr_q <= wptr;

  (* keep *) logic f_reach_full;
  (* keep *) logic f_reach_wrap;
  (* keep *) logic f_reach_pushpop_full;
  assign f_reach_full         = full;
  assign f_reach_wrap         = f_past_valid && !empty && (wptr == '0) && (f_wptr_q == AW'(DEPTH-1));
  assign f_reach_pushpop_full = full && push && pop;
