// Fair request mux and ID-directed response demux. ID bit0 names one of two
// independent memory lanes; responses never wait for another issued request.
module tcgen05_word_arbiter (
  input logic clk,rst_n,
  input logic [1:0] req_valid,
  output logic [1:0] req_ready,
  input tcgen05_pkg::tc_mem_req_t req [2],
  output logic [1:0] rsp_valid,
  input logic [1:0] rsp_ready,
  output tcgen05_pkg::tc_mem_rsp_t rsp [2],
  output logic out_valid,
  input logic out_ready,
  output tcgen05_pkg::tc_mem_req_t out_req,
  input logic out_rsp_valid,
  output logic out_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t out_rsp
);
  logic rr,locked,winner,selected;
  assign selected=locked ? winner : req_valid[rr] ? rr : !rr;
  assign out_valid=req_valid[selected];
  assign out_req=req[selected];
  for (genvar i=0;i<2;i++) begin : g_client
    assign req_ready[i]=selected==1'(i) && out_ready;
    assign rsp_valid[i]=out_rsp_valid && out_rsp.txn_id[0]==1'(i);
    assign rsp[i]=out_rsp;
  end
  assign out_rsp_ready=rsp_ready[out_rsp.txn_id[0]];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rr<=0;locked<=0;winner<=0;end
    else if (out_valid && out_ready) begin locked<=0;rr<=!selected;end
    else if (out_valid && !out_ready) begin locked<=1;winner<=selected;end
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    out_valid && !out_ready |=> out_valid && $stable(out_req));
`endif
endmodule
