// -----------------------------------------------------------------------------
// aegis_noc — AegisNoC top level: router_core wrapped in SECDED protection.
//
// Channel format (every input and output port): 39-bit SECDED codeword
//   {P_overall, p[5:0], flit[31:0]}   (see aegis_pkg for the code definition)
// Port p occupies bits [p*39 +: 39] of in_data/out_data; p = N0 S1 E2 W3 L4.
//
// Data path per flit:
//   in_data --> ecc_secded_decoder --(corrected flit)--> router_core (same
//   instance/parameters as baseline_noc) --> ecc_secded_encoder --> out_data
// Routing therefore only ever sees corrected header bits.
//
// Uncorrectable (double-bit) flits: the handshake completes (in_ready is
// !fifo_full exactly as in the baseline) but the flit is DROPPED — it is never
// pushed into a FIFO, so a corrupt header can never be routed. It is counted.
//
// Diagnostics (off the routing path; 1-cycle latency by design):
//   sec_evt_q[i] / ded_evt_q[i] register "an accepted flit on input i was
//   corrected / was uncorrectable". From these flops:
//   single_error_corrected    = OR of sec_evt_q  (one-cycle pulse)
//   double_error_detected     = OR of ded_evt_q  (one-cycle pulse)
//   corrected_error_count     += number of corrected flits that cycle
//   uncorrectable_error_count += number of dropped flits that cycle
// Counters are 32-bit and wrap around (documented; no saturation logic).
// "Corrected" includes flips in check bits: the codeword was repaired even
// though the logical flit was unaffected.
// -----------------------------------------------------------------------------
module aegis_noc #(
  parameter logic [aegis_pkg::COORD_W-1:0] CURRENT_X = 2'd1,
  parameter logic [aegis_pkg::COORD_W-1:0] CURRENT_Y = 2'd1
) (
  input  logic                                                clk,
  input  logic                                                rst,

  input  logic [aegis_pkg::NUM_PORTS-1:0]                     in_valid,
  input  logic [aegis_pkg::NUM_PORTS*aegis_pkg::ECC_CW_W-1:0] in_data,
  output logic [aegis_pkg::NUM_PORTS-1:0]                     in_ready,

  output logic [aegis_pkg::NUM_PORTS-1:0]                     out_valid,
  output logic [aegis_pkg::NUM_PORTS*aegis_pkg::ECC_CW_W-1:0] out_data,
  input  logic [aegis_pkg::NUM_PORTS-1:0]                     out_ready,

  output logic                                                single_error_corrected,
  output logic                                                double_error_detected,
  output logic [31:0]                                         corrected_error_count,
  output logic [31:0]                                         uncorrectable_error_count
);

  localparam int N  = aegis_pkg::NUM_PORTS;
  localparam int W  = aegis_pkg::FLIT_W;
  localparam int CW = aegis_pkg::ECC_CW_W;
  localparam int PW = aegis_pkg::ECC_PAR_W;

  // ---- Input boundary: decode + correct ----------------------------------------
  logic [N*W-1:0] dec_data;
  logic [N-1:0]   dec_sec;
  logic [N-1:0]   dec_ded;
  logic [N-1:0]   core_in_valid;

  for (genvar i = 0; i < N; i++) begin : g_dec
    /* verilator lint_off UNUSEDSIGNAL */
    logic [PW-1:0] syndrome;   // debug visibility (waveforms / demo), not used by logic
    /* verilator lint_on UNUSEDSIGNAL */

    ecc_secded_decoder u_dec (
      .codeword               (in_data[i*CW +: CW]),
      .data                   (dec_data[i*W +: W]),
      .single_error_corrected (dec_sec[i]),
      .double_error_detected  (dec_ded[i]),
      .syndrome               (syndrome)
    );

    // Uncorrectable flits never enter the router.
    assign core_in_valid[i] = in_valid[i] && !dec_ded[i];
  end

  // ---- Shared router (identical to baseline_noc) ----------------------------------
  logic [N*W-1:0] core_out_data;

  router_core #(
    .CURRENT_X (CURRENT_X),
    .CURRENT_Y (CURRENT_Y)
  ) u_core (
    .clk       (clk),
    .rst       (rst),
    .in_valid  (core_in_valid),
    .in_data   (dec_data),
    .in_ready  (in_ready),
    .out_valid (out_valid),
    .out_data  (core_out_data),
    .out_ready (out_ready)
  );

  // ---- Output boundary: re-encode -------------------------------------------------
  for (genvar o = 0; o < N; o++) begin : g_enc
    ecc_secded_encoder u_enc (
      .data     (core_out_data[o*W +: W]),
      .codeword (out_data[o*CW +: CW])
    );
  end

  // ---- Error events, flags and counters -------------------------------------------
  logic [N-1:0] accepted;
  logic [N-1:0] sec_evt_q;
  logic [N-1:0] ded_evt_q;
  logic [2:0]   n_sec;
  logic [2:0]   n_ded;

  assign accepted = in_valid & in_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      sec_evt_q <= '0;
      ded_evt_q <= '0;
    end else begin
      sec_evt_q <= accepted & dec_sec;
      ded_evt_q <= accepted & dec_ded;
    end
  end

  always_comb begin
    n_sec = '0;
    n_ded = '0;
    for (int i = 0; i < N; i++) begin
      n_sec = n_sec + {2'b00, sec_evt_q[i]};
      n_ded = n_ded + {2'b00, ded_evt_q[i]};
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      corrected_error_count     <= '0;
      uncorrectable_error_count <= '0;
    end else begin
      corrected_error_count     <= corrected_error_count     + {29'd0, n_sec};
      uncorrectable_error_count <= uncorrectable_error_count + {29'd0, n_ded};
    end
  end

  assign single_error_corrected = |sec_evt_q;
  assign double_error_detected  = |ded_evt_q;

endmodule
