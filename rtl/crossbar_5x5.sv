// -----------------------------------------------------------------------------
// crossbar_5x5 — combinational 5-input x 5-output flit crossbar.
//
// sel[o*N + i] = 1 connects input i to output o. Each output's select slice
// must be one-hot-or-zero; rr_arbiter guarantees this (and it is asserted in
// formal/router_properties.sv). Implemented as an AND-OR mux: no priority
// chain, balanced depth. An output with no select bit drives all zeros
// (deterministic default).
//
// Flat vectors: input i occupies in_data[i*W +: W], output o out_data[o*W +: W].
// -----------------------------------------------------------------------------
module crossbar_5x5 #(
  parameter int W = 32
) (
  input  logic [aegis_pkg::NUM_PORTS*W-1:0]                  in_data,
  input  logic [aegis_pkg::NUM_PORTS*aegis_pkg::NUM_PORTS-1:0] sel,
  output logic [aegis_pkg::NUM_PORTS*W-1:0]                  out_data
);

  localparam int N = aegis_pkg::NUM_PORTS;

  always_comb begin
    out_data = '0;
    for (int o = 0; o < N; o++) begin
      for (int i = 0; i < N; i++) begin
        out_data[o*W +: W] = out_data[o*W +: W] | ({W{sel[o*N + i]}} & in_data[i*W +: W]);
      end
    end
  end

endmodule
