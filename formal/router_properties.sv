// -----------------------------------------------------------------------------
// router_properties.sv — formal properties for router_core (white-box).
//
// `include`d at the end of router_core under `ifdef FORMAL. The five FIFOs and
// five arbiters carry their own properties (fifo/arbiter_properties.sv), which
// are therefore also re-proven in the integrated context.
//
// Proven for every input sequence (no assumptions on the environment):
//   R1 each output's grant vector is one-hot-or-zero
//   R2 a grant always corresponds to a non-empty input whose head routes there
//   R3 an input is consumed by at most one output per cycle
//   R4 a FIFO is never popped while empty; in_ready == !fifo_full
//   R5 route legality at every non-empty head (XY rules, legal port index):
//        dst_x > cur_x -> EAST, dst_x < cur_x -> WEST,
//        X equal: dst_y > cur_y -> NORTH, dst_y < cur_y -> SOUTH, same -> LOCAL
//   R6 crossbar: output o carries exactly the head of the input granted to it,
//      and zero when nothing is granted
//   R7 a stalled output (valid && !ready) keeps valid high and data stable
//   R8 a loaded output register holds exactly the granted head flit
//   R9 end-to-end routing: whenever output o is valid, the XY route of the
//      flit it presents (from this tile) IS o — no flit can leave the wrong port
// Reachability goals: all five outputs valid at once; an output stalled with
// a second flit waiting; two inputs contending for one output.
// -----------------------------------------------------------------------------

  logic f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // ---- Per-input properties ---------------------------------------------------------
  for (genvar i = 0; i < N; i++) begin : g_f_in
    logic [CW-1:0] f_dx, f_dy;
    logic [N-1:0]  f_served;
    assign f_dx = head[i*W + aegis_pkg::DX_LSB +: CW];
    assign f_dy = head[i*W + aegis_pkg::DY_LSB +: CW];
    for (genvar o = 0; o < N; o++) begin : g_f_srv
      assign f_served[o] = grant[o*N + i] & load[o];
    end

    always_comb begin
      assert ((f_served & (f_served - 1'b1)) == '0);                       // R3
      if (fifo_pop[i]) assert (!fifo_empty[i]);                            // R4
      assert (in_ready[i] == !fifo_full[i]);                               // R4
      if (!fifo_empty[i]) begin                                            // R5
        assert (head_port[i*PW +: PW] < PW'(N));
        if (f_dx > CURRENT_X) assert (head_port[i*PW +: PW] == aegis_pkg::PORT_E);
        if (f_dx < CURRENT_X) assert (head_port[i*PW +: PW] == aegis_pkg::PORT_W);
        if (f_dx == CURRENT_X && f_dy > CURRENT_Y) assert (head_port[i*PW +: PW] == aegis_pkg::PORT_N);
        if (f_dx == CURRENT_X && f_dy < CURRENT_Y) assert (head_port[i*PW +: PW] == aegis_pkg::PORT_S);
        if (f_dx == CURRENT_X && f_dy == CURRENT_Y) assert (head_port[i*PW +: PW] == aegis_pkg::PORT_L);
      end
    end
  end

  // ---- Per-output properties --------------------------------------------------------
  for (genvar o = 0; o < N; o++) begin : g_f_out
    logic [N-1:0]  f_g;
    logic [CW-1:0] f_odx, f_ody;
    logic [PW-1:0] f_oroute;
    assign f_g   = grant[o*N +: N];
    assign f_odx = out_data[o*W + aegis_pkg::DX_LSB +: CW];
    assign f_ody = out_data[o*W + aegis_pkg::DY_LSB +: CW];

    // Independent restatement of the XY rule for the presented flit.
    always_comb begin
      if      (f_odx > CURRENT_X) f_oroute = aegis_pkg::PORT_E;
      else if (f_odx < CURRENT_X) f_oroute = aegis_pkg::PORT_W;
      else if (f_ody > CURRENT_Y) f_oroute = aegis_pkg::PORT_N;
      else if (f_ody < CURRENT_Y) f_oroute = aegis_pkg::PORT_S;
      else                        f_oroute = aegis_pkg::PORT_L;
    end

    always_comb begin
      assert ((f_g & (f_g - 1'b1)) == '0);                                 // R1
      if (f_g == '0) assert (xbar_out[o*W +: W] == '0);                    // R6
      if (out_valid[o]) assert (f_oroute == PW'(o));                       // R9
    end

    for (genvar i = 0; i < N; i++) begin : g_f_gi
      always_comb if (f_g[i]) begin
        assert (!fifo_empty[i] && head_port[i*PW +: PW] == PW'(o));       // R2
        assert (xbar_out[o*W +: W] == head[i*W +: W]);                     // R6
      end
    end

    always_ff @(posedge clk) begin
      if (f_past_valid && !$past(rst)) begin
        if ($past(out_valid[o] && !out_ready[o]))                          // R7
          assert (out_valid[o] && out_data[o*W +: W] == $past(out_data[o*W +: W]));
        if ($past(load[o] && (f_g != '0)))                                 // R8
          assert (out_valid[o] && out_data[o*W +: W] == $past(xbar_out[o*W +: W]));
      end
    end
  end

  // ---- Reachability goals ---------------------------------------------------------------
  (* keep *) logic f_reach_all_out;
  (* keep *) logic f_reach_stall_backlog;
  (* keep *) logic f_reach_contention;
  assign f_reach_all_out       = (out_valid == '1);
  assign f_reach_stall_backlog = out_valid[aegis_pkg::PORT_E] && !out_ready[aegis_pkg::PORT_E] &&
                                 (req[aegis_pkg::PORT_E*N +: N] != '0);
  assign f_reach_contention    = ((req[aegis_pkg::PORT_E*N +: N] & (req[aegis_pkg::PORT_E*N +: N] - 1'b1)) != '0);
