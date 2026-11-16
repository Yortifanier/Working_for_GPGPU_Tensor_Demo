// Project TMEM word service. Owner/allocation permission is checked upstream.
// One 32-bit request and one registered response; RAM contents are not reset.
module tcgen05_tmem #(
  parameter int COLS = 576
) (
  input logic clk,
  input logic rst_n,
  input logic req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_mem_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_mem_rsp_t rsp
);
  import tcgen05_pkg::*;
  localparam int ROWS = 4 * COLS;
  localparam int ROW_W = $clog2(ROWS);
  logic [31:0] bank_ram [0:31][0:ROWS-1];
  logic [4:0] req_bank;
  logic [ROW_W-1:0] req_row;

  initial begin
    if (COLS < 32 || COLS > 576 || (COLS % 32) != 0)
      $fatal(1, "TMEM COLS must be a multiple of 32 in [32,576]");
  end

  // lane = 32*quarter + bank. Each column contributes four rows per bank.
  assign req_bank = req.lane[4:0];
  assign req_row = ROW_W'({req.col, req.lane[6:5]});
  // Deliberately no response/request bypass: even a consumed response owns
  // this cycle. The next request is accepted on a later rising clock edge.
  assign req_ready = rst_n && !rsp_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_valid <= 1'b0;
      rsp <= '0;
    end else if (rsp_valid) begin
      if (rsp_ready) rsp_valid <= 1'b0;
    end else if (req_valid && req_ready) begin
      rsp_valid <= 1'b1;
      rsp.rdata <= 32'b0;
      rsp.status <= TC_OK;
      rsp.txn_id <= req.txn_id;
      // Check before touching RAM: the representable col range is wider than
      // the implemented array. byte_addr/owner are not this port's address.
      if (int'(req.col) >= COLS) begin
        rsp.status <= TC_RANGE;
      end else if (req.write) begin
        for (int byte_index = 0; byte_index < 4; byte_index++)
          if (req.wstrb[byte_index])
            bank_ram[req_bank][req_row][8*byte_index +: 8] <=
              req.wdata[8*byte_index +: 8];
      end else begin
        rsp.rdata <= bank_ram[req_bank][req_row];
      end
    end
  end

`ifdef TCGEN05_ASSERTIONS
  property held_response;
    @(posedge clk) disable iff (!rst_n)
      rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp);
  endproperty
  assert property (held_response);
  property held_request;
    @(posedge clk) disable iff (!rst_n)
      req_valid && !req_ready |=> req_valid && $stable(req);
  endproperty
  assert property (held_request);
`endif
endmodule
