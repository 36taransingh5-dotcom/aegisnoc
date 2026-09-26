// -----------------------------------------------------------------------------
// sync_fifo — single-clock FIFO with show-ahead (first-word fall-through) read.
//
// Contract
//   * push takes effect only when (push && !full)
//   * pop  takes effect only when (pop  && !empty)
//   * push and pop in the same cycle are both honoured when legal; when full
//     only the pop happens, when empty only the push happens (no bypass).
//   * rdata always shows the head entry; it is meaningful only when !empty.
//   * Synchronous active-high reset clears pointers and count. The storage
//     array is intentionally NOT reset (it is never observed while empty).
//
// DEPTH must be a power of two >= 2 so pointers wrap with plain increment
// (no modulo logic). count is AW+1 bits wide so it can represent DEPTH.
// -----------------------------------------------------------------------------
module sync_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 4
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   push,
  input  logic [WIDTH-1:0]       wdata,
  input  logic                   pop,
  output logic [WIDTH-1:0]       rdata,
  output logic                   full,
  output logic                   empty,
  output logic [$clog2(DEPTH):0] count
);

  localparam int              AW      = $clog2(DEPTH);
  localparam logic [AW:0]     DEPTH_C = DEPTH[AW:0];

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW-1:0]    wptr;
  logic [AW-1:0]    rptr;
  logic [AW:0]      cnt;

  logic do_push;
  logic do_pop;

  assign full    = (cnt == DEPTH_C);
  assign empty   = (cnt == '0);
  assign do_push = push && !full;
  assign do_pop  = pop  && !empty;

  // Storage: written only on a legal push, never reset.
  always_ff @(posedge clk) begin
    if (do_push) begin
      mem[wptr] <= wdata;
    end
  end

  // Control state.
  always_ff @(posedge clk) begin
    if (rst) begin
      wptr <= '0;
      rptr <= '0;
      cnt  <= '0;
    end else begin
      if (do_push) wptr <= wptr + 1'b1;
      if (do_pop)  rptr <= rptr + 1'b1;
      case ({do_push, do_pop})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
        default: cnt <= cnt;          // none, or push+pop together
      endcase
    end
  end

  assign rdata = mem[rptr];
  assign count = cnt;

`ifdef FORMAL
  `include "fifo_properties.sv"
`endif

endmodule
