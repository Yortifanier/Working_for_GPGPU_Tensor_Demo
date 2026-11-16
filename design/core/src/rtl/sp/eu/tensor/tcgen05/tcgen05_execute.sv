// One parent tile/transfer at a time; the MMA child schedules DOT_ENGINES
// independent numerical contexts. MOVE and MMA share the same memory fabric.
module tcgen05_execute #(
  parameter int COLS=576,LANES=4,MAX_K=256,MAX_M=256,MAX_N=256,DOT_ENGINES=4,
  parameter bit ENABLE_FP64=1'b1
) (
  input logic clk,rst_n,req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_cmd_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp,
  output logic aread_done,
  input logic rf_in_valid,
  output logic rf_in_ready,
  input tcgen05_pkg::tc_rf_fragment_t rf_in,
  output logic rf_out_valid,
  input logic rf_out_ready,
  output tcgen05_pkg::tc_rf_fragment_t rf_out,
  output logic tm_req_valid,
  input logic tm_req_ready,
  output tcgen05_pkg::tc_mem_req_t tm_req,
  input logic tm_rsp_valid,
  output logic tm_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t tm_rsp,
  output logic smem_req_valid,
  input logic smem_req_ready,
  output tcgen05_pkg::tc_mem_req_t smem_req,
  input logic smem_rsp_valid,
  output logic smem_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t smem_rsp
);
  import tcgen05_pkg::*;
  logic running,mma_mode;
  logic mrdy,mv_rdy,mvalid,mv_valid,aread;
  tc_rsp_t mrsp,mv_rsp;
  logic m_tvalid,m_tready,m_svalid,m_sready,v_tvalid,v_tready,v_svalid,v_sready;
  tc_mem_req_t m_treq,m_sreq,v_treq,v_sreq;
  assign req_ready=!running && (req.op==TC_MMA ? mrdy : mv_rdy);
  assign rsp_valid=running && (mma_mode ? mvalid : mv_valid);
  assign rsp=mma_mode ? mrsp : mv_rsp;
  assign aread_done=running && mma_mode && aread;
  assign tm_req_valid=mma_mode ? m_tvalid : v_tvalid;
  assign tm_req=mma_mode ? m_treq : v_treq;
  assign tm_rsp_ready=mma_mode ? m_tready : v_tready;
  assign smem_req_valid=mma_mode ? m_svalid : v_svalid;
  assign smem_req=mma_mode ? m_sreq : v_sreq;
  assign smem_rsp_ready=mma_mode ? m_sready : v_sready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin running<=0;mma_mode<=0;end
    else if (req_valid && req_ready) begin running<=1;mma_mode<=req.op==TC_MMA;end
    else if (rsp_valid && rsp_ready) running<=0;
  end
  tcgen05_mma #(.COLS(COLS),.LANES(LANES),.MAX_K(MAX_K),.MAX_M(MAX_M),
    .MAX_N(MAX_N),.DOT_ENGINES(DOT_ENGINES),.ENABLE_FP64(ENABLE_FP64)) mma (
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid && !running && req.op==TC_MMA),
    .req_ready(mrdy),.req(req),.rsp_valid(mvalid),.rsp_ready(rsp_ready && mma_mode && running),
    .rsp(mrsp),.aread_done(aread),.tm_req_valid(m_tvalid),
    .tm_req_ready(tm_req_ready && mma_mode),.tm_req(m_treq),
    .tm_rsp_valid(tm_rsp_valid && mma_mode),.tm_rsp_ready(m_tready),.tm_rsp(tm_rsp),
    .smem_req_valid(m_svalid),.smem_req_ready(smem_req_ready && mma_mode),.smem_req(m_sreq),
    .smem_rsp_valid(smem_rsp_valid && mma_mode),.smem_rsp_ready(m_sready),.smem_rsp(smem_rsp)
  );
  tcgen05_move #(.COLS(COLS)) move_engine (
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid && !running && req.op!=TC_MMA),
    .req_ready(mv_rdy),.req(req),.rsp_valid(mv_valid),.rsp_ready(rsp_ready && !mma_mode && running),
    .rsp(mv_rsp),.rf_in_valid(rf_in_valid),.rf_in_ready(rf_in_ready),.rf_in(rf_in),
    .rf_out_valid(rf_out_valid),.rf_out_ready(rf_out_ready),.rf_out(rf_out),
    .tm_req_valid(v_tvalid),.tm_req_ready(tm_req_ready && !mma_mode),.tm_req(v_treq),
    .tm_rsp_valid(tm_rsp_valid && !mma_mode),.tm_rsp_ready(v_tready),.tm_rsp(tm_rsp),
    .smem_req_valid(v_svalid),.smem_req_ready(smem_req_ready && !mma_mode),.smem_req(v_sreq),
    .smem_rsp_valid(smem_rsp_valid && !mma_mode),.smem_rsp_ready(v_sready),.smem_rsp(smem_rsp)
  );
endmodule
