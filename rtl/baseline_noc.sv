// -----------------------------------------------------------------------------
// baseline_noc — BaselineNoC top level: router_core with NO error protection.
//
// Identical routing architecture to aegis_noc (same router_core instance and
// parameters), so synthesis results differ only by the ECC/diagnostic logic.
//
// Channel format: 32-bit logical flit {dst_x[1:0], dst_y[1:0], payload[27:0]}.
// Port p occupies bits [p*32 +: 32] of in_data/out_data; p = N0 S1 E2 W3 L4.
// -----------------------------------------------------------------------------
module baseline_noc #(
  parameter logic [aegis_pkg::COORD_W-1:0] CURRENT_X = 2'd1,
  parameter logic [aegis_pkg::COORD_W-1:0] CURRENT_Y = 2'd1
) (
  input  logic                                              clk,
  input  logic                                              rst,

  input  logic [aegis_pkg::NUM_PORTS-1:0]                   in_valid,
  input  logic [aegis_pkg::NUM_PORTS*aegis_pkg::FLIT_W-1:0] in_data,
  output logic [aegis_pkg::NUM_PORTS-1:0]                   in_ready,

  output logic [aegis_pkg::NUM_PORTS-1:0]                   out_valid,
  output logic [aegis_pkg::NUM_PORTS*aegis_pkg::FLIT_W-1:0] out_data,
  input  logic [aegis_pkg::NUM_PORTS-1:0]                   out_ready
);

  router_core #(
    .CURRENT_X (CURRENT_X),
    .CURRENT_Y (CURRENT_Y)
  ) u_core (
    .clk       (clk),
    .rst       (rst),
    .in_valid  (in_valid),
    .in_data   (in_data),
    .in_ready  (in_ready),
    .out_valid (out_valid),
    .out_data  (out_data),
    .out_ready (out_ready)
  );

endmodule
