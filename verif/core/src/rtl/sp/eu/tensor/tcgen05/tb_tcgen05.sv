// Blocking assignments are intentional in this procedural testbench's clock,
// driver and independent scoreboard; no DUT datapath warning is suppressed.
/* verilator lint_off BLKSEQ */
module tb_tcgen05;
  import malu_pkg::*;
  import tcgen05_pkg::*;
  parameter int COLS = 576;
  parameter int LANES = 4;
  parameter bit ENABLE_FP64 = 1;
  localparam int SMEM_WORDS = 8192;
  localparam int TAGS = 1024;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  tcgen05_if bus(clk,rst_n);
  tcgen05 #(.COLS(COLS),.LANES(LANES),.MAX_K(128),
    .ENABLE_FP64(ENABLE_FP64)) dut(bus);
  logic [31:0] smem [TC_OWNERS][SMEM_WORDS];
  tc_rsp_t received [TAGS];
  tc_event_t events [TAGS];
  logic [TAGS-1:0] got, event_got;
  int response_cycle [TAGS], event_cycle [TAGS];
  logic [31:0] multicast_seen [TAGS];
  int cycles=0, checks=0, responses=0, event_count=0, next_tag=1;
  int smem_reads=0, tmem_reads=0, operand_beats=0;
  int beat_counts [1024];
  bit hold_rsp=0, hold_event=0, hold_smem=0;
  bit smem_pending=0, inject_error=0;
  logic [31:0] fault_address=0, random_state=32'h19070511;
  int random_seed=1, memory_delay=0;
  tc_mem_rsp_t memory_response;

  function automatic logic [31:0] random_next(input logic [31:0] value);
    logic [31:0] x;
    x=value^(value<<13); x=x^(x>>17); return x^(x<<5);
  endfunction
  always @(negedge clk) begin
    random_state=random_next(random_state);
    bus.rsp_ready=rst_n && !hold_rsp && (random_state[0] || random_state[1]);
    bus.event_ready=rst_n && !hold_event && (random_state[2] || random_state[3]);
    bus.smem_req_ready=rst_n && !hold_smem && !smem_pending &&
      !bus.smem_rsp_valid && (random_state[4] || random_state[5]);
  end
  always @(posedge clk) begin
    cycles=cycles+1;
    if (cycles>3000000) $fatal(1,"TCGEN05 watchdog");
    if (!rst_n) begin
      smem_pending<=0;
      bus.smem_rsp_valid<=0;
      bus.smem_rsp<='0;
    end else begin
      if (bus.rsp_valid && bus.rsp_ready) begin
        if (int'(bus.rsp.tag)>=TAGS || got[int'(bus.rsp.tag)])
          $fatal(1,"Duplicate/out-of-range response tag %d",bus.rsp.tag);
        got[int'(bus.rsp.tag)]=1;
        received[int'(bus.rsp.tag)]=bus.rsp;
        response_cycle[int'(bus.rsp.tag)]=cycles;
        responses=responses+1;
      end
      if (bus.event_valid && bus.event_ready) begin
        if (int'(bus.event_data.tag)>=TAGS ||
            (!bus.event_data.multicast && event_got[int'(bus.event_data.tag)]))
          $fatal(1,"Duplicate/out-of-range event tag");
        if (bus.event_data.arrive_count!=(bus.event_data.status==TC_OK ? 1 : 0))
          $fatal(1,"Event arrival/error responsibility mismatch");
        if (bus.event_data.multicast) begin
          if (!bus.event_data.target_valid ||
              bus.event_data.cta_mask!=(32'b1<<bus.event_data.target_cta) ||
              multicast_seen[int'(bus.event_data.tag)][bus.event_data.target_cta])
            $fatal(1,"Duplicate or invalid multicast destination");
          multicast_seen[int'(bus.event_data.tag)] |= 32'b1<<bus.event_data.target_cta;
        end
        event_got[int'(bus.event_data.tag)]=1;
        events[int'(bus.event_data.tag)]=bus.event_data;
        event_cycle[int'(bus.event_data.tag)]=cycles;
        event_count=event_count+1;
      end
      if (dut.tm_req_valid && dut.tm_req_ready && !dut.tm_req.write)
        tmem_reads=tmem_reads+1;
      if (dut.engine.mma.array_op_valid && dut.engine.mma.array_op_ready) begin
        beat_counts[operand_beats%1024]=int'(dut.engine.mma.beat_count);
        operand_beats=operand_beats+1;
      end
      if (bus.smem_rsp_valid && bus.smem_rsp_ready) bus.smem_rsp_valid<=0;
      if (smem_pending) begin
        if (memory_delay==0) begin
          bus.smem_rsp_valid<=1;
          bus.smem_rsp<=memory_response;
          smem_pending<=0;
        end else memory_delay=memory_delay-1;
      end
      if (bus.smem_req_valid && bus.smem_req_ready) begin
        if (bus.smem_req.write || bus.smem_req.byte_addr[1:0]!=0 ||
            bus.smem_req.byte_addr>=SMEM_WORDS*4)
          $fatal(1,"Unexpected SMEM request");
        smem_reads=smem_reads+1;
        memory_response.rdata=smem[bus.smem_req.owner][bus.smem_req.byte_addr>>2];
        memory_response.status=TC_OK;
        memory_response.txn_id=bus.smem_req.txn_id;
        if (inject_error && bus.smem_req.byte_addr==fault_address) begin
          memory_response.status=TC_MEM_ERROR;
          inject_error=0;
        end
        smem_pending<=1;
        memory_delay=int'(random_state[9:6]);
      end
    end
  end

  function automatic tc_cmd_t command(input tc_opcode_e op);
    tc_cmd_t c;
    c='0; c.op=op; c.recipe=TC_RECIPE_WORD32_REF;
    c.owner_generation=1;
    c.participants=is_collective(op) ? 32'hffffffff : 32'h1;
    c.ncols=1;
    c.m=1; c.n=1;
    c.cfg.a_fmt=FMT_F16; c.cfg.b_fmt=FMT_F16;
    c.cfg.c_fmt=FMT_F32; c.cfg.d_fmt=FMT_F32;
    c.cfg.k=4; c.cfg.rounding=ROUND_RNE; c.cfg.profile=PROJECT_EXACT;
    c.a_addr=32'h100; c.b_addr=32'h500;
    c.scale_a_addr=32'ha00; c.scale_b_addr=32'hb00;
    c.barrier_addr=32'h7800;
    return c;
  endfunction
  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1,"%s (cycle %0d)",message,cycles);
    checks=checks+1;
  endtask
  task automatic submit(input tc_cmd_t original, output int tag_id);
    tc_cmd_t c;
    int timeout_at;
    c=original;
    tag_id=next_tag; next_tag=next_tag+1;
    check(next_tag<TAGS,"tag capacity");
    c.tag=16'(tag_id);
    @(negedge clk); bus.cmd=c; bus.cmd_valid=1;
    timeout_at=cycles+10000;
    do begin
      @(posedge clk);
      if (cycles>timeout_at) $fatal(1,"Command admission timeout op=%0d tag=%0d",c.op,c.tag);
    end while (!bus.cmd_ready);
    @(negedge clk); bus.cmd_valid=0;
  endtask
  task automatic await_response(input int tag_id, input tc_status_e status);
    int timeout_at;
    timeout_at=cycles+300000;
    while (!got[tag_id]) begin
      @(negedge clk);
      if (cycles>timeout_at) $fatal(1,"Response timeout tag=%0d",tag_id);
    end
    if (received[tag_id].status!=status)
      $fatal(1,"tag %0d expected status %0d actual %0d",tag_id,status,received[tag_id].status);
    checks=checks+1;
  endtask
  task automatic await_event(input int tag_id, input tc_status_e status);
    int timeout_at;
    timeout_at=cycles+300000;
    while (!event_got[tag_id]) begin
      @(negedge clk);
      if (cycles>timeout_at) $fatal(1,"Event timeout tag=%0d",tag_id);
    end
    check(events[tag_id].status==status,"event status");
  endtask
  task automatic transact(input tc_cmd_t c, input tc_status_e status, output int tag_id);
    submit(c,tag_id); await_response(tag_id,status);
  endtask
  task automatic load_column(input int col, input int warp_id, output tc_rsp_t data_rsp);
    tc_cmd_t c;
    int tag_id;
    c=command(TC_LD); c.tmem_col=10'(col); c.warp=6'(warp_id);
    transact(c,TC_OK,tag_id); data_rsp=received[tag_id];
  endtask
  task automatic fill_ones(input int k, input logic [31:0] a, input logic [31:0] b);
    for (int i=0; i<k; i++) begin
      smem[0][64+i]=a;
      smem[0][320+i]=b;
    end
  endtask

  initial begin : test_sequence
    tc_cmd_t c;
    tc_rsp_t r;
    int tag_id, first_tag, second_tag, restricted_tag, full_tag;
    int read_before, beat_before, k_done, expect_count, a_room, b_room;
    int base0, base_a, owner1_base;
    int release_tag,init_tag,fence_tag;
    bit new_generation_context;
    logic [31:0] expected;
    bus.cmd_valid=0; bus.cmd='0; bus.rsp_ready=0; bus.event_ready=0;
    bus.smem_req_ready=0; bus.smem_rsp_valid=0; bus.smem_rsp='0;
    bus.capabilities='1;bus.reset_epoch=1;
    bus.rf_in_valid=0;bus.rf_in='0;bus.rf_out_ready=1;
    bus.peer_cmd_ready=0;bus.peer_rsp_valid=0;bus.peer_rsp='0;
    bus.service_cmd_valid=0;bus.service_cmd='0;bus.service_rsp_ready=1;
    bus.peer_mem_req_ready=0;bus.peer_mem_rsp_valid=0;bus.peer_mem_rsp='0;
    bus.service_mem_req_valid=0;bus.service_mem_req='0;bus.service_mem_rsp_ready=1;
    got='0; event_got='0;
    for (int i=0;i<TAGS;i++) multicast_seen[i]=0;
    if ($value$plusargs("SEED=%d",random_seed)) begin end
    random_state=32'(random_seed)|32'h1;
    for (int owner=0; owner<TC_OWNERS; owner++) begin
      bus.owner_smem_bytes[owner]=SMEM_WORDS*4;
      for (int i=0; i<SMEM_WORDS; i++) smem[owner][i]=0;
    end
    repeat (4) @(negedge clk);
    rst_n=1;
    c=command(TC_CTX_INIT); transact(c,TC_OK,tag_id);
    c=command(TC_ALLOC); c.ncols=32;
    transact(c,TC_OK,tag_id); base0=int'(received[tag_id].tmem_col);
    check(base0==0,"first allocation base");

    // A delayed old RELEASE response must not erase a newly initialized
    // generation's CTA group or issuer context. Allocator ownership can change
    // before the old response escapes a blocked core response port.
    c=command(TC_CTX_INIT);c.owner=3;transact(c,TC_OK,tag_id);
    hold_rsp=1;c=command(TC_WAIT_ST);submit(c,first_tag);
    while(!bus.rsp_valid) @(negedge clk);
    c=command(TC_CTX_RELEASE);c.owner=3;submit(c,release_tag);
    repeat(80)@(negedge clk);
    check(!dut.owner_live[3],"old owner released behind blocked core response");
    c=command(TC_CTX_INIT);c.owner=3;c.owner_generation=2;c.cta_pair=1;
    c.recipe=TC_RECIPE_CANONICAL;submit(c,init_tag);
    repeat(80)@(negedge clk);
    check(dut.owner_live[3] && dut.owner_generation[3]==2,"new generation initialized before old response");
    c=command(TC_FENCE);c.owner=3;c.owner_generation=2;c.recipe=TC_RECIPE_CANONICAL;
    submit(c,fence_tag);hold_rsp=0;
    await_response(first_tag,TC_OK);await_response(release_tag,TC_OK);
    await_response(init_tag,TC_OK);await_response(fence_tag,TC_OK);
    check(dut.owner_pair[3],"old release preserves newer CTA group");
    new_generation_context=0;
    for(int i=0;i<32;i++) if(dut.ctx_live[i] && dut.ctx_owner[i]==3 && dut.ctx_generation[i]==2)
      new_generation_context=1;
    check(new_generation_context,"old release preserves newer issuer context");
    c=command(TC_COMMIT);c.owner=3;c.owner_generation=2;c.recipe=TC_RECIPE_CANONICAL;c.cta_pair=1;
    transact(c,TC_OK,tag_id);await_event(tag_id,TC_OK);
    c=command(TC_CTX_RELEASE);c.owner=3;c.owner_generation=2;transact(c,TC_OK,tag_id);

    // Every quarter must read its own 32 lanes, not lane0 replicated 32 times.
    for (int w=0; w<4; w++) begin
      c=command(TC_ST); c.warp=6'(w); c.tmem_col=10'(base0);
      for (int lane=0; lane<32; lane++) c.data[lane]=32'(w*32+lane+1000);
      transact(c,TC_OK,tag_id);
      load_column(base0,w,r);
      for (int lane=0; lane<32; lane++) check(r.data[lane]==32'(w*32+lane+1000),"warp-quarter mapping");
    end
    c=command(TC_WAIT_ST); transact(c,TC_OK,tag_id);
    c=command(TC_WAIT_LD); transact(c,TC_OK,tag_id);
    c=command(TC_FENCE); c.thread_lane=7; c.participants=32'h80;
    transact(c,TC_OK,tag_id);

    // Each selected cluster CTA gets one actual completion responsibility.
    c=command(TC_COMMIT);c.recipe=TC_RECIPE_CANONICAL;c.multicast=1;
    c.mask_width32=1;c.cta_mask=32'h80010003;
    transact(c,TC_OK,tag_id);
    begin : wait_multicast32
      int deadline;deadline=cycles+1000;
      while(multicast_seen[tag_id]!=32'h80010003)begin
        @(negedge clk);if(cycles>deadline)$fatal(1,"32bit multicast incomplete");
      end
      check(multicast_seen[tag_id]==32'h80010003,"32bit targets0,1,16,31 exactly once");
    end
    c.mask_width32=0;c.cta_mask=32'h8001;transact(c,TC_OK,tag_id);
    begin : wait_multicast16
      int deadline;deadline=cycles+1000;
      while(multicast_seen[tag_id]!=32'h8001)begin
        @(negedge clk);if(cycles>deadline)$fatal(1,"16bit multicast incomplete");
      end
      check(multicast_seen[tag_id]==32'h8001,"16bit boundary destinations");
    end
    c.cta_mask=0;transact(c,TC_OK,tag_id);repeat(12)@(negedge clk);
    check(!event_got[tag_id],"empty multicast has no fabricated arrival");
    c=command(TC_COMMIT);c.recipe=TC_RECIPE_CANONICAL;c.barrier_remote=1;c.barrier_target=7;
    transact(c,TC_OK,tag_id);await_event(tag_id,TC_OK);
    check(events[tag_id].target_valid && events[tag_id].target_cta==7,"remote unicast destination preserved");

    // Shared bytes -> distinct TMEM columns, checked without peeking into RAM.
    for (int i=0; i<256; i++) smem[0][512+i]=32'habc00000+32'(i);
    c=command(TC_CP); c.tmem_col=2; c.ncols=2; c.smem_addr=32'h800;
    transact(c,TC_OK,tag_id);
    for (int col=0; col<2; col++)
      for (int w=0; w<4; w++) begin
        load_column(2+col,w,r);
        for (int lane=0; lane<32; lane++)
          check(r.data[lane]==32'habc00000+32'(col*128+w*32+lane),"CP data and column mapping");
      end

    // Down-shuffle source selection: dst row r gets old row r+1; tail stays.
    for (int i=0; i<1024; i++) smem[0][1024+i]=32'h10000000+32'(i);
    c=command(TC_CP); c.tmem_col=8; c.ncols=8; c.smem_addr=32'h1000;
    transact(c,TC_OK,tag_id);
    c=command(TC_SHIFT); c.tmem_col=8; c.ncols=8; c.warp=2;
    transact(c,TC_OK,tag_id);
    for (int col=0; col<8; col++)
      for (int w=0; w<4; w++) begin
        load_column(8+col,w,r);
        for (int lane=0; lane<32; lane++) begin
          expected=32'h10000000+32'(col*128+w*32+lane);
          if (w==2 && lane!=31) expected=expected+1;
          check(r.data[lane]==expected,"SHIFT source-next-row and tail policy");
        end
      end

    // Non-square dense tile; independent B column and A row strides.
    for (int i=0; i<8; i++) smem[0][64+i]=(i<4) ? 32'h3c00 : 32'h4000;
    for (int i=0; i<4; i++) begin
      smem[0][320+3*i]=32'h3c00;
      smem[0][321+3*i]=32'h4000;
      smem[0][322+3*i]=32'h4200;
    end
    c=command(TC_MMA); c.m=2; c.n=3;
    transact(c,TC_OK,tag_id); load_column(0,0,r);
    check(r.data[0]==32'h40800000 && r.data[1]==32'h41000000 &&
      r.data[2]==32'h41400000 && r.data[3]==32'h41000000 &&
      r.data[4]==32'h41800000 && r.data[5]==32'h41c00000,"2x3 row-major dense tile");

    // Formal C is scaled exactly once. Disabling D must not even read old NaN.
    fill_ones(4,32'h3c00,32'h3c00);
    c=command(TC_ST); c.data[0]=32'h41000000; transact(c,TC_OK,tag_id);
    c=command(TC_MMA); c.enable_input_d=1; c.cfg.c_scale_shift=3;
    transact(c,TC_OK,tag_id); load_column(0,0,r);
    check(r.data[0]==32'h40a00000,"Cshift 8/8+4 equals5");
    c=command(TC_ST); c.data[0]=32'h7fc00000; transact(c,TC_OK,tag_id);
    c=command(TC_MMA); c.cfg.c_scale_shift=3;
    read_before=tmem_reads;
    transact(c,TC_OK,tag_id);
    check(tmem_reads==read_before,"enable_input_d false issues no old-D reads");
    load_column(0,0,r); check(r.data[0]==32'h40800000,"old NaN excluded");

    // BLOCK32 offsets differ: K64 splits at both boundaries; exactly 3 scales.
    fill_ones(64,32'h38,32'h38);
    for (int i=0; i<3; i++) begin smem[0][640+i]=32'h7f; smem[0][704+i]=32'h7f; end
    c=command(TC_MMA); c.cfg.a_fmt=FMT_E4M3; c.cfg.b_fmt=FMT_E4M3;
    c.cfg.k=64; c.cfg.block_scale_en=1; c.cfg.block_size=BLOCK32;
    c.cfg.a_scale_fmt=SCALE_UE8M0; c.cfg.b_scale_fmt=SCALE_UE8M0;
    c.cfg.a_block_offset=15; c.cfg.b_block_offset=31;
    beat_before=operand_beats;
    transact(c,TC_OK,tag_id); load_column(0,0,r);
    check(r.data[0]==32'h42800000,"BLOCK32 unequal offsets numeric64");
    k_done=0;
    for (int i=beat_before; i<operand_beats; i++) begin
      a_room=32-((15+k_done)%32); b_room=32-((31+k_done)%32);
      expect_count=LANES;
      if (expect_count>64-k_done) expect_count=64-k_done;
      if (expect_count>a_room) expect_count=a_room;
      if (expect_count>b_room) expect_count=b_room;
      check(beat_counts[i%1024]==expect_count,"beat splits at both block boundaries");
      k_done=k_done+expect_count;
    end
    check(k_done==64,"exact accepted logical K");
    if (LANES==4) check(operand_beats-beat_before==17,"17 beats [1,4x15,3]");

    fill_ones(33,32'h2,32'h2);
    for (int i=0; i<3; i++) begin smem[0][640+i]=32'h38; smem[0][704+i]=32'h38; end
    c.cfg.a_fmt=FMT_E2M1; c.cfg.b_fmt=FMT_E2M1; c.cfg.k=33;
    c.cfg.block_size=BLOCK16; c.cfg.a_block_offset=15; c.cfg.b_block_offset=0;
    c.cfg.a_scale_fmt=SCALE_UE4M3; c.cfg.b_scale_fmt=SCALE_UE4M3;
    transact(c,TC_OK,tag_id); load_column(0,0,r);
    check(r.data[0]==32'h42040000,"BLOCK16 unsigned fractional scale");

    c=command(TC_MMA); c.cfg.a_fmt=FMT_S8; c.cfg.b_fmt=FMT_S8;
    c.cfg.c_fmt=FMT_S32; c.cfg.d_fmt=FMT_S32; c.cfg.k=2;
    smem[0][64]=32'hff; smem[0][65]=2; smem[0][320]=3; smem[0][321]=32'hfc;
    transact(c,TC_OK,tag_id); load_column(0,0,r);
    check(r.data[0]==32'hfffffff5,"signed int8 dot -11");
    c.cfg.a_fmt=FMT_TI16; c.cfg.b_fmt=FMT_TI16; c.cfg.ti16_decoded=1;
    smem[0][64]=2047; smem[0][65]=32'hf801; smem[0][320]=1; smem[0][321]=1;
    transact(c,TC_OK,tag_id); load_column(0,0,r);
    check(r.data[0]==0,"decoded Ti16 integer transport");
    c.cfg.ti16_decoded=0; transact(c,TC_UNSUPPORTED,tag_id);
    if (ENABLE_FP64) begin
      c=command(TC_MMA); c.cfg.a_fmt=FMT_F64; c.cfg.b_fmt=FMT_F64;
      c.cfg.c_fmt=FMT_F64; c.cfg.d_fmt=FMT_F64; c.cfg.k=1;
      smem[0][64]=0; smem[0][65]=32'h3ff00000;
      smem[0][320]=0; smem[0][321]=32'h40000000;
      transact(c,TC_OK,tag_id); load_column(0,0,r);
      check(r.data[0]==0 && r.data[1]==32'h40000000,"F64 two words low-first");
    end

    // Illegal variants/ranges are rejected before either memory port is used.
    c=command(TC_MMA); read_before=smem_reads;
    c.recipe=TC_RECIPE_NATIVE; transact(c,TC_BAD_CMD,tag_id);
    c=command(TC_MMA); c.cta_pair=1; transact(c,TC_BAD_CMD,tag_id);
    c=command(TC_MMA); c.sparse=1; transact(c,TC_UNSUPPORTED,tag_id);
    c=command(TC_MMA); c.b_addr=SMEM_WORDS*4-4; transact(c,TC_RANGE,tag_id);
    c=command(TC_MMA); c.enable_input_d=1; c.cfg.d_fmt=FMT_F64;
    transact(c,TC_UNSUPPORTED,tag_id);
    c=command(TC_MMA); c.a_from_tmem=1; c.a_col=0; transact(c,TC_UNSUPPORTED,tag_id);
    c=command(TC_ST); c.participants=32'hffff; transact(c,TC_BAD_CMD,tag_id);
    check(smem_reads==read_before,"rejected forms cause no SMEM reads");

    if (COLS>=96) begin
      c=command(TC_CTX_INIT); c.owner=1; transact(c,TC_OK,tag_id);
      c=command(TC_ALLOC); c.owner=1; c.ncols=32; transact(c,TC_OK,tag_id);
      owner1_base=int'(received[tag_id].tmem_col);
      c=command(TC_ST); c.owner=1; c.tmem_col=0; transact(c,TC_BAD_ALLOC,tag_id);
      c.tmem_col=10'(owner1_base); c.data[0]=32'hc0ffee01;
      transact(c,TC_OK,tag_id);
      c=command(TC_LD); c.owner=1; c.tmem_col=10'(owner1_base);
      transact(c,TC_OK,tag_id); check(received[tag_id].data[0]==32'hc0ffee01,"owner isolation");
      c=command(TC_DEALLOC); c.owner=1; c.ncols=32; c.tmem_col=10'(owner1_base);
      transact(c,TC_OK,tag_id);
      c=command(TC_CTX_RELEASE); c.owner=1; transact(c,TC_OK,tag_id);
    end
    base_a=-1;
    if (COLS>=64) begin
      c=command(TC_ALLOC); c.ncols=32; transact(c,TC_OK,tag_id);
      base_a=int'(received[tag_id].tmem_col);
      fill_ones(128,32'h3c00,32'h3c00);
      c=command(TC_CP); c.ncols=1; c.tmem_col=10'(base_a); c.smem_addr=32'h100;
      transact(c,TC_OK,tag_id);
      c=command(TC_MMA); c.a_from_tmem=1; c.a_col=10'(base_a);
      transact(c,TC_OK,tag_id); load_column(0,0,r);
      check(r.data[0]==32'h40800000,"TMEM-A normalized operands");
    end

    // Restricted notification may release SMEM A before the D/full completion.
    fill_ones(64,32'h3c00,32'h3c00);
    c=command(TC_MMA); c.cfg.k=64;
    submit(c,first_tag);
    c=command(TC_COMMIT); c.restricted=1; submit(c,restricted_tag);
    c.restricted=0; submit(c,full_tag);
    await_response(restricted_tag,TC_OK); await_response(full_tag,TC_OK);
    await_event(restricted_tag,TC_OK); await_event(full_tag,TC_OK);
    await_response(first_tag,TC_OK);
    check(event_cycle[restricted_tag]<response_cycle[first_tag],"A-read is distinct from full");
    check(event_cycle[full_tag]>=response_cycle[first_tag]-1,"full event after D-write ack");

    // A snapshot excludes later work; wait::st observes only its own stream.
    hold_smem=1;
    c=command(TC_MMA); c.cfg.k=64; submit(c,first_tag);
    c=command(TC_WAIT_ST); transact(c,TC_OK,tag_id);
    check(!got[first_tag],"wait-st is not an MCS drain");
    c=command(TC_COMMIT); submit(c,full_tag);
    c=command(TC_MMA); c.cfg.k=64; submit(c,second_tag);
    c=command(TC_DEALLOC); c.ncols=32; transact(c,TC_BUSY,tag_id);
    hold_smem=0;
    await_response(first_tag,TC_OK); await_response(second_tag,TC_OK);
    await_response(full_tag,TC_OK); await_event(full_tag,TC_OK);
    check(event_cycle[full_tag]<response_cycle[second_tag],"commit excludes later accepted MCS");

    // Load done is RF acceptance, not just reading TMEM into an internal buffer.
    hold_rsp=1;
    c=command(TC_LD); submit(c,first_tag);
    repeat (300) @(negedge clk);
    c=command(TC_WAIT_LD); submit(c,second_tag);
    repeat (20) @(negedge clk);
    check(!got[first_tag] && !got[second_tag],"held RF response keeps wait incomplete");
    hold_rsp=0;
    await_response(first_tag,TC_OK); await_response(second_tag,TC_OK);
    check(response_cycle[second_tag]>response_cycle[first_tag],"wait after RF ack");

    // Four queue entries plus active command cannot block a commit registration.
    hold_smem=1;
    c=command(TC_MMA); c.cfg.k=4;
    submit(c,first_tag);
    for (int i=0; i<4; i++) submit(c,tag_id);
    second_tag=tag_id;
    c=command(TC_COMMIT); transact(c,TC_OK,full_tag);
    check(!got[first_tag],"commit admitted with full normal queue");
    hold_event=1; hold_smem=0;
    await_response(second_tag,TC_OK);
    repeat (30) @(negedge clk);
    check(bus.event_valid && !event_got[full_tag],"event retained under backpressure");
    hold_event=0; await_event(full_tag,TC_OK);

    // Both fence forms wait on the issuer's admitted MCS cutoff, including
    // work not yet past operand admission. Unrelated wait::st above does not.
    for(int form=0;form<2;form++)begin
      hold_smem=1;
      c=command(TC_MMA);c.thread_lane=7;c.participants=32'h80;submit(c,first_tag);
      c=command(TC_FENCE);c.thread_lane=7;c.participants=32'h80;c.fence_after=1'(form);
      submit(c,second_tag);repeat(16)@(negedge clk);
      check(!got[first_tag]&&!got[second_tag],"thread fence retains prior incomplete MCS");
      hold_smem=0;await_response(first_tag,TC_OK);await_response(second_tag,TC_OK);
      check(response_cycle[second_tag]>response_cycle[first_tag],"fence acknowledged after issuer completion");
    end

    // A memory failure poisons its owner; queued work closes without new writes.
    hold_smem=1; inject_error=1; fault_address=32'h100;
    c=command(TC_MMA); submit(c,first_tag); submit(c,second_tag);
    c=command(TC_COMMIT); submit(c,full_tag);
    read_before=smem_reads; hold_smem=0;
    await_response(first_tag,TC_MEM_ERROR);
    await_response(second_tag,TC_PRIOR_ERROR);
    await_response(full_tag,TC_OK); await_event(full_tag,TC_PRIOR_ERROR);
    check(smem_reads==read_before+1,"cancelled queued work performs no memory access");
    c=command(TC_MMA); transact(c,TC_PRIOR_ERROR,tag_id);
    c=command(TC_DEALLOC); c.tmem_col=0; c.ncols=32; transact(c,TC_OK,tag_id);
    if (base_a>=0) begin c.tmem_col=10'(base_a); transact(c,TC_OK,tag_id); end
    c=command(TC_CTX_RELEASE); transact(c,TC_OK,tag_id);
    c=command(TC_CTX_INIT); c.owner_generation=2; transact(c,TC_OK,tag_id);
    c=command(TC_ALLOC); c.owner_generation=2; c.ncols=32; transact(c,TC_OK,tag_id);
    c=command(TC_MMA); c.owner_generation=2; transact(c,TC_OK,tag_id);
    c.owner_generation=1; transact(c,TC_BAD_OWNER,tag_id);

    // Coordinated reset aborts the command AND its external memory endpoint.
    hold_smem=1;
    c=command(TC_MMA); c.owner_generation=2; submit(c,first_tag);
    repeat (10) @(negedge clk);
    rst_n=0; bus.cmd_valid=0;bus.reset_epoch=2;
    repeat (4) @(negedge clk);
    rst_n=1; hold_smem=0;
    c=command(TC_ST); c.owner_generation=2; transact(c,TC_BAD_OWNER,tag_id);
    c=command(TC_CTX_INIT); transact(c,TC_OK,tag_id);
    c=command(TC_ALLOC); c.ncols=32; transact(c,TC_OK,tag_id);
    c=command(TC_MMA); transact(c,TC_OK,tag_id);
    check(!got[first_tag],"reset-aborted command has no fabricated response");
    $display("TCGEN05_ENDPOINT_PASS checks=%0d responses=%0d events=%0d cycles=%0d smem_reads=%0d tmem_reads=%0d beats=%0d cols=%0d lanes=%0d fp64=%0d seed=%0d",
      checks,responses,event_count,cycles,smem_reads,tmem_reads,operand_beats,COLS,LANES,int'(ENABLE_FP64),random_seed);
    $finish;
  end
endmodule
