`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_crossbar — exhaustive select check for crossbar_5x5.
//
// Enumerates every legal select pattern (each output: none or one of 5 inputs
// -> 6^5 = 7776 patterns), each with fresh random input data, and checks every
// output equals the selected input (or zero when unselected).
// -----------------------------------------------------------------------------
module tb_crossbar;
  import aegis_pkg::*;

  localparam int N = NUM_PORTS;
  localparam int W = FLIT_W;

  logic [N*W-1:0] in_data;
  logic [N*N-1:0] sel;
  logic [N*W-1:0] out_data;

  crossbar_5x5 #(.W(W)) dut (.in_data, .sel, .out_data);

  integer seed = 777;
  int unsigned n_patterns = 0;

  initial begin
    // choice[o] in 0..N : 0 = unselected, k = input k-1
    for (int code = 0; code < 7776; code++) begin
      int c, choice [N];
      c = code;
      for (int o = 0; o < N; o++) begin
        choice[o] = c % (N + 1);
        c = c / (N + 1);
      end
      for (int i = 0; i < N; i++) in_data[i*W +: W] = $random(seed);
      sel = '0;
      for (int o = 0; o < N; o++) if (choice[o] != 0) sel[o*N + choice[o] - 1] = 1'b1;
      #1;
      for (int o = 0; o < N; o++) begin
        logic [W-1:0] exp_d;
        exp_d = (choice[o] == 0) ? '0 : in_data[(choice[o]-1)*W +: W];
        if (out_data[o*W +: W] !== exp_d)
          $fatal(1, "sel=%b output %0d: got %h expected %h", sel, o, out_data[o*W +: W], exp_d);
      end
      n_patterns++;
    end
    $display("[tb_crossbar] select patterns checked = %0d (all one-hot0 combinations)", n_patterns);
    $display("TB_CROSSBAR: PASS");
    $finish;
  end

endmodule
