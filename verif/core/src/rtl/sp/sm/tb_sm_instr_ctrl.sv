// Protocol-only backend BFM: routing/completion is exercised without claiming
// arithmetic, RF storage, SFU/TMA semantics, launch allocation or full SM RTL.
/* verilator lint_off BLKSEQ */
module tb_sm_instr_ctrl;
  timeunit 1ns;timeprecision 1ps;
  import sm_pkg::*;
  parameter int WARPS=4;
  parameter int FLIGHTS=4;
  localparam int ACTIVE_WARPS=WARPS>4 ? 4 : WARPS;
  localparam int LIMIT=512;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  sm_ctrl_if #(.WARPS(WARPS)) bus(clk,rst_n);
  sm_instr_ctrl #(.WARPS(WARPS),.FLIGHTS(FLIGHTS)) dut(bus);
  sm_issue_t issued[LIMIT],expected[LIMIT];
  bit live[LIMIT],expected_used[LIMIT];
  int issue_count=0,expect_count=0,completed=0,aborted=0,checks=0,cycles=0,seed=1907;
  logic [31:0] rng=32'h1907;
  int fetches=0,rejected=0,warp_commands=0,resets=0;
  int next_tag=1,expected_ticket=1,next_instance[WARPS];
  logic [2:0] model_owner[WARPS];
  logic [15:0] model_generation[WARPS];
  logic [31:0] model_active[WARPS];

  function automatic int response_hold_cycles;
    rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
    return 2+int'(rng[1:0]);
  endfunction

  task automatic check(input bit ok,input string why);
    if(!ok)$fatal(1,"%s cycle=%0d",why,cycles);
    checks++;
  endtask
  function automatic sm_instr_t exec(input sm_exec_e unit_id,input int src=-1,input int dst=-1);
    sm_instr_t ins;
    ins='0;ins.op=SM_OP_EXEC;ins.unit_id=unit_id;ins.lane_mask='1;
    ins.uniform_proven=unit_id==SM_EX_SALU;
    ins.function_id=16'h5100|16'(unit_id);
    ins.immediate=64'hd15c0de0a5a50000|64'(unit_id);
    if(src>=0)begin ins.src[0].kind=SM_RF_GPR;ins.src[0].base=8'(src);ins.src[0].count=1;end
    if(dst>=0)begin ins.dst[0].kind=SM_RF_GPR;ins.dst[0].base=8'(dst);ins.dst[0].count=1;end
    return ins;
  endfunction
  function automatic sm_instr_t control(input sm_opcode_e op);
    sm_instr_t ins;ins='0;ins.op=op;ins.lane_mask='1;return ins;
  endfunction

  always @(posedge clk)begin : monitor
    int match_index,record_index;
    cycles++;
    if(cycles>30000)$fatal(1,"SM control integration watchdog");
    if(!rst_n)begin
      for(int i=0;i<LIMIT;i++)begin if(live[i])aborted++;live[i]=0;end
      expected_ticket=1;
    end else begin
      if(|(bus.issue_valid&bus.issue_ready))begin
        check($onehot(bus.issue_valid),"exactly one dispatch domain");
        check(bus.issue_valid==(15'b1<<bus.issue.instr.unit_id),"typed backend route");
        check(bus.issue.token.ticket==32'(expected_ticket),"nonwrapping global dispatch ticket");
        expected_ticket++;
        match_index=-1;
        for(int i=0;i<expect_count;i++)
          if(!expected_used[i] && expected[i].token.owner==bus.issue.token.owner &&
              expected[i].token.generation==bus.issue.token.generation &&
              expected[i].token.warp==bus.issue.token.warp &&
              expected[i].token.epoch==bus.issue.token.epoch &&
              expected[i].token.instance_id==bus.issue.token.instance_id)
            match_index=i;
        check(match_index>=0,"dispatch has a real accepted IR instance");
        check(bus.issue.pc==expected[match_index].pc && bus.issue.instr===expected[match_index].instr,
          "complete immutable instruction and operands");
        for(int i=0;i<issue_count;i++)if(live[i])check(issued[i].token!=bus.issue.token,"unique live token");
        expected_used[match_index]=1;
        check(issue_count<LIMIT,"issue ledger capacity");
        issued[issue_count]=bus.issue;live[issue_count]=1;issue_count++;
      end
      if(bus.complete_valid&&bus.complete_ready)begin
        record_index=-1;
        for(int i=0;i<issue_count;i++)if(live[i] && issued[i].token==bus.complete.token)record_index=i;
        if(record_index>=0 && (bus.complete.status!=SM_OK || bus.complete.writes_committed))begin
          live[record_index]=0;completed++;
        end
      end
    end
  end

  task automatic reset_all(input logic [31:0] epoch,input logic [SM_EXEC_COUNT-1:0] caps);
    @(negedge clk);rst_n=0;
    bus.warp_cmd_valid=0;bus.fetch_valid=0;bus.source_valid=0;bus.complete_valid=0;
    bus.warp_rsp_ready=0;bus.fetch_rsp_ready=0;bus.issue_ready='0;
    bus.reset_epoch=epoch;bus.capabilities=caps;
    for(int w=0;w<WARPS;w++)begin
      next_instance[w]=1;model_owner[w]=0;model_generation[w]=0;model_active[w]='1;
    end
    repeat(4)@(negedge clk);rst_n=1;resets++;
    repeat(3)@(negedge clk);
    check(bus.warp_busy=='0,"reset clears all instruction responsibility");
    for(int w=0;w<WARPS;w++)check(bus.warp_state[w]==SM_W_FREE,"reset frees warp slot");
  endtask
  task automatic warp_cmd(input bit detach,input int warp_id,input int owner_id,
      input int gen,input sm_status_e status,input logic [31:0] active='1,
      input logic [31:0] entry=0,input bit stale_epoch=0);
    sm_warp_cmd_t c;sm_warp_rsp_t saved;
    c='0;c.epoch=bus.reset_epoch-(stale_epoch ? 1 : 0);
    c.detach=detach;c.warp=6'(warp_id);c.owner=3'(owner_id);c.generation=16'(gen);
    c.tag=16'(next_tag++);c.active_mask=active;c.entry_pc=entry;
    @(negedge clk);bus.warp_cmd=c;bus.warp_cmd_valid=1;
    do @(posedge clk);while(!bus.warp_cmd_ready);
    @(negedge clk);bus.warp_cmd_valid=0;
    while(!bus.warp_rsp_valid)@(negedge clk);
    saved=bus.warp_rsp;
    check(saved.status==status && saved.epoch==c.epoch && saved.tag==c.tag && saved.owner==c.owner &&
      saved.generation==c.generation && saved.warp==c.warp,"warp lifecycle response identity/status");
    repeat(response_hold_cycles())begin @(negedge clk);check(bus.warp_rsp_valid && bus.warp_rsp===saved,"held warp response stable");end
    bus.warp_rsp_ready=1;@(posedge clk);@(negedge clk);bus.warp_rsp_ready=0;warp_commands++;
    if(!detach && status==SM_OK)begin
      model_owner[warp_id]=3'(owner_id);model_generation[warp_id]=16'(gen);
      model_active[warp_id]=active;next_instance[warp_id]=1;
    end
  endtask
  task automatic fetch(input int warp_id,input sm_instr_t ins,input sm_status_e status=SM_OK,
      input bit override_pc=0,input logic [31:0] supplied_pc=0,input bit stale_epoch=0);
    sm_fetch_t c;sm_fetch_rsp_t saved;
    c='0;c.epoch=bus.reset_epoch-(stale_epoch ? 1 : 0);
    c.owner=model_owner[warp_id];c.generation=model_generation[warp_id];c.warp=6'(warp_id);
    c.pc=override_pc ? supplied_pc : bus.next_pc[warp_id];c.instr=ins;
    @(negedge clk);bus.fetch=c;bus.fetch_valid=1;
    do @(posedge clk);while(!bus.fetch_ready);
    @(negedge clk);bus.fetch_valid=0;
    while(!bus.fetch_rsp_valid)@(negedge clk);
    saved=bus.fetch_rsp;
    check(saved.status==status && saved.epoch==c.epoch && saved.owner==c.owner && saved.generation==c.generation &&
      saved.warp==c.warp && saved.pc==c.pc,"fetch response identity/status");
    if(status==SM_OK)begin
      if(ins.op==SM_OP_EXEC && ins.lane_mask!=0)begin
        check(expect_count<LIMIT,"expected instruction capacity");
        expected[expect_count]='0;expected[expect_count].token.epoch=bus.reset_epoch;
        expected[expect_count].token.owner=c.owner;expected[expect_count].token.generation=c.generation;
        expected[expect_count].token.warp=c.warp;
        expected[expect_count].token.instance_id=32'(next_instance[warp_id]);
        expected[expect_count].pc=c.pc;expected[expect_count].instr=ins;
        expected_used[expect_count]=0;expect_count++;
      end
      next_instance[warp_id]++;
    end else rejected++;
    repeat(response_hold_cycles())begin @(negedge clk);check(bus.fetch_rsp_valid && bus.fetch_rsp===saved,"held fetch response stable");end
    bus.fetch_rsp_ready=1;@(posedge clk);@(negedge clk);bus.fetch_rsp_ready=0;fetches++;
  endtask
  task automatic await_issues(input int count);
    int guard_cycles;guard_cycles=0;
    while(issue_count<count)begin @(negedge clk);guard_cycles++;check(guard_cycles<1000,"backend dispatch progress");end
    check(issue_count==count,"no extra dispatch");
  endtask
  task automatic source_release(input sm_token_t token);
    @(negedge clk);bus.source_token=token;bus.source_valid=1;
    do @(posedge clk);while(!bus.source_ready);
    @(negedge clk);bus.source_valid=0;
  endtask
  task automatic complete(input sm_token_t token,input sm_status_e status=SM_OK,input bit committed=1);
    @(negedge clk);bus.complete.token=token;bus.complete.status=status;
    bus.complete.writes_committed=committed;bus.complete_valid=1;
    do @(posedge clk);while(!bus.complete_ready);
    @(negedge clk);bus.complete_valid=0;
  endtask
  task automatic settle(input int count=5);
    repeat(count)@(negedge clk);
  endtask
  task automatic expect_pc(input int warp_id,input logic [31:0] pc);
    int count;count=0;
    while(bus.next_pc[warp_id]!=pc)begin @(negedge clk);count++;check(count<1000,"control instruction progress");end
  endtask
  task automatic same_retire_detach(input sm_token_t token,input int warp_id);
    sm_warp_cmd_t c;
    @(negedge clk);bus.complete.token=token;bus.complete.status=SM_EXEC_ERROR;
    bus.complete.writes_committed=0;bus.complete_valid=1;
    do @(posedge clk);while(!bus.complete_ready);
    @(negedge clk);bus.complete_valid=0;
    c='0;c.epoch=bus.reset_epoch;c.detach=1;c.tag=16'(next_tag++);c.owner=model_owner[warp_id];
    c.generation=model_generation[warp_id];c.warp=6'(warp_id);
    bus.warp_cmd=c;bus.warp_cmd_valid=1;
    do @(posedge clk);while(!bus.warp_cmd_ready);
    @(negedge clk);bus.warp_cmd_valid=0;
    check(bus.warp_rsp_valid && bus.warp_rsp.status==SM_OK,"detach accepted in final error-retire cycle");
    bus.warp_rsp_ready=1;@(posedge clk);@(negedge clk);bus.warp_rsp_ready=0;
    settle();check(bus.warp_state[warp_id]==SM_W_FREE,"old error retire cannot resurrect detached FAULT");
    warp_commands++;
  endtask

  initial begin : tests
    sm_instr_t ins,second;
    sm_token_t bad,old_token;
    sm_issue_t held;
    logic [31:0] pc;
    logic [SM_EXEC_COUNT-1:0] caps;
    int start,errors_before,idx,second_index;
    bus.warp_cmd='0;bus.fetch='0;bus.source_token='0;bus.complete='0;
    bus.warp_cmd_valid=0;bus.fetch_valid=0;bus.source_valid=0;bus.complete_valid=0;
    bus.warp_rsp_ready=0;bus.fetch_rsp_ready=0;bus.issue_ready='0;
    bus.reset_epoch=1;bus.capabilities='1;
    void'($value$plusargs("SEED=%d",seed));rng=32'(seed)|1;
    for(int i=0;i<LIMIT;i++)begin live[i]=0;expected_used[i]=0;end
    reset_all(1,'1);
    for(int w=0;w<ACTIVE_WARPS;w++)warp_cmd(0,w,w,1,SM_OK);
    bus.issue_ready='1;
    warp_cmd(1,0,0,1,SM_BAD_CONTEXT,'1,0,1);
    fetch(0,exec(SM_EX_FMA),SM_BAD_CONTEXT,0,0,1);
    if(WARPS<64)warp_cmd(0,WARPS,0,1,SM_BAD_WARP);

    // All execution classes route to explicit protocol-only BFM endpoints.
    for(int u=0;u<SM_EXEC_COUNT;u++)begin
      start=issue_count;ins=exec(sm_exec_e'(u),10,20);
      fetch(0,ins);await_issues(start+1);
      check(issued[start].instr.unit_id==sm_exec_e'(u),"each of fifteen execution domains routes");
      source_release(issued[start].token);complete(issued[start].token);settle();
      check(!bus.warp_busy[0],"domain completion releases instruction responsibility");
    end
    old_token=issued[0].token;

    // The packet carries all four source bindings, all three destination
    // bindings and a nonzero 64-bit immediate, not a narrowed 3R1W surrogate.
    start=issue_count;ins=exec(SM_EX_CVT,5,200);ins.dst[0].count=4;
    ins.src[3].kind=SM_RF_GPR;ins.src[3].base=250;ins.src[3].count=6;
    ins.dst[1].kind=SM_RF_PRED;ins.dst[1].base=4;ins.dst[1].count=2;
    ins.dst[2].kind=SM_RF_CC;ins.dst[2].count=1;
    fetch(0,ins);await_issues(start+1);source_release(issued[start].token);
    complete(issued[start].token);settle();

    // PC and dynamic-instance accounting include control and predicated-off ops.
    start=issue_count;pc=bus.next_pc[0];fetch(0,control(SM_OP_NOP));expect_pc(0,pc+4);
    ins=control(SM_OP_BRA);ins.branch_target=32'h400;fetch(0,ins);expect_pc(0,32'h400);
    ins=exec(SM_EX_FMA,1,2);ins.lane_mask=0;fetch(0,ins);expect_pc(0,32'h404);
    check(issue_count==start,"NOP branch and zero-active EXEC do not dispatch arithmetic");
    ins=exec(SM_EX_VALU_INT,1,2);ins.lane_mask=32'h0000000f;
    fetch(0,ins);await_issues(start+1);check(issued[start].instr.lane_mask==15,"partial-active EXEC retained");
    complete(issued[start].token);settle();
    ins=control(SM_OP_BRA);ins.lane_mask=15;ins.branch_target=32'h500;
    fetch(0,ins,SM_BAD_IR);
    ins=exec(SM_EX_SALU);ins.uniform_proven=0;fetch(0,ins,SM_BAD_IR);
    ins=exec(SM_EX_FMA);ins.src[0].kind=SM_RF_GPR;ins.src[0].base=255;ins.src[0].count=2;
    fetch(0,ins,SM_BAD_IR);
    ins=exec(SM_EX_SFU);ins.dst[0].kind=SM_RF_PRED;ins.dst[0].base=7;ins.dst[0].count=2;
    fetch(0,ins,SM_BAD_IR);
    ins=exec(SM_EX_VALU_INT);ins.src[0].kind=SM_RF_CC;ins.src[0].base=1;ins.src[0].count=1;
    fetch(0,ins,SM_BAD_IR);

    // A registered blocked dispatch remains fixed while other warp IR arrives;
    // all simultaneously waiting warps then receive round-robin service.
    if(ACTIVE_WARPS>1 && FLIGHTS>=ACTIVE_WARPS)begin
      start=issue_count;bus.issue_ready='0;
      for(int w=0;w<ACTIVE_WARPS;w++)begin
        ins=exec(sm_exec_e'(w),2,3);ins.uniform_proven=1;fetch(w,ins);
      end
      check(|bus.issue_valid,"registered dispatch held");held=bus.issue;
      repeat(7)begin @(negedge clk);check(bus.issue===held,"blocked dispatch immutable");end
      bus.issue_ready='1;await_issues(start+ACTIVE_WARPS);
      for(int w=0;w<ACTIVE_WARPS;w++)check(issued[start+w].token.warp==6'(w),"RR grants all waiting warp slots");
      for(int w=ACTIVE_WARPS-1;w>=0;w--)complete(issued[start+w].token);
      settle();check(bus.warp_busy=='0,"out-of-order multiwarp completion drains");
    end

    // A premature successful completion is rejected and cannot release RAW.
    start=issue_count;ins=exec(SM_EX_FMA,10,20);ins.dst[0].count=2;
    fetch(0,ins);await_issues(start+1);
    second=exec(SM_EX_SFU,21,30);fetch(0,second);settle();
    check(issue_count==start+1,"RAW range prevents dependent dispatch");
    errors_before=int'(bus.protocol_errors);complete(issued[start].token,SM_OK,0);settle();
    check(int'(bus.protocol_errors)==errors_before+1 && bus.warp_busy[0],"uncommitted write completion diagnosed and retained");
    check(issue_count==start+1,"premature completion cannot publish destination ready");
    if(WARPS>1)begin pc=bus.next_pc[WARPS>1 ? 1 : 0];fetch(1,control(SM_OP_NOP));expect_pc(1,pc+4);end
    bad=issued[start].token;bad.generation++;errors_before=int'(bus.protocol_errors);
    complete(bad);settle();check(int'(bus.protocol_errors)==errors_before+1 && bus.warp_busy[0],"stale generation completion cannot release live RAW");
    complete(issued[start].token);await_issues(start+2);complete(issued[start+1].token);settle();

    // Uncaptured source WAR protection releases on actual source acceptance,
    // allowing an independent same-warp flight before the reader completes.
    if(FLIGHTS>=2)begin
      start=issue_count;fetch(0,exec(SM_EX_FMA,40,50));await_issues(start+1);
      fetch(0,exec(SM_EX_VALU_INT,60,40));settle();
      check(issue_count==start+1,"uncaptured source blocks younger WAR write");
      source_release(issued[start].token);await_issues(start+2);
      check(live[start] && live[start+1],"multiple independent same-warp flights live");
      complete(issued[start+1].token);settle();check(bus.warp_busy[0],"younger completion retains older responsibility");
      complete(issued[start].token);settle();
    end

    // Predicate and carry are separate dependency objects, including multi-dst.
    start=issue_count;ins=exec(SM_EX_VALU_INT,1,2);
    ins.dst[1].kind=SM_RF_PRED;ins.dst[1].base=2;ins.dst[1].count=1;
    ins.dst[2].kind=SM_RF_CC;ins.dst[2].count=1;fetch(0,ins);await_issues(start+1);
    second=exec(SM_EX_VALU_INT,3,4);second.src[1].kind=SM_RF_PRED;second.src[1].base=2;second.src[1].count=1;
    second.src[2].kind=SM_RF_CC;second.src[2].count=1;fetch(0,second);settle();
    check(issue_count==start+1,"PRED and CC dependencies block younger consumer");
    complete(issued[start].token);await_issues(start+2);complete(issued[start+1].token);settle();

    // WAIT and EXIT observe actual flights, not decoder admission or dispatch.
    start=issue_count;fetch(0,exec(SM_EX_FMA,1,2));await_issues(start+1);
    if(FLIGHTS>=2)begin fetch(0,exec(SM_EX_SFU,3,4));await_issues(start+2);end
    second_index=issue_count;pc=bus.next_pc[0];fetch(0,control(SM_OP_WAIT));settle();
    check(bus.next_pc[0]==pc && bus.warp_busy[0],"WAIT remains at PC while backend flights live");
    for(int i=second_index-1;i>=start;i--)begin
      complete(issued[i].token);settle(2);
      if(i>start)check(bus.next_pc[0]==pc,"WAIT retains older incomplete flight after out-of-order return");
    end
    expect_pc(0,pc+4);
    start=issue_count;fetch(0,exec(SM_EX_FMA,1,2));await_issues(start+1);
    fetch(0,control(SM_OP_EXIT));settle();check(bus.warp_state[0]==SM_W_RUN,"EXIT waits for admitted backend responsibility");
    warp_cmd(1,0,0,1,SM_BUSY);complete(issued[start].token);settle();
    check(bus.warp_state[0]==SM_W_EXITED && !bus.warp_busy[0],"EXIT completes after backend drain");
    warp_cmd(1,0,0,1,SM_OK);warp_cmd(0,0,0,1,SM_BAD_CONTEXT);
    warp_cmd(0,0,0,2,SM_OK);

    // Error poisons a warp but already admitted work still dispatches/drains.
    start=issue_count;fetch(0,exec(SM_EX_SFU,10,20));await_issues(start+1);
    if(FLIGHTS>=2)begin
      bus.issue_ready[SM_EX_FMA]=0;fetch(0,exec(SM_EX_FMA,30,40));
      check(bus.issue_valid[SM_EX_FMA],"second flight reserved before error");
    end
    complete(issued[start].token,SM_EXEC_ERROR,0);settle();
    check(bus.warp_state[0]==SM_W_FAULT && bus.warp_fault[0]==SM_EXEC_ERROR,"backend error sets warp FAULT");
    fetch(0,control(SM_OP_NOP),SM_BAD_CONTEXT);
    if(FLIGHTS>=2)begin
      warp_cmd(1,0,0,2,SM_BUSY);bus.issue_ready[SM_EX_FMA]=1;await_issues(start+2);
      same_retire_detach(issued[start+1].token,0);
    end else warp_cmd(1,0,0,2,SM_OK);
    warp_cmd(0,0,0,3,SM_OK);
    start=issue_count;fetch(0,exec(SM_EX_FMA,1,2));await_issues(start+1);
    errors_before=int'(bus.protocol_errors);complete(old_token);settle();
    check(int'(bus.protocol_errors)==errors_before+1 && bus.warp_busy[0],"old generation token cannot clear new generation");
    old_token=issued[start].token;

    // Coordinated reset drops BFM work too; old epoch cannot retire new ticket1.
    caps='1;caps[SM_EX_TMA]=0;reset_all(2,caps);
    warp_cmd(0,0,0,1,SM_OK);bus.issue_ready='1;
    start=issue_count;fetch(0,exec(SM_EX_TMA),SM_UNSUPPORTED);
    check(issue_count==start && bus.next_pc[0]==0,"disabled backend rejects before side effects/PC advance");
    fetch(0,exec(SM_EX_FMA,1,2));await_issues(start+1);
    errors_before=int'(bus.protocol_errors);complete(old_token);settle();
    check(int'(bus.protocol_errors)==errors_before+1 && bus.warp_busy[0],"old epoch cannot clear new reset flight");
    complete(issued[start].token);settle();
    fetch(0,control(SM_OP_EXIT));settle();warp_cmd(1,0,0,1,SM_OK);
    check(bus.warp_busy=='0,"final instruction responsibility fully drained");
    idx=0;for(int i=0;i<issue_count;i++)if(live[i])idx++;
    check(idx==0,"independent backend ledger fully drained");
    check(issue_count==completed+aborted,"every dispatch completed or explicitly coordinated-reset aborted");
    $display("SM_INSTR_CTRL_PASS warps=%0d flights=%0d checks=%0d fetches=%0d rejected=%0d issues=%0d completed=%0d aborted=%0d warp_commands=%0d resets=%0d seed=%0d cycles=%0d",
      WARPS,FLIGHTS,checks,fetches,rejected,issue_count,completed,aborted,warp_commands,resets,seed,cycles);
    $finish;
  end
endmodule
/* verilator lint_on BLKSEQ */
