`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_fifo — self-checking testbench for sync_fifo.
//
// Every cycle the DUT outputs (full, empty, count, head data) are compared
// against a reference queue model. Directed phases cover each PRD §12 item,
// then a seeded random phase stresses arbitrary push/pop interleavings.
// Any mismatch -> $fatal. Success -> "TB_FIFO: PASS".
// -----------------------------------------------------------------------------
module tb_fifo;

  localparam int W     = 32;
  localparam int DEPTH = 4;
  localparam int CW    = $clog2(DEPTH) + 1;

  logic          clk = 1'b0;
  logic          rst;
  logic          push;
  logic [W-1:0]  wdata;
  logic          pop;
  logic [W-1:0]  rdata;
  logic          full;
  logic          empty;
  logic [CW-1:0] count;

  sync_fifo #(.WIDTH(W), .DEPTH(DEPTH)) dut (
    .clk, .rst, .push, .wdata, .pop, .rdata, .full, .empty, .count
  );

  always #5 clk = ~clk;

  // ---- Reference model ------------------------------------------------------
  logic [W-1:0] model[$];
  int unsigned  n_checks = 0;
  int unsigned  n_push_ok = 0, n_pop_ok = 0, n_push_blk = 0, n_pop_blk = 0, n_both = 0;

  task automatic check_outputs(input string tag);
    n_checks++;
    if (full !== (model.size() == DEPTH))
      $fatal(1, "[%s] full=%0b expected %0b (model size %0d)", tag, full, model.size() == DEPTH, model.size());
    if (empty !== (model.size() == 0))
      $fatal(1, "[%s] empty=%0b expected %0b (model size %0d)", tag, empty, model.size() == 0, model.size());
    if (count !== CW'(model.size()))
      $fatal(1, "[%s] count=%0d expected %0d", tag, count, model.size());
    if (model.size() != 0 && rdata !== model[0])
      $fatal(1, "[%s] head=%h expected %h", tag, rdata, model[0]);
  endtask

  // Apply one cycle of stimulus: drive on negedge, check pre-edge state,
  // clock, then update the model with the operations that were legal.
  task automatic step(input logic p, input logic [W-1:0] d, input logic q, input string tag);
    bit do_p, do_q;
    @(negedge clk);
    push  = p;
    wdata = d;
    pop   = q;
    check_outputs(tag);
    do_p = p && (model.size() != DEPTH);
    do_q = q && (model.size() != 0);
    if (p && !do_p) n_push_blk++;
    if (q && !do_q) n_pop_blk++;
    if (do_p && do_q) n_both++;
    @(posedge clk);
    #1;                       // past NBA updates: DUT state is settled
    push = 1'b0;              // strobes never linger into an unmodelled cycle
    pop  = 1'b0;
    if (do_q) begin void'(model.pop_front()); n_pop_ok++;  end
    if (do_p) begin model.push_back(d);         n_push_ok++; end
  endtask

  task automatic idle(input string tag);
    step(1'b0, '0, 1'b0, tag);
  endtask

  // ---- Stimulus -------------------------------------------------------------
  // $random(seed) updates `seed` in place -> reproducible stream in every simulator.
  integer seed = 20260925;
  function automatic logic [31:0] rnd();
    return $random(seed);
  endfunction

  logic [W-1:0] pre_head;

  initial begin
    push  = 1'b0;
    pop   = 1'b0;
    wdata = '0;
    rst   = 1'b1;

    // Reset: hold for a few cycles with junk on the inputs; must stay empty.
    repeat (3) begin
      @(negedge clk);
      push  = 1'b1;           // pushes during reset must not stick
      wdata = 32'hBAD0_0000;
    end
    @(negedge clk);
    push = 1'b0;
    rst  = 1'b0;
    check_outputs("reset");
    $display("[tb_fifo] reset ............................ ok");

    // 1. Single push / pop.
    step(1'b1, 32'h1111_1111, 1'b0, "single_push");
    step(1'b0, '0,            1'b1, "single_pop");
    idle("single_after");
    $display("[tb_fifo] single push/pop .................. ok");

    // 2. Fill to full (ordering is checked when draining).
    for (int i = 0; i < DEPTH; i++) step(1'b1, 32'hA000_0000 + i, 1'b0, "fill");
    check_outputs("full_reached");
    if (!full) $fatal(1, "FIFO not full after %0d pushes", DEPTH);
    $display("[tb_fifo] fill to full ..................... ok");

    // 3. Blocked push while full: state and head must not change.
    pre_head = rdata;
    step(1'b1, 32'hDEAD_DEAD, 1'b0, "push_when_full");
    step(1'b1, 32'hDEAD_BEEF, 1'b0, "push_when_full2");
    idle("after_blocked_push");
    if (rdata !== pre_head) $fatal(1, "head changed by blocked push");
    $display("[tb_fifo] blocked push while full .......... ok");

    // 4. Simultaneous push+pop while full: only the pop happens.
    step(1'b1, 32'hFFFF_0001, 1'b1, "push_pop_when_full");
    idle("after_push_pop_full");
    $display("[tb_fifo] push+pop while full (pop only) ... ok");

    // 5. Drain to empty, verifying order.
    while (model.size() != 0) step(1'b0, '0, 1'b1, "drain");
    idle("drained");
    if (!empty) $fatal(1, "FIFO not empty after drain");
    $display("[tb_fifo] drain to empty + ordering ........ ok");

    // 6. Blocked pop while empty, then prove pointers are still consistent.
    step(1'b0, '0, 1'b1, "pop_when_empty");
    step(1'b0, '0, 1'b1, "pop_when_empty2");
    step(1'b1, 32'hC0DE_0001, 1'b0, "push_after_blocked_pop");
    step(1'b0, '0, 1'b1, "pop_after_blocked_pop");
    idle("after_blocked_pop");
    $display("[tb_fifo] blocked pop while empty .......... ok");

    // 7. Simultaneous push+pop while empty: only the push happens.
    step(1'b1, 32'hE000_0001, 1'b1, "push_pop_when_empty");
    idle("after_push_pop_empty");
    $display("[tb_fifo] push+pop while empty (push only) . ok");

    // 8. Simultaneous push+pop at every intermediate occupancy.
    for (int occ = 1; occ < DEPTH; occ++) begin
      while (model.size() < occ) step(1'b1, 32'hB000_0000 + model.size(), 1'b0, "occ_fill");
      while (model.size() > occ) step(1'b0, '0, 1'b1, "occ_trim");
      repeat (DEPTH + 2) step(1'b1, rnd(), 1'b1, "push_pop_mid");
      if (model.size() != occ) $fatal(1, "occupancy drifted during push+pop");
    end
    while (model.size() != 0) step(1'b0, '0, 1'b1, "occ_drain");
    $display("[tb_fifo] push+pop at every occupancy ...... ok");

    // 9. Seeded random stress, biased so full and empty are both hit often.
    for (int i = 0; i < 20000; i++) begin
      bit p, q;
      if ((i / 500) % 2 == 0) begin p = (rnd() % 100 < 70); q = (rnd() % 100 < 40); end
      else                    begin p = (rnd() % 100 < 35); q = (rnd() % 100 < 70); end
      step(p, rnd(), q, "random");
    end
    while (model.size() != 0) step(1'b0, '0, 1'b1, "final_drain");
    idle("final");
    $display("[tb_fifo] random stress (20000 cycles) ..... ok");

    if (n_push_blk == 0 || n_pop_blk == 0 || n_both == 0)
      $fatal(1, "coverage hole: blocked_push=%0d blocked_pop=%0d both=%0d", n_push_blk, n_pop_blk, n_both);

    $display("[tb_fifo] checks=%0d pushes=%0d pops=%0d blocked_push=%0d blocked_pop=%0d push+pop=%0d",
             n_checks, n_push_ok, n_pop_ok, n_push_blk, n_pop_blk, n_both);
    $display("TB_FIFO: PASS");
    $finish;
  end

  // Watchdog.
  initial begin
    #5_000_000;
    $fatal(1, "TB_FIFO: TIMEOUT");
  end

endmodule
