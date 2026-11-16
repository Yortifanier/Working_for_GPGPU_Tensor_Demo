interface tcgen05_if (input logic clk, input logic rst_n);
  import tcgen05_pkg::*;
  logic cmd_valid, cmd_ready;
  tc_cmd_t cmd;
  logic rsp_valid, rsp_ready;
  tc_rsp_t rsp;
  logic event_valid, event_ready;
  tc_event_t event_data;
  logic smem_req_valid, smem_req_ready;
  tc_mem_req_t smem_req;
  logic smem_rsp_valid, smem_rsp_ready;
  tc_mem_rsp_t smem_rsp;
  tc_caps_t capabilities;
  logic [31:0] reset_epoch;
  logic rf_in_valid,rf_in_ready,rf_out_valid,rf_out_ready;
  tc_rf_fragment_t rf_in,rf_out;
  // A peer fabric connects outgoing requests to the other endpoint's service
  // ports. Requests/responses retain identity under backpressure.
  logic peer_cmd_valid,peer_cmd_ready,peer_rsp_valid,peer_rsp_ready;
  tc_cmd_t peer_cmd;
  tc_rsp_t peer_rsp;
  logic service_cmd_valid,service_cmd_ready,service_rsp_valid,service_rsp_ready;
  tc_cmd_t service_cmd;
  tc_rsp_t service_rsp;
  logic peer_mem_req_valid,peer_mem_req_ready,peer_mem_rsp_valid,peer_mem_rsp_ready;
  tc_mem_req_t peer_mem_req;
  tc_mem_rsp_t peer_mem_rsp;
  logic service_mem_req_valid,service_mem_req_ready,service_mem_rsp_valid,service_mem_rsp_ready;
  tc_mem_req_t service_mem_req;
  tc_mem_rsp_t service_mem_rsp;
  // Per-owner visible shared bytes, supplied by the core launch allocator.
  // Stable for the entire active owner generation, including outstanding reads.
  logic [31:0] owner_smem_bytes [TC_OWNERS];

  modport dut (
    input clk,rst_n,cmd_valid,cmd,rsp_ready,event_ready,smem_req_ready,
          smem_rsp_valid,smem_rsp,owner_smem_bytes,capabilities,reset_epoch,
          rf_in_valid,rf_in,rf_out_ready,peer_cmd_ready,peer_rsp_valid,peer_rsp,
          service_cmd_valid,service_cmd,service_rsp_ready,
          peer_mem_req_ready,peer_mem_rsp_valid,peer_mem_rsp,
          service_mem_req_valid,service_mem_req,service_mem_rsp_ready,
    output cmd_ready,rsp_valid,rsp,event_valid,event_data,smem_req_valid,
           smem_req,smem_rsp_ready,rf_in_ready,rf_out_valid,rf_out,
           peer_cmd_valid,peer_cmd,peer_rsp_ready,
           service_cmd_ready,service_rsp_valid,service_rsp,
           peer_mem_req_valid,peer_mem_req,peer_mem_rsp_ready,
           service_mem_req_ready,service_mem_rsp_valid,service_mem_rsp
  );
  modport driver (
    input clk,rst_n,cmd_ready,rsp_valid,rsp,event_valid,event_data,
          smem_req_valid,smem_req,smem_rsp_ready,rf_in_ready,rf_out_valid,rf_out,
          peer_cmd_valid,peer_cmd,peer_rsp_ready,service_cmd_ready,service_rsp_valid,service_rsp,
          peer_mem_req_valid,peer_mem_req,peer_mem_rsp_ready,
          service_mem_req_ready,service_mem_rsp_valid,service_mem_rsp,
    output cmd_valid,cmd,rsp_ready,event_ready,smem_req_ready,
           smem_rsp_valid,smem_rsp,owner_smem_bytes,capabilities,reset_epoch,
           rf_in_valid,rf_in,rf_out_ready,peer_cmd_ready,peer_rsp_valid,peer_rsp,
           service_cmd_valid,service_cmd,service_rsp_ready,
           peer_mem_req_ready,peer_mem_rsp_valid,peer_mem_rsp,
           service_mem_req_valid,service_mem_req,service_mem_rsp_ready
  );
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    cmd_valid && !cmd_ready |=> cmd_valid && $stable(cmd));
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    event_valid && !event_ready |=> event_valid && $stable(event_data));
  assert property (@(posedge clk) disable iff (!rst_n)
    smem_req_valid && !smem_req_ready |=> smem_req_valid && $stable(smem_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    smem_rsp_valid && !smem_rsp_ready |=> smem_rsp_valid && $stable(smem_rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    rf_out_valid && !rf_out_ready |=> rf_out_valid && $stable(rf_out));
  assert property (@(posedge clk) disable iff (!rst_n)
    rf_in_valid && !rf_in_ready |=> rf_in_valid && $stable(rf_in));
  assert property (@(posedge clk) disable iff (!rst_n)
    peer_cmd_valid && !peer_cmd_ready |=> peer_cmd_valid && $stable(peer_cmd));
  assert property (@(posedge clk) disable iff (!rst_n)
    peer_mem_req_valid && !peer_mem_req_ready |=> peer_mem_req_valid && $stable(peer_mem_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    service_rsp_valid && !service_rsp_ready |=> service_rsp_valid && $stable(service_rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    service_mem_rsp_valid && !service_mem_rsp_ready |=> service_mem_rsp_valid && $stable(service_mem_rsp));
`endif
endinterface
