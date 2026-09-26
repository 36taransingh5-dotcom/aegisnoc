// -----------------------------------------------------------------------------
// rr_arbiter — N-requester round-robin arbiter with consume-gated rotation.
//
// grant is combinational and one-hot-or-zero; grant is always a subset of req.
// Priority: the requester at index `ptr` is highest, then ptr+1, ... wrapping.
// Implementation: mask off requesters below ptr, pick the lowest set bit of
// the masked vector; if none, pick the lowest set bit of the raw vector.
//
// Rotation: when `accept` is high and a grant exists (the grant is consumed),
// ptr moves to one past the winner, making the winner lowest priority.
// If `accept` is low the pointer holds, so grant is stable for unchanged req.
// Bounded waiting: a requester that keeps requesting is granted within N-1
// consumed grants to other requesters.
// -----------------------------------------------------------------------------
module rr_arbiter #(
  parameter int N = 5
) (
  input  logic         clk,
  input  logic         rst,
  input  logic [N-1:0] req,
  input  logic         accept,
  output logic [N-1:0] grant
);

  localparam int IW = (N > 1) ? $clog2(N) : 1;

  logic [IW-1:0] ptr;
  logic [IW-1:0] next_ptr;
  logic [N-1:0]  mask;
  logic [N-1:0]  req_hi;
  logic [N-1:0]  grant_hi;
  logic [N-1:0]  grant_lo;

  // mask[i] = 1 for requesters at or above the priority pointer.
  always_comb begin
    for (int i = 0; i < N; i++) begin
      mask[i] = (IW'(i) >= ptr);
    end
  end

  assign req_hi   = req & mask;
  assign grant_hi = req_hi & ~(req_hi - 1'b1);   // lowest set bit of req_hi
  assign grant_lo = req    & ~(req    - 1'b1);   // lowest set bit of req
  assign grant    = (|req_hi) ? grant_hi : grant_lo;

  // Pointer after consuming the current grant: one past the winner, wrapping.
  always_comb begin
    next_ptr = ptr;
    for (int i = 0; i < N; i++) begin
      if (grant[i]) next_ptr = (i == N-1) ? '0 : IW'(i + 1);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ptr <= '0;
    end else if (accept && (|req)) begin
      ptr <= next_ptr;
    end
  end

`ifdef FORMAL
  `include "arbiter_properties.sv"
`endif

endmodule
