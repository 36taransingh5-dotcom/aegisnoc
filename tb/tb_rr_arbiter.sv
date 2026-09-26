`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_rr_arbiter — self-checking testbench for rr_arbiter (N = 5).
//
// Every cycle:
//   * grant must equal a reference model (circular search from the pointer,
//     written differently from the RTL's masked-priority implementation)
//   * grant must be one-hot-or-zero and a subset of req
//   * bounded waiting: a requester that keeps requesting may be passed over by
//     at most N-1 consumed grants (checked with per-requester wait counters)
// Directed phases cover PRD §12: none, each, all, persistent contention,
// round-robin sequence, backpressure. Then a seeded random phase.
// -----------------------------------------------------------------------------
module tb_rr_arbiter;

  localparam int N = 5;

  logic         clk = 1'b0;
  logic         rst;
  logic [N-1:0] req;
  logic         accept;
  logic [N-1:0] grant;

  rr_arbiter #(.N(N)) dut (.clk, .rst, .req, .accept, .grant);

  always #5 clk = ~clk;

  // ---- Reference model + fairness bookkeeping --------------------------------
  int          model_ptr = 0;
  int          wait_cnt [N];
  int unsigned grants_to[N];
  int          max_wait = 0;
  int unsigned n_checks = 0;
  int          last_winner = -1;

  // Note: no early `return` inside loops — Icarus 13 crashes on that pattern.
  function automatic logic [N-1:0] model_grant(logic [N-1:0] r, int p);
    logic [N-1:0] g;
    bit found;
    int idx;
    g = '0;
    found = 0;
    for (int k = 0; k < N; k++) begin
      idx = (p + k) % N;
      if (!found && r[idx]) begin
        g[idx] = 1'b1;
        found = 1;
      end
    end
    return g;
  endfunction

  function automatic int index_of(logic [N-1:0] g);
    int idx;
    idx = -1;
    for (int i = N-1; i >= 0; i--) if (g[i]) idx = i;
    return idx;
  endfunction

  function automatic bit onehot0(logic [N-1:0] v);
    return (v & (v - 1'b1)) == '0;
  endfunction

  task automatic cycle(input logic [N-1:0] r, input logic a, input string tag);
    logic [N-1:0] exp_g;
    bit consumed;
    @(negedge clk);
    req    = r;
    accept = a;
    #1;
    n_checks++;
    exp_g = model_grant(r, model_ptr);
    if (grant !== exp_g)
      $fatal(1, "[%s] req=%b ptr=%0d: grant=%b expected %b", tag, r, model_ptr, grant, exp_g);
    if (!onehot0(grant))      $fatal(1, "[%s] grant %b not one-hot0", tag, grant);
    if ((grant & ~r) != '0)   $fatal(1, "[%s] grant %b without request %b", tag, grant, r);

    consumed = a && (r != '0);
    for (int i = 0; i < N; i++) begin
      if (!r[i]) begin
        wait_cnt[i] = 0;
      end else if (consumed) begin
        if (grant[i]) begin
          wait_cnt[i] = 0;
          grants_to[i]++;
        end else begin
          wait_cnt[i]++;
          if (wait_cnt[i] > max_wait) max_wait = wait_cnt[i];
          if (wait_cnt[i] > N-1)
            $fatal(1, "[%s] STARVATION: requester %0d passed over %0d times", tag, i, wait_cnt[i]);
        end
      end
    end

    @(posedge clk);
    #1;
    if (consumed) begin
      last_winner = index_of(exp_g);
      model_ptr   = (last_winner + 1) % N;
    end
  endtask

  // ---- Stimulus -------------------------------------------------------------
  integer seed = 5150;
  function automatic logic [31:0] rnd();
    return $random(seed);
  endfunction

  initial begin
    for (int i = 0; i < N; i++) begin wait_cnt[i] = 0; grants_to[i] = 0; end
    req    = '0;
    accept = 1'b0;
    rst    = 1'b1;
    repeat (3) @(negedge clk);
    rst = 1'b0;

    // 1. No requests: no grant, pointer must not move even with accept high.
    repeat (5) cycle('0, 1'b1, "no_req");
    if (model_ptr != 0) $fatal(1, "model pointer moved without requests");
    $display("[tb_rr_arbiter] no requests ................ ok");

    // 2. Each individual requester is granted alone.
    for (int i = 0; i < N; i++) cycle(N'(1) << i, 1'b1, "single");
    $display("[tb_rr_arbiter] each individual requester .. ok");

    // 3. All requesters, grant consumed every cycle: strict rotation.
    begin
      int prev;
      prev = -1;
      for (int c = 0; c < 3*N; c++) begin
        cycle('1, 1'b1, "all");
        if (prev >= 0 && last_winner != (prev + 1) % N)
          $fatal(1, "rotation broken: %0d after %0d", last_winner, prev);
        prev = last_winner;
      end
    end
    $display("[tb_rr_arbiter] all requesters rotate ...... ok");

    // 4. Persistent contention from a subset (Demo D shape: 3 ports -> 1 output).
    begin
      int unsigned grants_before [N];
      string seq;
      for (int i = 0; i < N; i++) grants_before[i] = grants_to[i];
      seq = "";
      for (int c = 0; c < 30; c++) begin
        cycle(5'b11010, 1'b1, "contention");
        seq = {seq, $sformatf("%0d ", last_winner)};
      end
      for (int i = 0; i < N; i++) begin
        int unsigned got;
        got = grants_to[i] - grants_before[i];
        if (i == 1 || i == 3 || i == 4) begin
          if (got != 10) $fatal(1, "unfair share: requester %0d got %0d of 30", i, got);
        end else if (got != 0) begin
          $fatal(1, "non-requester %0d was granted", i);
        end
      end
      $display("[tb_rr_arbiter] contention {1,3,4} grant sequence: %s", seq);
      $display("[tb_rr_arbiter] persistent contention ...... ok (10/10/10)");
    end

    // 5. Backpressure: accept low -> grant stable, pointer frozen.
    begin
      logic [N-1:0] held;
      cycle('1, 1'b0, "bp_first");
      held = grant;
      for (int c = 0; c < 8; c++) begin
        cycle('1, 1'b0, "bp_hold");
        if (grant !== held) $fatal(1, "grant changed under backpressure: %b -> %b", held, grant);
      end
      cycle('1, 1'b1, "bp_release");
      if (last_winner != index_of(held)) $fatal(1, "released grant is not the held one");
      cycle('1, 1'b1, "bp_after");
      if (last_winner != (index_of(held) + 1) % N) $fatal(1, "pointer did not advance after release");
    end
    $display("[tb_rr_arbiter] backpressure / accept gating  ok");

    // 6. Seeded random: mixed request densities and accept rates.
    for (int c = 0; c < 20000; c++) begin
      logic [N-1:0] r;
      logic a;
      case ((c / 1000) % 3)
        0: r = N'(rnd());                        // ~50% density
        1: r = N'(rnd()) | N'(rnd());            // ~75% density
        default: r = N'(rnd()) & N'(rnd());      // ~25% density
      endcase
      a = (rnd() % 100) < 70;
      cycle(r, a, "random");
    end
    $display("[tb_rr_arbiter] random (20000 cycles) ...... ok");

    for (int i = 0; i < N; i++)
      if (grants_to[i] == 0) $fatal(1, "coverage hole: requester %0d never granted", i);

    $display("[tb_rr_arbiter] checks=%0d grants=[%0d %0d %0d %0d %0d] worst_wait=%0d (bound %0d)",
             n_checks, grants_to[0], grants_to[1], grants_to[2], grants_to[3], grants_to[4],
             max_wait, N-1);
    $display("TB_RR_ARBITER: PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_RR_ARBITER: TIMEOUT");
  end

endmodule
