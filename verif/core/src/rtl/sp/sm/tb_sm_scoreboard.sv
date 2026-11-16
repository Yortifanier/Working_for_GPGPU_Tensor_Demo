/* verilator lint_off BLKSEQ */
module tb_sm_scoreboard;
  import sm_pkg::*;
  parameter int WARPS=4;
  parameter int FLIGHTS=4;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  sm_issue_t probe[WARPS],reserve;
  logic [WARPS-1:0] probe_ready,warp_busy;
  logic reserve_valid,reserve_ready,dispatch_valid,source_valid,source_ready;
  logic complete_valid,complete_ready,retire_valid,protocol_error;
  sm_token_t dispatch_token,source_token,retire_token;
  sm_complete_t complete;
  sm_status_e retire_status;
  int checks=0,cycles=0,reservations=0,retirements=0,errors=0,serial=1;

  sm_scoreboard #(.WARPS(WARPS),.FLIGHTS(FLIGHTS)) dut(.*);

  always @(posedge clk) begin
    cycles++;
    if(cycles>20000)$fatal(1,"scoreboard watchdog");
    if(rst_n) begin
      if(reserve_valid && reserve_ready) reservations++;
      if(retire_valid)retirements++;
      if(protocol_error)errors++;
    end
  end

  function automatic sm_issue_t instruction(input int warp_id,
      input int src_base=0,input int src_count=0,input int dst_base=0,input int dst_count=0);
    sm_issue_t x;
    x='0;x.token.epoch=7;x.token.ticket=32'(serial);
    x.token.owner=3'(warp_id%8);x.token.generation=1;x.token.warp=6'(warp_id);
    x.token.instance_id=32'(serial*3+19);x.pc=32'(serial*4);
    x.instr.op=SM_OP_EXEC;x.instr.unit_id=SM_EX_FMA;x.instr.lane_mask='1;
    if(src_count!=0)begin x.instr.src[0].kind=SM_RF_GPR;x.instr.src[0].base=8'(src_base);x.instr.src[0].count=9'(src_count);end
    if(dst_count!=0)begin x.instr.dst[0].kind=SM_RF_GPR;x.instr.dst[0].base=8'(dst_base);x.instr.dst[0].count=9'(dst_count);end
    return x;
  endfunction
  function automatic sm_complete_t result(input sm_issue_t x,
      input sm_status_e status=SM_OK,input bit committed=1);
    sm_complete_t c;c='0;c.token=x.token;c.status=status;c.writes_committed=committed;return c;
  endfunction
  task automatic check(input bit yes,input string why);
    if(!yes)$fatal(1,"%s cycle=%0d",why,cycles);
    checks++;
  endtask
  task automatic expect_probe(input sm_issue_t x,input bit expected,input string why);
    int slot;slot=32'(x.token.warp)<WARPS ? int'(x.token.warp) : 0;
    probe[slot]=x;#1;
    check(probe_ready[slot]===expected,why);
  endtask
  task automatic push(input sm_issue_t x);
    int limit;
    @(negedge clk);reserve=x;reserve_valid=1;limit=cycles+100;
    do begin @(posedge clk);if(cycles>limit)$fatal(1,"reserve timeout");end while(!reserve_ready);
    @(negedge clk);reserve_valid=0;
  endtask
  task automatic events(input bit dv,input sm_token_t dt,input bit sv,input sm_token_t st,
      input bit cv,input sm_complete_t c,input bit expected_retire,input bit expected_error,
      input string why);
    @(negedge clk);
    dispatch_valid=dv;dispatch_token=dt;source_valid=sv;source_token=st;
    complete_valid=cv;complete=c;
    #1;check(source_ready && complete_ready,"return paths independent of issue selection/credit");
    @(posedge clk);@(negedge clk);
    check(retire_valid===expected_retire,{why," retire"});
    check(protocol_error===expected_error,{why," diagnostic"});
    if(expected_retire)begin
      check(retire_token===c.token,{why," exact retirement token"});
      check(retire_status==c.status,{why," retirement status"});
    end
    dispatch_valid=0;source_valid=0;complete_valid=0;
  endtask
  task automatic launch(input sm_issue_t x,input bit bad=0);
    events(1,x.token,0,'0,0,'0,0,bad,"dispatch identity/state");
  endtask
  task automatic source_capture(input sm_issue_t x,input bit bad=0);
    events(0,'0,1,x.token,0,'0,0,bad,"source capture identity/state");
  endtask
  task automatic finish(input sm_issue_t x,input sm_status_e status=SM_OK,
      input bit committed=1,input bit expected_retire=1,input bit expected_error=0);
    events(0,'0,0,'0,1,result(x,status,committed),expected_retire,expected_error,
      "completion identity/state/real writeback");
  endtask
  task automatic reset_dut;
    @(negedge clk);rst_n=0;reserve_valid=0;dispatch_valid=0;source_valid=0;complete_valid=0;
    repeat(3)@(negedge clk);
    check(warp_busy=='0 && !retire_valid && !protocol_error,"reset closes only scoreboard metadata");
    rst_n=1;#1;
  endtask

  initial begin:test
    sm_issue_t a,b,p,stale;
    sm_issue_t entries[FLIGHTS];
    bit accepted;
    reserve='0;reserve_valid=0;dispatch_valid=0;dispatch_token='0;
    source_valid=0;source_token='0;complete_valid=0;complete='0;
    for(int w=0;w<WARPS;w++)probe[w]=instruction(w);
    reset_dut();
    check(source_ready && complete_ready,"returns enabled after reset");
    a=instruction(0,4,2,8,2);serial++;push(a);
    check(warp_busy[0],"reservation already owns register dependencies");
    p=instruction(0,8,1);serial++;expect_probe(p,0,"RAW first result word");
    p=instruction(0,9,1);serial++;expect_probe(p,0,"RAW second result word");
    p=instruction(0,0,0,9,1);serial++;expect_probe(p,0,"WAW second result word");
    p=instruction(0,0,0,5,1);serial++;expect_probe(p,0,"WAR uncaptured second source word");
    p=instruction(0,4,1);serial++;expect_probe(p,FLIGHTS>1,"read/read sharing when credit exists");
    expect_probe(a,0,"duplicate full token never reserves twice");
    p=instruction(0,30,1,40,1);serial++;expect_probe(p,FLIGHTS>1,"unrelated same-context dependencies");
    p.token.generation=2;expect_probe(p,0,"live warp slot cannot change generation");
    source_capture(a,1);finish(a,SM_OK,1,0,1);
    check(warp_busy[0],"predispatch return cannot release a reservation");
    launch(a);launch(a,1);

    // Each token component must participate in both completion and source matching.
    for(int field_id=0;field_id<6;field_id++)begin
      stale=a;
      case(field_id)
        0:stale.token.epoch++;
        1:stale.token.ticket++;
        2:stale.token.owner^=3'd1;
        3:stale.token.generation++;
        4:stale.token.warp^=6'd1;
        5:stale.token.instance_id++;
        default:begin end
      endcase
      source_capture(stale,1);finish(stale,SM_OK,1,0,1);
      check(warp_busy[0],"tampered identity cannot clear a live flight");
    end
    source_capture(a);
    p=instruction(0,0,0,4,2);serial++;expect_probe(p,FLIGHTS>1,"captured source releases WAR protection");
    p=instruction(0,8,1);serial++;expect_probe(p,0,"source capture does not release destination RAW");
    source_capture(a,1);
    events(0,'0,1,a.token,1,result(a),1,0,"same-token source+complete coalesces even repeated source");
    check(warp_busy=='0,"successful completion closes reservation");
    finish(a,SM_OK,1,0,1);

    a=instruction(0,1,1,20,2);serial++;push(a);launch(a);
    finish(a,SM_OK,0,0,1);
    check(warp_busy[0],"premature success before actual destination writes holds dependencies");
    events(0,'0,0,'0,1,result(a,sm_status_e'(15),1),0,1,"reserved status encoding is not a completion");
    finish(a,SM_EXEC_ERROR,0);
    check(warp_busy=='0,"formal error retires with poison status instead of deadlocking");

    // Zero-destination operations do not need a fabricated RF write commit.
    a=instruction(0,12,1);serial++;push(a);
    events(1,a.token,1,a.token,1,result(a,SM_OK,0),1,0,"dispatch and zero-latency completion");
    check(warp_busy=='0,"zero-destination completion closes source protection");

    // Predicate and CC are independent namespaces; wide GPR ranges are checked.
    a=instruction(0);serial++;
    a.instr.src[0].kind=SM_RF_PRED;a.instr.src[0].base=2;a.instr.src[0].count=1;
    a.instr.dst[0].kind=SM_RF_CC;a.instr.dst[0].count=1;
    push(a);launch(a);
    p=instruction(0);serial++;p.instr.src[0].kind=SM_RF_CC;p.instr.src[0].count=1;
    expect_probe(p,0,"implicit per-thread CC dependency");
    p=instruction(0);serial++;p.instr.dst[0].kind=SM_RF_PRED;p.instr.dst[0].base=2;p.instr.dst[0].count=1;
    expect_probe(p,0,"predicate source WAR dependency");
    p=instruction(0,2,1);serial++;expect_probe(p,FLIGHTS>1,"GPR2 and predicate2 are independent");
    source_capture(a);expect_probe(p,FLIGHTS>1,"source capture preserves unrelated namespaces");
    finish(a);
    p=instruction(0,255,2);serial++;expect_probe(p,0,"out-of-range GPR span rejected before reservation");
    p=instruction(0);serial++;p.instr.dst[0].kind=SM_RF_CC;p.instr.dst[0].base=1;p.instr.dst[0].count=1;
    expect_probe(p,0,"invalid CC span rejected");
    p=instruction(WARPS);serial++;expect_probe(p,0,"out-of-range warp rejected");

    // Fill all credits with independent destinations, then finish in reverse order.
    for(int f=0;f<FLIGHTS;f++)begin
      entries[f]=instruction(0,32+f,1,128+f,1);serial++;
      push(entries[f]);launch(entries[f]);
    end
    p=instruction(0,0,0,250,1);serial++;expect_probe(p,0,"all flight credits reserved");
    check(source_ready && complete_ready,"full flight table cannot block its own completions");
    for(int f=FLIGHTS-1;f>=0;f--)finish(entries[f]);
    check(warp_busy=='0,"out-of-order completion empties the table");

    if(WARPS>1 && FLIGHTS>1)begin
      a=instruction(0,5,1,8,1);serial++;b=instruction(1,5,1,8,1);serial++;
      push(a);expect_probe(b,1,"same register numbers across warps do not alias");push(b);
      check(warp_busy[0] && warp_busy[int'(b.token.warp)],"independent warp busy state");
      launch(b);finish(b);check(warp_busy[0] && !warp_busy[int'(b.token.warp)],"one warp completion preserves another");
      launch(a);finish(a);
    end

    // Conflicting new reserve waits through the old completion; the old token
    // cannot clear the replacement producer on the following cycle.
    a=instruction(0,0,0,10,1);serial++;b=instruction(0,0,0,10,1);serial++;
    push(a);launch(a);
    @(negedge clk);reserve=b;reserve_valid=1;complete=result(a);complete_valid=1;
    #1;check(!reserve_ready,"no same-cycle bypass of an old destination dependency");
    @(posedge clk);accepted=reserve_ready;
    @(negedge clk);check(!accepted && retire_valid && retire_token==a.token,"old completion retires once");
    complete_valid=0;#1;check(reserve_ready,"new producer becomes eligible after old completion");
    @(posedge clk);@(negedge clk);reserve_valid=0;
    check(warp_busy[0],"newly reserved producer retains dependency");
    finish(a,SM_OK,1,0,1);check(warp_busy[0],"duplicate old completion cannot free replacement");
    launch(b);finish(b);

    a=instruction(0,1,1,8,1);serial++;push(a);launch(a);reset_dut();
    b=instruction(0,1,1,8,1);serial++;b.token.epoch=a.token.epoch+1;push(b);launch(b);
    finish(a,SM_OK,1,0,1);source_capture(a,1);
    check(warp_busy[0],"old reset-epoch token cannot release new flight");
    finish(b);repeat(2)@(negedge clk);
    check(warp_busy=='0,"all directed responsibilities closed");
    $display("SM_SCOREBOARD_PASS checks=%0d reservations=%0d retirements=%0d diagnostics=%0d cycles=%0d warps=%0d flights=%0d",
      checks,reservations,retirements,errors,cycles,WARPS,FLIGHTS);
    $finish;
  end
endmodule
/* verilator lint_on BLKSEQ */
