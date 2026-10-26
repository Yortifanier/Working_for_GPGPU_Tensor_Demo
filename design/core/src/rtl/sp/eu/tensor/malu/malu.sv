module malu #(
  parameter int LANES = 4,
  parameter int TAG_W = 8,
  parameter int MAX_K = 65535,
  parameter bit ENABLE_FP64 = 1'b1
) (malu_if.dut bus);
  initial begin
    if (LANES < 1 || LANES > 32 || TAG_W < 1 || MAX_K < 1 || MAX_K > 65535)
      $fatal(1, "Invalid MALU elaboration parameters");
    if ($bits(bus.req_tag) != TAG_W || $bits(bus.op_a) != LANES*64 ||
        $bits(bus.op_count) != $clog2(LANES+1))
      $fatal(1, "MALU interface and core parameters must match");
  end
  malu_core #(
    .LANES(LANES), .TAG_W(TAG_W), .MAX_K(MAX_K), .ENABLE_FP64(ENABLE_FP64)
  ) u_core (
    .clk(bus.clk), .rst_n(bus.rst_n),
    .req_valid(bus.req_valid), .req_ready(bus.req_ready), .req_cfg(bus.req_cfg),
    .req_c(bus.req_c), .req_tag(bus.req_tag),
    .op_valid(bus.op_valid), .op_ready(bus.op_ready),
    .op_a(bus.op_a), .op_b(bus.op_b), .op_count(bus.op_count),
    .op_scale_a(bus.op_scale_a), .op_scale_b(bus.op_scale_b), .op_last(bus.op_last),
    .rsp_valid(bus.rsp_valid), .rsp_ready(bus.rsp_ready),
    .rsp_data(bus.rsp_data), .rsp_tag(bus.rsp_tag), .rsp_status(bus.rsp_status)
  );
endmodule
