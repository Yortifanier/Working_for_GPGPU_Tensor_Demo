// Two-endpoint TMEM resource transaction. Capacity-waiting allocation never
// occupies the endpoint command bus; instantiate a separate control instance
// so release/permit operations can progress while allocation retries.
module tcgen05_pair #(
  parameter int COLS=576,
  parameter bit ALLOCATION_ONLY=1'b1
) (
  input logic clk,rst_n,cancel,
  input logic req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_cmd_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp,
  output logic local_valid,
  input logic local_ready,
  output tcgen05_pkg::tc_cmd_t local_cmd,
  input logic local_rsp_valid,
  output logic local_rsp_ready,
  input tcgen05_pkg::tc_rsp_t local_rsp,
  output logic remote_valid,
  input logic remote_ready,
  output tcgen05_pkg::tc_cmd_t remote_cmd,
  input logic remote_rsp_valid,
  output logic remote_rsp_ready,
  input tcgen05_pkg::tc_rsp_t remote_rsp,
  output logic busy,
  output logic [2:0] busy_owner
);
  import tcgen05_pkg::*;
  typedef enum logic [3:0] {
    P_IDLE,P_LOCAL_SEND,P_LOCAL_WAIT,P_REMOTE_SEND,P_REMOTE_WAIT,
    P_UNDO_LOCAL_SEND,P_UNDO_LOCAL_WAIT,P_UNDO_REMOTE_SEND,P_UNDO_REMOTE_WAIT,
    P_RETRY,P_RESPOND
  } state_e;
  state_e state;
  tc_cmd_t cmd;
  tc_rsp_t result;
  logic publish_phase,local_reserved,remote_reserved,retry_after_undo,aborted;
  tc_status_e failure;
  integer candidate,delay_count;
  logic [31:0] transaction_sequence,transaction_id;
  tc_opcode_e action,undo_action;
  logic first_ready,second_ready,first_rsp_valid,second_rsp_valid;
  tc_rsp_t first_rsp,second_rsp;
  logic first_response_matches,second_response_matches;
  tc_cmd_t first_request,second_request;
  assign req_ready=state==P_IDLE;
  assign rsp_valid=state==P_RESPOND;
  assign rsp=result;
  assign busy=state!=P_IDLE;
  assign busy_owner=cmd.owner;
  // All parents acquire the even endpoint first, including an odd issuer.
  // This prevents opposite-direction pair prepares from reserving one side
  // each and endlessly rolling back in lockstep.
  assign local_valid=cmd.pair_local_is_odd ? state inside {P_REMOTE_SEND,P_UNDO_REMOTE_SEND} :
    state inside {P_LOCAL_SEND,P_UNDO_LOCAL_SEND};
  assign remote_valid=cmd.pair_local_is_odd ? state inside {P_LOCAL_SEND,P_UNDO_LOCAL_SEND} :
    state inside {P_REMOTE_SEND,P_UNDO_REMOTE_SEND};
  assign local_rsp_ready=cmd.pair_local_is_odd ? state inside {P_REMOTE_WAIT,P_UNDO_REMOTE_WAIT} :
    state inside {P_LOCAL_WAIT,P_UNDO_LOCAL_WAIT};
  assign remote_rsp_ready=cmd.pair_local_is_odd ? state inside {P_LOCAL_WAIT,P_UNDO_LOCAL_WAIT} :
    state inside {P_REMOTE_WAIT,P_UNDO_REMOTE_WAIT};
  assign first_ready=cmd.pair_local_is_odd ? remote_ready : local_ready;
  assign second_ready=cmd.pair_local_is_odd ? local_ready : remote_ready;
  assign first_rsp_valid=cmd.pair_local_is_odd ? remote_rsp_valid : local_rsp_valid;
  assign second_rsp_valid=cmd.pair_local_is_odd ? local_rsp_valid : remote_rsp_valid;
  assign first_rsp=cmd.pair_local_is_odd ? remote_rsp : local_rsp;
  assign second_rsp=cmd.pair_local_is_odd ? local_rsp : remote_rsp;
  assign first_request=cmd.pair_local_is_odd ? remote_cmd : local_cmd;
  assign second_request=cmd.pair_local_is_odd ? local_cmd : remote_cmd;
  assign first_response_matches=first_rsp.tag==first_request.tag &&
    first_rsp.owner==first_request.owner && first_rsp.owner_generation==first_request.owner_generation &&
    first_rsp.op==first_request.op && first_rsp.tmem_col==first_request.tmem_col && first_rsp.ncols==first_request.ncols;
  assign second_response_matches=second_rsp.tag==second_request.tag &&
    second_rsp.owner==second_request.owner && second_rsp.owner_generation==second_request.owner_generation &&
    second_rsp.op==second_request.op && second_rsp.tmem_col==second_request.tmem_col && second_rsp.ncols==second_request.ncols;
  always_comb begin
    action=cmd.op;
    undo_action=TC_PAIR_ROLLBACK;
    if (cmd.op==TC_ALLOC) action=publish_phase ? TC_PAIR_PUBLISH : TC_PAIR_PREPARE;
    if (cmd.op==TC_DEALLOC) begin
      action=publish_phase ? TC_PAIR_FREE_COMMIT : TC_PAIR_FREE_PREPARE;
      undo_action=TC_PAIR_FREE_CANCEL;
    end
    local_cmd=cmd;
    local_cmd.cta_pair=1'b0;
    local_cmd.op=state inside {P_UNDO_LOCAL_SEND,P_UNDO_LOCAL_WAIT,P_UNDO_REMOTE_SEND,P_UNDO_REMOTE_WAIT} ? undo_action : action;
    local_cmd.tmem_col=10'(candidate);
    local_cmd.reservation_id=transaction_id;
    local_cmd.alloc_exact=1'b1;
    remote_cmd=local_cmd;
    remote_cmd.owner=cmd.peer_owner;
    remote_cmd.owner_generation=cmd.peer_generation;
    if (state inside {P_UNDO_REMOTE_SEND,P_UNDO_REMOTE_WAIT}) remote_cmd.op=undo_action;
  end
  task automatic respond(input tc_status_e status);
    result<=response_for(cmd,status);
    result.tmem_col<=10'(candidate);
    state<=P_RESPOND;
  endtask
  task automatic next_candidate;
    if (candidate+32+int'(cmd.ncols)>COLS) candidate<=0;
    else candidate<=candidate+32;
    delay_count<=4;
    state<=P_RETRY;
  endtask
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state<=P_IDLE;cmd<='0;result<='0;publish_phase<=0;
      local_reserved<=0;remote_reserved<=0;retry_after_undo<=0;
      failure<=TC_OK;candidate<=0;delay_count<=0;
      transaction_sequence<=1;transaction_id<=0;aborted<=0;
    end else begin
      if (busy && cancel) aborted<=1;
      case (state)
        P_IDLE: if (req_valid) begin
          cmd<=req; candidate<=req.op==TC_ALLOC ? 0 : int'(req.tmem_col);
          publish_phase<=0;local_reserved<=0;remote_reserved<=0;
          retry_after_undo<=0;failure<=TC_OK;aborted<=0;
          transaction_id<=transaction_sequence;
          if (transaction_sequence!=32'hffffffff) transaction_sequence<=transaction_sequence+1;
          if (transaction_sequence==32'hffffffff) begin
            result<=response_for(req,TC_SEQUENCE_EXHAUSTED);state<=P_RESPOND;
          end else if (!req.cta_pair ||
                       (ALLOCATION_ONLY ? req.op!=TC_ALLOC : !(req.op inside {TC_DEALLOC,TC_RELINQUISH}))) begin
            result<=response_for(req,TC_BAD_CMD);state<=P_RESPOND;
          end else state<=P_LOCAL_SEND;
        end
        P_LOCAL_SEND: if (first_ready) state<=P_LOCAL_WAIT;
        P_LOCAL_WAIT: if (first_rsp_valid && first_response_matches) begin
          if (first_rsp.status==TC_OK) begin
            if (!publish_phase && cmd.op inside {TC_ALLOC,TC_DEALLOC}) local_reserved<=1;
            state<=P_REMOTE_SEND;
          end else if (cmd.op==TC_ALLOC && !publish_phase &&
                       first_rsp.status==TC_BUSY && !aborted && !cancel) next_candidate();
          else if (local_reserved || remote_reserved) begin
            failure<=aborted || cancel ? TC_PRIOR_ERROR : first_rsp.status;
            retry_after_undo<=0;
            state<=P_UNDO_LOCAL_SEND;
          end else respond(aborted || cancel ? TC_PRIOR_ERROR : first_rsp.status);
        end
        P_REMOTE_SEND: if (second_ready) state<=P_REMOTE_WAIT;
        P_REMOTE_WAIT: if (second_rsp_valid && second_response_matches) begin
          if (second_rsp.status==TC_OK && !aborted && !cancel) begin
            if (!publish_phase && cmd.op inside {TC_ALLOC,TC_DEALLOC}) begin
              remote_reserved<=1;publish_phase<=1;state<=P_LOCAL_SEND;
            end else respond(TC_OK);
          end else begin
            failure<=aborted || cancel ? TC_PRIOR_ERROR : second_rsp.status;
            retry_after_undo<=cmd.op==TC_ALLOC && !publish_phase &&
              second_rsp.status==TC_BUSY && !aborted && !cancel;
            if (second_rsp.status==TC_OK && !publish_phase) remote_reserved<=1;
            if (local_reserved && cmd.op inside {TC_ALLOC,TC_DEALLOC}) state<=P_UNDO_LOCAL_SEND;
            else respond(aborted || cancel ? TC_PRIOR_ERROR : second_rsp.status);
          end
        end
        P_UNDO_LOCAL_SEND: if (first_ready) state<=P_UNDO_LOCAL_WAIT;
        P_UNDO_LOCAL_WAIT: if (first_rsp_valid && first_response_matches) begin
          local_reserved<=0;
          if (first_rsp.status!=TC_OK) begin failure<=TC_MEM_ERROR;retry_after_undo<=0;end
          if (remote_reserved) state<=P_UNDO_REMOTE_SEND;
          else if (retry_after_undo && first_rsp.status==TC_OK && !aborted && !cancel) next_candidate();
          else if (first_rsp.status!=TC_OK) respond(TC_MEM_ERROR);
          else respond(failure);
        end
        P_UNDO_REMOTE_SEND: if (second_ready) state<=P_UNDO_REMOTE_WAIT;
        P_UNDO_REMOTE_WAIT: if (second_rsp_valid && second_response_matches) begin
          remote_reserved<=0;
          if (second_rsp.status!=TC_OK) respond(TC_MEM_ERROR);
          else if (retry_after_undo && !aborted && !cancel) next_candidate();
          else respond(failure);
        end
        P_RETRY: begin
          if (aborted || cancel) respond(TC_PRIOR_ERROR);
          else if (delay_count==0) state<=P_LOCAL_SEND;
          else delay_count<=delay_count-1;
        end
        P_RESPOND: if (rsp_ready) state<=P_IDLE;
        default: state<=P_IDLE;
      endcase
    end
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    local_valid && !local_ready |=> local_valid && $stable(local_cmd));
  assert property (@(posedge clk) disable iff (!rst_n)
    remote_valid && !remote_ready |=> remote_valid && $stable(remote_cmd));
`endif
endmodule
