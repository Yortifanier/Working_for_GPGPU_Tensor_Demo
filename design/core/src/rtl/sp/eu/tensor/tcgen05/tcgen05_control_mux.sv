// One peer-control transaction at a time with round-robin independent clients.
// Once a request is selected its payload is registered until acceptance.
module tcgen05_control_mux #(
  parameter int CLIENTS=3
) (
  input logic clk,rst_n,
  input logic [CLIENTS-1:0] req_valid,
  output logic [CLIENTS-1:0] req_ready,
  input tcgen05_pkg::tc_cmd_t req [CLIENTS],
  output logic [CLIENTS-1:0] rsp_valid,
  input logic [CLIENTS-1:0] rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp [CLIENTS],
  output logic out_valid,
  input logic out_ready,
  output tcgen05_pkg::tc_cmd_t out_cmd,
  input logic out_rsp_valid,
  output logic out_rsp_ready,
  input tcgen05_pkg::tc_rsp_t out_rsp
);
  import tcgen05_pkg::*;
  typedef enum logic [1:0] {C_IDLE,C_SEND,C_WAIT,C_RESPOND} state_e;
  state_e state;
  integer rr,selected,source;
  tc_cmd_t held;
  tc_rsp_t result;
  always_comb begin
    selected=-1;
    for (int off=0;off<CLIENTS;off++) begin
      int i;
      i=rr+off;if (i>=CLIENTS) i=i-CLIENTS;
      if (selected<0 && req_valid[i]) selected=i;
    end
  end
  for (genvar i=0;i<CLIENTS;i++) begin : g_client
    assign req_ready[i]=state==C_IDLE && selected==i;
    assign rsp_valid[i]=state==C_RESPOND && source==i;
    assign rsp[i]=result;
  end
  assign out_valid=state==C_SEND;
  assign out_cmd=held;
  assign out_rsp_ready=state==C_WAIT;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin state<=C_IDLE;rr<=0;source<=0;held<='0;result<='0;end
    else case (state)
      C_IDLE: if (selected>=0) begin
        held<=req[selected];source<=selected;rr<=selected==CLIENTS-1 ? 0 : selected+1;
        state<=C_SEND;
      end
      C_SEND: if (out_ready) state<=C_WAIT;
      C_WAIT: if (out_rsp_valid) begin
        // Unrelated/stale responses are drained without advancing ownership.
        if (out_rsp.tag==held.tag && out_rsp.owner==held.owner &&
            out_rsp.owner_generation==held.owner_generation && out_rsp.op==held.op) begin
          result<=out_rsp;state<=C_RESPOND;
        end
      end
      C_RESPOND: if (rsp_ready[source]) state<=C_IDLE;
      default: state<=C_IDLE;
    endcase
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    out_valid && !out_ready |=> out_valid && $stable(out_cmd));
  for (genvar i=0;i<CLIENTS;i++) begin : g_held
    assert property (@(posedge clk) disable iff (!rst_n)
      rsp_valid[i] && !rsp_ready[i] |=> rsp_valid[i] && $stable(rsp[i]));
  end
`endif
endmodule
