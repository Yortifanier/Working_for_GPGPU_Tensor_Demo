// Project-configurable parallel dot backend. Each accepted tag owns exactly one
// MALU until its result is consumed. This implements actual concurrent dots;
// ENGINES is a project parameter, not a claim about NVIDIA physical MALU count.
module tcgen05_dot_array #(
  parameter int ENGINES = 4,
  parameter int LANES = 4,
  parameter int TAG_W = 16,
  parameter int MAX_K = 256,
  parameter bit ENABLE_FP64 = 1'b1
) (
  input logic clk, rst_n,
  input logic req_valid,
  output logic req_ready,
  input malu_pkg::malu_cfg_t req_cfg,
  input logic [63:0] req_c,
  input logic [TAG_W-1:0] req_tag,
  input logic op_valid,
  output logic op_ready,
  input logic [TAG_W-1:0] op_tag,
  input logic [LANES-1:0][63:0] op_a, op_b,
  input logic [$clog2(LANES+1)-1:0] op_count,
  input logic [7:0] op_scale_a, op_scale_b,
  input logic op_last,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [TAG_W-1:0] rsp_tag,
  output logic [63:0] rsp_data,
  output malu_pkg::malu_status_e rsp_status,
  output logic [ENGINES-1:0] busy_mask
);
  import malu_pkg::*;
  localparam int INDEX_W = ENGINES <= 1 ? 1 : $clog2(ENGINES);
  logic [ENGINES-1:0] core_req_valid, core_req_ready;
  logic [ENGINES-1:0] core_op_valid, core_op_ready;
  logic [ENGINES-1:0] core_rsp_valid, core_rsp_ready;
  logic [TAG_W-1:0] active_tag [ENGINES];
  logic [TAG_W-1:0] core_rsp_tag [ENGINES];
  logic [63:0] core_rsp_data [ENGINES];
  malu_status_e core_rsp_status [ENGINES];
  logic [INDEX_W-1:0] alloc_rr, response_rr, response_lock;
  logic response_locked, duplicate_tag;
  integer alloc_index, operand_index, response_index;

  initial begin
    if (ENGINES < 1 || ENGINES > 128 || LANES < 1 || LANES > 32 ||
        TAG_W < 1 || MAX_K < 1 || MAX_K > 65535)
      $fatal(1,"Invalid tcgen05_dot_array parameters");
  end

  for (genvar unit=0; unit<ENGINES; unit++) begin : g_dot
    malu_core #(.LANES(LANES),.TAG_W(TAG_W),.MAX_K(MAX_K),
      .ENABLE_FP64(ENABLE_FP64)) core (
      .clk(clk),.rst_n(rst_n),.req_valid(core_req_valid[unit]),
      .req_ready(core_req_ready[unit]),.req_cfg(req_cfg),.req_c(req_c),
      .req_tag(req_tag),.op_valid(core_op_valid[unit]),
      .op_ready(core_op_ready[unit]),.op_a(op_a),.op_b(op_b),
      .op_count(op_count),.op_scale_a(op_scale_a),.op_scale_b(op_scale_b),
      .op_last(op_last),.rsp_valid(core_rsp_valid[unit]),
      .rsp_ready(core_rsp_ready[unit]),.rsp_data(core_rsp_data[unit]),
      .rsp_tag(core_rsp_tag[unit]),.rsp_status(core_rsp_status[unit])
    );
  end

  always_comb begin
    duplicate_tag = 1'b0;
    operand_index = -1;
    alloc_index = -1;
    for (int unit=0; unit<ENGINES; unit++) begin
      if (busy_mask[unit] && active_tag[unit] == req_tag) duplicate_tag = 1'b1;
      if (busy_mask[unit] && active_tag[unit] == op_tag) operand_index = unit;
    end
    for (int offset=0; offset<ENGINES; offset++) begin
      if (alloc_index < 0 && !busy_mask[(int'(alloc_rr)+offset)%ENGINES] &&
          core_req_ready[(int'(alloc_rr)+offset)%ENGINES])
        alloc_index = (int'(alloc_rr)+offset)%ENGINES;
    end
    req_ready = rst_n && !duplicate_tag && alloc_index >= 0;
    // Deliberately independent of op_valid: the scheduler may probe a tag
    // before gathering its next beat, avoiding head-of-line operand blocking.
    op_ready = rst_n && operand_index >= 0 && core_op_ready[operand_index];
    core_req_valid = '0;
    core_op_valid = '0;
    if (req_valid && req_ready) core_req_valid[alloc_index] = 1'b1;
    if (op_valid && operand_index >= 0) core_op_valid[operand_index] = 1'b1;
  end

  always_comb begin
    response_index = -1;
    if (response_locked) response_index = int'(response_lock);
    else
      for (int offset=0; offset<ENGINES; offset++)
        if (response_index < 0 && core_rsp_valid[(int'(response_rr)+offset)%ENGINES])
          response_index = (int'(response_rr)+offset)%ENGINES;
    rsp_valid = rst_n && response_index >= 0 && core_rsp_valid[response_index];
    rsp_tag = '0;
    rsp_data = '0;
    rsp_status = STATUS_OK;
    core_rsp_ready = '0;
    if (response_index >= 0) begin
      rsp_tag = core_rsp_tag[response_index];
      rsp_data = core_rsp_data[response_index];
      rsp_status = core_rsp_status[response_index];
      core_rsp_ready[response_index] = rsp_ready;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_mask <= '0;
      alloc_rr <= 0;
      response_rr <= 0;
      response_lock <= 0;
      response_locked <= 1'b0;
      for (int unit=0; unit<ENGINES; unit++) active_tag[unit] <= '0;
    end else begin
      if (req_valid && req_ready) begin
        busy_mask[alloc_index] <= 1'b1;
        active_tag[alloc_index] <= req_tag;
        alloc_rr <= INDEX_W'(alloc_index == ENGINES-1 ? 0 : alloc_index+1);
      end
      if (rsp_valid && !rsp_ready) begin
        response_locked <= 1'b1;
        response_lock <= INDEX_W'(response_index);
      end
      if (rsp_valid && rsp_ready) begin
        busy_mask[response_index] <= 1'b0;
        response_locked <= 1'b0;
        response_rr <= INDEX_W'(response_index == ENGINES-1 ? 0 : response_index+1);
      end
    end
  end

`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable({rsp_tag,rsp_data,rsp_status}));
  assert property (@(posedge clk) disable iff (!rst_n)
    req_valid && !req_ready |=> req_valid && $stable({req_cfg,req_c,req_tag}));
  assert property (@(posedge clk) disable iff (!rst_n)
    op_valid && !op_ready && !(rsp_valid && rsp_status != STATUS_OK && rsp_tag == op_tag)
    |=> (rsp_valid && rsp_status != STATUS_OK && rsp_tag == $past(op_tag)) ||
      (op_valid && $stable({op_tag,op_a,op_b,op_count,op_scale_a,op_scale_b,op_last})));
  for (genvar unit=0; unit<ENGINES; unit++) begin : g_owner_assert
    assert property (@(posedge clk) disable iff (!rst_n)
      core_rsp_valid[unit] |-> busy_mask[unit] && core_rsp_tag[unit] == active_tag[unit]);
    for (genvar other=unit+1; other<ENGINES; other++) begin : g_tag_unique
      assert property (@(posedge clk) disable iff (!rst_n)
        !(busy_mask[unit] && busy_mask[other] && active_tag[unit] == active_tag[other]));
    end
  end
`endif
endmodule
