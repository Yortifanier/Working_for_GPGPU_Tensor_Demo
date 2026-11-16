/* verilator lint_off BLKSEQ */
module tb_sm_warp_sched;
  timeunit 1ns;timeprecision 1ps;
  parameter int WARPS=64;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  logic [WARPS-1:0] eligible;
  logic take,valid;
  logic [5:0] selected;
  int order[WARPS],rotated[WARPS],grants[WARPS];
  int checks=0,accepted=0,steps=0,seed=1907;
  logic [31:0] rng;
  sm_warp_sched #(.WARPS(WARPS))dut(.*);

  function automatic logic [31:0] next_random(input logic [31:0] v);
    logic [31:0] x;
    x=v^(v<<13);x=x^(x>>17);return x^(x<<5);
  endfunction
  task automatic check(input bit condition,input string message);
    if(!condition)$fatal(1,"%s WARPS=%0d step=%0d",message,WARPS,steps);
    checks++;
  endtask
  task automatic reset_scheduler;
    @(negedge clk);rst_n=0;eligible='1;take=0;
    #1;check(!valid,"reset suppresses candidate");
    repeat(2)@(negedge clk);
    eligible=0;rst_n=1;
    for(int i=0;i<WARPS;i++)begin order[i]=i;grants[i]=0;end
  endtask
  // Reference uses a rotating priority list, not the DUT pointer/index walk.
  task automatic step(input logic [WARPS-1:0] mask,input bit consume);
    int position,expected;
    @(negedge clk);eligible=mask;take=consume && |mask;
    #1;
    steps++;position=-1;expected=0;
    for(int i=0;i<WARPS;i++)if(position<0 && mask[order[i]])begin
      position=i;expected=order[i];
    end
    check(valid==(position>=0),"candidate valid matches eligible set");
    if(position>=0)check(selected==6'(expected),"round-robin reference selection");
    if(position>=0 && take)begin
      grants[expected]++;accepted++;
      for(int i=0;i<WARPS;i++)rotated[i]=order[(position+1+i)%WARPS];
      for(int i=0;i<WARPS;i++)order[i]=rotated[i];
    end
    @(posedge clk);#1;
  endtask
  initial begin
    logic [WARPS-1:0] mask;
    eligible=0;take=0;
    void'($value$plusargs("SEED=%d",seed));rng=32'(seed)|1;
    reset_scheduler();
    if($test$plusargs("NEGATIVE_TAKE"))begin
      @(negedge clk);eligible=0;take=1;
      @(posedge clk);#1;
      $fatal(1,"Expected a_take_requires_candidate assertion did not fire");
    end
    repeat(8)step('0,0);
    // Every continuously eligible warp wins once per WARPS actual grants.
    for(int i=0;i<3*WARPS;i++)step('1,1);
    for(int i=0;i<WARPS;i++)check(grants[i]==3,"persistent eligible fairness");
    mask=0;mask[0]=1;mask[WARPS/2]=1;mask[WARPS-1]=1;
    repeat(3*WARPS)step(mask,1);
    // No take means no priority advancement; changing eligibility may still
    // change the combinational candidate, as required by this internal port.
    repeat(12)step('1,0);
    for(int i=0;i<WARPS;i++)begin mask=0;mask[i]=1;step(mask,0);end
    step('1,1);
    for(int trial=0;trial<5000;trial++)begin
      for(int i=0;i<WARPS;i++)begin rng=next_random(rng);mask[i]=rng[3];end
      rng=next_random(rng);step(mask,rng[0] || rng[1]);
    end
    reset_scheduler();
    for(int i=0;i<2*WARPS;i++)step('1,1);
    for(int i=0;i<WARPS;i++)check(grants[i]==2,"post-reset priority/fairness");
    repeat(5)step('0,0);
    $display("SM_WARP_SCHED_PASS warps=%0d checks=%0d grants=%0d steps=%0d seed=%0d",
      WARPS,checks,accepted,steps,seed);
    $finish;
  end
endmodule
/* verilator lint_on BLKSEQ */
