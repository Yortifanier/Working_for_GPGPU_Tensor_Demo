// Completion signal for each selected cluster CTA, exactly once. The sink's
// handshake acknowledges the generic-proxy arrive-one responsibility; it must
// apply the update or independently retain the destination owner reference.
module tcgen05_commit_fanout (
  input logic clk,rst_n,req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_event_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_event_t rsp,
  output logic busy
);
  import tcgen05_pkg::*;
  logic active;
  logic [31:0] remaining;
  tc_event_t saved;
  integer selected;
  assign req_ready=!active;
  assign busy=active;
  always_comb begin
    selected=-1;
    for (int i=0;i<32;i++) if (remaining[i] && selected<0) selected=i;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin active<=0;remaining<=0;saved<='0;rsp_valid<=0;rsp<='0;end
    else if (!active) begin
      if (req_valid) begin
        active<=1;saved<=req;
        remaining<=req.multicast ? (req.mask_width32 ? req.cta_mask : req.cta_mask&32'hffff) : 1;
      end
    end else if (!rsp_valid || rsp_ready) begin
      if (selected<0) begin active<=0;rsp_valid<=0;end
      else begin
        rsp<=saved;rsp.arrive_count<=saved.status==TC_OK ? 1 : 0;rsp_valid<=1;
        if (saved.multicast) begin
          rsp.target_valid<=1;rsp.target_cta<=5'(selected);rsp.cta_mask<=32'b1<<selected;
        end
        remaining<=remaining&~(32'b1<<selected);
      end
    end
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid |-> rsp.arrive_count==(rsp.status==TC_OK ? 1 : 0));
`endif
endmodule
