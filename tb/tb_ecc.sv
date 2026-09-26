`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_ecc — exhaustive fault-injection testbench for the SECDED encoder/decoder.
//
// For every data pattern:
//   1. encoder output == independent positional reference model (ecc_ref_model.svh)
//   2. clean codeword        -> data unchanged, no flags, syndrome 0
//   3. EVERY one of the 39 codeword bits flipped alone
//                            -> original data recovered, single_error_corrected=1,
//                               double_error_detected=0, syndrome == Hamming
//                               position of the flipped bit, matches ref model
//   4. EVERY pair of distinct bits (C(39,2) = 741) flipped
//                            -> double_error_detected=1, single_error_corrected=0
// Patterns: 0x00000000, 0xFFFFFFFF, 0xDEADBEEF, 0xA5A55A5A, 0x5A5AA5A5,
// walking-1 and walking-0 (64), and 200 seeded random words.
// Triple-bit errors are beyond SECDED's guarantee: the detected/mis-corrected
// split is reported for information, but the DUT must still match the
// reference model's syndrome-table behaviour exactly on every sample.
// -----------------------------------------------------------------------------
module tb_ecc;
  import aegis_pkg::*;

  logic [31:0] enc_in;
  logic [38:0] enc_out;
  logic [38:0] dec_in;
  logic [31:0] dec_out;
  logic        sec;
  logic        ded;
  logic [5:0]  syn;

  ecc_secded_encoder u_enc (.data(enc_in), .codeword(enc_out));
  ecc_secded_decoder u_dec (
    .codeword(dec_in), .data(dec_out),
    .single_error_corrected(sec), .double_error_detected(ded), .syndrome(syn)
  );

  `include "ecc_ref_model.svh"

  int unsigned n_patterns = 0;
  int unsigned n_clean    = 0;
  int unsigned n_single   = 0;
  int unsigned n_double   = 0;

  function automatic string bit_role(int b);
    if (b == 38)      return "overall parity";
    else if (b >= 32) return $sformatf("check bit p%0d", b - 32);
    else              return $sformatf("data bit d%0d", b);
  endfunction

  task automatic check_pattern(input logic [31:0] d, input bit show_table);
    logic [38:0] cw, ref_cw, bad;
    logic [31:0] ref_d;
    bit          ref_sec, ref_ded;
    int          ref_syn;

    enc_in = d;
    #1;
    cw     = enc_out;
    ref_cw = ref_encode(d);
    if (cw !== ref_cw) $fatal(1, "encoder mismatch for %h: rtl %h ref %h", d, cw, ref_cw);

    // Clean codeword.
    dec_in = cw;
    #1;
    if (dec_out !== d || sec !== 1'b0 || ded !== 1'b0 || syn !== 6'd0)
      $fatal(1, "clean decode of %h: data=%h sec=%b ded=%b syn=%0d", d, dec_out, sec, ded, syn);
    n_clean++;

    // Every single-bit error.
    if (show_table) begin
      $display("[tb_ecc] single-bit fault table for data 0x%h (codeword 0x%h):", d, cw);
      $display("[tb_ecc]   bit | role            | H-pos | syndrome | corrected | recovered");
    end
    for (int b = 0; b < 39; b++) begin
      bad    = cw ^ (39'd1 << b);
      dec_in = bad;
      #1;
      ref_decode(bad, ref_d, ref_sec, ref_ded, ref_syn);
      if (dec_out !== d)
        $fatal(1, "single flip bit %0d of %h: recovered %h (expected original)", b, d, dec_out);
      if (sec !== 1'b1 || ded !== 1'b0)
        $fatal(1, "single flip bit %0d of %h: flags sec=%b ded=%b (expected 1,0)", b, d, sec, ded);
      if (int'(syn) != ref_phys_to_pos(b))
        $fatal(1, "single flip bit %0d: syndrome %0d expected position %0d", b, syn, ref_phys_to_pos(b));
      if (ref_d !== d || !ref_sec || ref_ded || ref_syn != int'(syn))
        $fatal(1, "reference model disagrees at bit %0d", b);
      if (show_table)
        $display("[tb_ecc]   %3d | %-15s | %5d | %b   | %-9s | 0x%h", b, bit_role(b),
                 ref_phys_to_pos(b), syn, sec ? "YES" : "no", dec_out);
      n_single++;
    end

    // Every pair of distinct bits.
    for (int b1 = 0; b1 < 39; b1++) begin
      for (int b2 = b1 + 1; b2 < 39; b2++) begin
        bad    = cw ^ (39'd1 << b1) ^ (39'd1 << b2);
        dec_in = bad;
        #1;
        if (ded !== 1'b1 || sec !== 1'b0)
          $fatal(1, "double flip bits %0d,%0d of %h: sec=%b ded=%b (expected 0,1)", b1, b2, d, sec, ded);
        ref_decode(bad, ref_d, ref_sec, ref_ded, ref_syn);
        if (!ref_ded || ref_sec) $fatal(1, "reference model disagrees on double flip %0d,%0d", b1, b2);
        n_double++;
      end
    end
    n_patterns++;
  endtask

  integer seed = 39;

  initial begin
    // Named patterns (DEADBEEF prints the full per-bit table for the demo).
    check_pattern(32'h0000_0000, 1'b0);
    check_pattern(32'hFFFF_FFFF, 1'b0);
    check_pattern(32'hDEAD_BEEF, 1'b1);
    check_pattern(32'hA5A5_5A5A, 1'b0);
    check_pattern(32'h5A5A_A5A5, 1'b0);
    for (int i = 0; i < 32; i++) check_pattern(32'd1 << i, 1'b0);
    for (int i = 0; i < 32; i++) check_pattern(~(32'd1 << i), 1'b0);
    for (int i = 0; i < 200; i++) check_pattern($random(seed), 1'b0);

    $display("[tb_ecc] patterns=%0d  clean=%0d  single-bit faults=%0d (all corrected)  double-bit faults=%0d (all detected)",
             n_patterns, n_clean, n_single, n_double);
    if (n_single != n_patterns * 39 || n_double != n_patterns * 741)
      $fatal(1, "coverage accounting mismatch");

    // Informational: triple-bit errors (outside the SECDED guarantee).
    begin
      int unsigned t_det = 0, t_mis = 0, t_n = 20000;
      for (int t = 0; t < t_n; t++) begin
        int b1, b2, b3;
        logic [31:0] d;
        d  = $random(seed);
        b1 = $unsigned($random(seed)) % 39;
        b2 = (b1 + 1 + $unsigned($random(seed)) % 38) % 39;
        do b3 = $unsigned($random(seed)) % 39; while (b3 == b1 || b3 == b2);
        enc_in = d;
        #1;
        dec_in = enc_out ^ (39'd1 << b1) ^ (39'd1 << b2) ^ (39'd1 << b3);
        #1;
        // Behaviour beyond the guarantee is still fully specified by the
        // syndrome table: the DUT must match the reference model exactly.
        begin
          logic [31:0] ref_d;
          bit          ref_sec, ref_ded;
          int          ref_syn;
          ref_decode(dec_in, ref_d, ref_sec, ref_ded, ref_syn);
          if (sec !== ref_sec || ded !== ref_ded || int'(syn) != ref_syn || (sec && dec_out !== ref_d))
            $fatal(1, "triple flip %0d,%0d,%0d: dut sec=%b ded=%b syn=%0d, ref sec=%b ded=%b syn=%0d",
                   b1, b2, b3, sec, ded, syn, ref_sec, ref_ded, ref_syn);
        end
        if (sec && ded) $fatal(1, "flags not mutually exclusive");
        if (ded) t_det++;
        else if (sec) t_mis++;
        else $fatal(1, "triple error produced no flag at all");
      end
      $display("[tb_ecc] INFO triple-bit faults (beyond SECDED guarantee): %0d samples, %0d flagged uncorrectable, %0d mis-corrected",
               t_n, t_det, t_mis);
    end

    $display("TB_ECC: PASS");
    $finish;
  end

endmodule
