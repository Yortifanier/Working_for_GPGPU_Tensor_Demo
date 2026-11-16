// Shared word service for Tensor engines and peer traffic. Every access checks
// owner generation and the current allocation/SMEM bounds. External responses
// are matched using {reset_epoch,sequence}; the engine's private ID is restored.
module tcgen05_memory_lane #(
  parameter int COLS=576, RECORDS=18, CLIENTS=3,
  parameter bit LANE_ID=1'b0, INBOUND=1'b0
) (
  input logic clk,rst_n,
  input logic [31:0] reset_epoch,
  input logic [tcgen05_pkg::TC_OWNERS-1:0] owner_live,owner_fault,
  input logic [15:0] owner_generation [tcgen05_pkg::TC_OWNERS],
  input logic [31:0] owner_smem_bytes [tcgen05_pkg::TC_OWNERS],
  input tcgen05_pkg::tc_alloc_record_t records [RECORDS],
  input logic [CLIENTS-1:0] req_valid,
  input logic [CLIENTS-1:0] client_smem,
  output logic [CLIENTS-1:0] req_ready,
  input tcgen05_pkg::tc_mem_req_t req [CLIENTS],
  output logic [CLIENTS-1:0] rsp_valid,
  input logic [CLIENTS-1:0] rsp_ready,
  output tcgen05_pkg::tc_mem_rsp_t rsp [CLIENTS],
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
  typedef enum logic [2:0] {F_IDLE,F_CHECK,F_SEND,F_WAIT,F_RESPOND} state_e;
  state_e state;
  integer selected,source,rr;
  logic [1:0] target;
  logic [31:0] sequence_number;
  logic [63:0] private_id;
  tc_mem_req_t held;
  tc_mem_rsp_t result,incoming;
  logic destination_ready,incoming_valid;
  tc_status_e permission;

  always_comb begin
    selected=-1;
    for (int off=0;off<CLIENTS;off++) begin
      int i;
      i=rr+off;if (i>=CLIENTS) i=i-CLIENTS;
      if (selected<0 && req_valid[i]) selected=i;
    end
  end
  for (genvar i=0;i<CLIENTS;i++) begin : g_client
    assign req_ready[i]=state==F_IDLE && selected==i;
    assign rsp_valid[i]=state==F_RESPOND && source==i;
    assign rsp[i]=result;
  end
  assign hold_valid=state!=F_IDLE && !held.peer;
  assign hold_owner=held.owner;
  always_comb begin
    logic found;
    found=1'b0;
    permission=TC_OK;
    if (!owner_live[held.owner] || owner_generation[held.owner]!=held.owner_generation)
      permission=TC_BAD_OWNER;
    else if (owner_fault[held.owner]) permission=TC_PRIOR_ERROR;
    else if (INBOUND && held.peer) permission=TC_BAD_CMD;
    else if (!held.peer && held.smem) begin
      if (held.byte_addr[1:0]!=0 || 64'(held.byte_addr)+4>64'(owner_smem_bytes[held.owner]))
        permission=TC_RANGE;
    end else if (!held.peer) begin
      for (int r=0;r<RECORDS;r++)
        if (records[r].live && !records[r].provisional && !records[r].release_pending &&
            records[r].owner==held.owner && records[r].owner_generation==held.owner_generation &&
            held.col>=records[r].base_col &&
            int'(held.col)<int'(records[r].base_col)+int'(records[r].ncols)) found=1'b1;
      if (int'(held.col)>=COLS || !found) permission=TC_BAD_ALLOC;
    end
    // Remote ownership is checked by the receiving endpoint. Locally, only the
    // parent owner must be pinned; held.owner names the remote owner here.
    if (held.peer && !INBOUND) permission=TC_OK;
    if (sequence_number==32'h7fffffff) permission=TC_SEQUENCE_EXHAUSTED;
  end
  assign local_req=held;
  assign smem_req=held;
  always_comb begin
    peer_req=held;
    peer_req.peer=1'b0;
  end
  assign local_valid=state==F_SEND && target==0;
  assign smem_valid=state==F_SEND && target==1;
  assign peer_valid=state==F_SEND && target==2;
  assign destination_ready=target==0 ? local_ready : target==1 ? smem_ready : peer_ready;
  assign incoming_valid=target==0 ? local_rsp_valid : target==1 ? smem_rsp_valid : peer_rsp_valid;
  assign incoming=target==0 ? local_rsp : target==1 ? smem_rsp : peer_rsp;
  assign local_rsp_ready=(state==F_WAIT && target==0) || state inside {F_IDLE,F_RESPOND} ||
    (local_rsp_valid && local_rsp.txn_id!=held.txn_id);
  assign smem_rsp_ready=(state==F_WAIT && target==1) || state inside {F_IDLE,F_RESPOND} ||
    (smem_rsp_valid && smem_rsp.txn_id!=held.txn_id);
  assign peer_rsp_ready=(state==F_WAIT && target==2) || state inside {F_IDLE,F_RESPOND} ||
    (peer_rsp_valid && peer_rsp.txn_id!=held.txn_id);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state<=F_IDLE;held<='0;result<='0;private_id<=0;
      sequence_number<=0;source<=0;rr<=0;target<=0;
    end else case (state)
      F_IDLE: if (selected>=0) begin
        held<=req[selected];
        held.smem<=client_smem[selected];
        held.txn_id<={reset_epoch,sequence_number[30:0],LANE_ID};
        private_id<=req[selected].txn_id;
        source<=selected;
        target<=req[selected].peer ? 2 :
          (client_smem[selected] ? 1 : 0);
        rr<=selected==CLIENTS-1 ? 0 : selected+1;
        state<=F_CHECK;
      end
      F_CHECK: begin
        if (permission!=TC_OK) begin
          result.rdata<=0;result.status<=permission;result.txn_id<=private_id;
          state<=F_RESPOND;
        end else state<=F_SEND;
      end
      F_SEND: if (destination_ready) begin
        sequence_number<=sequence_number+1;
        state<=F_WAIT;
      end
      F_WAIT: if (incoming_valid && incoming.txn_id==held.txn_id) begin
        result<=incoming;
        result.txn_id<=private_id;
        state<=F_RESPOND;
      end
      F_RESPOND: if (rsp_ready[source]) state<=F_IDLE;
      default: state<=F_IDLE;
    endcase
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    local_valid && !local_ready |=> local_valid && $stable(local_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    smem_valid && !smem_ready |=> smem_valid && $stable(smem_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    peer_valid && !peer_ready |=> peer_valid && $stable(peer_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    $stable(reset_epoch));
  for (genvar i=0;i<CLIENTS;i++) begin : g_response_stable
    assert property (@(posedge clk) disable iff (!rst_n)
      rsp_valid[i] && !rsp_ready[i] |=> rsp_valid[i] && $stable(rsp[i]));
  end
`endif
endmodule
