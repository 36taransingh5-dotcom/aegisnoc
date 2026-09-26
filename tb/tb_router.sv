`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_router — end-to-end self-checking testbench for the router.
//
// DUT: baseline_noc (default) or aegis_noc (+define+DUT_AEGIS). For Aegis the
// TB encodes every flit with an independent SECDED reference model and checks
// every output word is the exact codeword of the expected flit, so the SAME
// regression proves both tops route identically on clean traffic.
//
// Router tile at (1,1). Each flit carries {src[2:0], seq[24:0]} in its payload.
//
// Scoreboard: one expected queue per (output, source) pair, filled using an
// independent golden XY route. A flit is accepted only at the output its
// golden route predicts, and in order per (source, output) pair.
//
// Checked every cycle:
//   * stalled output (valid && !ready) keeps valid high and data stable
//   * no X on in_ready/out_valid, nor on out_data while valid (4-state sims)
//   * inputs carry random junk data while in_valid is low (catches sampling
//     data without valid)
// Directed checks: per-direction delivery + exact 2-cycle latency, all 25
// input/output pairs, contention with round-robin order, 5 outputs in
// parallel at full rate, backpressure with exact DEPTH+1 buffering, strict
// round-robin period under persistent load (with and without output
// backpressure), and seeded random traffic.
// -----------------------------------------------------------------------------
module tb_router;
  import aegis_pkg::*;

  localparam int N  = NUM_PORTS;
  localparam int W  = FLIT_W;
  localparam int QD = 8192;                  // TB queue depth (per queue)
  localparam logic [COORD_W-1:0] CX = 2'd1;
  localparam logic [COORD_W-1:0] CY = 2'd1;

  logic           clk = 1'b0;
  logic           rst;
  logic [N-1:0]   in_valid;
  logic [N*W-1:0] in_data;                   // logical flits driven by the TB
  logic [N-1:0]   in_ready;
  logic [N-1:0]   out_valid;
  logic [N*W-1:0] out_data;                  // logical flits seen by the TB
  logic [N-1:0]   out_ready;

  always #5 clk = ~clk;

`ifdef DUT_AEGIS
  // ---- Aegis: TB-side reference SECDED encode/decode ------------------------
  localparam int CWW = 39;
  logic [N*CWW-1:0] in_ch;
  logic [N*CWW-1:0] out_ch;
  logic             sec_flag, ded_flag;
  logic [31:0]      sec_count, ded_count;

  `include "ecc_ref_model.svh"

  always_comb begin
    for (int i = 0; i < N; i++) in_ch[i*CWW +: CWW] = ref_encode(in_data[i*W +: W]);
    for (int o = 0; o < N; o++) out_data[o*W +: W] = out_ch[o*CWW +: W];
  end

  aegis_noc #(.CURRENT_X(CX), .CURRENT_Y(CY)) dut (
    .clk, .rst,
    .in_valid, .in_data(in_ch), .in_ready,
    .out_valid, .out_data(out_ch), .out_ready,
    .single_error_corrected(sec_flag), .double_error_detected(ded_flag),
    .corrected_error_count(sec_count), .uncorrectable_error_count(ded_count)
  );
  `define TB_DUT_NAME "aegis_noc"
`else
  baseline_noc #(.CURRENT_X(CX), .CURRENT_Y(CY)) dut (
    .clk, .rst, .in_valid, .in_data, .in_ready, .out_valid, .out_data, .out_ready
  );
  `define TB_DUT_NAME "baseline_noc"
`endif

  // ---- Helpers -----------------------------------------------------------------
  function automatic string pname(int p);
    case (p)
      0: return "NORTH";
      1: return "SOUTH";
      2: return "EAST";
      3: return "WEST";
      4: return "LOCAL";
      default: return "???";
    endcase
  endfunction

  // Independent golden XY route (signed deltas).
  function automatic int golden_route(int dx, int dy);
    int ddx, ddy, r;
    ddx = dx - int'(CX);
    ddy = dy - int'(CY);
    if      (ddx > 0) r = PORT_E;
    else if (ddx < 0) r = PORT_W;
    else if (ddy > 0) r = PORT_N;
    else if (ddy < 0) r = PORT_S;
    else              r = PORT_L;
    return r;
  endfunction

  integer seed = 424242;
  function automatic int unsigned rnd();
    return $unsigned($random(seed));
  endfunction

  // ---- Queues -------------------------------------------------------------------
  logic [W-1:0] txq  [N][QD];
  int           tx_wr[N];
  int           tx_rd[N];
  logic [W-1:0] expq  [N*N][QD];             // index o*N + src
  int           exp_wr[N*N];
  int           exp_rd[N*N];
  int           seqno [N];

  int unsigned  n_sent = 0;
  int unsigned  n_recv = 0;

  task automatic enqueue(int src, int dx, int dy);
    logic [W-1:0] f;
    int o, k;
    f = {COORD_W'(dx), COORD_W'(dy), 3'(src), 25'(seqno[src])};
    seqno[src]++;
    if (tx_wr[src] - tx_rd[src] >= QD) $fatal(1, "TB tx queue overflow");
    txq[src][tx_wr[src] % QD] = f;
    tx_wr[src]++;
    o = golden_route(dx, dy);
    k = o*N + src;
    expq[k][exp_wr[k] % QD] = f;
    exp_wr[k]++;
    n_sent++;
  endtask

  // ---- Knobs (written by the control process at posedge+2) -----------------------
  bit          tb_run = 1'b0;
  int          valid_pct = 100;
  int          ready_pct [N];
  bit          check_latency = 1'b0;
  int          rr_out = -1;                  // output under strict-RR check (-1 = off)
  int          rr_k = 0;                     // number of persistent requesters

  // ---- Monitor state ------------------------------------------------------------------
  longint      cycle_no = 0;
  logic [N-1:0]   in_hold = '0;
  logic [N-1:0]   prev_stall = '0;
  logic [N*W-1:0] prev_data = '0;
  longint      in_fire_cycle [N];
  int unsigned n_accepted [N];
  int          last_out = -1;
  int          last_latency = -1;
  int          hist [N][4];                  // last sources seen per output
  int unsigned all5_cycles = 0;
  int unsigned n_stall_cycles = 0;
  int unsigned n_junk_cycles = 0;
  int unsigned n_rr_checked = 0;
  string       seq_log;
  bit          log_seq = 1'b0;

  function automatic bit src_in_recent(int o, int s, int k);
    bit found;
    found = 0;
    for (int j = 0; j < k; j++) if (hist[o][j] == s) found = 1;
    return found;
  endfunction

  task automatic check_receive(int o, logic [W-1:0] f);
    int src, k;
    logic [W-1:0] e;
    src = int'(f[27:25]);
    if (src >= N) $fatal(1, "out %s: flit %h has illegal source field", pname(o), f);
    k = o*N + src;
    if (exp_rd[k] == exp_wr[k])
      $fatal(1, "out %s: UNEXPECTED flit %h from %s (misroute, duplicate or spurious)",
             pname(o), f, pname(src));
    e = expq[k][exp_rd[k] % QD];
    if (f !== e)
      $fatal(1, "out %s from %s: got %h expected %h (reorder or corruption)", pname(o), pname(src), f, e);
    exp_rd[k]++;
    n_recv++;
    last_out     = o;
    last_latency = int'(cycle_no - in_fire_cycle[src]);
    if (check_latency && last_latency != 2)
      $fatal(1, "latency %0d cycles, expected 2 (src %s -> out %s)", last_latency, pname(src), pname(o));
    if (o == rr_out) begin
      if (src_in_recent(o, src, rr_k - 1))
        $fatal(1, "round-robin order violated at %s: src %s repeated within %0d grants (hist %0d %0d %0d)",
               pname(o), pname(src), rr_k - 1, hist[o][0], hist[o][1], hist[o][2]);
      n_rr_checked++;
    end
    if (log_seq && o == rr_out) begin
      string nm;
      nm = pname(src);
      seq_log = {seq_log, nm.substr(0, 0), " "};
    end
    for (int j = 3; j > 0; j--) hist[o][j] = hist[o][j-1];
    hist[o][0] = src;
  endtask

  // Single process drives inputs, checks outputs and accounts for the transfers
  // that will occur at the next posedge (all DUT outputs are flop-driven, so
  // they are stable from this negedge through the next posedge).
  always @(negedge clk) begin
    if (tb_run) begin
      int nf;
      cycle_no++;

      // 1. Output protocol checks.
      if ((^in_ready) === 1'bx || (^out_valid) === 1'bx) $fatal(1, "X on in_ready/out_valid");
      for (int o = 0; o < N; o++) begin
        if (prev_stall[o]) begin
          if (!out_valid[o]) $fatal(1, "out %s: valid dropped while stalled", pname(o));
          if (out_data[o*W +: W] !== prev_data[o*W +: W])
            $fatal(1, "out %s: data changed while stalled (%h -> %h)", pname(o),
                   prev_data[o*W +: W], out_data[o*W +: W]);
        end
        if (out_valid[o] && ((^out_data[o*W +: W]) === 1'bx))
          $fatal(1, "out %s: X on out_data while valid", pname(o));
`ifdef DUT_AEGIS
        if (out_valid[o] && out_ch[o*CWW +: CWW] !== ref_encode(out_data[o*W +: W]))
          $fatal(1, "out %s: codeword %h is not the SECDED encoding of flit %h", pname(o),
                 out_ch[o*CWW +: CWW], out_data[o*W +: W]);
`endif
      end

      // 2. Drive inputs (hold if the previous offer was not accepted).
      for (int i = 0; i < N; i++) begin
        if (in_hold[i]) begin
          // keep in_valid[i] and in_data[i] unchanged
        end else if (tx_rd[i] != tx_wr[i] && (rnd() % 100) < valid_pct) begin
          in_valid[i]       = 1'b1;
          in_data[i*W +: W] = txq[i][tx_rd[i] % QD];
        end else begin
          in_valid[i]       = 1'b0;
          in_data[i*W +: W] = rnd();                // junk while invalid
          n_junk_cycles++;
        end
      end

      // 3. Drive output ready.
      for (int o = 0; o < N; o++) out_ready[o] = ((rnd() % 100) < ready_pct[o]);

      // 4. Account for the transfers happening at the coming posedge.
      for (int i = 0; i < N; i++) begin
        in_hold[i] = in_valid[i] && !in_ready[i];
        if (in_valid[i] && in_ready[i]) begin
          tx_rd[i]++;
          in_fire_cycle[i] = cycle_no;
          n_accepted[i]++;
        end
      end
      nf = 0;
      for (int o = 0; o < N; o++) begin
        if (out_valid[o] && out_ready[o]) begin
          check_receive(o, out_data[o*W +: W]);
          nf++;
        end
        prev_stall[o] = out_valid[o] && !out_ready[o];
        if (prev_stall[o]) n_stall_cycles++;
      end
      prev_data = out_data;
      if (nf == N) all5_cycles++;
    end
  end

  // ---- Control-process helpers (act at posedge+2, never at negedge) --------------
  task automatic tick();
    @(posedge clk);
    #2;
  endtask

  task automatic set_ready_all(int pct);
    for (int o = 0; o < N; o++) ready_pct[o] = pct;
  endtask

  function automatic bit all_idle();
    bit idle;
    idle = (out_valid == '0) && (in_valid == '0);
    for (int i = 0; i < N; i++)   if (tx_rd[i] != tx_wr[i])   idle = 0;
    for (int k = 0; k < N*N; k++) if (exp_rd[k] != exp_wr[k]) idle = 0;
    return idle;
  endfunction

  task automatic wait_idle(int max_cycles, string tag);
    int c;
    c = 0;
    tick();
    while (!all_idle()) begin
      tick();
      c++;
      if (c > max_cycles) begin
        for (int k = 0; k < N*N; k++)
          if (exp_rd[k] != exp_wr[k])
            $display("  pending: %0d flit(s) %s -> %s", exp_wr[k] - exp_rd[k], pname(k % N), pname(k / N));
        $fatal(1, "[%s] TIMEOUT waiting for idle (%0d cycles): lost flit or deadlock", tag, max_cycles);
      end
    end
    repeat (2) tick();
  endtask

  task automatic reset_hist();
    for (int o = 0; o < N; o++) for (int j = 0; j < 4; j++) hist[o][j] = -1;
  endtask

  // Destination coordinates that make router (1,1) pick each output.
  function automatic int dest_x_for(int port);
    case (port)
      PORT_E:  return 3;
      PORT_W:  return 0;
      default: return 1;
    endcase
  endfunction
  function automatic int dest_y_for(int port);
    case (port)
      PORT_N:  return 3;
      PORT_S:  return 0;
      default: return 1;
    endcase
  endfunction

  // ---- Test sequence ------------------------------------------------------------------
  initial begin
    for (int i = 0; i < N; i++) begin
      tx_wr[i] = 0; tx_rd[i] = 0; seqno[i] = 0; in_fire_cycle[i] = 0; n_accepted[i] = 0;
      ready_pct[i] = 100;
    end
    for (int k = 0; k < N*N; k++) begin exp_wr[k] = 0; exp_rd[k] = 0; end
    reset_hist();

    rst       = 1'b1;
    in_valid  = '0;
    in_data   = '0;
    out_ready = '0;
    repeat (4) @(posedge clk);
    #2;
    rst = 1'b0;
    if (out_valid !== '0) $fatal(1, "out_valid not cleared by reset");
    if (in_ready !== '1)  $fatal(1, "in_ready not asserted after reset");
    tb_run = 1'b1;
    $display("[tb_router] DUT = %s, tile (%0d,%0d)", `TB_DUT_NAME, CX, CY);

    // ---- Phase 1: one flit per direction from LOCAL, and each cardinal input to LOCAL.
    check_latency = 1'b1;
    for (int p = 0; p < N; p++) begin
      enqueue(PORT_L, dest_x_for(p), dest_y_for(p));
      wait_idle(50, "direction");
      if (last_out != p) $fatal(1, "direction test: expected exit %s, got %s", pname(p), pname(last_out));
      $display("[tb_router] LOCAL in -> dst(%0d,%0d) -> exits %-5s latency=%0d cycles  ok",
               dest_x_for(p), dest_y_for(p), pname(last_out), last_latency);
    end
    for (int s = 0; s < 4; s++) begin
      enqueue(s, 1, 1);
      wait_idle(50, "to_local");
      if (last_out != PORT_L) $fatal(1, "local delivery failed from %s", pname(s));
    end
    $display("[tb_router] N/S/E/W inputs -> LOCAL delivery ......... ok");
    check_latency = 1'b0;

    // ---- Phase 2: every input to every output, all at once.
    for (int s = 0; s < N; s++)
      for (int p = 0; p < N; p++) enqueue(s, dest_x_for(p), dest_y_for(p));
    wait_idle(200, "all_pairs");
    $display("[tb_router] all 25 input->output pairs .............. ok");

    // ---- Phase 3: contention, 3 inputs -> EAST (Demo D shape).
    reset_hist();
    rr_out = PORT_E; rr_k = 3; log_seq = 1'b1; seq_log = "";
    for (int n = 0; n < 12; n++) begin
      enqueue(PORT_N, 3, 1);
      enqueue(PORT_W, 3, 1);
      enqueue(PORT_L, 3, 1);
    end
    wait_idle(200, "contention");
    log_seq = 1'b0; rr_out = -1;
    $display("[tb_router] 3 inputs contend for EAST, winners: %s", seq_log);
    $display("[tb_router] contention round-robin ................... ok");

    // ---- Phase 4: permutation traffic, all 5 outputs busy every cycle.
    all5_cycles = 0;
    for (int n = 0; n < 40; n++) begin
      enqueue(PORT_N, 1, 0);   // N in  -> S out
      enqueue(PORT_S, 1, 3);   // S in  -> N out
      enqueue(PORT_E, 0, 1);   // E in  -> W out
      enqueue(PORT_W, 3, 1);   // W in  -> E out
      enqueue(PORT_L, 1, 1);   // L in  -> L out
    end
    wait_idle(200, "parallel");
    if (all5_cycles < 38) $fatal(1, "parallel outputs: only %0d cycles with all 5 outputs firing", all5_cycles);
    $display("[tb_router] 5 outputs in parallel: %0d/40 cycles with 5 flits out  ok", all5_cycles);

    // ---- Phase 5: backpressure + FIFO buildup on EAST.
    begin
      int unsigned acc0;
      ready_pct[PORT_E] = 0;
      acc0 = n_accepted[PORT_L];
      for (int n = 0; n < 10; n++) enqueue(PORT_L, 3, 1);
      repeat (30) tick();
      if (n_accepted[PORT_L] - acc0 != FIFO_DEPTH + 1)
        $fatal(1, "backpressure: accepted %0d flits, expected %0d (FIFO %0d + output reg 1)",
               n_accepted[PORT_L] - acc0, FIFO_DEPTH + 1, FIFO_DEPTH);
      if (in_ready[PORT_L] !== 1'b0) $fatal(1, "backpressure: LOCAL in_ready should be low");
      if (out_valid[PORT_E] !== 1'b1) $fatal(1, "backpressure: EAST out_valid should be high");
      $display("[tb_router] backpressure: EAST stalled, LOCAL accepted %0d then in_ready=0 ok",
               n_accepted[PORT_L] - acc0);
      ready_pct[PORT_E] = 100;
      wait_idle(200, "backpressure_release");
      $display("[tb_router] backpressure release, in-order drain ...... ok");
    end

    // ---- Phase 6: strict round-robin period under persistent load.
    for (int pass = 0; pass < 2; pass++) begin
      reset_hist();
      rr_out = PORT_E; rr_k = 4;
      ready_pct[PORT_E] = (pass == 0) ? 100 : 50;
      for (int n = 0; n < 150; n++) begin
        enqueue(PORT_N, 3, 0);
        enqueue(PORT_S, 2, 3);
        enqueue(PORT_W, 3, 2);
        enqueue(PORT_L, 2, 1);
      end
      // check only while all four requesters stay backlogged
      while (tx_rd[PORT_N] < tx_wr[PORT_N] - 8 && tx_rd[PORT_S] < tx_wr[PORT_S] - 8 &&
             tx_rd[PORT_W] < tx_wr[PORT_W] - 8 && tx_rd[PORT_L] < tx_wr[PORT_L] - 8) tick();
      rr_out = -1;
      ready_pct[PORT_E] = 100;
      wait_idle(2000, "fairness");
      $display("[tb_router] fairness: 4 persistent requesters, EAST ready=%0d%%, strict RR period ok",
               (pass == 0) ? 100 : 50);
    end

    // ---- Phase 7: seeded random traffic with random backpressure.
    valid_pct = 70;
    set_ready_all(60);
    for (int n = 0; n < 3000; n++)
      for (int s = 0; s < N; s++) enqueue(s, int'(rnd() % 4), int'(rnd() % 4));
    wait_idle(200000, "random");
    valid_pct = 100;
    set_ready_all(100);
    $display("[tb_router] random traffic: 15000 flits, 70%% valid / 60%% ready ok");

    // ---- Final accounting.
    if (n_recv != n_sent) $fatal(1, "sent %0d received %0d", n_sent, n_recv);
    if (n_stall_cycles == 0 || n_junk_cycles == 0 || n_rr_checked == 0)
      $fatal(1, "coverage hole: stalls=%0d junk=%0d rr_checked=%0d", n_stall_cycles, n_junk_cycles, n_rr_checked);
`ifdef DUT_AEGIS
    if (sec_count != 0 || ded_count != 0)
      $fatal(1, "clean traffic raised ECC events: corrected=%0d uncorrectable=%0d", sec_count, ded_count);
    $display("[tb_router] clean traffic: 0 corrected, 0 uncorrectable ECC events ok");
`endif
    $display("[tb_router] sent=%0d received=%0d stall_cycles=%0d rr_checks=%0d cycles=%0d",
             n_sent, n_recv, n_stall_cycles, n_rr_checked, cycle_no);
    $display("TB_ROUTER: PASS");
    $finish;
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_ROUTER: TIMEOUT");
  end

endmodule
