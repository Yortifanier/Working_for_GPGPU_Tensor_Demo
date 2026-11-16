`timescale 1ns/1ps
// Independent byte/word memories and fixed exact-value oracles. The scoreboard
// never calls the DUT address/format/sparsity helpers to create expected data.
/* verilator lint_off BLKSEQ */
module tb_tcgen05_mma;
  import malu_pkg::*;
  import tcgen05_pkg::*;
  parameter int DOT_ENGINES=4;
  parameter int LANES=4;
  parameter bit ENABLE_FP64=1'b1;
  localparam int COLS=128;
  localparam int SMEM_WORDS=16384;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  logic req_valid=0,req_ready,rsp_valid,rsp_ready=0,aread_done;
  tc_cmd_t req;
  tc_rsp_t rsp;
  logic tm_req_valid,tm_req_ready,tm_rsp_valid=0,tm_rsp_ready;
  logic smem_req_valid,smem_req_ready,smem_rsp_valid=0,smem_rsp_ready;
  tc_mem_req_t tm_req,smem_req,pending_request;
  tc_mem_rsp_t tm_rsp,smem_rsp;
  logic [31:0] tm[2][COLS*128];
  logic [31:0] sm[2][SMEM_WORDS];
  bit pending=0,pending_smem=0,hold_memory=0,error_enable=0;
  logic [31:0] error_address;
  bit inject_stale=0,stale_sent=0;
  logic [31:0] random_state=32'h1907a110;
  int delay_count=0,cycles=0,commands=0,checks=0,areads=0;
  int treads=0,sreads=0,twrites=0,beats=0,max_contexts=0;
  int total_terms=0;
  logic [15:0] last_command_tag=0;
  tcgen05_mma #(.COLS(COLS),.LANES(LANES),.MAX_K(256),
    .MAX_M(256),.MAX_N(256),.DOT_ENGINES(DOT_ENGINES),
    .ENABLE_FP64(ENABLE_FP64)) dut(.*);
  assign tm_req_ready=rst_n && !hold_memory && !pending && !tm_rsp_valid &&
    !smem_rsp_valid && (random_state[0] || random_state[1]);
  assign smem_req_ready=tm_req_ready;

  function automatic logic [31:0] random_next(input logic [31:0] old);
    logic [31:0] x;
    x=old^(old<<13);x=x^(x>>17);return x^(x<<5);
  endfunction
  always @(negedge clk) random_state=random_next(random_state);
  always @(posedge clk) begin : memory_and_monitors
    int flat,peer_id,live;
    tc_mem_rsp_t result;
    cycles=cycles+1;
    if (cycles>40000000) $fatal(1,"MMA watchdog state=%0d cmd=%0d",dut.state,commands);
    if (!rst_n) begin
      pending<=0;tm_rsp_valid<=0;smem_rsp_valid<=0;
      tm_rsp<='0;smem_rsp<='0;
    end else begin
      live=$countones(dut.context_live);
      if (live>max_contexts) max_contexts=live;
      if (aread_done) areads=areads+1;
      if (dut.array_op_valid && dut.array_op_ready) begin
        beats=beats+1;total_terms=total_terms+int'(dut.beat_count);
      end
      if (tm_rsp_valid && tm_rsp_ready) tm_rsp_valid<=0;
      if (smem_rsp_valid && smem_rsp_ready) smem_rsp_valid<=0;
      if (tm_req_valid && smem_req_valid) $fatal(1,"both memory ports issued");
      if ((tm_req_valid && tm_req_ready) || (smem_req_valid && smem_req_ready)) begin
        if (pending || tm_rsp_valid || smem_rsp_valid) $fatal(1,"multiple outstanding");
        pending<=1;pending_smem<=smem_req_valid;
        pending_request<=smem_req_valid ? smem_req : tm_req;
        delay_count=1+int'(random_state[3:2]);stale_sent=0;
        if (tm_req_valid) begin
          if (int'(tm_req.col)>=COLS) $fatal(1,"TMEM range");
          if (tm_req.write) twrites=twrites+1;else treads=treads+1;
        end else begin
          sreads=sreads+1;
          if (smem_req.write || smem_req.byte_addr[1:0]!=0 || smem_req.byte_addr>=SMEM_WORDS*4)
            $fatal(1,"SMEM malformed request");
        end
      end
      if (pending && !tm_rsp_valid && !smem_rsp_valid) begin
        if (delay_count!=0) delay_count=delay_count-1;
        else begin
          peer_id=int'(pending_request.peer);
          flat=int'(pending_request.col)*128+int'(pending_request.lane);
          result='0;result.txn_id=pending_request.txn_id;
          result.status=TC_OK;
          if (pending_smem) result.rdata=sm[peer_id][pending_request.byte_addr>>2];
          else result.rdata=tm[peer_id][flat];
          if (pending_smem && error_enable && pending_request.byte_addr==error_address) begin
            result.status=TC_MEM_ERROR;error_enable=0;
          end
          if (pending_smem && inject_stale && !stale_sent) begin
            result.txn_id=pending_request.txn_id+64'h10000000;
            stale_sent=1;inject_stale=0;
            delay_count=2;
          end else begin
            pending<=0;
            if (!pending_smem && pending_request.write && result.status==TC_OK)
              for (int b=0;b<4;b++)
                if (pending_request.wstrb[b]) tm[peer_id][flat][8*b+:8]=pending_request.wdata[8*b+:8];
          end
          if (pending_smem) begin smem_rsp_valid<=1;smem_rsp<=result;end
          else begin tm_rsp_valid<=1;tm_rsp<=result;end
        end
      end
    end
  end

  function automatic logic [31:0] integer_f32(input int unsigned value);
    int lead;
    logic [31:0] bits_value;
    if (value==0) return 0;
    lead=0;
    for (int i=0;i<31;i++) if ((value>>i)!=0) lead=i;
    bits_value=((32'(127+lead))<<23)|((32'(value)<<(23-lead))&32'h7fffff);
    return bits_value;
  endfunction
  function automatic logic [63:0] encoded_one(input malu_fmt_e fmt);
    case (fmt)
      FMT_F16:return 64'h3c00;
      FMT_BF16:return 64'h3f80;
      FMT_TF32,FMT_F32:return 64'h3f800000;
      FMT_F64:return 64'h3ff0000000000000;
      FMT_E4M3:return 64'h38;
      FMT_E5M2:return 64'h3c;
      FMT_E2M3:return 64'h8;
      FMT_E3M2:return 64'hc;
      FMT_E2M1:return 64'h2;
      default:return 1;
    endcase
  endfunction
  function automatic tc_cmd_t base_command;
    tc_cmd_t c;
    c='0;c.op=TC_MMA;c.recipe=TC_RECIPE_CANONICAL;c.kind=TC_KIND_F16;
    c.owner_generation=1;c.peer_generation=1;c.peer_owner=1;
    c.m=1;c.n=1;c.cfg.k=4;
    c.cfg.a_fmt=FMT_F16;c.cfg.b_fmt=FMT_F16;
    c.cfg.c_fmt=FMT_F32;c.cfg.d_fmt=FMT_F32;c.cfg.rounding=ROUND_RNE;
    c.cfg.profile=PROJECT_EXACT;
    c.a_addr=32'h1000;c.b_addr=32'h4000;
    c.a_packing=TC_PACK_BITS;c.b_packing=TC_PACK_BITS;
    c.sparse_meta_col=32;c.scale_a_col=40;c.scale_b_col=44;c.lut_col=48;
    c.collector_a=TC_COLLECT_DISCARD;c.collector_b=TC_COLLECT_DISCARD;
    return c;
  endfunction
  task automatic check(input bit yes,input string why);
    if (!yes) $fatal(1,"%s command=%0d cycle=%0d",why,commands,cycles);
    checks=checks+1;
  endtask
  task automatic equal(input logic [31:0] actual,input logic [31:0] expected,input string why);
    if (actual!==expected) $fatal(1,"%s actual=%h expected=%h command=%0d",why,actual,expected,commands);
    checks=checks+1;
  endtask
  task automatic write_smem_bits(input int peer,input int byte_base,
      input int bit_index,input int width,input logic [63:0] value);
    int bit_address,word_index;
    for (int i=0;i<width;i++) begin
      bit_address=byte_base*8+bit_index+i;word_index=bit_address/32;
      sm[peer][word_index][bit_address%32]=value[i];
    end
  endtask
  task automatic put_a(input tc_cmd_t c,input int row,input int k,input logic [63:0] value);
    int physical_row,physical_col,row_len,bits_per_element,local_row,m_rows,peer;
    m_rows=c.cta_pair ? int'(c.m)/2 : int'(c.m);
    local_row=c.cta_pair ? row%m_rows : row;
    peer=c.cta_pair ? ((row/m_rows)^int'(c.pair_local_is_odd)) : 0;
    physical_row=c.transpose_a ? k : local_row;physical_col=c.transpose_a ? local_row : k;
    row_len=c.transpose_a ? m_rows : (c.sparse ? int'(c.cfg.k)/2 : int'(c.cfg.k));
    bits_per_element=c.a_packing==TC_PACK_BYTE ? 8 :
      (c.a_packing==TC_PACK_WORD32 ? (c.cfg.a_fmt==FMT_F64 ? 64 : 32) : fmt_width(c.cfg.a_fmt));
    write_smem_bits(peer,int'(c.a_addr),(physical_row*row_len+physical_col)*bits_per_element,fmt_width(c.cfg.a_fmt),value);
  endtask
  task automatic put_b(input tc_cmd_t c,input int k,input int n,input logic [63:0] value);
    int physical_row,physical_col,row_len,bits_per_element,local_n,n_cols,peer;
    n_cols=c.cta_pair ? int'(c.n)/2 : int'(c.n);
    local_n=c.cta_pair ? n%n_cols : n;
    peer=c.cta_pair ? ((n/n_cols)^int'(c.pair_local_is_odd)) : 0;
    physical_row=c.transpose_b ? local_n : k;physical_col=c.transpose_b ? k : local_n;
    row_len=c.transpose_b ? int'(c.cfg.k) : n_cols;
    bits_per_element=c.b_packing==TC_PACK_BYTE ? 8 :
      (c.b_packing==TC_PACK_WORD32 ? (c.cfg.b_fmt==FMT_F64 ? 64 : 32) : (c.lut ? 3 : fmt_width(c.cfg.b_fmt)));
    write_smem_bits(peer,int'(c.b_addr),(physical_row*row_len+physical_col)*bits_per_element,
      c.lut ? 3 : fmt_width(c.cfg.b_fmt),value);
  endtask
  task automatic fill_one_operands(input tc_cmd_t c);
    for (int m=0;m<int'(c.m);m++)
      for (int k=0;k<(c.sparse ? int'(c.cfg.k)/2 : int'(c.cfg.k));k++) put_a(c,m,k,encoded_one(c.cfg.a_fmt));
    for (int k=0;k<int'(c.cfg.k);k++)
      for (int n=0;n<int'(c.n);n++) put_b(c,k,n,encoded_one(c.cfg.b_fmt));
  endtask
  task automatic transact(input tc_cmd_t original,input tc_status_e expected=TC_OK,
                          input malu_status_e numerical=STATUS_OK);
    tc_cmd_t c;
    tc_rsp_t saved;
    int deadline;
    c=original;commands=commands+1;c.tag=16'(commands);last_command_tag=c.tag;
    @(negedge clk);req=c;req_valid=1;
    do @(posedge clk);while (!req_ready);
    @(negedge clk);req_valid=0;
    deadline=cycles+10000000;
    while (!rsp_valid) begin
      @(negedge clk);
      if (cycles>deadline) $fatal(1,"MMA command timeout tag=%0d state=%0d",c.tag,dut.state);
    end
    saved=rsp;
    repeat (4) begin @(negedge clk);check(rsp_valid && rsp===saved,"stable blocked response");end
    check(rsp.status==expected && rsp.malu_status==numerical,"expected response status");
    check(rsp.tag==c.tag && rsp.owner==c.owner && rsp.owner_generation==c.owner_generation,"response identity");
    @(negedge clk);rsp_ready=1;
    @(posedge clk);
    @(negedge clk);rsp_ready=0;
  endtask

  tc_cmd_t c;
  malu_fmt_e formats[16]='{FMT_F16,FMT_BF16,FMT_TF32,FMT_F32,FMT_F64,
    FMT_E4M3,FMT_E5M2,FMT_E2M3,FMT_E3M2,FMT_E2M1,FMT_S8,FMT_U8,
    FMT_S4,FMT_U4,FMT_TI16,FMT_B1};
  logic [3:0] metadata[7]='{4'h4,4'h8,4'hc,4'h9,4'hd,4'h6,4'he};
  int before_a,before_r,before_t,expected_value;
  initial begin
    req='0;tm_rsp='0;smem_rsp='0;
    for (int p=0;p<2;p++) begin
      for (int i=0;i<COLS*128;i++) tm[p][i]=0;
      for (int i=0;i<SMEM_WORDS;i++) sm[p][i]=0;
    end
    repeat (4) @(negedge clk);rst_n=1;

    // Every existing project input format, including packed FP6 word crossing.
    for (int f=0;f<16;f++) begin
      if (formats[f]!=FMT_F64 || ENABLE_FP64) begin
        c=base_command();c.cfg.k=10;c.cfg.a_fmt=formats[f];c.cfg.b_fmt=formats[f];
        if (f>=10) begin c.cfg.c_fmt=FMT_S32;c.cfg.d_fmt=FMT_S32;c.cfg.ti16_decoded=1;end
        fill_one_operands(c);transact(c);
        equal(tm[0][0],f>=10 ? 32'd10 : integer_f32(10),"all-format packed ones dot");
      end
    end
    check(max_contexts>=1,"at least one active dot");

    // Both transpose coordinates and independent row/column output strides.
    c=base_command();c.m=2;c.n=2;c.cfg.k=3;c.transpose_a=1;c.transpose_b=1;
    // Integer16 decoded transport makes a compact exact matrix oracle.
    c.cfg.a_fmt=FMT_TI16;c.cfg.b_fmt=FMT_TI16;c.cfg.c_fmt=FMT_S32;c.cfg.d_fmt=FMT_S32;c.cfg.ti16_decoded=1;
    for (int m=0;m<2;m++) for (int k=0;k<3;k++) put_a(c,m,k,64'(32'(m*3+k+1)));
    for (int k=0;k<3;k++) for (int n=0;n<2;n++) put_b(c,k,n,64'(32'(k*2+n+1)));
    transact(c);
    equal(tm[0][0],22,"transposed dot00");equal(tm[0][128],28,"transposed dot01");
    equal(tm[0][1],49,"transposed dot10");equal(tm[0][129],64,"transposed dot11");
    if (DOT_ENGINES>1) check(max_contexts==DOT_ENGINES,"multiple physical dot contexts admitted");

    c=base_command();fill_one_operands(c);tm[0][0]=32'h41000000;
    c.enable_input_d=1;c.cfg.c_scale_shift=3;transact(c);
    equal(tm[0][0],32'h40a00000,"single formal Cshift result5");
    tm[0][0]=32'h7fc00000;c.enable_input_d=0;before_r=treads;transact(c);
    equal(tm[0][0],32'h40800000,"disabled oldD NaN ignored");
    check(treads==before_r,"disabled oldD never read");
    c.cfg.c_scale_shift=0;c.negate_a=1;transact(c);equal(tm[0][0],32'hc0800000,"negateA");
    c.negate_b=1;transact(c);equal(tm[0][0],32'h40800000,"negateAandB");

    // All seven metadata encodings listed by uploaded PTX; order is preserved.
    for (int code=0;code<7;code++) begin
      c=base_command();c.sparse=1;c.cfg.k=8;c.kind=TC_KIND_F16;
      for (int k=0;k<4;k++) put_a(c,0,k,k%2==0 ? 64'h3c00 : 64'h4000);
      for (int k=0;k<8;k++) put_b(c,k,0,64'h3c00);
      tm[0][32*128]=32'(metadata[code])|(32'(metadata[code])<<4);
      transact(c);equal(tm[0][0],32'h40c00000,"2of4 all valid metadata");
    end
    c=base_command();c.sparse=1;c.cfg.k=4;c.kind=TC_KIND_TF32;
    c.cfg.a_fmt=FMT_TF32;c.cfg.b_fmt=FMT_TF32;
    put_a(c,0,0,64'h3f800000);put_a(c,0,1,64'h40000000);
    put_b(c,0,0,64'h3f800000);put_b(c,1,0,64'h40000000);
    put_b(c,2,0,64'h40800000);put_b(c,3,0,64'h41000000);
    tm[0][32*128]=32'he4;
    transact(c);equal(tm[0][0],32'h41880000,"TF32 1of2 positional mapping");
    c=base_command();c.sparse=1;c.cfg.k=8;c.kind=TC_KIND_MXF4;
    c.cfg.a_fmt=FMT_E2M1;c.cfg.b_fmt=FMT_E2M1;
    put_a(c,0,0,2);put_a(c,0,1,4);put_a(c,0,2,5);put_a(c,0,3,6);
    for (int k=0;k<8;k++) put_b(c,k,0,k<2 ? 2 : (k<4 ? 4 : (k<6 ? 5 : 6)));
    tm[0][32*128]=9;transact(c);equal(tm[0][0],32'h41d80000,"paired4of8 positions");
    tm[0][32*128]=6;transact(c);equal(tm[0][0],32'h41b80000,"paired4of8 reversed metadata order");
    tm[0][32*128]=0;transact(c,TC_BAD_CMD,STATUS_BAD_ENCODING);

    // Structural sparse zero multiplied by infinity remains NaN in PROJECT_EXACT.
    c=base_command();c.sparse=1;c.cfg.k=4;tm[0][32*128]=4;
    put_a(c,0,0,64'h3c00);put_a(c,0,1,64'h3c00);
    for (int k=0;k<4;k++) put_b(c,k,0,k==3 ? 64'h7c00 : 64'h3c00);
    transact(c);check(tm[0][0][30:23]==8'hff && tm[0][0][22:0]!=0,"structural-zero timesInf NaN");

    // Different scale matrices, independent row/column vectors and K chunks.
    c=base_command();c.m=2;c.n=2;c.cfg.k=64;c.kind=TC_KIND_MXF8F6F4;
    c.cfg.a_fmt=FMT_E4M3;c.cfg.b_fmt=FMT_E4M3;c.cfg.block_scale_en=1;
    c.cfg.block_size=BLOCK32;c.cfg.a_scale_fmt=SCALE_UE8M0;c.cfg.b_scale_fmt=SCALE_UE8M0;
    c.scale_count_a=2;c.scale_count_b=2;fill_one_operands(c);
    tm[0][40*128]=32'h0000807f;tm[0][40*128+1]=32'h0000817f;
    tm[0][44*128]=32'h00007f7f;tm[0][44*128+1]=32'h0000807f;
    transact(c);
    equal(tm[0][0],integer_f32(96),"scale row0col0");equal(tm[0][128],integer_f32(160),"scale row0col1");
    equal(tm[0][1],integer_f32(160),"scale row1col0");equal(tm[0][129],integer_f32(288),"scale row1col1");
    c.m=1;c.n=1;c.cfg.a_block_offset=15;c.cfg.b_block_offset=31;
    c.scale_count_a=3;c.scale_count_b=3;fill_one_operands(c);
    tm[0][40*128]=32'h0081807f;tm[0][44*128]=32'h0081807f;
    before_t=beats;transact(c);equal(tm[0][0],integer_f32(465),"unequal block offsets preserve block32 span");
    if (LANES==4) check(beats-before_t==17,"unequal offset17beat cuts");
    c=base_command();c.cfg.k=32;c.kind=TC_KIND_MXF4NVF4;
    c.cfg.a_fmt=FMT_E2M1;c.cfg.b_fmt=FMT_E2M1;c.cfg.block_scale_en=1;
    c.cfg.block_size=BLOCK16;c.cfg.a_scale_fmt=SCALE_UE4M3;c.cfg.b_scale_fmt=SCALE_UE4M3;
    c.scale_count_a=2;c.scale_count_b=2;fill_one_operands(c);
    tm[0][40*128]=32'h00004038;tm[0][44*128]=32'h00003838;
    transact(c);equal(tm[0][0],integer_f32(48),"BLOCK16 UE4M3 scale");

    c=base_command();c.kind=TC_KIND_I8;c.cfg.a_fmt=FMT_S8;c.cfg.b_fmt=FMT_U8;
    c.cfg.c_fmt=FMT_S32;c.cfg.d_fmt=FMT_S32;c.enable_input_d=1;c.cfg.int_sat=1;
    for (int k=0;k<4;k++) begin put_a(c,0,k,127);put_b(c,k,0,127);end
    tm[0][0]=32'h7fffffff;transact(c);equal(tm[0][0],32'h7fffffff,"integer final saturation");
    c.cfg.int_sat=0;tm[0][0]=32'h7fffffff;transact(c);equal(tm[0][0],32'h8000fc03,"integer final modulo32");

    // LUT indices cross word boundaries; each eight-column slice has 8 values.
    c=base_command();c.cfg.a_fmt=FMT_E4M3;c.cfg.b_fmt=FMT_E4M3;c.kind=TC_KIND_F8F6F4;
    c.cfg.k=12;c.n=2;c.lut=1;c.b_packing=TC_PACK_BITS;
    for (int k=0;k<12;k++) begin put_a(c,0,k,64'h38);put_b(c,k,0,0);put_b(c,k,1,1);end
    tm[0][48*128]=32'h00004038;
    transact(c);equal(tm[0][0],integer_f32(12),"LUT index0 E4M3 one");
    equal(tm[0][128],integer_f32(24),"LUT index1 E4M3 two");
    c.kind=TC_KIND_MXF8F6F4;c.cfg.block_scale_en=1;c.cfg.block_size=BLOCK32;
    c.cfg.a_scale_fmt=SCALE_UE8M0;c.cfg.b_scale_fmt=SCALE_UE8M0;c.scale_count_a=1;c.scale_count_b=1;
    tm[0][40*128]=32'h80;tm[0][44*128]=32'h81;tm[0][44*128+1]=32'h81;
    transact(c);equal(tm[0][0],integer_f32(96),"LUT combined with blockscale0");
    equal(tm[0][128],integer_f32(192),"LUT combined with blockscale1");

    // WS zero-column descriptor examples and column shift, independent of Dmask.
    c=base_command();c.ws=1;c.m=32;c.n=8;c.cfg.k=1;
    c.zero_column_mask_desc[39]=1;c.zero_column_mask_desc[47:40]=1;
    c.zero_column_mask_desc[55:48]=0;c.zero_column_mask_desc[61:56]=2;
    c.zero_column_mask_desc[15:8]=1;c.zero_column_mask_desc[23:16]=2;
    for (int m=0;m<32;m++) put_a(c,m,0,64'h3c00);
    for (int n=0;n<10;n++) write_smem_bits(0,int'(c.b_addr),n*16,16,
      n<2 ? 64'h3c00 : (n==2 ? 64'h4200 : (n==7 ? 64'h4800 : (n==8 ? 64'h4880 : 64'h4000))));
    c.collector_b=TC_COLLECT_FILL;c.collector_b_id=2;transact(c);
    for (int m=0;m<32;m++) begin
      equal(tm[0][m],integer_f32(3),"WS mask/shift column0");
      equal(tm[0][128+m],0,"WS mask column1");equal(tm[0][256+m],0,"WS mask column2");
      equal(tm[0][5*128+m],integer_f32(8),"WS mask/shift column5");
      equal(tm[0][6*128+m],integer_f32(9),"WS mask/shift column6");
    end
    c.collector_b=TC_COLLECT_USE;transact(c);
    c.collector_b=TC_COLLECT_LASTUSE;transact(c);
    c.collector_b=TC_COLLECT_USE;transact(c,TC_ORDER);
    c.collector_b=TC_COLLECT_DISCARD;c.sparse=1;c.cfg.k=4;
    for (int m=0;m<32;m++) begin
      put_a(c,m,0,64'h3c00);put_a(c,m,1,64'h4000);tm[0][32*128+m]=4;
    end
    for (int k=0;k<4;k++) for (int n=0;n<10;n++)
      write_smem_bits(0,int'(c.b_addr),(k*8+n)*16,16,64'h3c00);
    transact(c);
    equal(tm[0][0],integer_f32(3),"WS sparse nonmasked result");equal(tm[0][128],0,"WS sparse zero column");
    c=base_command();fill_one_operands(c);c.collector_a=TC_COLLECT_FILL;transact(c);
    c.collector_a=TC_COLLECT_USE;transact(c);
    c.collector_a=TC_COLLECT_LASTUSE;transact(c);
    c.collector_a=TC_COLLECT_USE;transact(c,TC_ORDER);

    // Native single-CTA FP16 layout D, real packed TMEM A, descriptor-backed B.
    c=base_command();c.recipe=TC_RECIPE_NATIVE;c.m=128;c.n=8;c.cfg.k=16;
    c.a_from_tmem=1;c.a_col=64;c.b_desc=64'(32'h2000>>4)|(64'd8<<16)|(64'd16<<32)|(64'd1<<46);
    c.disable_d_lanes[5]=1;
    for (int row=0;row<128;row++) for (int word_id=0;word_id<8;word_id++) tm[0][(64+word_id)*128+row]=32'h3c003c00;
    for (int word_id=0;word_id<64;word_id++) sm[0][32'h2000/4+word_id]=32'h3c003c00;
    for (int n=0;n<8;n++) tm[0][n*128+5]=32'h12345678;
    before_a=areads;transact(c);
    for (int row=0;row<128;row++) for (int n=0;n<8;n++)
      equal(tm[0][n*128+row],row==5 ? 32'h12345678 : integer_f32(16),"native layoutD TMEM A and Dmask");
    check(areads==before_a,"TMEM A creates no SMEM-A event");

    // A native MXFP8 shape: one scale vector per row/column, with TMEM scales.
    c=base_command();c.recipe=TC_RECIPE_NATIVE;c.m=128;c.n=8;c.cfg.k=32;
    c.kind=TC_KIND_MXF8F6F4;c.cfg.a_fmt=FMT_E4M3;c.cfg.b_fmt=FMT_E4M3;
    c.cfg.block_scale_en=1;c.cfg.block_size=BLOCK32;c.scale_count_a=1;c.scale_count_b=1;
    c.cfg.a_scale_fmt=SCALE_UE8M0;c.cfg.b_scale_fmt=SCALE_UE8M0;
    c.a_from_tmem=1;c.a_col=64;c.b_desc=64'(32'h2000>>4)|(64'd8<<16)|(64'd16<<32)|(64'd1<<46);
    for (int row=0;row<128;row++) for (int word_id=0;word_id<8;word_id++) tm[0][(64+word_id)*128+row]=32'h38383838;
    for (int word_id=0;word_id<64;word_id++) sm[0][32'h2000/4+word_id]=32'h38383838;
    for (int row=0;row<32;row++) for (int partition=0;partition<4;partition++) tm[0][(40+partition)*128+row]=32'h7f;
    for (int row=0;row<128;row++) tm[0][44*128+row]=32'h80;
    transact(c);
    for (int row=0;row<128;row++) for (int n=0;n<8;n++) equal(tm[0][n*128+row],integer_f32(64),"native MXFP8 TMEM scale matrices");

    // Native NVFP4 packs two values/byte and has four UE4M3 scales at BLOCK16.
    c.kind=TC_KIND_MXF4NVF4;c.cfg.k=64;c.cfg.a_fmt=FMT_E2M1;c.cfg.b_fmt=FMT_E2M1;
    c.cfg.block_size=BLOCK16;c.scale_count_a=4;c.scale_count_b=4;
    c.cfg.a_scale_fmt=SCALE_UE4M3;c.cfg.b_scale_fmt=SCALE_UE4M3;
    for (int row=0;row<128;row++) for (int word_id=0;word_id<8;word_id++) tm[0][(64+word_id)*128+row]=32'h22222222;
    for (int word_id=0;word_id<64;word_id++) sm[0][32'h2000/4+word_id]=32'h22222222;
    for (int row=0;row<32;row++) for (int partition=0;partition<4;partition++) tm[0][(40+partition)*128+row]=32'h50484038;
    for (int row=0;row<128;row++) tm[0][44*128+row]=32'h38383838;
    transact(c);
    for (int row=0;row<128;row++) for (int n=0;n<8;n++) equal(tm[0][n*128+row],integer_f32(240),"native NVFP4 BLOCK16 scale mapping");

    // Native sparse FP16 logical K32 / compressed K16; poisoned metadata
    // changes the selected B positions, independently of identical A row sizes.
    c=base_command();c.recipe=TC_RECIPE_NATIVE;c.m=128;c.n=8;c.cfg.k=32;c.sparse=1;
    c.a_from_tmem=1;c.a_col=64;c.b_desc=64'(32'h2000>>4)|(64'd8<<16)|(64'd16<<32)|(64'd1<<46);
    for (int row=0;row<128;row++) begin
      tm[0][32*128+row]=row%2==0 ? 32'h44444444 : 32'heeeeeeee;
      for (int word_id=0;word_id<8;word_id++) tm[0][(64+word_id)*128+row]=32'h40003c00;
    end
    for (int n=0;n<8;n++) for (int k=0;k<32;k++)
      write_smem_bits(0,32'h2000+n*16+(k/8)*128,(k%8)*16,16,
        k%4==0 ? 64'h3c00 : (k%4==1 ? 64'h4000 : (k%4==2 ? 64'h4400 : 64'h4800)));
    transact(c);
    for (int row=0;row<128;row++) for (int n=0;n<8;n++) equal(tm[0][n*128+row],integer_f32(row%2==0 ? 40 : 160),"native sparse metadata position mapping");

    // Metadata itself may share D storage. More outputs than arithmetic cores
    // force a later dot to read the metadata after an earlier dot has finished.
    c=base_command();c.m=1;c.n=16'(DOT_ENGINES+1);c.cfg.k=4;c.sparse=1;
    c.sparse_meta_col=0;c.d_col=0;
    tm[0][0]=32'h4;
    fill_one_operands(c);transact(c);
    for(int n=0;n<DOT_ENGINES+1;n++) equal(tm[0][n*128],integer_f32(2),"metadata/D alias preserves every later dot");

    // Native A and D may occupy the same physical columns. All old input bits
    // must be consumed before output writes overwrite this shared object.
    c=base_command();c.recipe=TC_RECIPE_NATIVE;c.m=128;c.n=8;c.cfg.k=16;
    c.a_from_tmem=1;c.a_col=0;c.d_col=0;
    c.b_desc=64'(32'h2000>>4)|(64'd8<<16)|(64'd16<<32)|(64'd1<<46);
    for(int row=0;row<128;row++)for(int w=0;w<8;w++)tm[0][w*128+row]=32'h3c003c00;
    for(int w=0;w<64;w++)sm[0][32'h2000/4+w]=32'h3c003c00;
    transact(c);
    for(int row=0;row<128;row++)for(int n=0;n<8;n++)
      equal(tm[0][n*128+row],integer_f32(16),"native A/D shared columns preserve original A");

    // Native compressed B is a 3-bit index stream, with one eight-value LUT per
    // eight-column slice. This is distinct from the CP4/CP6 unpacking operation.
    c=base_command();c.recipe=TC_RECIPE_NATIVE;c.m=128;c.n=8;c.cfg.k=32;c.lut=1;
    c.kind=TC_KIND_F8F6F4;c.cfg.a_fmt=FMT_E4M3;c.cfg.b_fmt=FMT_E4M3;
    c.a_from_tmem=1;c.a_col=64;c.b_desc=64'(32'h2000>>4)|(64'd8<<16)|(64'd16<<32)|(64'd1<<46);
    for (int row=0;row<128;row++) for (int word_id=0;word_id<8;word_id++) tm[0][(64+word_id)*128+row]=32'h38383838;
    for (int n=0;n<8;n++) for (int k=0;k<32;k++) write_smem_bits(0,32'h2000+n*16,k*3,3,64'(32'(n%2)));
    tm[0][48*128]=32'h40384038;tm[0][49*128]=32'h40384038;
    transact(c);
    for (int row=0;row<128;row++) for (int n=0;n<8;n++) equal(tm[0][n*128+row],integer_f32(n%2==0 ? 32 : 64),"native LUT B numerical mapping");

    // LayoutF leaves half of each physical quarter untouched. Poison unused
    // A lanes so a mistaken dense mapping cannot pass the numerical check.
    c=base_command();c.recipe=TC_RECIPE_NATIVE;c.m=64;c.n=8;c.cfg.k=16;
    c.a_from_tmem=1;c.a_col=64;c.b_desc=64'(32'h2000>>4)|(64'd8<<16)|(64'd16<<32)|(64'd1<<46);
    for (int word_id=0;word_id<64;word_id++) sm[0][32'h2000/4+word_id]=32'h3c003c00;
    for (int row=0;row<128;row++) for (int word_id=0;word_id<8;word_id++) begin
      tm[0][(64+word_id)*128+row]=row%32<16 ? 32'h3c003c00 : 32'h7e007e00;
      tm[0][word_id*128+row]=32'ha5a50000;
    end
    transact(c);
    for (int row=0;row<128;row++) for (int n=0;n<8;n++)
      equal(tm[0][n*128+row],row%32<16 ? integer_f32(16) : 32'ha5a50000,"native layoutF half lanes");

    // LayoutB uses both endpoints AND both N-dependent lane halves. Different
    // endpoint values distinguish M splitting, B's N split and odd coordinator.
    c.m=128;c.n=16;c.cta_pair=1;
    for (int p=0;p<2;p++) begin
      for (int row=0;row<128;row++) for (int word_id=0;word_id<8;word_id++)
        tm[p][(64+word_id)*128+row]=p==0 ? 32'h3c003c00 : 32'h40004000;
      for (int word_id=0;word_id<64;word_id++) sm[p][32'h2000/4+word_id]=p==0 ? 32'h3c003c00 : 32'h40004000;
    end
    for (int odd=0;odd<2;odd++) begin
      c.pair_local_is_odd=1'(odd);transact(c);
      for (int p=0;p<2;p++) for (int row=0;row<128;row++) for (int n=0;n<8;n++) begin
        expected_value=16*(p==0 ? 1 : 2)*(((row<64 ? 0 : 1)^odd)==0 ? 1 : 2);
        equal(tm[p][n*128+row],integer_f32(32'(expected_value)),"native layoutB endpoint/N partition");
      end
    end

    // Canonical pair dispatch really accesses both distinct endpoint memories.
    c=base_command();c.cta_pair=1;c.m=4;c.n=2;c.cfg.k=2;c.a_from_tmem=1;c.a_col=64;
    fill_one_operands(c);
    for (int p=0;p<2;p++) for (int row=0;row<2;row++) tm[p][64*128+row]=32'h3c003c00;
    before_a=areads;transact(c);
    for (int p=0;p<2;p++) for (int row=0;row<2;row++) for (int n=0;n<2;n++)
      equal(tm[p][n*128+row],integer_f32(2),"pair endpoint result");
    check(areads==before_a,"pair TMEM A no Aread");

    if (ENABLE_FP64) begin
      c=base_command();c.cfg.a_fmt=FMT_F64;c.cfg.b_fmt=FMT_F64;
      c.cfg.c_fmt=FMT_F64;c.cfg.d_fmt=FMT_F64;c.cfg.k=2;
      fill_one_operands(c);transact(c);
      equal(tm[0][0],0,"F64 low result word");equal(tm[0][128],32'h40000000,"F64 high result word");
      c.enable_input_d=1;c.cfg.c_fmt=FMT_F32;transact(c,TC_UNSUPPORTED);
    end

    // Ashift slides row1 into row0, preserving the tail for an explicit refill.
    c=base_command();c.m=128;c.n=1;c.cfg.k=1;c.ashift=1;c.a_from_tmem=1;c.a_col=64;
    c.cfg.a_fmt=FMT_TI16;c.cfg.b_fmt=FMT_TI16;c.cfg.c_fmt=FMT_S32;c.cfg.d_fmt=FMT_S32;c.cfg.ti16_decoded=1;
    for (int row=0;row<128;row++) tm[0][64*128+row]=32'(row+1);
    put_b(c,0,0,1);transact(c);
    for (int row=0;row<128;row++) begin
      equal(tm[0][row],32'(row+1),"ashift computes original A");
      equal(tm[0][64*128+row],row==127 ? 128 : 32'(row+2),"ashift full-row sliding window");
    end
    before_r=treads;before_a=areads;c.transpose_a=1;
    transact(c,TC_BAD_CMD);
    check(treads==before_r && areads==before_a,"transposed ashift rejected before reads");

    // Unknown/stale response IDs are consumed but cannot satisfy current read.
    c=base_command();fill_one_operands(c);inject_stale=1;transact(c);
    equal(tm[0][0],integer_f32(4),"stale response ignored");
    error_enable=1;error_address=c.a_addr;transact(c,TC_MEM_ERROR);
    transact(c);equal(tm[0][0],integer_f32(4),"memory fault abort then clean recovery");
    c.cfg.a_fmt=FMT_TF32;c.cfg.b_fmt=FMT_TF32;fill_one_operands(c);
    sm[0][int'(c.a_addr)/4]=32'h3f800001;
    transact(c,TC_MALU_ERROR,STATUS_BAD_ENCODING);
    fill_one_operands(c);transact(c);equal(tm[0][0],integer_f32(4),"early MALU error clean recovery");
    $display("TCGEN05_MMA_PASS commands=%0d checks=%0d cycles=%0d areads=%0d sreads=%0d treads=%0d writes=%0d beats=%0d terms=%0d max_contexts=%0d engines=%0d lanes=%0d fp64=%0d",
      commands,checks,cycles,areads,sreads,treads,twrites,beats,total_terms,max_contexts,DOT_ENGINES,LANES,int'(ENABLE_FP64));
    $finish;
  end
endmodule
