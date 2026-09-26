// -----------------------------------------------------------------------------
// ecc_secded_encoder — SECDED Hamming(38,32) + overall parity -> 39-bit codeword.
//
// Pure combinational XOR trees. Code definition, codeword layout and syndrome
// interpretation are documented once, in aegis_pkg (ECC section).
//   codeword = {P_overall, p[5:0], data[31:0]}
// -----------------------------------------------------------------------------
module ecc_secded_encoder (
  input  logic [aegis_pkg::ECC_DATA_W-1:0] data,
  output logic [aegis_pkg::ECC_CW_W-1:0]   codeword
);

  logic [aegis_pkg::ECC_PAR_W-1:0] p;
  logic                            p_all;

  assign p[0] = ^(data & aegis_pkg::ECC_M0);
  assign p[1] = ^(data & aegis_pkg::ECC_M1);
  assign p[2] = ^(data & aegis_pkg::ECC_M2);
  assign p[3] = ^(data & aegis_pkg::ECC_M3);
  assign p[4] = ^(data & aegis_pkg::ECC_M4);
  assign p[5] = ^(data & aegis_pkg::ECC_M5);

  // Even overall parity across data and Hamming bits.
  assign p_all = ^{p, data};

  assign codeword = {p_all, p, data};

endmodule
