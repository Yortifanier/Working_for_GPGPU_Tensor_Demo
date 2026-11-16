`timescale 1ns/1ps
// Procedural test driver/scoreboard intentionally use blocking assignments.
/* verilator lint_off BLKSEQ */
module tb_tcgen05_dot_array;
  import malu_pkg::*;
  parameter int ENGINES=4;
  parameter int LANES=4;
  parameter bit ENABLE_FP64=1;
  localparam int JOBS=16;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic req_valid=0, req_ready;
  malu_cfg_t req_cfg;
  logic [63:0] req_c=0;
  logic [15:0] req_tag=0;
  logic op_valid=0, op_ready;
  logic [15:0] op_tag=0;
  logic [LANES-1:0][63:0] op_a,op_b;
  logic [$clog2(LANES+1)-1:0] op_count;
  logic [7:0] op_scale_a=0,op_scale_b=0;
  logic op_last=0;
  logic rsp_valid,rsp_ready=0;
  logic [15:0] rsp_tag;
  logic [63:0] rsp_data;
  malu_status_e rsp_status;
  logic [ENGINES-1:0] busy_mask;
  tcgen05_dot_array #(.ENGINES(ENGINES),.LANES(LANES),.TAG_W(16),
    .MAX_K(128),.ENABLE_FP64(ENABLE_FP64)) dut(.*);

  malu_cfg_t configs[JOBS];
  logic [63:0] seeds[JOBS],expected[JOBS];
  malu_status_e statuses[JOBS];
  int mode[JOBS],sent[JOBS],seen[JOBS];
  bit admitted[JOBS];
  int checks=0,cycles=0,phase_start=0,completed=0,submitted=0;
  int total_responses=0,performance_cycles=0,max_busy=0,max_math=0;
  int rr=0,phase_id=0,held_cycles=0,hold_count=0;
  int random_seed=1907;
  bit held_once=0,run_phase=0,reverse_completion_seen=0;
  logic [31:0] rng=32'h1a2211;

  function automatic logic [31:0] next_rng(input logic [31:0] x);
    logic [31:0] y;
    y=x^(x<<13); y=y^(y>>17); return y^(y<<5);
  endfunction
  function automatic malu_cfg_t normal_cfg(input int k);
    malu_cfg_t c;
    c='0;c.a_fmt=FMT_F16;c.b_fmt=FMT_F16;c.c_fmt=FMT_F32;c.d_fmt=FMT_F32;
    c.k=16'(k);c.rounding=ROUND_RNE;c.profile=PROJECT_EXACT;
    return c;
  endfunction
  function automatic logic [31:0] float_integer(input int value);
    logic [31:0] magnitude,result;
    int lead;
    if(value==0)return 0;
    magnitude=32'(value<0?-value:value);lead=0;
    for(int b=0;b<31;b++)if(magnitude[b])lead=b;
    result=(32'(lead+127)<<23)|((magnitude<<(23-lead))&32'h7fffff);
    if(value<0)result[31]=1;
    return result;
  endfunction
  function automatic logic [63:0] value_a(input int job,input int index);
    case(mode[job])
      1:return 64'(8'(index%7-3));
      2:return 64'h38;
      3:return index==0?64'h7ff:64'hf801;
      4:return 64'h3f800001;
      5:return 64'h3ff0000000000000;
      6:return 64'h2;
      default:return 64'h3c00;
    endcase
  endfunction
  function automatic logic [63:0] value_b(input int job,input int index);
    case(mode[job])
      1:return 64'(8'(index%5-2));
      2:return 64'h38;
      3:return 64'h1;
      4:return 64'h3f800000;
      5:return 64'h4000000000000000;
      6:return 64'h2;
      default:return 64'h3c00;
    endcase
  endfunction
  task automatic check(input bit pass,input string message);
    if(!pass)$fatal(1,"%s phase=%0d cycle=%0d",message,phase_id,cycles);
    checks++;
  endtask

  always @(posedge clk)begin
    cycles++;
    if(cycles>500000)$fatal(1,"dot array watchdog");
    if(rst_n && run_phase)begin
      if($countones(busy_mask)>max_busy)max_busy=$countones(busy_mask);
      if($countones(busy_mask & ~dut.core_op_ready & ~dut.core_rsp_valid)>max_math)
        max_math=$countones(busy_mask & ~dut.core_op_ready & ~dut.core_rsp_valid);
      if(req_valid&&req_ready)begin
        admitted[int'(req_tag)-1]=1;
        submitted++;
      end
      if(op_valid&&op_ready)sent[int'(op_tag)-1]+=int'(op_count);
      if(rsp_valid&&!rsp_ready)held_cycles++;
      if(rsp_valid&&rsp_ready)begin
        int j;
        j=int'(rsp_tag)-1;
        check(j>=0&&j<JOBS,"response tag range");
        check(admitted[j] && seen[j]==0,"one response per accepted dot");
        check(rsp_status==statuses[j],"numerical/protocol status");
        if(rsp_status==STATUS_OK)begin
          check(rsp_data==expected[j],"independent numerical result");
          check(sent[j]==int'(configs[j].k),"all and only requested K accepted");
        end
        if(j>0&&seen[0]==0)reverse_completion_seen=1;
        seen[j]++;
        completed++;
        total_responses++;
      end
    end
  end

  task automatic reset_endpoint;
    @(negedge clk);rst_n=0;req_valid=0;op_valid=0;rsp_ready=0;run_phase=0;
    repeat(4)@(negedge clk);
    check(busy_mask=='0&&!rsp_valid,"reset cancels all dot ownership and response");
    rst_n=1;
  endtask
  task automatic execute_phase(input int which);
    int candidate,count,block_len,room_a,room_b,timeout_at,op_start_k;
    phase_id=which;completed=0;submitted=0;rr=0;held_once=0;hold_count=0;
    reverse_completion_seen=0;max_busy=0;max_math=0;
    for(int j=0;j<JOBS;j++)begin
      admitted[j]=0;seen[j]=0;sent[j]=0;mode[j]=0;seeds[j]=0;
      configs[j]=normal_cfg(which==0?16:((j%4)+1));
      expected[j]=64'(float_integer(int'(configs[j].k)));
      statuses[j]=STATUS_OK;
    end
    if(which==1)begin
      int oracle;
      configs[0]=normal_cfg(64);expected[0]=64'(float_integer(64));
      configs[1]=normal_cfg(17);configs[1].a_fmt=FMT_S8;configs[1].b_fmt=FMT_S8;
      configs[1].c_fmt=FMT_S32;configs[1].d_fmt=FMT_S32;mode[1]=1;oracle=0;
      for(int k=0;k<17;k++)oracle+=(k%7-3)*(k%5-2);
      expected[1]=64'(32'(oracle));
      configs[2]=normal_cfg(64);configs[2].a_fmt=FMT_E4M3;configs[2].b_fmt=FMT_E4M3;
      configs[2].block_scale_en=1;configs[2].block_size=BLOCK32;
      configs[2].a_scale_fmt=SCALE_UE8M0;configs[2].b_scale_fmt=SCALE_UE8M0;
      configs[2].a_block_offset=15;configs[2].b_block_offset=31;
      mode[2]=2;expected[2]=64'(float_integer(128));
      configs[3]=normal_cfg(2);configs[3].a_fmt=FMT_TI16;configs[3].b_fmt=FMT_TI16;
      configs[3].c_fmt=FMT_S32;configs[3].d_fmt=FMT_S32;
      configs[3].ti16_decoded=1;mode[3]=3;expected[3]=0;
      configs[4]=normal_cfg(8);configs[4].a_fmt=FMT_TF32;configs[4].b_fmt=FMT_TF32;
      mode[4]=4;statuses[4]=STATUS_BAD_ENCODING;
      configs[5]=normal_cfg(0);statuses[5]=STATUS_LENGTH;
      configs[6]=normal_cfg(4);configs[6].profile=2'd1;statuses[6]=STATUS_UNSUPPORTED;
      if(ENABLE_FP64)begin
        configs[7]=normal_cfg(1);configs[7].a_fmt=FMT_F64;configs[7].b_fmt=FMT_F64;
        configs[7].c_fmt=FMT_F64;configs[7].d_fmt=FMT_F64;mode[7]=5;
        expected[7]=64'h4000000000000000;
      end
      configs[8]=normal_cfg(33);configs[8].a_fmt=FMT_E2M1;configs[8].b_fmt=FMT_E2M1;
      configs[8].block_scale_en=1;configs[8].block_size=BLOCK16;
      configs[8].a_scale_fmt=SCALE_UE4M3;configs[8].b_scale_fmt=SCALE_UE4M3;
      configs[8].a_block_offset=15;mode[8]=6;expected[8]=64'(float_integer(33));
    end
    req_valid=0;op_valid=0;run_phase=1;phase_start=cycles;timeout_at=cycles+150000;op_start_k=0;
    while(completed<JOBS)begin
      @(negedge clk);
      rng=next_rng(rng);
      // Advance an accepted descriptor; hold an unaccepted one unchanged.
      if(!req_valid||admitted[int'(req_tag)-1])begin
        candidate=-1;
        for(int j=0;j<JOBS;j++)if(candidate<0&&!admitted[j])candidate=j;
        req_valid=candidate>=0;
        if(candidate>=0)begin req_tag=16'(candidate+1);req_cfg=configs[candidate];req_c=seeds[candidate];end
      end
      // Error response is an explicit abort, including a held unaccepted beat.
      if(op_valid&&seen[int'(op_tag)-1]!=0)op_valid=0;
      if(op_valid&&sent[int'(op_tag)-1]>op_start_k)op_valid=0;
      if(op_valid&&sent[int'(op_tag)-1]>=int'(configs[int'(op_tag)-1].k))op_valid=0;
      if(!op_valid)begin
        candidate=-1;
        for(int offset=0;offset<JOBS;offset++)begin
          int j;
          j=(rr+offset)%JOBS;
          if(candidate<0&&admitted[j]&&seen[j]==0&&sent[j]<int'(configs[j].k)&&
              statuses[j]!=STATUS_LENGTH&&statuses[j]!=STATUS_UNSUPPORTED)candidate=j;
        end
        if(candidate>=0)begin
          op_tag=16'(candidate+1);
          #1;
          if(op_ready)begin
            count=LANES;
            if(count>int'(configs[candidate].k)-sent[candidate])count=int'(configs[candidate].k)-sent[candidate];
            if(configs[candidate].block_scale_en)begin
              block_len=configs[candidate].block_size==BLOCK16?16:32;
              room_a=block_len-((int'(configs[candidate].a_block_offset)+sent[candidate])%block_len);
              room_b=block_len-((int'(configs[candidate].b_block_offset)+sent[candidate])%block_len);
              if(count>room_a)count=room_a;if(count>room_b)count=room_b;
            end
            op_count=$clog2(LANES+1)'(count);op_a='0;op_b='0;
            for(int lane=0;lane<LANES;lane++)if(lane<count)begin
              op_a[lane]=value_a(candidate,sent[candidate]+lane);
              op_b[lane]=value_b(candidate,sent[candidate]+lane);
            end
            op_scale_a=mode[candidate]==2?8'h80:8'h38;
            op_scale_b=mode[candidate]==2?8'h7f:8'h38;
            op_last=sent[candidate]+count==int'(configs[candidate].k);
            op_start_k=sent[candidate];op_valid=1;rr=(candidate+1)%JOBS;
          end else rr=(candidate+1)%JOBS;
        end
      end
      if(!held_once&&rsp_valid)begin held_once=1;hold_count=13;end
      if(hold_count>0)begin rsp_ready=0;hold_count--;end
      else rsp_ready=rng[0]||rng[1];
      if(cycles>timeout_at)$fatal(1,"array phase timeout");
    end
    @(negedge clk);req_valid=0;op_valid=0;rsp_ready=1;run_phase=0;
    repeat(2)@(negedge clk);
    check(submitted==JOBS,"all requested jobs admitted");
    check(busy_mask=='0,"all ownership released");
    check(held_once,"backpressured response exercised");
    if(ENGINES>1)begin
      check(max_busy>=2 && max_math>=2,"actual overlapping dot execution");
      if(which==1)check(reverse_completion_seen,"tag matched out-of-order completion");
    end
    if(which==0)performance_cycles=cycles-phase_start;
  endtask

  initial begin
    req_cfg='0;op_a='0;op_b='0;op_count='0;
    void'($value$plusargs("SEED=%d",random_seed));
    rng=32'(random_seed)|32'h1;
    reset_endpoint();execute_phase(0);execute_phase(1);
    // Reset while multiple descriptors own units but no operands have arrived.
    @(negedge clk);req_tag=16'hff00;req_cfg=normal_cfg(16);req_valid=1;
    do @(posedge clk);while(!req_ready);
    @(negedge clk);req_valid=0;req_tag=16'hff00;#1;
    check(!req_ready,"duplicate active tag cannot allocate another engine");
    reset_endpoint();execute_phase(0);
    check(total_responses==3*JOBS,"three nonempty phases completed");
    check(held_cycles>=39,"response arbitration lock under backpressure");
    $display("TCGEN05_DOT_ARRAY_PASS checks=%0d responses=%0d perf_jobs=%0d perf_cycles=%0d max_busy=%0d max_math=%0d held=%0d engines=%0d lanes=%0d fp64=%0d seed=%0d cycles=%0d",
      checks,total_responses,JOBS,performance_cycles,max_busy,max_math,held_cycles,ENGINES,LANES,int'(ENABLE_FP64),random_seed,cycles);
    $finish;
  end
endmodule
