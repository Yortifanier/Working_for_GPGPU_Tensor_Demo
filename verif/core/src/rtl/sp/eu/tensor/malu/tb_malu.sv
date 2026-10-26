module tb_malu;
  timeunit 1ns;
  timeprecision 1ps;
  import malu_pkg::*;
  parameter int LANES=4;
  parameter bit ENABLE_FP64=1'b1;
  localparam int TAG_W=8;
  localparam int MAX_VECTOR_K=65535;
  logic clk=0;
  logic rst_n=0;
  // A testbench clock generator intentionally uses a blocking assignment.
  /* verilator lint_off BLKSEQ */
  always #5 clk=~clk;
  /* verilator lint_on BLKSEQ */
  malu_if #(.LANES(LANES),.TAG_W(TAG_W)) bus(clk,rst_n);
  malu #(.LANES(LANES),.TAG_W(TAG_W),.ENABLE_FP64(ENABLE_FP64)) dut(bus);
  logic [63:0] av [0:MAX_VECTOR_K-1];
  logic [63:0] bv [0:MAX_VECTOR_K-1];
  logic [7:0] sa [0:MAX_VECTOR_K-1];
  logic [7:0] sb [0:MAX_VECTOR_K-1];
  integer cases=0, protocol_cases=0;
  integer cycle_count=0;
  integer rng_seed=1;
  always @(posedge clk) begin
    cycle_count <= cycle_count+1;
    if (cycle_count>100_000_000) $fatal(1,"Global watchdog: no silent zero-test pass");
  end

  task automatic request(input malu_cfg_t cfg, input logic [63:0] c,
                         input logic [7:0] tag);
    integer guard_count;
    @(negedge clk);
    bus.req_cfg=cfg; bus.req_c=c; bus.req_tag=tag; bus.req_valid=1;
    guard_count=0;
    do begin
      @(posedge clk);
      guard_count++;
      if (guard_count>50000) $fatal(1,"Request timeout case=%0d",cases);
    end while (!bus.req_ready);
    @(negedge clk); bus.req_valid=0;
  endtask

  task automatic beat(input integer first, input integer count,
                      input bit last, output bit aborted);
    integer guard_count;
    aborted=0;
    @(negedge clk);
    if (bus.rsp_valid) begin aborted=1; return; end
    bus.op_a='0; bus.op_b='0;
    for (int lane=0;lane<LANES;lane++) begin
      if (lane<count) begin bus.op_a[lane]=av[first+lane]; bus.op_b[lane]=bv[first+lane]; end
    end
    bus.op_count=$clog2(LANES+1)'(count);
    bus.op_scale_a=sa[first]; bus.op_scale_b=sb[first]; bus.op_last=last;
    bus.op_valid=1;
    guard_count=0;
    do begin
      @(posedge clk);
      guard_count++;
      if (bus.rsp_valid) begin aborted=1; break; end
      if (guard_count>50000) $fatal(1,"Operand timeout case=%0d first=%0d",cases,first);
    end while (!bus.op_ready);
    @(negedge clk); bus.op_valid=0;
  endtask

  task automatic response(input malu_status_e expected_status,
                          input logic [63:0] expected_data,
                          input logic [7:0] expected_tag);
    integer guard_count, stall;
    logic [63:0] held_data;
    logic [7:0] held_tag;
    malu_status_e held_status;
    guard_count=0;
    while (!bus.rsp_valid) begin
      @(posedge clk); guard_count++;
      if (guard_count>50000) $fatal(1,"Response timeout case=%0d",cases);
    end
    @(negedge clk);
    held_data=bus.rsp_data; held_tag=bus.rsp_tag; held_status=bus.rsp_status;
    if (held_status!==expected_status || held_data!==expected_data || held_tag!==expected_tag)
      $fatal(1,"MISMATCH case=%0d cfg=%h expected=%h/%0d/tag%h got=%h/%0d/tag%h cycle=%0d",
        cases,bus.req_cfg,expected_data,expected_status,expected_tag,held_data,held_status,held_tag,cycle_count);
    stall=$urandom_range(5,1);
    repeat (stall) begin
      @(negedge clk);
      if (!bus.rsp_valid || bus.rsp_data!==held_data || bus.rsp_tag!==held_tag || bus.rsp_status!==held_status)
        $fatal(1,"Response changed under backpressure case=%0d",cases);
      if (bus.req_ready) $fatal(1,"Single-context engine accepted another request while response held");
    end
    bus.rsp_ready=1;
    @(posedge clk);
    @(negedge clk); bus.rsp_ready=0;
    if (bus.rsp_valid) $fatal(1,"Duplicate response case=%0d",cases);
  endtask

  task automatic send_vector(input malu_cfg_t cfg, input logic [63:0] c,
                             input integer n, input integer expected_status,
                             input logic [63:0] expected_data);
    integer sent, count, limit_count, length, a_room, b_room;
    bit aborted;
    logic [7:0] tag;
    tag=8'(cases);
    request(cfg,c,tag);
    sent=0;
    while (sent<n) begin
      repeat ($urandom_range(2,0)) @(negedge clk);
      if (bus.rsp_valid) break;
      limit_count=(n-sent<LANES)?n-sent:LANES;
      if (cfg.block_scale_en) begin
        length=cfg.block_size==BLOCK16?16:32;
        a_room=length-((int'(cfg.a_block_offset)+sent)%length);
        b_room=length-((int'(cfg.b_block_offset)+sent)%length);
        if (limit_count>a_room) limit_count=a_room;
        if (limit_count>b_room) limit_count=b_room;
      end
      count=int'($urandom_range(32'(limit_count),1));
      beat(sent,count,sent+count==n,aborted);
      if (aborted) break;
      sent+=count;
    end
    response(malu_status_e'(expected_status),expected_data,tag);
    cases++;
  endtask

  task automatic pulse_reset;
    @(negedge clk);rst_n=0;
    bus.req_valid=0;bus.op_valid=0;bus.rsp_ready=0;
    repeat (3) @(posedge clk);
    @(negedge clk);rst_n=1;
    repeat (2) @(negedge clk);
    if (bus.rsp_valid || !bus.req_ready) $fatal(1,"Reset did not clear the transaction");
  endtask

  task automatic protocol_tests;
    malu_cfg_t cfg;
    bit aborted;
    integer guard_count;
    cfg='0;cfg.a_fmt=FMT_U8;cfg.b_fmt=FMT_U8;cfg.c_fmt=FMT_S32;cfg.d_fmt=FMT_S32;
    cfg.k=1;av[0]=2;bv[0]=3;sa[0]=0;sb[0]=0;

    // Invalid empty beat: immediate error and recovery.
    request(cfg,7,8'he0);beat(0,0,1,aborted);response(STATUS_LENGTH,0,8'he0);protocol_cases++;
    // Missing last when K is reached.
    request(cfg,7,8'he1);beat(0,1,0,aborted);response(STATUS_LENGTH,0,8'he1);protocol_cases++;
    // Early last before K is reached.
    cfg.k=2;request(cfg,7,8'he2);beat(0,1,1,aborted);response(STATUS_LENGTH,0,8'he2);protocol_cases++;

    // Reset during clearing; no stale response survives.
    request(cfg,7,8'he3);pulse_reset();protocol_cases++;
    cfg.k=1;request(cfg,7,8'he4);beat(0,1,1,aborted);response(STATUS_OK,13,8'he4);protocol_cases++;

    // Reset while a response is blocked, then reuse the context.
    request(cfg,7,8'he5);beat(0,1,1,aborted);
    guard_count=0;
    while (!bus.rsp_valid) begin @(posedge clk);guard_count++;if(guard_count>50000)$fatal(1,"Reset-response timeout");end
    pulse_reset();protocol_cases++;
    request(cfg,1,8'he6);beat(0,1,1,aborted);response(STATUS_OK,7,8'he6);protocol_cases++;

    // A new descriptor remains stable while the previous result is blocked.
    request(cfg,7,8'hd0);beat(0,1,1,aborted);
    @(negedge clk);
    bus.req_cfg=cfg;bus.req_c=1;bus.req_tag=8'hd1;bus.req_valid=1;
    response(STATUS_OK,13,8'hd0);protocol_cases++;
    do @(posedge clk); while(!bus.req_ready);
    @(negedge clk);bus.req_valid=0;
    beat(0,1,1,aborted);response(STATUS_OK,7,8'hd1);protocol_cases++;

    // Reset while a finite floating term is being added across RAM words.
    cfg='0;cfg.a_fmt=ENABLE_FP64?FMT_F64:FMT_F32;cfg.b_fmt=cfg.a_fmt;
    cfg.c_fmt=cfg.a_fmt;cfg.d_fmt=cfg.a_fmt;cfg.k=4;
    for(int i=0;i<4;i++)begin
      av[i]=ENABLE_FP64?64'h3ff0000000000000:64'h3f800000;bv[i]=av[i];sa[i]=0;sb[i]=0;
    end
    request(cfg,0,8'hd2);beat(0,(LANES<4?LANES:4),LANES>=4,aborted);
    repeat(10)@(posedge clk);
    pulse_reset();protocol_cases++;
    cfg.k=1;request(cfg,0,8'hd3);beat(0,1,1,aborted);
    response(STATUS_OK,ENABLE_FP64?64'h3ff0000000000000:64'h3f800000,8'hd3);protocol_cases++;

    // The error response explicitly cancels an unaccepted following beat.
    cfg='0;cfg.a_fmt=FMT_TI16;cfg.b_fmt=FMT_TI16;cfg.c_fmt=FMT_S32;cfg.d_fmt=FMT_S32;
    cfg.ti16_decoded=1;cfg.k=8;av[0]=2048;bv[0]=1;
    request(cfg,0,8'hd4);beat(0,1,0,aborted);
    bus.op_a='0;bus.op_b='0;bus.op_a[0]=1;bus.op_b[0]=1;
    bus.op_count=1;bus.op_last=0;bus.op_valid=1;
    guard_count=0;
    while(!bus.rsp_valid)begin
      @(posedge clk);guard_count++;
      if(guard_count>50000)$fatal(1,"Error-abort timeout");
    end
    @(negedge clk);bus.op_valid=0;
    response(STATUS_BAD_ENCODING,0,8'hd4);protocol_cases++;

    // Same scale block may not change its value between beats.
    cfg='0;cfg.a_fmt=FMT_E2M1;cfg.b_fmt=FMT_E2M1;cfg.c_fmt=FMT_F32;cfg.d_fmt=FMT_F32;
    cfg.k=2;cfg.block_scale_en=1;cfg.block_size=BLOCK16;
    cfg.a_scale_fmt=SCALE_UE4M3;cfg.b_scale_fmt=SCALE_UE4M3;
    av[0]=2;bv[0]=2;av[1]=2;bv[1]=2;sa[0]=56;sb[0]=56;sa[1]=57;sb[1]=56;
    request(cfg,0,8'he7);beat(0,1,0,aborted);beat(1,1,1,aborted);
    response(STATUS_BAD_ENCODING,0,8'he7);protocol_cases++;

    if (LANES>1) begin
      // A single beat cannot cross either side's scale boundary.
      cfg.a_block_offset=15;cfg.b_block_offset=0;sa[1]=56;
      request(cfg,0,8'he8);beat(0,2,1,aborted);response(STATUS_LENGTH,0,8'he8);protocol_cases++;
    end
  endtask

  initial begin : run
    string vector_file;
    integer fd, scanned, count, expected_status;
    logic [62:0] cfg_bits;
    logic [63:0] c_bits, expected_data;
    malu_cfg_t cfg;
    bus.req_valid=0;bus.req_cfg='0;bus.req_c=0;bus.req_tag=0;
    bus.op_valid=0;bus.op_a='0;bus.op_b='0;bus.op_count=0;
    bus.op_scale_a=0;bus.op_scale_b=0;bus.op_last=0;bus.rsp_ready=0;
    if ($value$plusargs("SEED=%d",rng_seed)) begin end
    rng_seed=$urandom(rng_seed);
    pulse_reset();
    if (!$value$plusargs("VECTORS=%s",vector_file)) $fatal(1,"VECTORS file is required");
    fd=$fopen(vector_file,"r");if(fd==0)$fatal(1,"Cannot read vector file %s",vector_file);
    while (!$feof(fd)) begin
      scanned=$fscanf(fd,"%h %h %d %d %h",cfg_bits,c_bits,count,expected_status,expected_data);
      if (scanned<=0 && $feof(fd)) break;
      if (scanned!=5 || count<0 || count>MAX_VECTOR_K) $fatal(1,"Bad vector header case=%0d",cases);
      cfg=malu_cfg_t'(cfg_bits);
      for(int i=0;i<count;i++) begin
        scanned=$fscanf(fd,"%h %h %h %h",av[i],bv[i],sa[i],sb[i]);
        if(scanned!=4)$fatal(1,"Bad operands case=%0d index=%0d",cases,i);
      end
      send_vector(cfg,c_bits,count,expected_status,expected_data);
    end
    $fclose(fd);
    if(cases==0)$fatal(1,"Zero numerical cases executed");
    protocol_tests();
    $display("MALU_PASS numerical=%0d protocol=%0d lanes=%0d fp64=%0d cycles=%0d",cases,protocol_cases,LANES,ENABLE_FP64,cycle_count);
    $finish;
  end
endmodule
