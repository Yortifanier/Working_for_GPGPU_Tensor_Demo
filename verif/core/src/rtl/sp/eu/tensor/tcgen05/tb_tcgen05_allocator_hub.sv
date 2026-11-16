`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
module tb_tcgen05_allocator_hub;
  import tcgen05_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  logic [2:0] cmd_valid='0,cmd_ready,rsp_valid,rsp_ready='0;
  tc_cmd_t cmd[3];tc_rsp_t rsp[3];
  logic [TC_OWNERS-1:0] owner_live;
  logic [15:0] owner_generation[TC_OWNERS];
  tc_alloc_record_t records[2];
  bit accepted[3];
  int received=0,cycles=0,checks=0;
  tcgen05_allocator_hub #(.COLS(64),.RECORDS(2),.CLIENTS(3),.ROUTES(4)) dut(
    .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd(cmd),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp(rsp),
    .owner_busy('0),.owner_fault('0),.owner_live(owner_live),
    .owner_generation(owner_generation),.records(records)
  );
  // A new higher-priority client may arrive while the allocator is blocked.
  // The already advertised internal request must retain its identity.
  assert property(@(posedge clk)disable iff(!rst_n)
    dut.a_cmd_valid&&!dut.a_cmd_ready |=> dut.a_cmd_valid&&$stable(dut.a_cmd));
  always @(posedge clk)begin
    cycles++;
    if(rst_n)for(int c=0;c<3;c++)begin
      if(cmd_valid[c]&&cmd_ready[c])accepted[c]=1;
      if(rsp_valid[c]&&rsp_ready[c])begin
        if(rsp[c].status!=TC_OK||rsp[c].owner_generation!=1||
            rsp[c].tag!=16'(64+int'(rsp[c].owner)))
          $fatal(1,"Hub response identity/status client%0d",c);
        if((c==0&&!(rsp[c].owner inside {3'd0,3'd1}))||
            (c==1&&rsp[c].owner!=3)||(c==2&&rsp[c].owner!=2))
          $fatal(1,"Hub routed response to wrong client");
        received++;checks++;
      end
    end
    if(cycles>1000)$fatal(1,"Hub arbitration watchdog");
  end
  always @(negedge clk)for(int c=0;c<3;c++)if(accepted[c])cmd_valid[c]=0;
  function automatic tc_cmd_t init_cmd(input int owner);
    tc_cmd_t c;
    c='0;c.op=TC_CTX_INIT;c.recipe=TC_RECIPE_WORD32_REF;
    c.owner=3'(owner);c.owner_generation=1;c.tag=16'(64+owner);
    return c;
  endfunction
  task automatic start(input int client,input int owner);
    @(negedge clk);accepted[client]=0;cmd[client]=init_cmd(owner);cmd_valid[client]=1;
  endtask
  initial begin
    for(int c=0;c<3;c++)begin cmd[c]='0;accepted[c]=0;end
    repeat(4)@(negedge clk);rst_n=1;
    start(0,0);while(!rsp_valid[0])@(negedge clk);
    // First response fills client0's buffer; second fills allocator response.
    start(0,1);while(!(dut.a_rsp_valid&&!dut.a_rsp_ready))@(negedge clk);
    start(2,2);repeat(3)@(negedge clk);
    start(1,3);repeat(3)@(negedge clk);
    // One reserved skid entry may accept client2 while the allocator's return
    // is blocked. Client1 cannot displace that captured request or its tag.
    if(!accepted[2]||accepted[1])$fatal(1,"Hub violated its single reserved skid credit");
    checks++;
    rsp_ready='1;
    while(received<4)@(negedge clk);
    repeat(3)@(negedge clk);
    if(received!=4||owner_live[3:0]!=4'hf)$fatal(1,"Hub lost/duplicated accepted commands");
    $display("TCGEN05_ALLOCATOR_HUB_PASS responses=%0d checks=%0d cycles=%0d",received,checks,cycles);
    $finish;
  end
endmodule
