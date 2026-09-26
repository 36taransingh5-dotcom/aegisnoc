`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_aegis_fault_injection — deterministic hero demo + fault regression.
//
// Router tile (1,1). Demo flit 0xDEADBEEF = {dst_x=3, dst_y=1, payload=0xEADBEEF}
// so it leaves through the EAST port.
//
//   Demo A  clean protected flit            -> delivered EAST, no flags
//   Demo B  1 payload bit flipped (bit 12)  -> corrected, original delivered EAST
//   Demo B2 1 HEADER bit flipped (bit 31)   -> a baseline router misroutes it to
//           LOCAL; AegisNoC corrects the header BEFORE routing -> EAST, intact
//   Demo C  2 bits flipped (12 and 30)      -> flagged uncorrectable and dropped
//   Demo D  3 inputs contend for EAST       -> round-robin rotation, no starvation
//   Sweep   every one of the 39 codeword bits, end-to-end through the router
//   Sweep   39 double-bit pairs end-to-end  -> all dropped and counted
//   Burst   single errors on all 5 inputs in the same cycle -> counter +5 at once
//   Stall   faulty flit held under backpressure counts once, on acceptance;
//           corrupted junk on idle (in_valid=0) inputs never counts
// Every step self-checks; the error counters are checked exactly at the end.
// Optional waveform: +vcd  (writes build/aegis_demo.vcd)
// -----------------------------------------------------------------------------
module tb_aegis_fault_injection;
  import aegis_pkg::*;

  localparam int N   = NUM_PORTS;
  localparam int W   = FLIT_W;
  localparam int CWW = ECC_CW_W;
  localparam logic [31:0] DEMO_FLIT = 32'hDEAD_BEEF;

  logic             clk = 1'b0;
  logic             rst;
  logic [N-1:0]     in_valid;
  logic [N*CWW-1:0] in_data;
  logic [N-1:0]     in_ready;
  logic [N-1:0]     out_valid;
  logic [N*CWW-1:0] out_data;
  logic [N-1:0]     out_ready;
  logic             sec_flag, ded_flag;
  logic [31:0]      sec_count, ded_count;

  aegis_noc #(.CURRENT_X(2'd1), .CURRENT_Y(2'd1)) dut (
    .clk, .rst,
    .in_valid, .in_data, .in_ready,
    .out_valid, .out_data, .out_ready,
    .single_error_corrected(sec_flag), .double_error_detected(ded_flag),
    .corrected_error_count(sec_count), .uncorrectable_error_count(ded_count)
  );

  // Unprotected baseline router, used only to show what the same fault does
  // without ECC (Demo B2).
  logic [N-1:0]   b_in_valid;
  logic [N*W-1:0] b_in_data;
  logic [N-1:0]   b_in_ready;
  logic [N-1:0]   b_out_valid;
  logic [N*W-1:0] b_out_data;

  baseline_noc #(.CURRENT_X(2'd1), .CURRENT_Y(2'd1)) base (
    .clk, .rst,
    .in_valid(b_in_valid), .in_data(b_in_data), .in_ready(b_in_ready),
    .out_valid(b_out_valid), .out_data(b_out_data), .out_ready(5'b11111)
  );

  always #5 clk = ~clk;

  `include "ecc_ref_model.svh"

  // ---- Helpers ------------------------------------------------------------------
  function automatic string pname(int p);
    case (p)
      0: return "NORTH";
      1: return "SOUTH";
      2: return "EAST";
      3: return "WEST";
      4: return "LOCAL";
      default: return "NONE";
    endcase
  endfunction

  // string-typed so literals of different lengths are not space-padded
  function automatic string yes_no(bit b);
    if (b) return "YES";
    return "NO";
  endfunction

  function automatic string status_str(bit s, bit d);
    if (d) return "UNCORRECTABLE ERROR";
    if (s) return "error corrected";
    return "no error";
  endfunction

  function automatic string bit_role(int b);
    if (b == 38)      return "overall parity";
    else if (b >= 32) return $sformatf("check bit p%0d", b - 32);
    else if (b >= 30) return $sformatf("HEADER dst_x[%0d]", b - 30);
    else if (b >= 28) return $sformatf("HEADER dst_y[%0d]", b - 28);
    else              return $sformatf("payload bit %0d", b);
  endfunction

  // Hardware syndrome of input decoder p (hierarchical debug probe).
  function automatic logic [5:0] hw_syndrome(int p);
    case (p)
      0: return dut.g_dec[0].syndrome;
      1: return dut.g_dec[1].syndrome;
      2: return dut.g_dec[2].syndrome;
      3: return dut.g_dec[3].syndrome;
      default: return dut.g_dec[4].syndrome;
    endcase
  endfunction

  // ---- Output monitors (record every transfer) -------------------------------------
  localparam int OBS = 1024;
  int          obs_port [OBS];
  logic [38:0] obs_cw   [OBS];
  int          obs_wr = 0, obs_rd = 0;
  int          b_obs_port [OBS];
  logic [31:0] b_obs_flit [OBS];
  int          b_obs_wr = 0, b_obs_rd = 0;

  always @(negedge clk) begin
    if (!rst) begin
      for (int o = 0; o < N; o++) begin
        if (out_valid[o] && out_ready[o]) begin
          obs_port[obs_wr % OBS] = o;
          obs_cw[obs_wr % OBS]   = out_data[o*CWW +: CWW];
          obs_wr++;
        end
        if (b_out_valid[o]) begin
          b_obs_port[b_obs_wr % OBS] = o;
          b_obs_flit[b_obs_wr % OBS] = b_out_data[o*W +: W];
          b_obs_wr++;
        end
      end
    end
  end

  // ---- Stimulus tasks -------------------------------------------------------------
  // Offer codeword `cw` on input p until accepted. Returns the hardware syndrome
  // seen while offered and the registered flags one cycle after acceptance.
  task automatic send(input int p, input logic [38:0] cw,
                      output logic [5:0] syn_hw, output bit sec_seen, output bit ded_seen);
    @(negedge clk);
    in_valid[p]           = 1'b1;
    in_data[p*CWW +: CWW] = cw;
    #1;
    syn_hw = hw_syndrome(p);
    while (!in_ready[p]) @(negedge clk);
    @(posedge clk);                       // handshake happens on this edge
    @(negedge clk);
    in_valid[p]           = 1'b0;
    in_data[p*CWW +: CWW] = '0;
    sec_seen = sec_flag;                  // flags are registered: visible now
    ded_seen = ded_flag;
  endtask

  // Wait for the next AegisNoC output transfer.
  task automatic next_output(input int max_cycles, output int port, output logic [38:0] cw);
    int c;
    c = 0;
    while (obs_rd == obs_wr) begin
      @(negedge clk);
      c++;
      if (c > max_cycles) $fatal(1, "no output within %0d cycles", max_cycles);
    end
    port = obs_port[obs_rd % OBS];
    cw   = obs_cw[obs_rd % OBS];
    obs_rd++;
  endtask

  task automatic expect_silence(input int cycles, input string what);
    repeat (cycles) @(negedge clk);
    if (obs_rd != obs_wr)
      $fatal(1, "%s: unexpected output on %s (%h)", what, pname(obs_port[obs_rd % OBS]), obs_cw[obs_rd % OBS]);
  endtask

  // Expected totals, accumulated as faults are injected.
  int unsigned exp_sec = 0;
  int unsigned exp_ded = 0;

  task automatic line(); $display("  ------------------------------------------------------------"); endtask

  // ---- Demo -------------------------------------------------------------------------
  initial begin
    logic [38:0] cw, bad, got_cw;
    logic [31:0] got_flit;
    logic [5:0]  syn_hw;
    int          got_port;
    bit          sec_seen, ded_seen;
    logic [31:0] got_d;
    bit          r_sec, r_ded;
    int          r_syn;

    if ($test$plusargs("vcd")) begin
      $dumpfile("build/aegis_demo.vcd");
      $dumpvars(0, tb_aegis_fault_injection);
    end

    rst        = 1'b1;
    in_valid   = '0;
    in_data    = '0;
    out_ready  = '1;
    b_in_valid = '0;
    b_in_data  = '0;
    repeat (4) @(posedge clk);
    #2 rst = 1'b0;

    cw = ref_encode(DEMO_FLIT);

    $display("");
    $display("  ============================================================");
    $display("   AegisNoC live fault-injection demo      router tile (1,1)");
    $display("  ============================================================");

    // ---- Demo A: clean packet.
    $display("");
    $display("  [Demo A] Clean protected packet");
    line();
    send(PORT_L, cw, syn_hw, sec_seen, ded_seen);
    next_output(20, got_port, got_cw);
    got_flit = got_cw[31:0];
    $display("  Source port            : LOCAL");
    $display("  Destination            : (x=%0d, y=%0d)  -> expected exit EAST", DEMO_FLIT[31:30], DEMO_FLIT[29:28]);
    $display("  Original flit          : 0x%h   (payload 0x%h)", DEMO_FLIT, DEMO_FLIT[27:0]);
    $display("  Codeword sent (39 b)   : 0x%h", cw);
    $display("  ECC syndrome           : %b", syn_hw);
    $display("  Status                 : %s", status_str(sec_seen, ded_seen));
    $display("  Exit port              : %s", pname(got_port));
    $display("  Received flit          : 0x%h", got_flit);
    if (got_port != PORT_E || got_flit !== DEMO_FLIT || got_cw !== cw || sec_seen || ded_seen || syn_hw != 0)
      $fatal(1, "Demo A failed");
    $display("  RESULT                 : PASS");

    // ---- Demo B: single payload bit flip.
    $display("");
    $display("  [Demo B] Single-bit corruption in the payload");
    line();
    bad = cw ^ (39'd1 << 12);
    send(PORT_L, bad, syn_hw, sec_seen, ded_seen);
    next_output(20, got_port, got_cw);
    got_flit = got_cw[31:0];
    exp_sec++;
    $display("  Original flit          : 0x%h", DEMO_FLIT);
    $display("  Injected fault bit     : 12  (%s)", bit_role(12));
    $display("  Corrupted flit on wire : 0x%h", bad[31:0]);
    $display("  ECC syndrome           : %b  (= Hamming position %0d)", syn_hw, syn_hw);
    $display("  Single error corrected : %s", yes_no(sec_seen));
    $display("  Double error detected  : %s", yes_no(ded_seen));
    $display("  Exit port              : %s", pname(got_port));
    $display("  Received flit          : 0x%h", got_flit);
    if (got_port != PORT_E || got_flit !== DEMO_FLIT || !sec_seen || ded_seen || int'(syn_hw) != ref_phys_to_pos(12))
      $fatal(1, "Demo B failed");
    $display("  RESULT                 : PASS");

    // ---- Demo B2: single HEADER bit flip, baseline vs Aegis.
    $display("");
    $display("  [Demo B2] Single-bit corruption in the ROUTING HEADER (bit 31 = dst_x MSB)");
    line();
    bad = cw ^ (39'd1 << 31);
    // Baseline router receives the same corrupted logical flit.
    @(negedge clk);
    b_in_valid[PORT_L]      = 1'b1;
    b_in_data[PORT_L*W +: W] = bad[31:0];
    @(negedge clk);
    b_in_valid[PORT_L]      = 1'b0;
    repeat (4) @(negedge clk);
    if (b_obs_rd == b_obs_wr) $fatal(1, "baseline produced no output");
    $display("  Corrupted flit         : 0x%h  -> header now says x=%0d, y=%0d", bad[31:0], bad[31:30], bad[29:28]);
    $display("  BaselineNoC (no ECC)   : exits %-5s with flit 0x%h   <-- MISROUTED + CORRUPT",
             pname(b_obs_port[b_obs_rd % OBS]), b_obs_flit[b_obs_rd % OBS]);
    if (b_obs_port[b_obs_rd % OBS] != PORT_L) $fatal(1, "expected baseline to misroute to LOCAL");
    b_obs_rd++;
    send(PORT_L, bad, syn_hw, sec_seen, ded_seen);
    next_output(20, got_port, got_cw);
    got_flit = got_cw[31:0];
    exp_sec++;
    $display("  AegisNoC  (SECDED)     : exits %-5s with flit 0x%h   <-- header corrected before routing",
             pname(got_port), got_flit);
    $display("  ECC syndrome           : %b  (= Hamming position %0d)", syn_hw, syn_hw);
    $display("  Single error corrected : %s", yes_no(sec_seen));
    if (got_port != PORT_E || got_flit !== DEMO_FLIT || !sec_seen) $fatal(1, "Demo B2 failed");
    $display("  RESULT                 : PASS");

    // ---- Demo C: double-bit corruption.
    $display("");
    $display("  [Demo C] Double-bit corruption (bits 12 and 30)");
    line();
    bad = cw ^ (39'd1 << 12) ^ (39'd1 << 30);
    send(PORT_L, bad, syn_hw, sec_seen, ded_seen);
    exp_ded++;
    $display("  Original flit          : 0x%h", DEMO_FLIT);
    $display("  Injected fault bits    : 12 (%s), 30 (%s)", bit_role(12), bit_role(30));
    $display("  ECC syndrome           : %b  (overall parity even -> not a single error)", syn_hw);
    $display("  Single error corrected : %s", yes_no(sec_seen));
    $display("  Double error detected  : %s", yes_no(ded_seen));
    expect_silence(20, "Demo C");
    $display("  Delivery               : DROPPED (never routed on an uncorrectable header)");
    if (!ded_seen || sec_seen) $fatal(1, "Demo C failed");
    $display("  RESULT                 : PASS");

    // ---- Demo D: contention, 3 inputs -> EAST.
    $display("");
    $display("  [Demo D] Contention: NORTH, WEST and LOCAL all stream to EAST");
    line();
    begin
      int  src_seq [18];
      int  cnt [N];
      string order;
      for (int i = 0; i < N; i++) cnt[i] = 0;
      fork
        for (int k = 0; k < 6; k++) send(PORT_N, ref_encode({2'd3, 2'd1, 3'(PORT_N), 25'(k)}), syn_hw, sec_seen, ded_seen);
        for (int k = 0; k < 6; k++) send(PORT_W, ref_encode({2'd3, 2'd1, 3'(PORT_W), 25'(k)}), syn_hw, sec_seen, ded_seen);
        for (int k = 0; k < 6; k++) send(PORT_L, ref_encode({2'd3, 2'd1, 3'(PORT_L), 25'(k)}), syn_hw, sec_seen, ded_seen);
      join
      order = "";
      for (int k = 0; k < 18; k++) begin
        next_output(50, got_port, got_cw);
        if (got_port != PORT_E) $fatal(1, "Demo D: flit left through %s", pname(got_port));
        src_seq[k] = int'(got_cw[27:25]);
        cnt[src_seq[k]]++;
        begin
          string nm;
          nm = pname(src_seq[k]);
          order = {order, nm.substr(0, 0), " "};
        end
      end
      $display("  EAST grant order       : %s", order);
      $display("  Grants N / W / L       : %0d / %0d / %0d", cnt[PORT_N], cnt[PORT_W], cnt[PORT_L]);
      for (int k = 2; k < 18; k++)
        if (src_seq[k] == src_seq[k-1] || src_seq[k] == src_seq[k-2])
          $fatal(1, "Demo D: round-robin order violated at grant %0d", k);
      if (cnt[PORT_N] != 6 || cnt[PORT_W] != 6 || cnt[PORT_L] != 6) $fatal(1, "Demo D: unfair");
      $display("  RESULT                 : PASS (strict rotation, nobody starved)");
    end

    // ---- Sweep: every codeword bit, end-to-end through the router.
    $display("");
    $display("  [Sweep] Every single codeword bit (0..38) flipped, end-to-end");
    line();
    for (int b = 0; b < CWW; b++) begin
      int p;
      p = b % N;                                  // spread over all five inputs
      bad = cw ^ (39'd1 << b);
      send(p, bad, syn_hw, sec_seen, ded_seen);
      next_output(20, got_port, got_cw);
      exp_sec++;
      ref_decode(bad, got_d, r_sec, r_ded, r_syn);
      if (got_port != PORT_E || got_cw[31:0] !== DEMO_FLIT || !sec_seen || ded_seen || int'(syn_hw) != r_syn)
        $fatal(1, "sweep bit %0d (%s) via %s: port %s flit %h sec=%b ded=%b syn=%0d",
               b, bit_role(b), pname(p), pname(got_port), got_cw[31:0], sec_seen, ded_seen, syn_hw);
      if (got_cw !== cw) $fatal(1, "sweep bit %0d: output codeword not re-encoded cleanly", b);
    end
    $display("  39/39 bits corrected; every flit exited EAST as 0x%h with a clean codeword", DEMO_FLIT);
    $display("  (includes all 4 header bits, all 6 check bits and the overall parity bit)");
    $display("  RESULT                 : PASS");

    // ---- Sweep: double-bit pairs, end-to-end.
    $display("");
    $display("  [Sweep] 39 double-bit faults end-to-end (bit b and bit (b+7) mod 39)");
    line();
    for (int b = 0; b < CWW; b++) begin
      bad = cw ^ (39'd1 << b) ^ (39'd1 << ((b + 7) % CWW));
      send(b % N, bad, syn_hw, sec_seen, ded_seen);
      exp_ded++;
      if (!ded_seen || sec_seen) $fatal(1, "double sweep %0d: flags sec=%b ded=%b", b, sec_seen, ded_seen);
    end
    expect_silence(20, "double sweep");
    $display("  39/39 flagged uncorrectable and dropped; nothing reached an output");
    $display("  RESULT                 : PASS");

    // ---- Burst: single errors on all 5 inputs in the same cycle.
    $display("");
    $display("  [Burst] Single-bit faults on all 5 inputs in the SAME cycle");
    line();
    begin
      int unsigned c0;
      c0 = sec_count;
      @(negedge clk);
      for (int p = 0; p < N; p++) begin
        in_valid[p]           = 1'b1;
        in_data[p*CWW +: CWW] = ref_encode({2'd1, 2'd1, 3'(p), 25'h1_2345}) ^ (39'd1 << (3 + p));
      end
      @(posedge clk);
      @(negedge clk);
      in_valid = '0;
      if (!sec_flag) $fatal(1, "burst: flag not raised");
      @(negedge clk);
      exp_sec += 5;
      if (sec_count - c0 != 5) $fatal(1, "burst: counter moved by %0d, expected 5", sec_count - c0);
      for (int k = 0; k < N; k++) begin
        next_output(50, got_port, got_cw);
        if (got_port != PORT_L || got_cw[24:0] !== 25'h1_2345) $fatal(1, "burst: bad delivery");
      end
      $display("  corrected_error_count jumped by 5 in one cycle; all 5 flits delivered to LOCAL intact");
      $display("  RESULT                 : PASS");
    end

    // ---- Stall: a corrupted flit held while in_ready is low counts exactly once,
    //      and junk on an idle (in_valid=0) input never counts.
    $display("");
    $display("  [Stall] Faulty flit held under backpressure + junk on idle inputs");
    line();
    begin
      int unsigned c0;
      int          held;
      c0 = sec_count;
      out_ready[PORT_E] = 1'b0;
      // Fill LOCAL's FIFO (4) + EAST output register (1) with clean flits.
      for (int k = 0; k < FIFO_DEPTH + 1; k++) send(PORT_L, cw, syn_hw, sec_seen, ded_seen);
      // Idle inputs carry corrupted words with in_valid low: must not count.
      @(negedge clk);
      for (int p = 0; p < N; p++) if (p != PORT_L) in_data[p*CWW +: CWW] = cw ^ (39'd1 << p) ^ (39'd1 << (p + 9));
      in_valid[PORT_L]           = 1'b1;
      in_data[PORT_L*CWW +: CWW] = cw ^ (39'd1 << 5);
      held = 0;
      repeat (10) begin
        @(negedge clk);
        if (in_ready[PORT_L]) $fatal(1, "stall: LOCAL should be backpressured");
        if (sec_flag || ded_flag) $fatal(1, "stall: flag raised for a flit not yet accepted");
        held++;
      end
      if (sec_count != c0 || ded_count != exp_ded) $fatal(1, "stall: counters moved before acceptance");
      out_ready[PORT_E] = 1'b1;                     // release: the held flit is accepted once
      while (!in_ready[PORT_L]) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      in_valid[PORT_L] = 1'b0;
      in_data          = '0;
      if (!sec_flag) $fatal(1, "stall: flag not raised on acceptance");
      exp_sec++;
      @(negedge clk);
      if (sec_count - c0 != 1) $fatal(1, "stall: counter moved by %0d, expected 1", sec_count - c0);
      for (int k = 0; k < FIFO_DEPTH + 2; k++) begin
        next_output(50, got_port, got_cw);
        if (got_port != PORT_E || got_cw !== cw) $fatal(1, "stall: bad delivery %s %h", pname(got_port), got_cw);
      end
      $display("  held %0d cycles unaccepted: no flag, no count; counted exactly once on acceptance", held);
      $display("  RESULT                 : PASS");
    end

    // ---- Final counters.
    repeat (3) @(negedge clk);
    $display("");
    $display("  [Counters] corrected_error_count = %0d (expected %0d), uncorrectable_error_count = %0d (expected %0d)",
             sec_count, exp_sec, ded_count, exp_ded);
    if (sec_count != exp_sec || ded_count != exp_ded) $fatal(1, "error counters wrong");
    $display("");
    $display("TB_AEGIS_FAULT_INJECTION: PASS");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_AEGIS_FAULT_INJECTION: TIMEOUT");
  end

endmodule
