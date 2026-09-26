// -----------------------------------------------------------------------------
// ecc_secded_decoder — SECDED check and single-bit correction.
//
// Pure combinational. Code, layout and syndrome table are in aegis_pkg.
//   syndrome s = received p[5:0] XOR parity recomputed from received data
//   q          = XOR of all 39 received bits (1 => odd number of flips)
//
// Correction: data bit i is inverted iff q=1 and s equals the H-matrix column
// of d_i, which is {ECC_M5[i], ..., ECC_M0[i]} (= its Hamming position).
// A single flip in a check bit or in the overall parity bit leaves the data
// untouched but is still reported as corrected (the codeword was repaired).
//
//   single_error_corrected = q & (s <= 38)
//   double_error_detected  = (~q & (s != 0)) | (q & (s > 38))
// The two flags are mutually exclusive. For uncorrectable words, `data` is the
// received data unmodified and must not be trusted.
// -----------------------------------------------------------------------------
module ecc_secded_decoder (
  input  logic [aegis_pkg::ECC_CW_W-1:0]   codeword,
  output logic [aegis_pkg::ECC_DATA_W-1:0] data,
  output logic                             single_error_corrected,
  output logic                             double_error_detected,
  output logic [aegis_pkg::ECC_PAR_W-1:0]  syndrome
);

  localparam int DW = aegis_pkg::ECC_DATA_W;
  localparam int PW = aegis_pkg::ECC_PAR_W;

  logic [DW-1:0] d_rx;
  logic [PW-1:0] p_rx;
  logic          q;
  logic          s_nonzero;
  logic          s_in_range;
  logic [DW-1:0] flip;

  assign d_rx = codeword[DW-1:0];
  assign p_rx = codeword[DW +: PW];

  assign syndrome[0] = p_rx[0] ^ (^(d_rx & aegis_pkg::ECC_M0));
  assign syndrome[1] = p_rx[1] ^ (^(d_rx & aegis_pkg::ECC_M1));
  assign syndrome[2] = p_rx[2] ^ (^(d_rx & aegis_pkg::ECC_M2));
  assign syndrome[3] = p_rx[3] ^ (^(d_rx & aegis_pkg::ECC_M3));
  assign syndrome[4] = p_rx[4] ^ (^(d_rx & aegis_pkg::ECC_M4));
  assign syndrome[5] = p_rx[5] ^ (^(d_rx & aegis_pkg::ECC_M5));

  assign q          = ^codeword;
  assign s_nonzero  = |syndrome;
  assign s_in_range = (syndrome <= PW'(aegis_pkg::ECC_MAX_POS));

  for (genvar i = 0; i < DW; i++) begin : g_flip
    localparam logic [PW-1:0] COL = {aegis_pkg::ECC_M5[i], aegis_pkg::ECC_M4[i],
                                     aegis_pkg::ECC_M3[i], aegis_pkg::ECC_M2[i],
                                     aegis_pkg::ECC_M1[i], aegis_pkg::ECC_M0[i]};
    assign flip[i] = q && (syndrome == COL);
  end

  assign data                   = d_rx ^ flip;
  assign single_error_corrected = q && s_in_range;
  assign double_error_detected  = (!q && s_nonzero) || (q && !s_in_range);

endmodule
