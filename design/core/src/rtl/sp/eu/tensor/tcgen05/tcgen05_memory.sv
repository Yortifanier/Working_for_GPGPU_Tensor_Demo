// Independent outbound execution and inbound peer-service paths. Two reserved
// lanes break the bidirectional peer-request/response dependency.
module tcgen05_memory #(
  parameter int COLS=576, RECORDS=18
) (
  input logic clk,rst_n,
  input logic [31:0] reset_epoch,
  input logic [tcgen05_pkg::TC_OWNERS-1:0] owner_live,owner_fault,
  input logic [15:0] owner_generation [tcgen05_pkg::TC_OWNERS],
  input logic [31:0] owner_smem_bytes [tcgen05_pkg::TC_OWNERS],
  input tcgen05_pkg::tc_alloc_record_t records [RECORDS],
  input logic [3:0] req_valid,
  output logic [3:0] req_ready,
  input tcgen05_pkg::tc_mem_req_t req [4],
  output logic [3:0] rsp_valid,
  input logic [3:0] rsp_ready,
  output tcgen05_pkg::tc_mem_rsp_t rsp [4],
  output logic local_valid,
  input logic local_ready,
  output tcgen05_pkg::tc_mem_req_t local_req,
  input logic local_rsp_valid,
  output logic local_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t local_rsp,
  output logic smem_valid,
  input logic smem_ready,
  output tcgen05_pkg::tc_mem_req_t smem_req,
  input logic smem_rsp_valid,
  output logic smem_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t smem_rsp,
  output logic peer_valid,
  input logic peer_ready,
  output tcgen05_pkg::tc_mem_req_t peer_req,
  input logic peer_rsp_valid,
  output logic peer_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t peer_rsp,
  output logic hold_valid,
  output logic [2:0] hold_owner
);
  import tcgen05_pkg::*;
  tc_mem_req_t normal_req[3],service_req[1];
  tc_mem_rsp_t normal_rsp[3],service_rsp[1];
  logic [2:0] normal_valid,normal_ready,normal_rvalid,normal_rready;
  logic [0:0] service_valid,service_ready,service_rvalid,service_rready,service_smem;
  logic [1:0] l_valid,l_ready,l_rvalid,l_rready,s_valid,s_ready,s_rvalid,s_rready;
  tc_mem_req_t l_req[2],s_req[2];
  tc_mem_rsp_t l_rsp[2],s_rsp[2];
  logic normal_hold,service_hold,unused_peer_valid,unused_peer_rsp_ready;
  logic [2:0] normal_owner,service_owner;
  tc_mem_req_t unused_peer_req;
  assign normal_valid={req_valid[3],req_valid[1],req_valid[0]};
  assign normal_req[0]=req[0];assign normal_req[1]=req[1];assign normal_req[2]=req[3];
  assign {req_ready[3],req_ready[1],req_ready[0]}=normal_ready;
  assign normal_rready={rsp_ready[3],rsp_ready[1],rsp_ready[0]};
  assign {rsp_valid[3],rsp_valid[1],rsp_valid[0]}=normal_rvalid;
  assign rsp[0]=normal_rsp[0];assign rsp[1]=normal_rsp[1];assign rsp[3]=normal_rsp[2];
  assign service_valid[0]=req_valid[2];assign service_req[0]=req[2];
  assign service_smem[0]=req[2].smem;
  assign req_ready[2]=service_ready[0];assign rsp_valid[2]=service_rvalid[0];
  assign service_rready[0]=rsp_ready[2];assign rsp[2]=service_rsp[0];
  // Normal owners are also held by top-level command/return references. Give
  // the independent service lane priority here because it has no local token.
  assign hold_valid=normal_hold || service_hold;
  assign hold_owner=service_hold ? service_owner : normal_owner;
  tcgen05_memory_lane #(.COLS(COLS),.RECORDS(RECORDS),.CLIENTS(3),.LANE_ID(0)) normal (
    .clk(clk),.rst_n(rst_n),.reset_epoch(reset_epoch),.owner_live(owner_live),.owner_fault(owner_fault),
    .owner_generation(owner_generation),.owner_smem_bytes(owner_smem_bytes),.records(records),
    .req_valid(normal_valid),.req_ready(normal_ready),.req(normal_req),.client_smem(3'b110),
    .rsp_valid(normal_rvalid),.rsp_ready(normal_rready),.rsp(normal_rsp),
    .local_valid(l_valid[0]),.local_ready(l_ready[0]),.local_req(l_req[0]),
    .local_rsp_valid(l_rvalid[0]),.local_rsp_ready(l_rready[0]),.local_rsp(l_rsp[0]),
    .smem_valid(s_valid[0]),.smem_ready(s_ready[0]),.smem_req(s_req[0]),
    .smem_rsp_valid(s_rvalid[0]),.smem_rsp_ready(s_rready[0]),.smem_rsp(s_rsp[0]),
    .peer_valid(peer_valid),.peer_ready(peer_ready),.peer_req(peer_req),
    .peer_rsp_valid(peer_rsp_valid),.peer_rsp_ready(peer_rsp_ready),.peer_rsp(peer_rsp),
    .hold_valid(normal_hold),.hold_owner(normal_owner)
  );
  tcgen05_memory_lane #(.COLS(COLS),.RECORDS(RECORDS),.CLIENTS(1),.LANE_ID(1),.INBOUND(1)) service (
    .clk(clk),.rst_n(rst_n),.reset_epoch(reset_epoch),.owner_live(owner_live),.owner_fault(owner_fault),
    .owner_generation(owner_generation),.owner_smem_bytes(owner_smem_bytes),.records(records),
    .req_valid(service_valid),.req_ready(service_ready),.req(service_req),.client_smem(service_smem),
    .rsp_valid(service_rvalid),.rsp_ready(service_rready),.rsp(service_rsp),
    .local_valid(l_valid[1]),.local_ready(l_ready[1]),.local_req(l_req[1]),
    .local_rsp_valid(l_rvalid[1]),.local_rsp_ready(l_rready[1]),.local_rsp(l_rsp[1]),
    .smem_valid(s_valid[1]),.smem_ready(s_ready[1]),.smem_req(s_req[1]),
    .smem_rsp_valid(s_rvalid[1]),.smem_rsp_ready(s_rready[1]),.smem_rsp(s_rsp[1]),
    .peer_valid(unused_peer_valid),.peer_ready(1'b0),.peer_req(unused_peer_req),
    .peer_rsp_valid(1'b0),.peer_rsp_ready(unused_peer_rsp_ready),.peer_rsp('0),
    .hold_valid(service_hold),.hold_owner(service_owner)
  );
  tcgen05_word_arbiter local_arbiter (
    .clk(clk),.rst_n(rst_n),.req_valid(l_valid),.req_ready(l_ready),.req(l_req),
    .rsp_valid(l_rvalid),.rsp_ready(l_rready),.rsp(l_rsp),
    .out_valid(local_valid),.out_ready(local_ready),.out_req(local_req),
    .out_rsp_valid(local_rsp_valid),.out_rsp_ready(local_rsp_ready),.out_rsp(local_rsp)
  );
  tcgen05_word_arbiter smem_arbiter (
    .clk(clk),.rst_n(rst_n),.req_valid(s_valid),.req_ready(s_ready),.req(s_req),
    .rsp_valid(s_rvalid),.rsp_ready(s_rready),.rsp(s_rsp),
    .out_valid(smem_valid),.out_ready(smem_ready),.out_req(smem_req),
    .out_rsp_valid(smem_rsp_valid),.out_rsp_ready(smem_rsp_ready),.out_rsp(smem_rsp)
  );
endmodule
