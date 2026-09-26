// -----------------------------------------------------------------------------
// arbiter_properties.sv — formal properties for rr_arbiter (white-box).
//
// `include`d at the end of rr_arbiter under `ifdef FORMAL.
//
// Proven for every input sequence:
//   A1 grant is one-hot-or-zero                         ($onehot0)
//   A2 no grant without a request
//   A3 work conserving: some request -> some grant
//   A4 pointer always addresses a real requester (ptr < N)
//   A5 the winner is the FIRST requester at/after ptr in circular order
//   A6 rotation: a consumed grant to i moves ptr to (i+1) mod N; otherwise ptr holds
//   A7 bounded waiting (starvation freedom): a requester that keeps requesting
//      is passed over by at most N-1 consumed grants. Made inductive with the
//      invariant  wait[i] + circular_distance(ptr, i) <= N-1.
// Reachability goals: a requester actually waits N-1 grants (the bound is
// tight); all requesters active and granted in turn.
// -----------------------------------------------------------------------------

  logic f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  logic f_consume;
  assign f_consume = accept && (req != '0);

  // Circular distance from ptr to each requester index (0..N-1 when ptr < N).
  logic [IW:0] f_dist [N];
  for (genvar i = 0; i < N; i++) begin : g_f_dist
    assign f_dist[i] = (IW'(i) >= ptr) ? ((IW+1)'(i) - {1'b0, ptr})
                                       : ((IW+1)'(i + N) - {1'b0, ptr});
  end

  // ---- Combinational properties ---------------------------------------------------
  always_comb begin
    assert ((grant & (grant - 1'b1)) == '0);          // A1
    assert ((grant & ~req) == '0);                    // A2
    assert ((req != '0) == (grant != '0));            // A3
    assert (ptr < IW'(N));                            // A4
  end

  // A5: nobody strictly closer to ptr (circularly) than the winner is requesting.
  for (genvar i = 0; i < N; i++) begin : g_f_first
    for (genvar j = 0; j < N; j++) begin : g_f_other
      if (i != j) begin : g_f_ne
        always_comb if (grant[i] && req[j]) assert (f_dist[j] > f_dist[i]);
      end
    end
  end

  // ---- A6: rotation ------------------------------------------------------------------
  logic [IW-1:0] f_expect_ptr;
  always_comb begin
    f_expect_ptr = ptr;
    for (int i = 0; i < N; i++) if (grant[i]) f_expect_ptr = (i == N-1) ? '0 : IW'(i + 1);
  end
  logic [IW-1:0] f_expect_ptr_q = '0;
  always_ff @(posedge clk) f_expect_ptr_q <= f_expect_ptr;

  always_ff @(posedge clk) begin
    if (f_past_valid && !$past(rst)) begin
      if ($past(f_consume)) assert (ptr == f_expect_ptr_q);
      else                  assert (ptr == $past(ptr));
    end
  end

  // ---- A7: bounded waiting ------------------------------------------------------------
  logic [3:0] f_wait [N];
  for (genvar i = 0; i < N; i++) begin : g_f_wait
    initial f_wait[i] = '0;
    always_ff @(posedge clk) begin
      if (rst || !req[i])              f_wait[i] <= '0;
      else if (f_consume && grant[i])  f_wait[i] <= '0;
      else if (f_consume)              f_wait[i] <= f_wait[i] + 4'd1;
    end
    always_comb begin
      assert (f_wait[i] <= 4'(N - 1));                                   // A7
      assert ({1'b0, f_wait[i]} + {{(4-IW){1'b0}}, f_dist[i]} <= 5'(N - 1)); // inductive strengthening
    end
  end

  // ---- Reachability goals ---------------------------------------------------------------
  (* keep *) logic f_reach_max_wait;
  (* keep *) logic f_reach_all_req;
  assign f_reach_max_wait = (f_wait[0] == 4'(N - 1)) && f_consume && grant[0];
  assign f_reach_all_req  = (req == '1) && f_consume && grant[N-1];
