`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
module tb_tcgen05_pair_rollback;
  import tcgen05_pkg::*;
  logic clk=0,rst_n=0,cancel=0;
  always #5 clk=~clk;
  logic req_valid=0,req_ready,rsp_valid,rsp_ready=1;
  tc_cmd_t req;
  tc_rsp_t rsp;
  logic local_valid,local_ready,local_rsp_valid,local_rsp_ready;
  logic remote_valid,remote_ready,remote_rsp_valid,remote_rsp_ready,busy;
  logic [2:0] busy_owner;
  tc_cmd_t local_cmd,remote_cmd;
  tc_rsp_t local_rsp,remote_rsp;
  logic [TC_OWNERS-1:0] owner_live[2],owner_fault[2];
  logic [15:0] generations[2][TC_OWNERS];
  tc_alloc_record_t records[2][2];
  logic [1:0] a_valid,a_ready,a_rsp_valid,a_rsp_ready;
  tc_cmd_t a_cmd[2];tc_rsp_t a_rsp[2];
  bit setup_mode=1,fault_first_publish=0,cancel_remote_prepare=0;
  logic [1:0] setup_valid='0;
  tc_cmd_t setup_cmd[2];
  int cycles=0,checks=0,commands=0,rollback_acks=0,retries=0;
  tcgen05_pair #(.COLS(64)) dut(.*);
  for(genvar e=0;e<2;e++)begin:g_alloc
    tcgen05_allocator #(.MAX_COLS(64),.OWNERS(TC_OWNERS),.RECORDS(2)) allocator(
      .clk(clk),.rst_n(rst_n),.cmd_valid(a_valid[e]),.cmd_ready(a_ready[e]),.cmd(a_cmd[e]),
      .rsp_valid(a_rsp_valid[e]),.rsp_ready(a_rsp_ready[e]),.rsp(a_rsp[e]),
      .owner_busy('0),.owner_fault(owner_fault[e]),.owner_live(owner_live[e]),
      .owner_generation(generations[e]),.records(records[e])
    );
    assign a_valid[e]=setup_mode ? setup_valid[e] : (e==0 ? local_valid : remote_valid);
    assign a_cmd[e]=setup_mode ? setup_cmd[e] : (e==0 ? local_cmd : remote_cmd);
    assign a_rsp_ready[e]=setup_mode ? 1'b1 : (e==0 ? local_rsp_ready : remote_rsp_ready);
    always @(posedge clk)if(rst_n&&!setup_mode)begin
      if($test$plusargs("TRACE")&&a_valid[e]&&a_ready[e])
        $display("TRACE cmd e%0d op%0d owner%0d gen%0d cols%0d base%0d seq%0d state%0d",e,a_cmd[e].op,a_cmd[e].owner,a_cmd[e].owner_generation,a_cmd[e].ncols,a_cmd[e].tmem_col,a_cmd[e].reservation_id,dut.state);
      if($test$plusargs("TRACE")&&a_rsp_valid[e]&&a_rsp_ready[e])
        $display("TRACE rsp e%0d op%0d status%0d state%0d",e,a_rsp[e].op,a_rsp[e].status,dut.state);
      if(a_rsp_valid[e]&&a_rsp_ready[e]&&a_rsp[e].op==TC_PAIR_ROLLBACK&&a_rsp[e].status==TC_OK)
        rollback_acks++;
      if(a_rsp_valid[e]&&a_rsp_ready[e]&&a_rsp[e].op==TC_PAIR_PREPARE&&a_rsp[e].status==TC_BUSY)
        retries++;
    end
  end
  assign local_ready=!setup_mode&&a_ready[0];
  assign remote_ready=!setup_mode&&a_ready[1];
  assign local_rsp_valid=!setup_mode&&a_rsp_valid[0];
  assign remote_rsp_valid=!setup_mode&&a_rsp_valid[1];
  assign local_rsp=a_rsp[0];assign remote_rsp=a_rsp[1];
  always @(posedge clk)begin
    cycles++;
    if(cycles>10000)$fatal(1,"Pair rollback test watchdog setup=%b setup_valid=%b allocator_ready=%b allocator_rsp=%b req=%b/%b state=%0d",
      setup_mode,setup_valid,a_ready,a_rsp_valid,req_valid,req_ready,dut.state);
  end
  always @(negedge clk)if(rst_n&&!setup_mode)begin
    if(fault_first_publish&&local_valid&&local_cmd.op==TC_PAIR_PUBLISH)
      owner_fault[0][0]=1;
    if(cancel_remote_prepare&&remote_valid&&remote_cmd.op==TC_PAIR_PREPARE)
      cancel=1;
  end
  function automatic tc_cmd_t command(input tc_opcode_e op,input int owner);
    tc_cmd_t c;
    c='0;c.op=op;c.recipe=TC_RECIPE_WORD32_REF;c.owner=3'(owner);
    c.owner_generation=1;c.participants=32'hffffffff;c.ncols=32;
    return c;
  endfunction
  task automatic check(input bit pass,input string why);
    if(!pass)$fatal(1,"%s cycle=%0d",why,cycles);
    checks++;
  endtask
  task automatic setup_transaction(input int endpoint,input tc_cmd_t c);
    int timeout_at;
    @(negedge clk);setup_cmd[endpoint]=c;setup_valid[endpoint]=1;
    do @(posedge clk);while(!a_ready[endpoint]);
    @(negedge clk);setup_valid[endpoint]=0;
    timeout_at=cycles+100;
    while(!a_rsp_valid[endpoint])begin
      @(negedge clk);
      if(cycles>timeout_at)$fatal(1,"setup response timeout endpoint%0d op%0d valid%b ready%b rsp%b",endpoint,c.op,a_valid,a_ready,a_rsp_valid);
    end
    check(a_rsp[endpoint].status==TC_OK,"setup command status");
    @(negedge clk);
  endtask
  task automatic reset_and_init;
    @(negedge clk);rst_n=0;setup_mode=1;setup_valid='0;req_valid=0;cancel=0;
    owner_fault[0]='0;owner_fault[1]='0;fault_first_publish=0;cancel_remote_prepare=0;
    repeat(4)@(negedge clk);rst_n=1;
    setup_transaction(0,command(TC_CTX_INIT,0));
    setup_transaction(1,command(TC_CTX_INIT,1));
    @(negedge clk);setup_mode=0;
  endtask
  task automatic pair_allocate(input tc_status_e expected,input int expected_base);
    int timeout_at;
    req=command(TC_ALLOC,0);req.tag=16'(commands+100);
    req.cta_pair=1;req.peer_owner=1;req.peer_generation=1;
    req.peer_participants=32'hffffffff;
    @(negedge clk);req_valid=1;
    #1;
    while(!req_ready)begin @(negedge clk);#1;end
    @(posedge clk);
    @(negedge clk);req_valid=0;timeout_at=cycles+500;
    while(!rsp_valid)begin @(negedge clk);if(cycles>timeout_at)$fatal(1,"pair response timeout");end
    check(rsp.status==expected,"parent status");
    check(rsp.tag==req.tag&&rsp.owner==req.owner&&rsp.owner_generation==req.owner_generation,"parent identity");
    if(expected==TC_OK)check(int'(rsp.tmem_col)==expected_base,"joint allocation common base");
    commands++;
    @(negedge clk);
  endtask
  function automatic int live_count(input int e);
    int count;
    count=0;for(int r=0;r<2;r++)if(records[e][r].live)count++;
    return count;
  endfunction
  task automatic no_provisionals;
    for(int e=0;e<2;e++)for(int r=0;r<2;r++)
      check(!records[e][r].live||!records[e][r].provisional,"no published parent leaves provisional storage");
  endtask
  initial begin
    req='0;setup_cmd[0]='0;setup_cmd[1]='0;
    reset_and_init();pair_allocate(TC_OK,0);
    check(live_count(0)==1&&live_count(1)==1,"both endpoints allocate");no_provisionals();
    reset_and_init();fault_first_publish=1;
    pair_allocate(TC_PRIOR_ERROR,0);
    check(live_count(0)==0&&live_count(1)==0,"first PUBLISH rejection must roll back both prepared endpoints");
    check(rollback_acks>=2,"both rollback acknowledgements consumed");
    reset_and_init();setup_mode=1;
    setup_transaction(1,command(TC_ALLOC,1));setup_mode=0;
    pair_allocate(TC_OK,32);
    check(live_count(0)==1&&live_count(1)==2,"failed candidate was released before retry");
    check(retries>=1,"capacity collision retry exercised");no_provisionals();
    reset_and_init();cancel_remote_prepare=1;
    pair_allocate(TC_PRIOR_ERROR,0);
    check(live_count(0)==0&&live_count(1)==0,"cancel drains and rolls back both endpoints");
    $display("TCGEN05_PAIR_ROLLBACK_PASS commands=%0d checks=%0d rollback_acks=%0d retries=%0d cycles=%0d",
      commands,checks,rollback_acks,retries,cycles);
    $finish;
  end
endmodule
