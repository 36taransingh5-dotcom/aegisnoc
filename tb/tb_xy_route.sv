`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_xy_route — exhaustive check of xy_route over the full coordinate space.
//
// 4 x 4 current positions x 4 x 4 destinations = 256 cases. The golden model
// is written differently from the RTL (signed deltas) so a shared mistake is
// unlikely. Also checks that every output port is exercised and that the
// X-before-Y priority case (both dimensions differ) is covered.
// -----------------------------------------------------------------------------
module tb_xy_route;
  import aegis_pkg::*;

  logic [COORD_W-1:0]    cur_x, cur_y, dst_x, dst_y;
  logic [PORT_IDX_W-1:0] out_port;

  xy_route dut (.cur_x, .cur_y, .dst_x, .dst_y, .out_port);

  function automatic logic [PORT_IDX_W-1:0] golden(int cx, int cy, int dx, int dy);
    int ddx, ddy;
    ddx = dx - cx;
    ddy = dy - cy;
    if (ddx != 0) return (ddx > 0) ? PORT_E : PORT_W;
    if (ddy != 0) return (ddy > 0) ? PORT_N : PORT_S;
    return PORT_L;
  endfunction

  function automatic string pname(logic [PORT_IDX_W-1:0] p);
    case (p)
      PORT_N:  return "NORTH";
      PORT_S:  return "SOUTH";
      PORT_E:  return "EAST";
      PORT_W:  return "WEST";
      PORT_L:  return "LOCAL";
      default: return "ILLEGAL";
    endcase
  endfunction

  localparam int SPAN = 1 << COORD_W;

  int unsigned n_cases = 0;
  int unsigned hits [NUM_PORTS];
  int unsigned n_x_priority = 0;

  initial begin
    for (int p = 0; p < NUM_PORTS; p++) hits[p] = 0;

    for (int cx = 0; cx < SPAN; cx++)
      for (int cy = 0; cy < SPAN; cy++)
        for (int dx = 0; dx < SPAN; dx++)
          for (int dy = 0; dy < SPAN; dy++) begin
            logic [PORT_IDX_W-1:0] exp_p;
            cur_x = COORD_W'(cx);
            cur_y = COORD_W'(cy);
            dst_x = COORD_W'(dx);
            dst_y = COORD_W'(dy);
            #1;
            exp_p = golden(cx, cy, dx, dy);
            if (out_port !== exp_p)
              $fatal(1, "cur=(%0d,%0d) dst=(%0d,%0d): got %s expected %s",
                     cx, cy, dx, dy, pname(out_port), pname(exp_p));
            if (out_port >= PORT_IDX_W'(NUM_PORTS))
              $fatal(1, "illegal port index %0d", out_port);
            hits[out_port]++;
            if (dx != cx && dy != cy) begin
              n_x_priority++;
              if (out_port != PORT_E && out_port != PORT_W)
                $fatal(1, "X-priority violated at cur=(%0d,%0d) dst=(%0d,%0d)", cx, cy, dx, dy);
            end
            n_cases++;
          end

    for (int p = 0; p < NUM_PORTS; p++)
      if (hits[p] == 0) $fatal(1, "coverage hole: port %s never selected", pname(PORT_IDX_W'(p)));

    $display("[tb_xy_route] cases=%0d  N=%0d S=%0d E=%0d W=%0d L=%0d  x_priority_cases=%0d",
             n_cases, hits[PORT_N], hits[PORT_S], hits[PORT_E], hits[PORT_W], hits[PORT_L], n_x_priority);
    $display("TB_XY_ROUTE: PASS");
    $finish;
  end

endmodule
