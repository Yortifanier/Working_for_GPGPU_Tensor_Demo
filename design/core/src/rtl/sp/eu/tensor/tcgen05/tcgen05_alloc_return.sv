// Native alloc writes the returned TMEM address to each participating CTA's
// shared destination. WORD32/canonical clients receive a debug response only.
module tcgen05_alloc_return (
  input logic clk,rst_n,
  input logic req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_rsp_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp,
  output logic mem_valid,
  input logic mem_ready,
  output tcgen05_pkg::tc_mem_req_t mem_req,
  input logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t mem_rsp,
  output logic busy,
  output logic [2:0] busy_owner
);
  import tcgen05_pkg::*;
  typedef enum logic [1:0] {A_IDLE,A_SEND,A_WAIT,A_RESPOND} state_e;
  state_e state;
  tc_rsp_t result;
  logic peer_side;
  logic [63:0] sequence_number;
  assign req_ready=state==A_IDLE;
  assign rsp_valid=state==A_RESPOND;
  assign rsp=result;
  assign busy=state!=A_IDLE;
  assign busy_owner=result.owner;
  assign mem_valid=state==A_SEND;
  assign mem_rsp_ready=state==A_WAIT;
  always_comb begin
    mem_req='0;
    mem_req.write=1'b1;mem_req.smem=1'b1;
    mem_req.peer=peer_side;
    mem_req.owner=peer_side ? result.peer_owner : result.owner;
    mem_req.owner_generation=peer_side ? result.peer_generation : result.owner_generation;
    mem_req.byte_addr=peer_side ? result.peer_return_addr : result.return_addr;
    mem_req.wdata={22'b0,result.tmem_col};
    mem_req.wstrb=4'hf;
    mem_req.txn_id=sequence_number;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin state<=A_IDLE;result<='0;peer_side<=0;sequence_number<=0;end
    else case (state)
      A_IDLE: if (req_valid) begin
        result<=req;peer_side<=0;
        if (req.status==TC_OK && req.op==TC_ALLOC && req.recipe==TC_RECIPE_NATIVE)
          state<=A_SEND;
        else state<=A_RESPOND;
      end
      A_SEND: if (mem_ready) state<=A_WAIT;
      A_WAIT: if (mem_rsp_valid && mem_rsp.txn_id==sequence_number) begin
        sequence_number<=sequence_number+1;
        if (mem_rsp.status!=TC_OK) begin result.status<=TC_MEM_ERROR;state<=A_RESPOND;end
        else if (result.cta_pair && !peer_side) begin peer_side<=1;state<=A_SEND;end
        else state<=A_RESPOND;
      end
      A_RESPOND: if (rsp_ready) state<=A_IDLE;
      default: state<=A_IDLE;
    endcase
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    mem_valid && !mem_ready |=> mem_valid && $stable(mem_req));
`endif
endmodule
