// Identity-preserving allocator arbitration. A blocked ALLOC owns a routing
// slot, not the request port: dealloc/permit/peer transactions keep progressing.
module tcgen05_allocator_hub #(
  parameter int COLS=576, RECORDS=18, CLIENTS=4, ROUTES=64
) (
  input logic clk,rst_n,
  input logic [CLIENTS-1:0] cmd_valid,
  output logic [CLIENTS-1:0] cmd_ready,
  input tcgen05_pkg::tc_cmd_t cmd [CLIENTS],
  output logic [CLIENTS-1:0] rsp_valid,
  input logic [CLIENTS-1:0] rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp [CLIENTS],
  input logic [tcgen05_pkg::TC_OWNERS-1:0] owner_busy,owner_fault,
  output logic [tcgen05_pkg::TC_OWNERS-1:0] owner_live,
  output logic [15:0] owner_generation [tcgen05_pkg::TC_OWNERS],
  output tcgen05_pkg::tc_alloc_record_t records [RECORDS]
);
  import tcgen05_pkg::*;
  logic [ROUTES-1:0] route_live;
  integer route_client [ROUTES];
  logic [15:0] route_tag [ROUTES];
  integer rr,selected,free_route,response_route,response_client;
  logic a_cmd_valid,a_cmd_ready,a_rsp_valid,a_rsp_ready;
  tc_cmd_t a_cmd;
  tc_rsp_t a_rsp;
  logic pipe_valid;
  tc_cmd_t pipe_cmd;
  tc_rsp_t restored_rsp;
  initial begin
    if (CLIENTS<1 || ROUTES<CLIENTS || ROUTES>65534)
      $fatal(1,"Invalid allocator hub routing dimensions");
  end
  always_comb begin
    selected=-1; free_route=-1;
    for (int r=0;r<ROUTES;r++) if (!route_live[r] && free_route<0) free_route=r;
    for (int off=0;off<CLIENTS;off++) begin
      int c;
      c=rr+off;
      if (c>=CLIENTS) c=c-CLIENTS;
      if (selected<0 && cmd_valid[c]) selected=c;
    end
  end
  assign a_cmd=pipe_cmd;
  assign a_cmd_valid=pipe_valid;
  for (genvar c=0;c<CLIENTS;c++) begin : g_ready
    assign cmd_ready[c]=selected==c && free_route>=0 && !pipe_valid;
  end
  assign response_route=int'(a_rsp.tag)-1;
  always_comb begin
    response_client=0;
    if (response_route>=0 && response_route<ROUTES)
      response_client=route_client[response_route];
  end
  assign a_rsp_ready=response_route>=0 && response_route<ROUTES &&
    route_live[response_route] && (!rsp_valid[response_client] || rsp_ready[response_client]);
  always_comb begin
    restored_rsp=a_rsp;
    if (response_route>=0 && response_route<ROUTES) restored_rsp.tag=route_tag[response_route];
  end

  tcgen05_allocator #(.MAX_COLS(COLS),.OWNERS(TC_OWNERS),.RECORDS(RECORDS)) allocator (
    .clk(clk),.rst_n(rst_n),.cmd_valid(a_cmd_valid),.cmd_ready(a_cmd_ready),.cmd(a_cmd),
    .rsp_valid(a_rsp_valid),.rsp_ready(a_rsp_ready),.rsp(a_rsp),
    .owner_busy(owner_busy),.owner_fault(owner_fault),.owner_live(owner_live),
    .owner_generation(owner_generation),.records(records)
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      route_live<='0; rsp_valid<='0; rr<=0;
      pipe_valid<=0;pipe_cmd<='0;
      for (int c=0;c<CLIENTS;c++) rsp[c]<='0;
      for (int r=0;r<ROUTES;r++) begin route_client[r]<=0; route_tag[r]<=0; end
    end else begin
      for (int c=0;c<CLIENTS;c++) begin
        if (a_rsp_valid && a_rsp_ready && response_client==c) begin
          rsp_valid[c]<=1'b1;
          rsp[c]<=restored_rsp;
        end else if (rsp_ready[c]) rsp_valid[c]<=1'b0;
      end
      if (a_rsp_valid && a_rsp_ready) route_live[response_route]<=1'b0;
      if (pipe_valid && a_cmd_ready) pipe_valid<=0;
      if (!pipe_valid && selected>=0 && free_route>=0) begin
        pipe_valid<=1;
        pipe_cmd<=cmd[selected];
        pipe_cmd.tag<=16'(free_route+1);
        route_live[free_route]<=1'b1;
        route_client[free_route]<=selected;
        route_tag[free_route]<=cmd[selected].tag;
        rr<=selected==CLIENTS-1 ? 0 : selected+1;
      end
    end
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    a_cmd_valid && !a_cmd_ready |=> a_cmd_valid && $stable(a_cmd));
  assert property (@(posedge clk) disable iff (!rst_n)
    a_rsp_valid |-> response_route>=0 && response_route<ROUTES && route_live[response_route]);
  for (genvar c=0;c<CLIENTS;c++) begin : g_rsp_assert
    assert property (@(posedge clk) disable iff (!rst_n)
      rsp_valid[c] && !rsp_ready[c] |=> rsp_valid[c] && $stable(rsp[c]));
  end
`endif
endmodule
