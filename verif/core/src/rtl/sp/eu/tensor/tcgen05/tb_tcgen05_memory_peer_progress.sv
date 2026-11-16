`timescale 1ns/1ps
// Opposite-direction peer traffic must not occupy the inbound service it needs.
/* verilator lint_off BLKSEQ */
module tb_tcgen05_memory_peer_progress;
  import tcgen05_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  logic [TC_OWNERS-1:0] owner_live[2],owner_fault[2];
  logic [15:0] owner_generation[2][TC_OWNERS];
  logic [31:0] owner_smem_bytes[2][TC_OWNERS];
  tc_alloc_record_t records[2][2];
  logic [3:0] cv[2],cr[2],rv[2],rr[2];
  tc_mem_req_t cq[2][4];
  tc_mem_rsp_t rs[2][4];
  logic local_valid[2],local_ready[2],local_rsp_valid[2],local_rsp_ready[2];
  tc_mem_req_t local_req[2];
  tc_mem_rsp_t local_rsp[2];
  logic smem_valid[2],smem_rsp_ready[2];
  tc_mem_req_t smem_req[2];
  logic peer_valid[2],peer_ready[2],peer_rsp_ready[2],hold_valid[2];
  logic [2:0] hold_owner[2];
  tc_mem_req_t peer_req[2];
  bit accepted[2],complete[2];
  int cycles=0;

  for(genvar e=0;e<2;e++)begin:g_fabric
    assign cv[e][2]=peer_valid[1-e];
    assign cq[e][2]=peer_req[1-e];
    assign peer_ready[e]=cr[1-e][2];
    assign rr[e][2]=peer_rsp_ready[1-e];
    assign local_ready[e]=!local_rsp_valid[e];
    tcgen05_memory #(.COLS(64),.RECORDS(2)) dut(
      .clk(clk),.rst_n(rst_n),.reset_epoch(32'h10203),
      .owner_live(owner_live[e]),.owner_fault(owner_fault[e]),
      .owner_generation(owner_generation[e]),.owner_smem_bytes(owner_smem_bytes[e]),
      .records(records[e]),.req_valid(cv[e]),.req_ready(cr[e]),.req(cq[e]),
      .rsp_valid(rv[e]),.rsp_ready(rr[e]),.rsp(rs[e]),
      .local_valid(local_valid[e]),.local_ready(local_ready[e]),.local_req(local_req[e]),
      .local_rsp_valid(local_rsp_valid[e]),.local_rsp_ready(local_rsp_ready[e]),.local_rsp(local_rsp[e]),
      .smem_valid(smem_valid[e]),.smem_ready(1'b1),.smem_req(smem_req[e]),
      .smem_rsp_valid(1'b0),.smem_rsp_ready(smem_rsp_ready[e]),.smem_rsp('0),
      .peer_valid(peer_valid[e]),.peer_ready(peer_ready[e]),.peer_req(peer_req[e]),
      .peer_rsp_valid(rv[1-e][2]),.peer_rsp_ready(peer_rsp_ready[e]),.peer_rsp(rs[1-e][2]),
      .hold_valid(hold_valid[e]),.hold_owner(hold_owner[e])
    );
    always @(posedge clk)begin
      if(!rst_n)begin local_rsp_valid[e]<=0;local_rsp[e]<='0;end
      else begin
        if(local_rsp_valid[e]&&local_rsp_ready[e])local_rsp_valid[e]<=0;
        if(local_valid[e]&&local_ready[e])begin
          local_rsp_valid[e]<=1;
          local_rsp[e].rdata<=32'ha0000000 | 32'(e<<16) | 32'(local_req[e].lane);
          local_rsp[e].status<=TC_OK;
          local_rsp[e].txn_id<=local_req[e].txn_id;
        end
        if(cv[e][0]&&cr[e][0])accepted[e]=1;
        if(rv[e][0]&&rr[e][0])begin
          if(rs[e][0].status!=TC_OK || rs[e][0].txn_id!=(64'hfab0000000000000|64'(e)) ||
             rs[e][0].rdata!=(32'ha0000000|32'((1-e)<<16)|32'(5+e)))
            $fatal(1,"Peer memory identity/data mismatch endpoint%0d",e);
          complete[e]=1;
        end
      end
    end
  end
  always @(posedge clk)cycles++;
  initial begin
    for(int e=0;e<2;e++)begin
      owner_live[e]='0;owner_live[e][0]=1;owner_fault[e]='0;
      cv[e][0]=0;cv[e][1]=0;cv[e][3]=0;rr[e][0]=1;rr[e][1]=1;rr[e][3]=1;
      cq[e][0]='0;cq[e][1]='0;cq[e][3]='0;
      accepted[e]=0;complete[e]=0;local_rsp_valid[e]=0;local_rsp[e]='0;
      for(int o=0;o<TC_OWNERS;o++)begin owner_generation[e][o]=1;owner_smem_bytes[e][o]=4096;end
      for(int r=0;r<2;r++)records[e][r]='0;
      records[e][0].live=1;records[e][0].owner=0;records[e][0].owner_generation=1;
      records[e][0].base_col=0;records[e][0].ncols=32;
      cq[e][0].owner=0;cq[e][0].owner_generation=1;cq[e][0].col=0;
      cq[e][0].lane=7'(5+e);cq[e][0].peer=1;
      cq[e][0].txn_id=64'hfab0000000000000|64'(e);
    end
    repeat(4)@(negedge clk);rst_n=1;
    @(negedge clk);cv[0][0]=1;cv[1][0]=1;
    repeat(200)begin
      @(negedge clk);
      for(int e=0;e<2;e++)if(accepted[e])cv[e][0]=0;
      if(complete[0]&&complete[1])begin
        $display("TCGEN05_MEMORY_PEER_PROGRESS_PASS transactions=2 cycles=%0d",cycles);
        $finish;
      end
    end
    $fatal(1,"Peer progress timeout: peer_valid=%b/%b peer_ready=%b/%b input_ready=%b/%b",
      peer_valid[0],peer_valid[1],peer_ready[0],peer_ready[1],cr[0][2],cr[1][2]);
  end
endmodule
