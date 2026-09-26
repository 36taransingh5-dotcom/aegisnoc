// -----------------------------------------------------------------------------
// xy_route — deterministic dimension-ordered (XY) route computation.
//
// Pure combinational. Orientation: X grows EAST, Y grows NORTH.
//   1. dst_x > cur_x -> EAST
//   2. dst_x < cur_x -> WEST
//   3. dst_y > cur_y -> NORTH
//   4. dst_y < cur_y -> SOUTH
//   5. otherwise     -> LOCAL
// X is fully resolved before Y, which makes XY routing deadlock-free on a mesh.
// All comparisons are unsigned (coordinates are non-negative).
// -----------------------------------------------------------------------------
module xy_route (
  input  logic [aegis_pkg::COORD_W-1:0]    cur_x,
  input  logic [aegis_pkg::COORD_W-1:0]    cur_y,
  input  logic [aegis_pkg::COORD_W-1:0]    dst_x,
  input  logic [aegis_pkg::COORD_W-1:0]    dst_y,
  output logic [aegis_pkg::PORT_IDX_W-1:0] out_port
);

  always_comb begin
    if      (dst_x > cur_x) out_port = aegis_pkg::PORT_E;
    else if (dst_x < cur_x) out_port = aegis_pkg::PORT_W;
    else if (dst_y > cur_y) out_port = aegis_pkg::PORT_N;
    else if (dst_y < cur_y) out_port = aegis_pkg::PORT_S;
    else                    out_port = aegis_pkg::PORT_L;
  end

endmodule
