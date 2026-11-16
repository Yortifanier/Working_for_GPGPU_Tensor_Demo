// Exact destination-set scoreboard for completion multicast. No iteration/order
// function from the DUT is used by this sink. An error is a diagnostic, with no
// barrier arrival responsibility.
/* verilator lint_off BLKSEQ */
module tb_tcgen05_commit_fanout;
  import tcgen05_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  logic req_valid=0,req_ready,rsp_valid,rsp_ready=0,busy;
  tc_event_t req='0,rsp;
  tcgen05_commit_fanout dut(.*);
  tc_event_t expected;
  logic [31:0] expected_targets,seen_targets;
  logic [31:0] rng=32'h1907;
  bit checking=0,force_hold=0;
  int seed=1907,commands=0,completed=0,outputs=0,arrivals=0,checks=0,cycles=0;
  int seen=0,expected_count=0,held_cycles=0,reset_aborts=0;
  function automatic logic[31:0] next_rng(input logic[31:0] value);
    logic[31:0] x;
    x=value^(value<<13);x=x^(x>>17);return x^(x<<5);
  endfunction
  always @(negedge clk)begin
    rng=next_rng(rng);
    rsp_ready=rst_n && !force_hold && (rng[0]||rng[1]);
  end
  always @(posedge clk)begin
    cycles++;
    if(cycles>200000)$fatal(1,"FANOUT watchdog");
    if(rst_n)begin
      if(rsp_valid && !rsp_ready)held_cycles++;
      if(req_valid && req_ready)commands++;
      if(rsp_valid && rsp_ready)begin
        if(!checking)$fatal(1,"Unexpected fanout output after completion/reset");
        if(rsp.tag!=expected.tag || rsp.owner!=expected.owner ||
           rsp.owner_generation!=expected.owner_generation || rsp.warp!=expected.warp ||
           rsp.thread_lane!=expected.thread_lane || rsp.barrier_addr!=expected.barrier_addr ||
           rsp.restricted!=expected.restricted || rsp.cutoff!=expected.cutoff ||
           rsp.status!=expected.status || rsp.multicast!=expected.multicast ||
           rsp.mask_width32!=expected.mask_width32)
          $fatal(1,"Fanout identity mismatch command%0d",commands);
        if(rsp.arrive_count!=(expected.status==TC_OK ? 1 : 0))
          $fatal(1,"Diagnostic created a barrier arrival or success lost arrive-one");
        if(expected.multicast)begin
          if(!rsp.target_valid || !expected_targets[rsp.target_cta] || seen_targets[rsp.target_cta] ||
              rsp.cta_mask!=(32'b1<<rsp.target_cta))
            $fatal(1,"Fanout duplicate/unrequested/non-onehot destination target%0d mask%h",rsp.target_cta,rsp.cta_mask);
          seen_targets[rsp.target_cta]=1;
        end else if(rsp.target_valid!=expected.target_valid || rsp.target_cta!=expected.target_cta)
          $fatal(1,"Unicast local/remote target was not preserved");
        seen++;outputs++;arrivals+=int'(rsp.arrive_count);checks+=3;
        if(seen>expected_count)$fatal(1,"Too many fanout outputs");
      end
    end
  end
  task automatic check(input bit condition,input string message);
    if(!condition)$fatal(1,"%s at cycle%0d",message,cycles);
    checks++;
  endtask
  function automatic tc_event_t event_for(input logic multicast,input logic width32,
      input logic[31:0] mask,input tc_status_e status,input int tag_id);
    tc_event_t e;
    e='0;e.tag=16'(tag_id);e.owner=3'(tag_id%8);e.owner_generation=16'(tag_id+13);
    e.warp=6'(tag_id%64);e.thread_lane=5'(tag_id%32);e.barrier_addr=32'h1000+32'(tag_id)*8;
    e.restricted=1'(tag_id%2);e.cutoff=32'(tag_id*11);e.status=status;
    e.multicast=multicast;e.mask_width32=width32;e.cta_mask=mask;
    return e;
  endfunction
  task automatic expect_event(input tc_event_t e);
    expected=e;expected_targets=e.mask_width32 ? e.cta_mask : e.cta_mask&32'hffff;
    expected_count=e.multicast ? $countones(expected_targets) : 1;
    seen=0;seen_targets=0;checking=1;
  endtask
  task automatic submit(input tc_event_t e);
    @(negedge clk);req=e;req_valid=1;
    do @(posedge clk);while(!req_ready);
    @(negedge clk);req_valid=0;
  endtask
  task automatic await_complete;
    int timeout_at;
    timeout_at=cycles+1000;
    while(seen!=expected_count || busy || !req_ready)begin
      @(negedge clk);
      if(cycles>timeout_at)$fatal(1,"Fanout incomplete %0d/%0d busy%0d",seen,expected_count,busy);
    end
    if(expected.multicast)check(seen_targets==expected_targets,"Destination set exactly matches original mask");
    checking=0;completed++;
  endtask
  task automatic transact(input tc_event_t e);
    expect_event(e);force_hold=1;submit(e);
    repeat(7)@(negedge clk);
    check(seen==0,"Backpressured sink accepted no output");
    force_hold=0;await_complete();
  endtask
  initial begin
    tc_event_t e,next_event;
    int tag_id,cancelled_seen;
    void'($value$plusargs("SEED=%d",seed));rng=32'(seed)|1;
    repeat(4)@(negedge clk);rst_n=1;
    tag_id=1;
    e=event_for(0,0,0,TC_OK,tag_id++);transact(e);
    e=event_for(0,1,32'hffffffff,TC_OK,tag_id++);e.target_valid=1;e.target_cta=27;transact(e);
    e=event_for(1,0,0,TC_OK,tag_id++);transact(e);
    e=event_for(1,1,0,TC_OK,tag_id++);transact(e);
    for(int bit_id=0;bit_id<32;bit_id++)begin
      e=event_for(1,bit_id>=16,32'b1<<bit_id,TC_OK,tag_id++);transact(e);
    end
    e=event_for(1,0,32'h0000ffff,TC_OK,tag_id++);transact(e);
    e=event_for(1,1,32'hffffffff,TC_OK,tag_id++);transact(e);
    e=event_for(1,1,32'h80018001,TC_PRIOR_ERROR,tag_id++);transact(e);
    e=event_for(0,0,0,TC_PRIOR_ERROR,tag_id++);e.target_valid=1;e.target_cta=15;transact(e);
    for(int trial=0;trial<100;trial++)begin
      e=event_for(1,trial%2!=0,trial%2!=0 ? rng : rng&32'hffff,
        trial%7==0 ? TC_PRIOR_ERROR : TC_OK,tag_id++);
      transact(e);
    end

    // Queue the next request while the current packet is stalled. It must keep
    // its payload stable and cannot overwrite the active multicast snapshot.
    e=event_for(1,1,32'hf0018001,TC_OK,tag_id++);
    next_event=event_for(1,0,32'h00008001,TC_OK,tag_id++);
    expect_event(e);force_hold=1;submit(e);
    @(negedge clk);req=next_event;req_valid=1;
    repeat(4)begin @(negedge clk);check(!req_ready,"Busy fanout backpressures a second request");end
    force_hold=0;
    while(!req_ready)@(negedge clk);
    check(seen==expected_count && seen_targets==expected_targets,"Original packet drains before queued request");
    checking=0;completed++;expect_event(next_event);
    do @(posedge clk);while(!req_ready);
    @(negedge clk);req_valid=0;await_complete();

    // Reset cancels the remaining destination responsibility together with the
    // external sink; it must not emit stale arrivals after restart.
    e=event_for(1,1,32'hffffffff,TC_OK,tag_id++);expect_event(e);submit(e);
    while(seen<3)@(negedge clk);
    force_hold=1;cancelled_seen=seen;
    @(negedge clk);rst_n=0;checking=0;req_valid=0;reset_aborts++;
    repeat(3)@(negedge clk);
    rst_n=1;force_hold=0;
    repeat(12)begin @(negedge clk);check(!rsp_valid && !busy,"No stale response after coordinated reset");end
    check(cancelled_seen<32,"Reset actually interrupted a partial fanout");
    e=event_for(0,0,0,TC_OK,tag_id++);transact(e);
    check(held_cycles>100,"Output backpressure was exercised");
    check(commands==completed+reset_aborts,"Every input completed or was explicitly reset-aborted");
    $display("TCGEN05_COMMIT_FANOUT_PASS commands=%0d completed=%0d outputs=%0d arrivals=%0d checks=%0d held=%0d resets=%0d cycles=%0d seed=%0d",
      commands,completed,outputs,arrivals,checks,held_cycles,reset_aborts,cycles,seed);
    $finish;
  end
`ifdef TCGEN05_ASSERTIONS
  assert property(@(posedge clk)disable iff(!rst_n)
    req_valid && !req_ready |=> req_valid && $stable(req));
  assert property(@(posedge clk)disable iff(!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
`endif
endmodule
