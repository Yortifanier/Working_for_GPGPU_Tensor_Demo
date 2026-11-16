interface sm_ctrl_if #(parameter int WARPS=64)(input logic clk,rst_n);
  import sm_pkg::*;
  logic [31:0] reset_epoch;
  logic [SM_EXEC_COUNT-1:0] capabilities;
  logic warp_cmd_valid,warp_cmd_ready,warp_rsp_valid,warp_rsp_ready;
  sm_warp_cmd_t warp_cmd;
  sm_warp_rsp_t warp_rsp;
  logic fetch_valid,fetch_ready,fetch_rsp_valid,fetch_rsp_ready;
  sm_fetch_t fetch;
  sm_fetch_rsp_t fetch_rsp;
  logic [SM_EXEC_COUNT-1:0] issue_valid,issue_ready;
  sm_issue_t issue;
  logic source_valid,source_ready;
  sm_token_t source_token;
  logic complete_valid,complete_ready;
  sm_complete_t complete;
  sm_warp_state_e warp_state[WARPS];
  sm_status_e warp_fault[WARPS];
  logic [31:0] next_pc[WARPS];
  logic [WARPS-1:0] warp_busy;
  logic [31:0] protocol_errors;
  modport dut(
    input clk,rst_n,reset_epoch,capabilities,warp_cmd_valid,warp_cmd,warp_rsp_ready,
          fetch_valid,fetch,fetch_rsp_ready,issue_ready,source_valid,source_token,
          complete_valid,complete,
    output warp_cmd_ready,warp_rsp_valid,warp_rsp,fetch_ready,fetch_rsp_valid,fetch_rsp,
          issue_valid,issue,source_ready,complete_ready,warp_state,warp_fault,
          next_pc,warp_busy,protocol_errors
  );
`ifdef SM_ASSERTIONS
  assert property(@(posedge clk)disable iff(!rst_n)
    warp_cmd_valid&&!warp_cmd_ready |=> warp_cmd_valid&&$stable(warp_cmd));
  assert property(@(posedge clk)disable iff(!rst_n)
    warp_rsp_valid&&!warp_rsp_ready |=> warp_rsp_valid&&$stable(warp_rsp));
  assert property(@(posedge clk)disable iff(!rst_n)
    fetch_valid&&!fetch_ready |=> fetch_valid&&$stable(fetch));
  assert property(@(posedge clk)disable iff(!rst_n)
    fetch_rsp_valid&&!fetch_rsp_ready |=> fetch_rsp_valid&&$stable(fetch_rsp));
  assert property(@(posedge clk)disable iff(!rst_n)
    (|(issue_valid&~issue_ready)) |=> $stable(issue)&&$stable(issue_valid));
  assert property(@(posedge clk)disable iff(!rst_n)
    source_valid&&!source_ready |=> source_valid&&$stable(source_token));
  assert property(@(posedge clk)disable iff(!rst_n)
    complete_valid&&!complete_ready |=> complete_valid&&$stable(complete));
  assert property(@(posedge clk)disable iff(!rst_n) $onehot0(issue_valid));
  assert property(@(posedge clk)disable iff(!rst_n) $stable(reset_epoch));
  assert property(@(posedge clk)disable iff(!rst_n) $stable(capabilities));
`endif
endinterface
