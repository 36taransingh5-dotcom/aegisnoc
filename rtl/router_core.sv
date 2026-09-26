// -----------------------------------------------------------------------------
// router_core — 5-port XY mesh router datapath, shared by BaselineNoC and AegisNoC.
//
// Pipeline (per flit):  input FIFO -> XY route of head -> per-output RR arbiter
//                       -> 5x5 crossbar -> per-output registered output stage
//
// Handshake (every channel): a transfer happens on a clock edge where
// valid && ready. Senders must hold valid and data stable until accepted.
//   * in_ready[i]  = FIFO i not full (never depends on in_valid or data)
//   * out_valid[o] / out_data[o] come directly from flops, so they are stable
//     while out_ready[o] is low by construction.
//
// Output stage o can load a new flit when it is empty or being drained this
// cycle:  load[o] = !out_valid[o] || out_ready[o].  The arbiter for output o
// only rotates (and the winning FIFO only pops) when load[o] is high.
// A FIFO head targets exactly one output, so at most one arbiter can grant a
// given input: pop[i] never has two sources.
//
// Latency: a flit accepted at edge t appears on out_valid after edge t+1.
// Throughput: 1 flit/cycle/output with out_ready held high.
// No combinational path from any input port to any output port.
// -----------------------------------------------------------------------------
module router_core #(
  parameter logic [aegis_pkg::COORD_W-1:0] CURRENT_X = 2'd1,
  parameter logic [aegis_pkg::COORD_W-1:0] CURRENT_Y = 2'd1
) (
  input  logic                                           clk,
  input  logic                                           rst,

  input  logic [aegis_pkg::NUM_PORTS-1:0]                in_valid,
  input  logic [aegis_pkg::NUM_PORTS*aegis_pkg::FLIT_W-1:0] in_data,
  output logic [aegis_pkg::NUM_PORTS-1:0]                in_ready,

  output logic [aegis_pkg::NUM_PORTS-1:0]                out_valid,
  output logic [aegis_pkg::NUM_PORTS*aegis_pkg::FLIT_W-1:0] out_data,
  input  logic [aegis_pkg::NUM_PORTS-1:0]                out_ready
);

  localparam int N  = aegis_pkg::NUM_PORTS;
  localparam int W  = aegis_pkg::FLIT_W;
  localparam int PW = aegis_pkg::PORT_IDX_W;
  localparam int CW = aegis_pkg::COORD_W;
  localparam int D  = aegis_pkg::FIFO_DEPTH;

  // ---- Input stage: FIFO + route computation per input ---------------------
  logic [N-1:0]    fifo_full;
  logic [N-1:0]    fifo_empty;
  logic [N-1:0]    fifo_pop;
  logic [N*W-1:0]  head;
  logic [N*PW-1:0] head_port;

  for (genvar i = 0; i < N; i++) begin : g_in
    /* verilator lint_off UNUSEDSIGNAL */
    logic [$clog2(D):0] fifo_count;   // debug only, not used by the datapath
    /* verilator lint_on UNUSEDSIGNAL */

    sync_fifo #(.WIDTH(W), .DEPTH(D)) u_fifo (
      .clk   (clk),
      .rst   (rst),
      .push  (in_valid[i]),
      .wdata (in_data[i*W +: W]),
      .pop   (fifo_pop[i]),
      .rdata (head[i*W +: W]),
      .full  (fifo_full[i]),
      .empty (fifo_empty[i]),
      .count (fifo_count)
    );

    assign in_ready[i] = !fifo_full[i];

    xy_route u_route (
      .cur_x    (CURRENT_X),
      .cur_y    (CURRENT_Y),
      .dst_x    (head[i*W + aegis_pkg::DX_LSB +: CW]),
      .dst_y    (head[i*W + aegis_pkg::DY_LSB +: CW]),
      .out_port (head_port[i*PW +: PW])
    );
  end

  // ---- Request matrix: req[o*N + i] = input i's head wants output o ---------
  logic [N*N-1:0] req;

  always_comb begin
    for (int o = 0; o < N; o++) begin
      for (int i = 0; i < N; i++) begin
        req[o*N + i] = !fifo_empty[i] && (head_port[i*PW +: PW] == PW'(o));
      end
    end
  end

  // ---- Per-output arbitration -----------------------------------------------
  logic [N-1:0]   out_valid_q;
  logic [N-1:0]   load;
  logic [N*N-1:0] grant;         // grant[o*N + i]

  for (genvar o = 0; o < N; o++) begin : g_arb
    assign load[o] = !out_valid_q[o] || out_ready[o];

    rr_arbiter #(.N(N)) u_arb (
      .clk    (clk),
      .rst    (rst),
      .req    (req[o*N +: N]),
      .accept (load[o]),
      .grant  (grant[o*N +: N])
    );
  end

  // An input pops when the output its head targets loads it this cycle.
  always_comb begin
    for (int i = 0; i < N; i++) begin
      fifo_pop[i] = 1'b0;
      for (int o = 0; o < N; o++) begin
        fifo_pop[i] = fifo_pop[i] | (grant[o*N + i] & load[o]);
      end
    end
  end

  // ---- Crossbar ---------------------------------------------------------------
  logic [N*W-1:0] xbar_out;

  crossbar_5x5 #(.W(W)) u_xbar (
    .in_data  (head),
    .sel      (grant),
    .out_data (xbar_out)
  );

  // ---- Registered output stage ----------------------------------------------
  logic [N*W-1:0] out_data_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      out_valid_q <= '0;
      out_data_q  <= '0;
    end else begin
      for (int o = 0; o < N; o++) begin
        if (load[o]) begin
          out_valid_q[o] <= |req[o*N +: N];
          if (|req[o*N +: N]) out_data_q[o*W +: W] <= xbar_out[o*W +: W];
        end
      end
    end
  end

  assign out_valid = out_valid_q;
  assign out_data  = out_data_q;

`ifdef FORMAL
  `include "router_properties.sv"
`endif

endmodule
