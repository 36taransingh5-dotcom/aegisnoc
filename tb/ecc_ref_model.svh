// -----------------------------------------------------------------------------
// ecc_ref_model.svh — independent SECDED reference model for testbenches.
//
// Written from the textbook positional definition, deliberately NOT from the
// ECC_M* masks the RTL uses:
//   * data bits occupy the non-power-of-two Hamming positions 1..38 in order
//   * check bits are chosen so the XOR of the positions of all set bits is 0
//   * the syndrome of a received word is the XOR of the positions of its set
//     bits; overall parity bit (physical bit 38) is "position 0"
// Physical layout matches the RTL: {P_overall, p[5:0], data[31:0]}.
// (No early `return` inside loops: Icarus 13 crashes on that pattern.)
// -----------------------------------------------------------------------------

// Physical codeword bit -> Hamming position (0 for the overall parity bit).
function automatic int ref_phys_to_pos(input int b);
  int pos, di;
  if (b == 38) begin
    pos = 0;
  end else if (b >= 32) begin
    pos = 1 << (b - 32);
  end else begin
    pos = 0;
    di  = 0;
    for (int k = 1; k <= 38; k++) begin
      if ((k & (k - 1)) != 0) begin
        if (di == b) pos = k;
        di++;
      end
    end
  end
  return pos;
endfunction

function automatic logic [38:0] ref_encode(input logic [31:0] d);
  logic [38:0] ham;          // ham[k] = bit at Hamming position k; ham[0] = overall
  logic [5:0]  s;
  int          di;
  ham = '0;
  di  = 0;
  for (int k = 1; k <= 38; k++) begin
    if ((k & (k - 1)) != 0) begin
      ham[k] = d[di];
      di++;
    end
  end
  s = '0;
  for (int k = 1; k <= 38; k++) if (ham[k]) s = s ^ 6'(k);
  for (int j = 0; j < 6; j++) ham[1 << j] = s[j];   // cancels the position XOR
  ham[0] = ^ham[38:1];                                // even overall parity
  return {ham[0], ham[32], ham[16], ham[8], ham[4], ham[2], ham[1], d};
endfunction

// Decode: syndrome = XOR of positions of set bits; correct if single error.
task automatic ref_decode(input  logic [38:0] cw,
                          output logic [31:0] d,
                          output bit          sec,
                          output bit          ded,
                          output int          syn);
  bit q;
  syn = 0;
  for (int b = 0; b < 39; b++) if (cw[b]) syn = syn ^ ref_phys_to_pos(b);
  q   = ^cw;
  d   = cw[31:0];
  sec = 0;
  ded = 0;
  if (q && syn <= 38) begin
    sec = 1;
    for (int b = 0; b < 32; b++) if (ref_phys_to_pos(b) == syn) d[b] = ~d[b];
  end else if (q || syn != 0) begin
    ded = 1;
  end
endtask
