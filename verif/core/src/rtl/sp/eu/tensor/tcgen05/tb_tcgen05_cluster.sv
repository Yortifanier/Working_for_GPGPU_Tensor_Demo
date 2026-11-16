// Two actual endpoints and a bidirectional peer fabric. The external shared
// memory and barrier-ack sinks are test models, not alternate Tensor engines.
/* verilator lint_off BLKSEQ */
module tb_tcgen05_cluster;
  import malu_pkg::*;
  import tcgen05_pkg::*;
  localparam int TAGS=512;
  localparam int SHARED_WORDS=8192;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  tcgen05_if even_bus(clk,rst_n),odd_bus(clk,rst_n);
  tcgen05 #(.DOT_ENGINES(4),.MAX_M(256),.MAX_N(256),.MAX_K(128)) even_dut(even_bus);
  tcgen05 #(.DOT_ENGINES(4),.MAX_M(256),.MAX_N(256),.MAX_K(128)) odd_dut(odd_bus);

  assign odd_bus.service_cmd_valid=even_bus.peer_cmd_valid;
  assign odd_bus.service_cmd=even_bus.peer_cmd;
  assign even_bus.peer_cmd_ready=odd_bus.service_cmd_ready;
  assign even_bus.peer_rsp_valid=odd_bus.service_rsp_valid;
  assign even_bus.peer_rsp=odd_bus.service_rsp;
  assign odd_bus.service_rsp_ready=even_bus.peer_rsp_ready;
  assign even_bus.service_cmd_valid=odd_bus.peer_cmd_valid;
  assign even_bus.service_cmd=odd_bus.peer_cmd;
  assign odd_bus.peer_cmd_ready=even_bus.service_cmd_ready;
  assign odd_bus.peer_rsp_valid=even_bus.service_rsp_valid;
  assign odd_bus.peer_rsp=even_bus.service_rsp;
  assign even_bus.service_rsp_ready=odd_bus.peer_rsp_ready;
  assign odd_bus.service_mem_req_valid=even_bus.peer_mem_req_valid;
  assign odd_bus.service_mem_req=even_bus.peer_mem_req;
  assign even_bus.peer_mem_req_ready=odd_bus.service_mem_req_ready;
  assign even_bus.peer_mem_rsp_valid=odd_bus.service_mem_rsp_valid;
  assign even_bus.peer_mem_rsp=odd_bus.service_mem_rsp;
  assign odd_bus.service_mem_rsp_ready=even_bus.peer_mem_rsp_ready;
  assign even_bus.service_mem_req_valid=odd_bus.peer_mem_req_valid;
  assign even_bus.service_mem_req=odd_bus.peer_mem_req;
  assign odd_bus.peer_mem_req_ready=even_bus.service_mem_req_ready;
  assign odd_bus.peer_mem_rsp_valid=even_bus.service_mem_rsp_valid;
  assign odd_bus.peer_mem_rsp=even_bus.service_mem_rsp;
  assign even_bus.service_mem_rsp_ready=odd_bus.peer_mem_rsp_ready;

  logic hold_smem=0,hold_event=0;
  integer even_smem_requests,odd_smem_requests,even_smem_writes,odd_smem_writes;
  tcgen05_cluster_smem #(.WORDS(SHARED_WORDS)) even_smem (
    .clk(clk),.rst_n(rst_n),.hold_requests(hold_smem),.seed(32'h12e0),
    .req_valid(even_bus.smem_req_valid),.req_ready(even_bus.smem_req_ready),.req(even_bus.smem_req),
    .rsp_valid(even_bus.smem_rsp_valid),.rsp_ready(even_bus.smem_rsp_ready),.rsp(even_bus.smem_rsp),
    .requests(even_smem_requests),.writes(even_smem_writes)
  );
  tcgen05_cluster_smem #(.WORDS(SHARED_WORDS)) odd_smem (
    .clk(clk),.rst_n(rst_n),.hold_requests(hold_smem),.seed(32'h12d1),
    .req_valid(odd_bus.smem_req_valid),.req_ready(odd_bus.smem_req_ready),.req(odd_bus.smem_req),
    .rsp_valid(odd_bus.smem_rsp_valid),.rsp_ready(odd_bus.smem_rsp_ready),.rsp(odd_bus.smem_rsp),
    .requests(odd_smem_requests),.writes(odd_smem_writes)
  );

  tc_rsp_t received[2][TAGS];
  tc_event_t received_event[2][TAGS];
  logic [TAGS-1:0] got[2],event_got[2];
  int response_cycle[2][TAGS],event_cycle[2][TAGS];
  logic [31:0] expected_rf[2][8][32];
  logic [31:0] expected_lanes[2];
  int expected_rf_count[2],rf_seen[2],expected_rf_tag[2];
  int pins[2],unpins[2];
  int cycles=0,checks=0,commands=0,next_tag=1,responses=0,events=0,peer_memory=0;
  int seed=1907;
  logic [31:0] rng=32'h1907;
  function automatic logic[31:0] next_rng(input logic[31:0] value);
    logic[31:0] x;
    x=value^(value<<13);x=x^(x>>17);return x^(x<<5);
  endfunction
  always @(negedge clk)begin
    rng=next_rng(rng);
    even_bus.rsp_ready=rst_n && (rng[0]||rng[1]);
    odd_bus.rsp_ready=rst_n && (rng[2]||rng[3]);
    even_bus.event_ready=rst_n && !hold_event && (rng[4]||rng[5]);
    odd_bus.event_ready=rst_n && !hold_event && (rng[6]||rng[7]);
    even_bus.rf_out_ready=rst_n && (rng[8]||rng[9]);
    odd_bus.rf_out_ready=rst_n && (rng[10]||rng[11]);
  end
  task automatic observe_response(input int side,input tc_rsp_t r);
    if(int'(r.tag)>=TAGS || got[side][int'(r.tag)])$fatal(1,"duplicate response side%0d tag%0d",side,r.tag);
    got[side][int'(r.tag)]=1;received[side][int'(r.tag)]=r;
    response_cycle[side][int'(r.tag)]=cycles;responses++;
  endtask
  task automatic observe_event(input int side,input tc_event_t e);
    if(int'(e.tag)>=TAGS || event_got[side][int'(e.tag)])$fatal(1,"duplicate event");
    event_got[side][int'(e.tag)]=1;received_event[side][int'(e.tag)]=e;
    event_cycle[side][int'(e.tag)]=cycles;events++;
  endtask
  task automatic observe_rf(input int side,input tc_rf_fragment_t f);
    if(int'(f.tag)!=expected_rf_tag[side] || f.kind!=TC_RF_DATA ||
        int'(f.index)!=rf_seen[side] || f.mask!=32'hffffffff ||
        f.last!=(rf_seen[side]+1==expected_rf_count[side]))
      $fatal(1,"cluster RF identity side%0d index%0d seen%0d tag%0d expectedtag%0d",side,f.index,rf_seen[side],f.tag,expected_rf_tag[side]);
    for(int t=0;t<32;t++)if(expected_lanes[side][t])begin
      if(f.data[t]!==expected_rf[side][rf_seen[side]][t])
        $fatal(1,"cluster RF data side%0d reg%0d thread%0d got%h expected%h",side,rf_seen[side],t,f.data[t],expected_rf[side][rf_seen[side]][t]);
      checks++;
    end
    rf_seen[side]++;
  endtask
  always @(posedge clk)begin
    cycles++;
    if(cycles>2000000)$fatal(1,"CLUSTER watchdog");
    if(rst_n)begin
      if(even_bus.rsp_valid && even_bus.rsp_ready)observe_response(0,even_bus.rsp);
      if(odd_bus.rsp_valid && odd_bus.rsp_ready)observe_response(1,odd_bus.rsp);
      if(even_bus.event_valid && even_bus.event_ready)observe_event(0,even_bus.event_data);
      if(odd_bus.event_valid && odd_bus.event_ready)observe_event(1,odd_bus.event_data);
      if(even_bus.rf_out_valid && even_bus.rf_out_ready)observe_rf(0,even_bus.rf_out);
      if(odd_bus.rf_out_valid && odd_bus.rf_out_ready)observe_rf(1,odd_bus.rf_out);
      if(even_bus.service_cmd_valid && even_bus.service_cmd_ready)begin
        if(even_bus.service_cmd.op==TC_PAIR_PIN)pins[0]++;
        if(even_bus.service_cmd.op==TC_PAIR_UNPIN)unpins[0]++;
      end
      if(odd_bus.service_cmd_valid && odd_bus.service_cmd_ready)begin
        if(odd_bus.service_cmd.op==TC_PAIR_PIN)pins[1]++;
        if(odd_bus.service_cmd.op==TC_PAIR_UNPIN)unpins[1]++;
      end
      if(even_bus.peer_mem_req_valid && even_bus.peer_mem_req_ready)peer_memory++;
      if(odd_bus.peer_mem_req_valid && odd_bus.peer_mem_req_ready)peer_memory++;
    end
  end
  task automatic check(input bit ok,input string message);
    if(!ok)$fatal(1,"%s cycle%0d",message,cycles);
    checks++;
  endtask
  function automatic tc_cmd_t command(input tc_opcode_e op,input int side=0);
    tc_cmd_t c;
    c='0;c.op=op;c.recipe=TC_RECIPE_CANONICAL;c.owner_generation=1;
    c.peer_owner=0;c.peer_generation=1;c.pair_local_is_odd=side!=0;
    c.participants=is_collective(op)?32'hffffffff:32'h1;c.peer_participants=32'hffffffff;
    c.kind=TC_KIND_F16;c.repeat_num=1;c.move_shape=TC_SHAPE_32X32B;
    c.cfg.a_fmt=FMT_F16;c.cfg.b_fmt=FMT_F16;c.cfg.c_fmt=FMT_F32;c.cfg.d_fmt=FMT_F32;
    c.cfg.k=2;c.cfg.profile=PROJECT_EXACT;c.cfg.rounding=ROUND_RNE;
    c.m=2;c.n=2;c.a_addr=32'h100;c.b_addr=32'h200;
    c.a_packing=TC_PACK_WORD32;c.b_packing=TC_PACK_WORD32;
    c.barrier_addr=32'h7000;c.ncols=32;
    return c;
  endfunction
  task automatic submit(input int side,input tc_cmd_t original,output int tag_id);
    tc_cmd_t c;
    int timeout_at;
    c=original;tag_id=next_tag;next_tag++;commands++;
    check(next_tag<TAGS,"tag capacity");c.tag=16'(tag_id);
    if(c.op==TC_LD)begin expected_rf_tag[side]=tag_id;rf_seen[side]=0;end
    @(negedge clk);
    if(side==0)begin even_bus.cmd=c;even_bus.cmd_valid=1;end
    else begin odd_bus.cmd=c;odd_bus.cmd_valid=1;end
    timeout_at=cycles+50000;
    do begin @(posedge clk);if(cycles>timeout_at)$fatal(1,"cluster admission timeout side%0d op%0d",side,c.op);end
    while(!(side==0 ? even_bus.cmd_ready : odd_bus.cmd_ready));
    @(negedge clk);
    if(side==0)even_bus.cmd_valid=0;else odd_bus.cmd_valid=0;
  endtask
  task automatic await_response(input int side,input int tag_id,input tc_status_e status);
    int timeout_at;
    timeout_at=cycles+200000;
    while(!got[side][tag_id])begin @(negedge clk);if(cycles>timeout_at)$fatal(1,"cluster response timeout side%0d tag%0d",side,tag_id);end
    if(received[side][tag_id].status!=status)$fatal(1,"cluster response side%0d tag%0d status%0d expected%0d",side,tag_id,received[side][tag_id].status,status);
    checks++;
  endtask
  task automatic transact(input int side,input tc_cmd_t c,input tc_status_e status,output int tag_id);
    submit(side,c,tag_id);await_response(side,tag_id,status);
  endtask
  task automatic await_event(input int side,input int tag_id);
    int timeout_at;
    timeout_at=cycles+200000;
    while(!event_got[side][tag_id])begin @(negedge clk);if(cycles>timeout_at)$fatal(1,"cluster event timeout");end
    check(received_event[side][tag_id].status==TC_OK,"commit event status");
  endtask
  task automatic check_dot_output(input int side,input int base,input logic[31:0] d0,d1);
    tc_cmd_t c;
    int tag_id;
    expected_rf_count[side]=2;expected_lanes[side]=32'h1;
    expected_rf[side][0][0]=d0;expected_rf[side][1][0]=d1;
    c=command(TC_LD,side);c.tmem_col=10'(base);c.repeat_num=2;c.ncols=2;c.rf_stream=1;
    transact(side,c,TC_OK,tag_id);check(rf_seen[side]==2,"MMA output fragments accepted");
  endtask
  task automatic check_copied_quarter(input int side,input int base,input bit shifted);
    tc_cmd_t c;
    int tag_id,source_lane;
    expected_rf_count[side]=8;expected_lanes[side]=32'hffffffff;
    for(int r=0;r<8;r++)for(int t=0;t<32;t++)begin
      source_lane=shifted && t<31 ? t+1 : t;
      expected_rf[side][r][t]=(side==0?32'ha0000000:32'hb0000000)+32'(source_lane*8+r);
    end
    c=command(TC_LD,side);c.tmem_col=10'(base);c.repeat_num=8;c.ncols=8;c.rf_stream=1;
    transact(side,c,TC_OK,tag_id);check(rf_seen[side]==8,"CP/SHIFT fragments accepted");
  endtask

  initial begin : main
    tc_cmd_t c;
    int tag_id,alloc_tag,base,mma_tag,restricted_tag,normal_tag,pin_before,timeout_at;
    void'($value$plusargs("SEED=%d",seed));rng=32'(seed)|1;
    even_bus.cmd='0;odd_bus.cmd='0;even_bus.cmd_valid=0;odd_bus.cmd_valid=0;
    even_bus.rsp_ready=0;odd_bus.rsp_ready=0;even_bus.event_ready=0;odd_bus.event_ready=0;
    even_bus.rf_out_ready=0;odd_bus.rf_out_ready=0;
    even_bus.rf_in='0;odd_bus.rf_in='0;even_bus.rf_in_valid=0;odd_bus.rf_in_valid=0;
    even_bus.capabilities='1;odd_bus.capabilities='1;even_bus.reset_epoch=1;odd_bus.reset_epoch=1;
    for(int side=0;side<2;side++)begin
      got[side]='0;event_got[side]='0;expected_rf_count[side]=0;rf_seen[side]=0;
      expected_rf_tag[side]=0;expected_lanes[side]=0;pins[side]=0;unpins[side]=0;
    end
    for(int owner=0;owner<TC_OWNERS;owner++)begin
      even_bus.owner_smem_bytes[owner]=SHARED_WORDS*4;
      odd_bus.owner_smem_bytes[owner]=SHARED_WORDS*4;
    end
    repeat(4)@(negedge clk);rst_n=1;
    c=command(TC_CTX_INIT);c.cta_pair=1;
    transact(0,c,TC_OK,tag_id);transact(1,c,TC_OK,tag_id);
    even_smem.words[0][16]=32'hdead0040;odd_smem.words[0][17]=32'hbeef0044;
    c=command(TC_ALLOC);c.recipe=TC_RECIPE_NATIVE;c.cta_pair=1;c.smem_addr=32'h40;c.peer_smem_addr=32'h44;
    transact(0,c,TC_OK,alloc_tag);base=int'(received[0][alloc_tag].tmem_col);
    check(even_smem.words[0][16]==32'(base),"native alloc stores local returned TMEM address");
    check(odd_smem.words[0][17]==32'(base),"native alloc stores peer returned TMEM address");
    check(even_smem_writes>=1 && odd_smem_writes>=1,"alloc produced real SMEM writes on both endpoints");

    // A split by M/2, B by N/2. No layout helper is used to create expected data.
    even_smem.words[0][64]=32'h3c00;even_smem.words[0][65]=32'h4000;
    odd_smem.words[0][64]=32'h4200;odd_smem.words[0][65]=32'h4400;
    even_smem.words[0][128]=32'h4500;even_smem.words[0][129]=32'h4700;
    odd_smem.words[0][128]=32'h4600;odd_smem.words[0][129]=32'h4800;
    hold_smem=1;pin_before=pins[1];
    c=command(TC_MMA);c.cta_pair=1;c.d_col=10'(base);submit(0,c,mma_tag);
    timeout_at=cycles+5000;
    while(pins[1]==pin_before)begin @(negedge clk);if(cycles>timeout_at)$fatal(1,"peer PIN not acquired");end
    c=command(TC_DEALLOC,1);c.cta_pair=1;c.tmem_col=10'(base);
    transact(1,c,TC_BUSY,tag_id);
    check(unpins[1]<pins[1],"remote child PIN remains live while parent memory is blocked");
    c=command(TC_COMMIT);c.cta_pair=1;c.restricted=1;submit(0,c,restricted_tag);
    c.restricted=0;submit(0,c,normal_tag);
    await_response(0,restricted_tag,TC_OK);await_response(0,normal_tag,TC_OK);
    hold_event=1;hold_smem=0;
    await_response(0,mma_tag,TC_OK);
    check(unpins[1]==pins[1],"parent full response follows peer UNPIN acknowledgement");
    c=command(TC_DEALLOC);c.cta_pair=1;c.tmem_col=10'(base);
    transact(0,c,TC_BUSY,tag_id);
    hold_event=0;await_event(0,restricted_tag);await_event(0,normal_tag);
    check(received_event[0][restricted_tag].restricted && !received_event[0][normal_tag].restricted,
      "restricted and normal notification types remain separate");
    check(event_cycle[0][restricted_tag]<=event_cycle[0][normal_tag],"A-read notification no later than full notification");
    check_dot_output(0,base,32'h41980000,32'h41b00000); //19,22
    check_dot_output(1,base,32'h422c0000,32'h42480000); //43,50

    // Odd issuer must still use even-first peer acquisition and even/odd data.
    c=command(TC_MMA,1);c.cta_pair=1;c.d_col=10'(base);c.enable_input_d=1;
    transact(1,c,TC_OK,tag_id);
    check(pins[0]>0 && pins[0]==unpins[0],"odd issuer remote parent/child closure");
    check_dot_output(0,base,32'h42180000,32'h42300000); //38,44
    check_dot_output(1,base,32'h42ac0000,32'h42c80000); //86,100

    for(int i=0;i<1024;i++)begin
      even_smem.words[0][1024+i]=32'ha0000000+32'(i);
      odd_smem.words[0][1024+i]=32'hb0000000+32'(i);
    end
    c=command(TC_CP);c.cta_pair=1;c.move_shape=TC_SHAPE_128X256B;c.tmem_col=10'(base+8);
    c.ncols=8;c.smem_addr=32'h1000;transact(0,c,TC_OK,tag_id);
    check_copied_quarter(0,base+8,0);check_copied_quarter(1,base+8,0);
    c=command(TC_SHIFT,1);c.cta_pair=1;c.tmem_col=10'(base+8);c.tmem_lane=0;c.ncols=8;
    transact(1,c,TC_OK,tag_id);
    check_copied_quarter(0,base+8,1);check_copied_quarter(1,base+8,1);
    check(peer_memory>10,"actual bidirectional peer memory traffic");

    c=command(TC_DEALLOC,1);c.recipe=TC_RECIPE_NATIVE;c.cta_pair=1;c.tmem_col=10'(base);
    transact(1,c,TC_OK,tag_id);
    c=command(TC_RELINQUISH);c.recipe=TC_RECIPE_NATIVE;c.cta_pair=1;transact(0,c,TC_OK,tag_id);
    c=command(TC_ALLOC);c.recipe=TC_RECIPE_NATIVE;c.cta_pair=1;c.smem_addr=32'h48;c.peer_smem_addr=32'h4c;
    transact(0,c,TC_NO_PERMIT,tag_id);
    c=command(TC_CTX_RELEASE);transact(0,c,TC_OK,tag_id);transact(1,c,TC_OK,tag_id);
    check(pins[0]==unpins[0] && pins[1]==unpins[1],"no leaked child PIN at owner release");
    check(responses==commands,"every admitted command has one response");
    $display("TCGEN05_CLUSTER_PASS checks=%0d commands=%0d responses=%0d events=%0d peer_memory=%0d pins_even=%0d pins_odd=%0d cycles=%0d seed=%0d",
      checks,commands,responses,events,peer_memory,pins[0],pins[1],cycles,seed);
    $finish;
  end
endmodule
