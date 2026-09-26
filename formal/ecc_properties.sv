// -----------------------------------------------------------------------------
// ecc_properties — formal proof harness for the SECDED encoder/decoder.
//
// Standalone combinational miter. All inputs are free, so each assertion is
// proven for EVERY value: all 2^32 data words, every bit position, and every
// possible 39-bit received word. (Simulation in tb_ecc covers 269 patterns;
// this closes the gap to all data.)
//
//   E1 clean codeword  -> data unchanged, no flags, syndrome 0
//   E2 any single-bit error at any of the 39 positions -> original data
//      recovered and single_error_corrected=1, double_error_detected=0
//   E3 any double-bit error (two distinct positions) -> double_error_detected=1,
//      single_error_corrected=0
//   E4 for ANY 39-bit input the two flags are mutually exclusive
//   E5 for ANY 39-bit input with no flag: it is a valid codeword and the data
//      passes through unmodified (no silent modification)
//   E6 for ANY 39-bit input flagged corrected: re-encoding the output gives a
//      valid codeword exactly one bit away from what was received
// -----------------------------------------------------------------------------
module ecc_properties #(
  parameter int GROUP = 0          // 0 = all groups; 1..6 = only E<GROUP> (one SAT instance each)
) (
  input logic [aegis_pkg::ECC_DATA_W-1:0] data,
  input logic [5:0]                       b1,
  input logic [5:0]                       b2,
  input logic [aegis_pkg::ECC_CW_W-1:0]   any_cw
);

  localparam int CW = aegis_pkg::ECC_CW_W;
  localparam int DW = aegis_pkg::ECC_DATA_W;

  logic [CW-1:0] cw, e1, e2;
  logic [DW-1:0] d0, d1, d2, d3;
  logic          sec0, ded0, sec1, ded1, sec2, ded2, sec3, ded3;
  logic [5:0]    syn0, syn1, syn2, syn3;
  logic [CW-1:0] recode3, diff3;

  ecc_secded_encoder u_enc (.data(data), .codeword(cw));

  assign e1 = CW'(1) << b1;
  assign e2 = CW'(1) << b2;

  ecc_secded_decoder u_dec_clean  (.codeword(cw),
    .data(d0), .single_error_corrected(sec0), .double_error_detected(ded0), .syndrome(syn0));
  ecc_secded_decoder u_dec_single (.codeword(cw ^ e1),
    .data(d1), .single_error_corrected(sec1), .double_error_detected(ded1), .syndrome(syn1));
  ecc_secded_decoder u_dec_double (.codeword(cw ^ e1 ^ e2),
    .data(d2), .single_error_corrected(sec2), .double_error_detected(ded2), .syndrome(syn2));
  ecc_secded_decoder u_dec_any    (.codeword(any_cw),
    .data(d3), .single_error_corrected(sec3), .double_error_detected(ded3), .syndrome(syn3));
  ecc_secded_encoder u_enc_any    (.data(d3), .codeword(recode3));

  assign diff3 = recode3 ^ any_cw;

  always_comb begin
    assume (b1 < 6'(CW));
    assume (b2 < 6'(CW));
    assume (b1 != b2);
  end

  if (GROUP == 0 || GROUP == 1) begin : g_e1
    always_comb assert (d0 == data && !sec0 && !ded0 && syn0 == '0);              // E1
  end
  if (GROUP == 0 || GROUP == 2) begin : g_e2
    always_comb assert (d1 == data && sec1 && !ded1);                             // E2
  end
  if (GROUP == 0 || GROUP == 3) begin : g_e3
    always_comb assert (ded2 && !sec2);                                           // E3
  end
  if (GROUP == 0 || GROUP == 4) begin : g_e4
    always_comb assert (!(sec3 && ded3));                                         // E4
  end
  if (GROUP == 0 || GROUP == 5) begin : g_e5
    always_comb if (!sec3 && !ded3) assert (diff3 == '0 && d3 == any_cw[DW-1:0]); // E5
  end
  if (GROUP == 0 || GROUP == 6) begin : g_e6
    always_comb if (sec3) assert (diff3 != '0 && (diff3 & (diff3 - 1'b1)) == '0); // E6
  end

  // Reachability (the assumptions are satisfiable and every branch is live).
  (* keep *) logic f_reach_single;
  (* keep *) logic f_reach_double;
  (* keep *) logic f_reach_any_corrected;
  (* keep *) logic f_reach_any_uncorrectable;
  assign f_reach_single            = sec1;
  assign f_reach_double            = ded2;
  assign f_reach_any_corrected     = sec3;
  assign f_reach_any_uncorrectable = ded3 && (^any_cw);   // odd-weight multi-bit case (s > 38)

endmodule
