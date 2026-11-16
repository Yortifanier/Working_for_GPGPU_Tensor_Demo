/* verilator lint_off BLKSEQ */
module tcgen05_cluster_smem #(
  parameter int WORDS=8192
) (
  input logic clk,rst_n,hold_requests,
  input logic[31:0] seed,
  input logic req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_mem_req_t req,
  output logic rsp_valid=0,
  input logic rsp_ready,
  output tcgen05_pkg::tc_mem_rsp_t rsp,
  output integer requests=0,writes=0
);
  import tcgen05_pkg::*;
  logic[31:0] words[TC_OWNERS][WORDS];
  logic[31:0] rng=1;
  logic pending=0;
  tc_mem_rsp_t saved;
  integer delay_count=0;
  function automatic logic[31:0] step(input logic[31:0] value);
    logic[31:0] x;
    x=value^(value<<13);x=x^(x>>17);return x^(x<<5);
  endfunction
  assign req_ready=rst_n && !hold_requests && !pending && !rsp_valid && (rng[0]||rng[1]);
  initial begin
    rsp='0;
    for(int o=0;o<TC_OWNERS;o++)for(int i=0;i<WORDS;i++)words[o][i]=0;
  end
  always @(posedge clk)begin
    if(!rst_n)begin pending<=0;rsp_valid<=0;rng<=seed;end
    else begin
      rng<=step(rng);
      if(rsp_valid && rsp_ready)rsp_valid<=0;
      if(pending)begin
        if(delay_count==0)begin rsp<=saved;rsp_valid<=1;pending<=0;end
        else delay_count--;
      end
      if(req_valid && req_ready)begin
        saved='0;saved.txn_id=req.txn_id;saved.status=TC_OK;
        if(req.byte_addr[1:0]!=0 || req.byte_addr>=WORDS*4)$fatal(1,"cluster SMEM range/alignment");
        if(req.write)begin
          for(int b=0;b<4;b++)if(req.wstrb[b])words[req.owner][req.byte_addr>>2][8*b+:8]=req.wdata[8*b+:8];
          writes++;
        end else saved.rdata=words[req.owner][req.byte_addr>>2];
        requests++;pending<=1;delay_count=int'(rng[4:2]);
      end
    end
  end
endmodule
