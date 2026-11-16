// Independent scalar TMEM/SMEM model and RF fragment scoreboard. No DUT address
// function or comparison circuit is used to form expected register fragments.
/* verilator lint_off BLKSEQ */
module tb_tcgen05_move;
  import tcgen05_pkg::*;
  localparam int COLS=576;
  localparam int SMEM_WORDS=65536;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  logic req_valid=0,req_ready,rsp_valid,rsp_ready=0;
  tc_cmd_t req='0;
  tc_rsp_t rsp;
  logic rf_in_valid=0,rf_in_ready,rf_out_valid,rf_out_ready=0;
  tc_rf_fragment_t rf_in='0,rf_out;
  logic tm_req_valid,tm_req_ready=0,tm_rsp_valid=0,tm_rsp_ready;
  logic smem_req_valid,smem_req_ready=0,smem_rsp_valid=0,smem_rsp_ready;
  tc_mem_req_t tm_req,smem_req;
  tc_mem_rsp_t tm_rsp='0,smem_rsp='0;
  tcgen05_move #(.COLS(COLS)) dut(.*);
  logic [31:0] tmem[2][COLS*128],expected_tmem[2][COLS*128];
  logic [31:0] smem[2][SMEM_WORDS];
  tc_rf_fragment_t expected_rf[160];
  tc_cmd_t executing;
  tc_status_e expected_status;
  int expected_rf_count=0,rf_seen=0,rf_fragments=0,responses=0,commands=0,checks=0,cycles=0;
  int mem_reads=0,mem_writes=0,peer_transfers=0,rf_hold_cycles=0,mem_hold_cycles=0;
  int seed=1907,memory_delay=0;
  logic [31:0] rng=32'h1907;
  logic memory_pending=0,pending_is_smem=0;
  tc_mem_rsp_t saved_response;
  bit corrupt_next_id=0,fail_next_memory=0;
  function automatic logic[31:0] next_rng(input logic[31:0] value);
    logic[31:0] x;
    x=value^(value<<13);x=x^(x>>17);return x^(x<<5);
  endfunction
  always @(negedge clk) begin
    rng=next_rng(rng);
    rsp_ready=rst_n && (rng[0] || rng[1]);
    rf_out_ready=rst_n && (rng[2] || rng[3]);
    tm_req_ready=rst_n && !memory_pending && !tm_rsp_valid && !smem_rsp_valid && rng[4];
    smem_req_ready=rst_n && !memory_pending && !tm_rsp_valid && !smem_rsp_valid && rng[5];
  end
  always @(posedge clk) begin : models
    tc_mem_req_t m;
    bit is_smem;
    int side,index;
    cycles=cycles+1;
    if (cycles>10000000) $fatal(1,"MOVE watchdog");
    if (!rst_n) begin
      memory_pending<=0;tm_rsp_valid<=0;smem_rsp_valid<=0;
    end else begin
      if (tm_req_valid && smem_req_valid) $fatal(1,"two active requests");
      if (rf_out_valid && !rf_out_ready) rf_hold_cycles++;
      if ((tm_req_valid && !tm_req_ready) || (smem_req_valid && !smem_req_ready)) mem_hold_cycles++;
      if (rf_out_valid && rf_out_ready) begin
        if (rf_seen>=expected_rf_count) $fatal(1,"unexpected RF fragment kind%0d index%0d",rf_out.kind,rf_out.index);
        if (rf_out.tag!=executing.tag || rf_out.owner!=executing.owner ||
            rf_out.owner_generation!=executing.owner_generation || rf_out.mask!=32'hffffffff ||
            rf_out.kind!=expected_rf[rf_seen].kind || rf_out.index!=expected_rf[rf_seen].index ||
            rf_out.last!=expected_rf[rf_seen].last)
          $fatal(1,"RF identity/order mismatch cmd%0d fragment%0d got kind%0d idx%0d last%0d expected kind%0d idx%0d last%0d",
            commands,rf_seen,rf_out.kind,rf_out.index,rf_out.last,
            expected_rf[rf_seen].kind,expected_rf[rf_seen].index,expected_rf[rf_seen].last);
        for (int t=0;t<32;t++)
          if (rf_out.data[t]!==expected_rf[rf_seen].data[t])
            $fatal(1,"RF data cmd%0d fragment%0d thread%0d got%h expected%h",commands,rf_seen,t,rf_out.data[t],expected_rf[rf_seen].data[t]);
        checks+=33;rf_seen++;rf_fragments++;
      end
      if (rsp_valid && rsp_ready) begin
        if (rsp.tag!=executing.tag || rsp.owner!=executing.owner ||
            rsp.owner_generation!=executing.owner_generation || rsp.status!=expected_status)
          $fatal(1,"MOVE response cmd%0d status%0d expected%0d",commands,rsp.status,expected_status);
        if (rf_seen!=expected_rf_count) $fatal(1,"Response before RF completion %0d/%0d",rf_seen,expected_rf_count);
        checks++;responses++;
      end
      if (tm_rsp_valid && tm_rsp_ready) tm_rsp_valid<=0;
      if (smem_rsp_valid && smem_rsp_ready) smem_rsp_valid<=0;
      if (memory_pending) begin
        if (memory_delay==0) begin
          if (pending_is_smem) begin smem_rsp_valid<=1;smem_rsp<=saved_response;end
          else begin tm_rsp_valid<=1;tm_rsp<=saved_response;end
          memory_pending<=0;
        end else memory_delay--;
      end
      if ((tm_req_valid && tm_req_ready) || (smem_req_valid && smem_req_ready)) begin
        is_smem=smem_req_valid && smem_req_ready;
        m=is_smem ? smem_req : tm_req;
        side=m.peer ? 1 : 0;
        saved_response='0;saved_response.status=TC_OK;saved_response.txn_id=m.txn_id;
        if (corrupt_next_id) begin saved_response.txn_id^=64'h10000;corrupt_next_id=0;end
        if (fail_next_memory) begin saved_response.status=TC_MEM_ERROR;fail_next_memory=0;end
        if (m.peer) peer_transfers++;
        if (is_smem) begin
          if (m.write || m.byte_addr[1:0]!=0 || m.byte_addr>=SMEM_WORDS*4) $fatal(1,"Unexpected SMEM request");
          saved_response.rdata=smem[side][m.byte_addr>>2];mem_reads++;
        end else begin
          if (int'(m.lane)>=128 || int'(m.col)>=COLS) $fatal(1,"Out-of-range TMEM request");
          index=int'(m.col)*128+int'(m.lane);
          if (m.write) begin
            if (saved_response.status==TC_OK)
              for (int b=0;b<4;b++)
                if (m.wstrb[b]) tmem[side][index][8*b+:8]=m.wdata[8*b+:8];
            mem_writes++;
          end else begin saved_response.rdata=tmem[side][index];mem_reads++;end
        end
        memory_pending<=1;pending_is_smem<=is_smem;memory_delay=int'(rng[9:6]);
      end
    end
  end

  task automatic check(input bit ok,input string message);
    if (!ok) $fatal(1,"%s command%0d cycle%0d",message,commands,cycles);
    checks++;
  endtask
  function automatic tc_cmd_t command(input tc_opcode_e op);
    tc_cmd_t c;
    c='0;c.op=op;c.recipe=TC_RECIPE_CANONICAL;c.owner=2;c.owner_generation=7;
    c.participants=32'hffffffff;c.repeat_num=1;c.move_shape=TC_SHAPE_32X32B;
    c.rf_stream=1;c.half_splitoff=256;c.smem_addr=32'h1000;
    return c;
  endfunction
  function automatic int register_count(input tc_cmd_t c);
    case(c.move_shape)
      TC_SHAPE_16X128B:return int'(c.repeat_num)*2;
      TC_SHAPE_16X256B:return int'(c.repeat_num)*4;
      default:return int'(c.repeat_num);
    endcase
  endfunction
  // Addresses transcribed from PTX figures186-190. Thread lookup for 16x64
  // uses explicit lane pairs rather than the DUT's bit-arithmetic expression.
  function automatic int reference_index(input tc_cmd_t c,input int r,t,p);
    int lane,col;
    lane=int'(c.tmem_lane)+t;col=r;
    case(c.move_shape)
      TC_SHAPE_16X64B:begin
        case(t%4)
          0,2:lane=int'(c.tmem_lane)+t/4;
          default:lane=int'(c.tmem_lane)+t/4+8;
        endcase
        col=2*r+(t%4>=2 ? 1 : 0);
      end
      TC_SHAPE_16X128B:begin
        lane=int'(c.tmem_lane)+t/4+8*(r%2);col=4*(r/2)+t%4;
      end
      TC_SHAPE_16X256B:begin
        lane=int'(c.tmem_lane)+t/4+8*((r%4)/2);col=8*(r/4)+2*(t%4)+r%2;
      end
      default:begin end
    endcase
    if(c.pack16 || c.unpack16)col=2*col+p;
    if(c.move_shape==TC_SHAPE_16X32BX2 && t>=16)col+=int'(c.half_splitoff);
    return (int'(c.tmem_col)+col)*128+lane;
  endfunction
  function automatic logic[31:0] store_value(input int r,t);
    return 32'h81002000+32'(r*129+t*3+commands*7);
  endfunction
  task automatic expected_store(input tc_cmd_t c);
    int index;
    logic[31:0] value;
    for(int r=0;r<register_count(c);r++)
      for(int t=0;t<32;t++)begin
        value=store_value(r,t);
        index=reference_index(c,r,t,0);
        if(c.unpack16)begin
          expected_tmem[0][index][15:0]=value[15:0];
          index=reference_index(c,r,t,1);expected_tmem[0][index][15:0]=value[31:16];
        end else expected_tmem[0][index]=value;
      end
  endtask
  task automatic expected_load(input tc_cmd_t c);
    int a,b;
    expected_rf_count=register_count(c);
    for(int r=0;r<expected_rf_count;r++)begin
      expected_rf[r]='0;expected_rf[r].kind=TC_RF_DATA;expected_rf[r].index=8'(r);
      expected_rf[r].last=r+1==expected_rf_count;
      for(int t=0;t<32;t++)begin
        a=reference_index(c,r,t,0);
        if(c.pack16)begin
          b=reference_index(c,r,t,1);
          expected_rf[r].data[t]={expected_tmem[0][b][15:0],expected_tmem[0][a][15:0]};
        end else expected_rf[r].data[t]=expected_tmem[0][a];
      end
    end
  endtask
  task automatic run_command(input tc_cmd_t original,input tc_status_e status);
    tc_cmd_t c;
    int response_target,timeout_at;
    c=original;commands++;c.tag=16'(commands);executing=c;expected_status=status;rf_seen=0;
    response_target=responses+1;
    @(negedge clk);req=c;req_valid=1;
    do @(posedge clk);while(!req_ready);
    @(negedge clk);req_valid=0;
    if(c.op==TC_ST && c.rf_stream && status==TC_OK)begin
      for(int r=0;r<register_count(c);r++)begin
        repeat(int'(rng[1:0]))@(negedge clk);
        rf_in='0;rf_in.tag=c.tag;rf_in.owner=c.owner;rf_in.owner_generation=c.owner_generation;
        rf_in.kind=TC_RF_DATA;rf_in.index=8'(r);rf_in.mask=32'hffffffff;
        rf_in.last=r+1==register_count(c);
        for(int t=0;t<32;t++)rf_in.data[t]=store_value(r,t);
        rf_in_valid=1;
        do @(posedge clk);while(!rf_in_ready);
        @(negedge clk);rf_in_valid=0;
      end
    end
    timeout_at=cycles+1000000;
    while(responses<response_target)begin
      @(negedge clk);
      if(cycles>timeout_at)$fatal(1,"MOVE response timeout op%0d cmd%0d state%0d",c.op,commands,dut.state);
    end
    @(negedge clk);
  endtask
  task automatic compare_memory;
    for(int side=0;side<2;side++)
      for(int i=0;i<COLS*128;i++)
        if(tmem[side][i]!==expected_tmem[side][i])
          $fatal(1,"TMEM oracle mismatch cmd%0d side%0d lane%0d col%0d got%h expected%h",
            commands,side,i%128,i/128,tmem[side][i],expected_tmem[side][i]);
    checks++;
  endtask

  function automatic int native_source_word(input tc_cmd_t c,input int row,word);
    int address,swizzle,width;
    swizzle=int'(c.smem_desc[63:61]);
    width=swizzle==2 ? 128 : swizzle==4 ? 64 : swizzle==6 ? 32 : 16;
    address=(int'(c.smem_desc[14:0])<<4)+(row%8)*width+
      (row/8)*(int'(c.smem_desc[45:32])<<4);
    if(swizzle==0)address+=(word/4)*(int'(c.smem_desc[30:16])<<4)+(word%4)*4;
    else begin
      address+=(word/4)*16+(word%4)*4;
      address=address^((address>>3)&(width-16));
    end
    return address/4;
  endfunction

  initial begin : main
    tc_cmd_t c;
    int count,index,frame,first,second,rows,width,srcrow,destlane,shiftbase,subgroups,mdcount;
    int swizzle;
    logic[31:0] value,meta_word;
    logic[127:0] packed_source;
    void'($value$plusargs("SEED=%d",seed));rng=32'(seed)|1;
    for(int side=0;side<2;side++)begin
      for(int i=0;i<COLS*128;i++)begin
        value=32'ha5000000+32'(i)+32'(side)*32'h100000;
        tmem[side][i]=value;expected_tmem[side][i]=value;
      end
      for(int i=0;i<SMEM_WORDS;i++)smem[side][i]=32'h31000000+32'(side)*32'h100000+32'(i);
    end
    repeat(4)@(negedge clk);rst_n=1;
    // Each legal shape/repeat and both raw32 and low16 pack/unpack modes.
    for(int shape=0;shape<5;shape++)
      for(int lg=0;lg<8;lg++)begin
        c=command(TC_ST);c.move_shape=tc_move_shape_e'(4'(shape));c.repeat_num=8'(1<<lg);
        count=register_count(c);
        if(count<=128)begin
          for(int packing=0;packing<2;packing++)begin
            c.op=TC_ST;c.pack16=0;c.unpack16=packing!=0;expected_rf_count=0;
            // store_value includes the command number assigned by run_command.
            commands++;expected_store(c);commands--;
            run_command(c,TC_OK);compare_memory();
            c.op=TC_LD;c.pack16=c.unpack16;c.unpack16=0;
            expected_load(c);run_command(c,TC_OK);
          end
        end
      end

    // F32/S32/U32 reductions through both permitted row mappings. Positive
    // F32 patterns are monotonically ordered, allowing an independent max oracle.
    for(int shape_i=0;shape_i<2;shape_i++)
      for(int type_i=0;type_i<3;type_i++)begin
        c=command(TC_LD);c.move_shape=shape_i==0 ? TC_SHAPE_32X32B : TC_SHAPE_16X32BX2;
        c.repeat_num=8;c.ld_red=1;c.red_max=1;c.red_type=tc_red_type_e'(2'(type_i));
        for(int r=0;r<8;r++)for(int t=0;t<32;t++)begin
          index=reference_index(c,r,t,0);value=32'h3f000000+32'(r*64+t);
          tmem[0][index]=value;expected_tmem[0][index]=value;
        end
        expected_load(c);expected_rf[7].last=0;
        expected_rf[8]='0;expected_rf[8].kind=TC_RF_RED;expected_rf[8].last=1;
        for(int t=0;t<32;t++)expected_rf[8].data[t]=32'h3f000000+32'(7*64+t);
        expected_rf_count=9;run_command(c,TC_OK);
      end

    // Compression throughout x4..x128, NaN preservation and interleaved metadata.
    for(int lg=2;lg<8;lg++)
      for(int reduction=0;reduction<2;reduction++)begin
        c=command(TC_LD);c.repeat_num=8'(1<<lg);c.spcompress=1;c.ld_red=reduction!=0;
        c.red_type=TC_RED_F32;c.red_max=1;c.red_abs=1;c.red_nan=1;
        for(int r=0;r<int'(c.repeat_num);r++)
          for(int t=0;t<32;t++)begin
            case(r%4)
              0:value=32'hc0400000; // -3
              1:value=32'h40800000; // +4
              2:value=32'h7fc00001+32'(t);
              default:value=32'h40000000; // +2
            endcase
            tmem[0][r*128+t]=value;expected_tmem[0][r*128+t]=value;
          end
        frame=0;subgroups=int'(c.repeat_num)/4;mdcount=(int'(c.repeat_num)+31)/32;
        for(int g=0;g<subgroups;g++)begin
          for(int part=0;part<2;part++)begin
            expected_rf[frame]='0;expected_rf[frame].kind=TC_RF_DATA;expected_rf[frame].index=8'(g*2+part);
            for(int t=0;t<32;t++)expected_rf[frame].data[t]=part==0 ? 32'h40800000 : 32'h7fc00001+32'(t);
            frame++;
          end
          if(g%8==7 || g+1==subgroups)begin
            expected_rf[frame]='0;expected_rf[frame].kind=TC_RF_META;expected_rf[frame].index=8'(g/8);
            meta_word=0;
            for(int n=0;n<8 && n<subgroups-(g/8)*8;n++)meta_word[4*n+:4]=4'h9;
            for(int t=0;t<32;t++)expected_rf[frame].data[t]=meta_word;
            expected_rf[frame].last=g+1==subgroups && reduction==0;frame++;
          end
        end
        if(reduction!=0)begin
          expected_rf[frame]='0;expected_rf[frame].kind=TC_RF_RED;expected_rf[frame].last=1;
          for(int t=0;t<32;t++)expected_rf[frame].data[t]=32'h7fc00000;
          frame++;
        end
        expected_rf_count=frame;run_command(c,TC_OK);
      end

    // CP all shapes and both warp-pair modes; peer_side is a second real array.
    for(int shape=5;shape<10;shape++)
      for(int packing=0;packing<3;packing++)
        for(int mode=0;mode<(shape==7 ? 2 : 1);mode++)begin
          c=command(TC_CP);c.cta_pair=1;c.move_shape=tc_move_shape_e'(4'(shape));
          c.cp_format=tc_cp_format_e'(2'(packing));c.tmem_col=16;c.rf_stream=0;
          if(shape==6)c.cp_multicast=TC_WARPX4;
          if(shape==7)c.cp_multicast=mode==0 ? TC_WARPX2_02_13 : TC_WARPX2_01_23;
          width=shape==5 || shape==8 ? 8 : 4;
          rows=shape==5 ? 4 : 128;
          for(int side=0;side<2;side++)
            for(int row=0;row<(shape==6 ? 32 : shape==7 ? 64 : rows);row++)
              for(int block_index=0;block_index<width/4;block_index++)begin
                packed_source='1; // Nonzero padding must not enter expanded values.
                if(packing==0)begin
                  for(int word=0;word<4;word++)packed_source[32*word+:32]=32'h51000000+32'(side*8192+row*8+block_index*4+word);
                end else
                  for(int e=0;e<16;e++)begin
                    if(packing==1)packed_source[4*e+:4]=4'((row+e+block_index+side)%16);
                    else packed_source[6*e+:6]=6'((row+e+block_index+side)%64);
                  end
                for(int word=0;word<4;word++)smem[side][1024+row*width+block_index*4+word]=packed_source[32*word+:32];
              end
          for(int side=0;side<2;side++)
            for(int row=0;row<rows;row++)begin
              srcrow=row;destlane=shape==5 ? row*32 : row;
              if(shape==6)srcrow=row%32;
              if(shape==7)srcrow=(mode==0 ? (row/32)%2 : row/64)*32+row%32;
              for(int col=0;col<width;col++)begin
                if(packing==0)value=smem[side][1024+srcrow*width+col];
                else begin
                  value=0;
                  for(int b=0;b<4;b++)begin
                    if(packing==1)value[8*b+:8]=8'(((srcrow+(col%4)*4+b+col/4+side)%16)*4);
                    else value[8*b+:8]=8'((srcrow+(col%4)*4+b+col/4+side)%64);
                  end
                end
                expected_tmem[side][(16+col)*128+destlane]=value;
              end
            end
          expected_rf_count=0;run_command(c,TC_OK);compare_memory();
        end

    // Down shift slides row1..31 into row0..30, leaving the last row available
    // for a separate CP.4x256b tail refresh. Exercise both endpoints.
    for(int quarter=0;quarter<4;quarter++)begin
      c=command(TC_SHIFT);c.tmem_lane=7'(quarter*32);c.tmem_col=24;c.cta_pair=1;
      shiftbase=quarter*32;
      for(int side=0;side<2;side++)
        for(int row=0;row<31;row++)
          for(int col=0;col<8;col++)
            expected_tmem[side][(24+col)*128+shiftbase+row]=expected_tmem[side][(24+col)*128+shiftbase+row+1];
      expected_rf_count=0;run_command(c,TC_OK);compare_memory();
    end

    // Full sliding-window sequence: shift each quarter, refresh the four tail
    // rows through 4DP, then load all four quarters to observe the updated tile.
    for(int col=0;col<8;col++)
      for(int row=0;row<128;row++)begin
        value=32'h33000000+32'(col*128+row);
        tmem[0][(56+col)*128+row]=value;expected_tmem[0][(56+col)*128+row]=value;
      end
    for(int q=0;q<4;q++)begin
      c=command(TC_SHIFT);c.tmem_col=56;c.tmem_lane=7'(q*32);
      for(int row=0;row<31;row++)
        for(int col=0;col<8;col++)
          expected_tmem[0][(56+col)*128+q*32+row]=expected_tmem[0][(56+col)*128+q*32+row+1];
      expected_rf_count=0;run_command(c,TC_OK);
    end
    c=command(TC_CP);c.move_shape=TC_SHAPE_4X256B;c.tmem_lane=31;c.tmem_col=56;c.rf_stream=0;
    for(int q=0;q<4;q++)
      for(int col=0;col<8;col++)begin
        value=32'h44000000+32'(q*8+col);smem[0][1024+q*8+col]=value;
        expected_tmem[0][(56+col)*128+q*32+31]=value;
      end
    expected_rf_count=0;run_command(c,TC_OK);compare_memory();
    for(int q=0;q<4;q++)begin
      c=command(TC_LD);c.move_shape=TC_SHAPE_32X32B;c.repeat_num=8;
      c.tmem_col=56;c.tmem_lane=7'(q*32);c.warp=6'(q);
      expected_load(c);run_command(c,TC_OK);
    end

    // Native descriptor K-major CP recipes: separate scalar address oracle
    // exercises no swizzle and 32/64/128-byte swizzle, with both packed formats.
    for(int layout_mode=0;layout_mode<4;layout_mode++)
      for(int packing=0;packing<3;packing++)begin
        c=command(TC_CP);c.recipe=TC_RECIPE_NATIVE;c.rf_stream=0;
        c.move_shape=TC_SHAPE_128X256B;c.tmem_col=40;
        c.cp_format=tc_cp_format_e'(2'(packing));
        swizzle=layout_mode==0 ? 0 : layout_mode==1 ? 6 : layout_mode==2 ? 4 : 2;
        c.smem_desc='0;c.smem_desc[14:0]=15'h100;
        c.smem_desc[30:16]=15'd8;c.smem_desc[48:46]=3'b001;
        c.smem_desc[63:61]=3'(swizzle);
        c.smem_desc[45:32]=14'(layout_mode==0 ? 16 : (layout_mode==1 ? 16 : layout_mode==2 ? 32 : 64));
        for(int row=0;row<128;row++)
          for(int block_index=0;block_index<2;block_index++)begin
            packed_source='1;
            for(int e=0;e<16;e++)begin
              if(packing==1)packed_source[4*e+:4]=4'((row+e+block_index)%16);
              else if(packing==2)packed_source[6*e+:6]=6'((row+e+block_index)%64);
            end
            for(int word=0;word<4;word++)begin
              index=native_source_word(c,row,block_index*4+word);
              smem[0][index]=packing==0 ? 32'h71000000+32'(row*8+block_index*4+word) : packed_source[32*word+:32];
            end
          end
        for(int row=0;row<128;row++)
          for(int col=0;col<8;col++)begin
            if(packing==0)value=smem[0][native_source_word(c,row,col)];
            else begin
              value=0;
              for(int b=0;b<4;b++)
                value[8*b+:8]=packing==1 ? 8'(((row+(col%4)*4+b+col/4)%16)*4) :
                  8'((row+(col%4)*4+b+col/4)%64);
            end
            expected_tmem[0][(40+col)*128+row]=value;
          end
        expected_rf_count=0;run_command(c,TC_OK);compare_memory();
      end

    // Compression tie/NaN policies are verified through the streaming engine,
    // beyond the independently generated comparison-circuit oracle.
    for(int pattern=0;pattern<4;pattern++)
      for(int maximum=0;maximum<2;maximum++)
        for(int absolute=0;absolute<2;absolute++)
          for(int propagation=0;propagation<2;propagation++)begin
            c=command(TC_LD);c.repeat_num=4;c.spcompress=1;c.ld_red=1;
            c.red_max=maximum!=0;c.red_abs=absolute!=0;c.red_nan=propagation!=0;
            for(int r=0;r<4;r++)
              for(int t=0;t<32;t++)begin
                case(pattern)
                  0:case(r)
                    0:value=32'hc0400000;
                    1:value=32'h40800000;
                    2:value=32'h7fc00002+32'(t);
                    default:value=32'h40000000;
                  endcase
                  1:value=r%2==0 ? 32'h7fc00100+32'(r*32+t) : r==1 ? 32'h3f800000 : 32'hbf800000;
                  2:value=r<3 ? 32'h7fc00200+32'(r*32+t) : 32'h40400000;
                  default:value=r%2==0 ? 32'h80000000 : 32'h00000000;
                endcase
                tmem[0][r*128+t]=value;expected_tmem[0][r*128+t]=value;
              end
            if(pattern==0)begin
              if(maximum!=0)begin first=1;second=2;end
              else if(absolute!=0)begin first=2;second=3;end
              else begin first=0;second=2;end
            end else if(pattern==1)begin first=0;second=2;end
            else if(pattern==2 || absolute!=0)begin first=0;second=1;end
            else if(maximum!=0)begin first=1;second=3;end
            else begin first=0;second=2;end
            for(int r=0;r<4;r++)begin
              expected_rf[r]='0;
              expected_rf[r].kind=r<2 ? TC_RF_DATA : r==2 ? TC_RF_META : TC_RF_RED;
              expected_rf[r].index=8'(r==1 ? 1 : 0);expected_rf[r].last=r==3;
              for(int t=0;t<32;t++)begin
                if(r<2)expected_rf[r].data[t]=expected_tmem[0][(r==0 ? first : second)*128+t];
                else if(r==2)expected_rf[r].data[t]=32'(first+second*4);
                else if(propagation!=0 && pattern<3)expected_rf[r].data[t]=32'h7fc00000;
                else if(pattern==0)expected_rf[r].data[t]=maximum!=0 ? 32'h40800000 : absolute!=0 ? 32'h40000000 : 32'hc0400000;
                else if(pattern==1)expected_rf[r].data[t]=maximum!=0 || absolute!=0 ? 32'h3f800000 : 32'hbf800000;
                else if(pattern==2)expected_rf[r].data[t]=32'h40400000;
                else expected_rf[r].data[t]=maximum!=0 || absolute!=0 ? 32'h00000000 : 32'h80000000;
              end
            end
            expected_rf_count=4;run_command(c,TC_OK);
          end

    // Legacy inline data is still a transport adapter; no RF stream is emitted.
    c=command(TC_ST);c.recipe=TC_RECIPE_WORD32_REF;c.rf_stream=0;c.repeat_num=0;
    c.warp=3;c.tmem_col=50;
    for(int t=0;t<32;t++)begin
      c.data[t]=32'h98760000+32'(t);expected_tmem[0][50*128+96+t]=c.data[t];
    end
    expected_rf_count=0;run_command(c,TC_OK);compare_memory();
    c.op=TC_LD;run_command(c,TC_OK);
    for(int t=0;t<32;t++)check(rsp.data[t]==c.data[t],"legacy inline load payload");

    // Malformed command rejection, transport fault, old-transaction detection,
    // then a successful command prove the engine does not retain a dead state.
    c=command(TC_LD);c.repeat_num=3;expected_rf_count=0;run_command(c,TC_BAD_CMD);
    c=command(TC_LD);c.spcompress=1;run_command(c,TC_BAD_CMD);
    c=command(TC_LD);fail_next_memory=1;run_command(c,TC_MEM_ERROR);
    corrupt_next_id=1;run_command(c,TC_MEM_ERROR);
    expected_load(c);run_command(c,TC_OK);
    check(mem_hold_cycles>100 && rf_hold_cycles>100,"Backpressure actually exercised");
    check(peer_transfers>100,"Peer accesses actually exercised");
    $display("TCGEN05_MOVE_PASS commands=%0d checks=%0d responses=%0d rf_fragments=%0d cycles=%0d reads=%0d writes=%0d peer=%0d rf_hold=%0d mem_hold=%0d seed=%0d",
      commands,checks,responses,rf_fragments,cycles,mem_reads,mem_writes,peer_transfers,rf_hold_cycles,mem_hold_cycles,seed);
    $finish;
  end
endmodule
