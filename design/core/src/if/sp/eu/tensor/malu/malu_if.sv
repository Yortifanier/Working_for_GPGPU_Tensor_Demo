interface malu_if #(
  parameter int LANES = 4,
  parameter int TAG_W = 8
) (input logic clk, input logic rst_n);
  import malu_pkg::*;
  localparam int COUNT_W = $clog2(LANES + 1);
  logic req_valid, req_ready;
  malu_cfg_t req_cfg;
  logic [63:0] req_c;
  logic [TAG_W-1:0] req_tag;
  logic op_valid, op_ready;
  logic [LANES-1:0][63:0] op_a, op_b;
  logic [COUNT_W-1:0] op_count;
  logic [7:0] op_scale_a, op_scale_b;
  logic op_last;
  logic rsp_valid, rsp_ready;
  logic [63:0] rsp_data;
  logic [TAG_W-1:0] rsp_tag;
  malu_status_e rsp_status;

  modport dut (
    input clk,rst_n,req_valid,req_cfg,req_c,req_tag,
          op_valid,op_a,op_b,op_count,op_scale_a,op_scale_b,op_last,rsp_ready,
    output req_ready,op_ready,rsp_valid,rsp_data,rsp_tag,rsp_status
  );
  modport driver (
    input clk,rst_n,req_ready,op_ready,rsp_valid,rsp_data,rsp_tag,rsp_status,
    output req_valid,req_cfg,req_c,req_tag,
           op_valid,op_a,op_b,op_count,op_scale_a,op_scale_b,op_last,rsp_ready
  );

`ifdef MALU_ASSERTIONS
  // Reset aborts in-flight transfers. Payloads are stable while back-pressured.
  property response_stable;
    @(posedge clk) disable iff (!rst_n)
      rsp_valid && !rsp_ready |=> rsp_valid &&
        $stable({rsp_data,rsp_tag,rsp_status});
  endproperty
  assert property (response_stable);
  property request_stable;
    @(posedge clk) disable iff (!rst_n)
      req_valid && !req_ready |=> req_valid && $stable({req_cfg,req_c,req_tag});
  endproperty
  assert property (request_stable);
  property operands_stable;
    // An error response aborts the current transaction, including unaccepted
    // beats. The producer may then withdraw that aborted beat.
    @(posedge clk) disable iff (!rst_n || (rsp_valid && rsp_status != STATUS_OK))
      op_valid && !op_ready |=> op_valid &&
        $stable({op_a,op_b,op_count,op_scale_a,op_scale_b,op_last});
  endproperty
  assert property (operands_stable);
`endif
endinterface
