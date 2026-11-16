// Streaming tcgen05 transfer engine. All register-vector lengths are serviced
// in bounded 128-byte fragments. Normalized canonical addressing and native
// descriptor addressing share the public layout helper; WORD32 is a legacy
// verification adapter, not NVIDIA's native packing.
module tcgen05_move #(
  parameter int COLS=576
) (
  input logic clk,rst_n,
  input logic req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_cmd_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp,
  input logic rf_in_valid,
  output logic rf_in_ready,
  input tcgen05_pkg::tc_rf_fragment_t rf_in,
  output logic rf_out_valid,
  input logic rf_out_ready,
  output tcgen05_pkg::tc_rf_fragment_t rf_out,
  output logic tm_req_valid,
  input logic tm_req_ready,
  output tcgen05_pkg::tc_mem_req_t tm_req,
  input logic tm_rsp_valid,
  output logic tm_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t tm_rsp,
  output logic smem_req_valid,
  input logic smem_req_ready,
  output tcgen05_pkg::tc_mem_req_t smem_req,
  input logic smem_rsp_valid,
  output logic smem_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t smem_rsp
);
  import tcgen05_pkg::*;
  import tcgen05_layout_pkg::*;
  typedef enum logic [5:0] {
    M_IDLE,M_CHECK,M_RESPOND,M_MEM_ISSUE,M_MEM_WAIT,
    M_LD_WORD,M_LD_CAPTURE,M_LD_EMIT,M_ST_FRAGMENT,M_ST_WORD,M_ST_NEXT,
    M_SP_SELECT,M_SP_EMIT0,M_SP_EMIT1,M_META_EMIT,M_RED_EMIT,
    M_CP_READ,M_CP_CAPTURE,M_CP_WRITE,M_CP_NEXT,
    M_SHIFT_READ,M_SHIFT_CAPTURE,M_SHIFT_WRITE,M_SHIFT_NEXT
  } state_e;
  state_e state,mem_return;
  tc_cmd_t cmd;
  tc_rsp_t response;
  tc_rf_fragment_t fragment;
  tc_mem_req_t memory_request;
  logic memory_is_smem,peer_side;
  logic [31:0] memory_data;
  logic [63:0] transaction_sequence;
  logic legacy;
  int unsigned repeats,register_count,register_index,thread_index;
  int unsigned base_lane,word_column,word_lane,pack_part;
  logic [15:0] pack_low;
  logic [31:0][31:0] store_fragment,load_fragment;
  logic [3:0][31:0][31:0] compression_group;
  logic [1:0][31:0][31:0] compressed_data;
  logic [31:0][31:0] metadata,red_acc;
  logic [31:0] red_valid;
  int unsigned select_thread,group_index;
  logic [31:0] loaded_word,red_lhs,red_rhs,red_result;
  logic [3:0][31:0] selection_values;
  logic [1:0][31:0] selection_data;
  logic [3:0] selection_indices;
  int unsigned cp_lane,cp_column,cp_source_word,cp_rows,cp_width;
  int unsigned cp_source_row,cp_dest_lane;
  logic [127:0] cp_container;
  logic [31:0] cp_expanded_word;
  int unsigned shift_row,shift_column;
  tc_access_t cp_access;
  logic [63:0] cp_source_bit_offset;

  assign req_ready=state==M_IDLE;
  assign rsp_valid=state==M_RESPOND;
  assign rsp=response;
  assign tm_req=memory_request;
  assign smem_req=memory_request;
  assign tm_req_valid=state==M_MEM_ISSUE && !memory_is_smem;
  assign smem_req_valid=state==M_MEM_ISSUE && memory_is_smem;
  assign tm_rsp_ready=state==M_MEM_WAIT && !memory_is_smem;
  assign smem_rsp_ready=state==M_MEM_WAIT && memory_is_smem;
  assign rf_in_ready=state==M_ST_FRAGMENT;
  assign rf_out_valid=state inside {M_LD_EMIT,M_SP_EMIT0,M_SP_EMIT1,M_META_EMIT,M_RED_EMIT} && cmd.rf_stream;

  tcgen05_move_math comparisons (
    .red_lhs(red_lhs),.red_rhs(red_rhs),.red_type(cmd.red_type),
    .select_max(cmd.red_max),.use_abs(cmd.red_abs),.propagate_nan(cmd.red_nan),
    .red_result(red_result),.sp_values(selection_values),
    .sp_data(selection_data),.sp_indices(selection_indices)
  );

  always_comb begin
    legacy=cmd.recipe==TC_RECIPE_WORD32_REF;
    repeats=cmd.repeat_num==0 && legacy ? 1 : int'(cmd.repeat_num);
    register_count=repeats;
    if (!legacy && cmd.move_shape==TC_SHAPE_16X128B) register_count=repeats<<1;
    if (!legacy && cmd.move_shape==TC_SHAPE_16X256B) register_count=repeats<<2;
    base_lane=legacy ? (int'(cmd.warp)&3)*32 : int'(cmd.tmem_lane);
    word_lane=base_lane+thread_index;
    word_column=register_index;
    if (!legacy) begin
      case (cmd.move_shape)
        TC_SHAPE_16X64B: begin
          word_lane=base_lane+(thread_index>>2)+((thread_index&1)<<3);
          word_column=(register_index<<1)+((thread_index>>1)&1);
        end
        TC_SHAPE_16X128B: begin
          word_lane=base_lane+(thread_index>>2)+((register_index&1)<<3);
          word_column=((register_index>>1)<<2)+(thread_index&3);
        end
        TC_SHAPE_16X256B: begin
          word_lane=base_lane+(thread_index>>2)+(((register_index>>1)&1)<<3);
          word_column=((register_index>>2)<<3)+((thread_index&3)<<1)+(register_index&1);
        end
        TC_SHAPE_16X32BX2: word_column=register_index;
        default: begin end
      endcase
    end
    if (cmd.pack16 || cmd.unpack16) word_column=(word_column<<1)+pack_part;
    if (!legacy && cmd.move_shape==TC_SHAPE_16X32BX2 && thread_index>=16)
      word_column=word_column+int'(cmd.half_splitoff);
    word_column=word_column+int'(cmd.tmem_col);
    loaded_word=cmd.pack16 ? {memory_data[15:0],pack_low} : memory_data;
    red_lhs=red_acc[thread_index]; red_rhs=loaded_word;
    for (int i=0; i<4; i++) selection_values[i]=compression_group[i][select_thread];

    cp_rows=128; cp_width=4;
    if (legacy) cp_width=int'(cmd.ncols);
    else case (cmd.move_shape)
      TC_SHAPE_4X256B: begin cp_rows=4; cp_width=8; end
      TC_SHAPE_128X256B: cp_width=8;
      default: begin end
    endcase
    cp_source_row=cp_lane;
    cp_dest_lane=int'(cmd.tmem_lane)+cp_lane;
    if (legacy) cp_dest_lane=cp_lane;
    else if (cmd.move_shape==TC_SHAPE_4X256B)
      cp_dest_lane=int'(cmd.tmem_lane)+cp_lane*32;
    else case (cmd.cp_multicast)
      TC_WARPX4: cp_source_row=cp_lane&31;
      TC_WARPX2_02_13: cp_source_row=((cp_lane>>5)&1)*32+(cp_lane&31);
      TC_WARPX2_01_23: cp_source_row=(cp_lane>>6)*32+(cp_lane&31);
      default: begin end
    endcase
    cp_source_bit_offset=0;
    if (legacy) begin
      // The old WORD32 adapter lays out each complete column contiguously.
      cp_source_bit_offset=(64'(cp_column)*128+64'(cp_source_row))*32;
    end else begin
      cp_source_bit_offset=64'(cp_source_row)*
        (cmd.src_row_stride_bits==0 ? 64'(cp_width)*32 : 64'(cmd.src_row_stride_bits));
      if (cmd.cp_format==TC_CP_PLAIN)
        cp_source_bit_offset=cp_source_bit_offset+64'(cp_column)*
          (cmd.src_col_stride_bits==0 ? 32 : 64'(cmd.src_col_stride_bits));
      else
        cp_source_bit_offset=cp_source_bit_offset+64'(cp_column>>2)*128+64'(cp_source_word)*32;
    end
    cp_access='0;
    if (cmd.recipe==TC_RECIPE_NATIVE)
      cp_access=tc_smem_access(cmd.smem_desc,cp_source_row,
        cmd.cp_format==TC_CP_PLAIN ? cp_column*32 : (cp_column>>2)*128+cp_source_word*32,1'b1);
    else cp_access=tc_byte_access(cmd.smem_addr,cp_source_bit_offset);
    cp_expanded_word=0;
    for (int i=0; i<4; i++) begin
      if (cmd.cp_format==TC_CP_B4)
        cp_expanded_word[8*i+:8]={2'b0,cp_container[4*((cp_column&3)*4+32'(i))+:4],2'b0};
      else cp_expanded_word[8*i+:8]={2'b0,cp_container[6*((cp_column&3)*4+32'(i))+:6]};
    end

    rf_out=fragment;
    rf_out.tag=cmd.tag; rf_out.owner=cmd.owner;
    rf_out.owner_generation=cmd.owner_generation;
    rf_out.mask=32'hffffffff;
    rf_out.kind=TC_RF_DATA; rf_out.index=8'(register_index);
    rf_out.data=load_fragment;
    rf_out.last=register_index+1==register_count && !cmd.ld_red;
    if (state==M_SP_EMIT0 || state==M_SP_EMIT1) begin
      rf_out.index=8'(group_index*2+(state==M_SP_EMIT1 ? 1 : 0));
      rf_out.data=compressed_data[state==M_SP_EMIT1 ? 1 : 0];
      rf_out.last=0;
    end else if (state==M_META_EMIT) begin
      rf_out.kind=TC_RF_META; rf_out.index=8'(group_index>>3);
      rf_out.data=metadata;
      rf_out.last=register_index+1==register_count && !cmd.ld_red;
    end else if (state==M_RED_EMIT) begin
      rf_out.kind=TC_RF_RED; rf_out.index=0;
      rf_out.data=red_acc; rf_out.last=1;
    end
  end

  task automatic fail(input tc_status_e reason);
    response.status<=reason;
    state<=M_RESPOND;
  endtask
  task automatic tmem_access(input logic write_access,input int unsigned lane,
                             input int unsigned column,input logic[31:0] data,
                             input logic[3:0] byte_mask,input state_e continuation);
    if (lane>=128 || column>=COLS) fail(TC_RANGE);
    else if (&transaction_sequence) fail(TC_SEQUENCE_EXHAUSTED);
    else begin
      memory_request<='0;
      memory_request.write<=write_access;
      memory_request.owner<=cmd.owner;
      memory_request.owner_generation<=cmd.owner_generation;
      memory_request.peer<=peer_side;
      memory_request.lane<=7'(lane); memory_request.col<=10'(column);
      memory_request.wdata<=data; memory_request.wstrb<=byte_mask;
      memory_request.txn_id<=transaction_sequence;
      transaction_sequence<=transaction_sequence+1;
      memory_is_smem<=0; mem_return<=continuation; state<=M_MEM_ISSUE;
    end
  endtask
  task automatic finish_move;
    if (cmd.cta_pair && !peer_side && cmd.op inside {TC_CP,TC_SHIFT}) begin
      peer_side<=1;
      cp_lane<=0; cp_column<=0; cp_source_word<=0;
      shift_row<=0; shift_column<=0;
      state<=cmd.op==TC_CP ? M_CP_READ : M_SHIFT_READ;
    end else state<=M_RESPOND;
  endtask
  task automatic next_load_group;
    if (register_index+1==register_count) begin
      if (cmd.ld_red) state<=M_RED_EMIT;
      else state<=M_RESPOND;
    end else begin
      register_index<=register_index+1; thread_index<=0; pack_part<=0;
      state<=M_LD_WORD;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state<=M_IDLE; mem_return<=M_IDLE; cmd<='0; response<='0; fragment<='0;
      memory_request<='0; memory_is_smem<=0; memory_data<=0;
      transaction_sequence<=0; peer_side<=0;
      register_index<=0; thread_index<=0; pack_part<=0; pack_low<=0;
      store_fragment<='0; load_fragment<='0; compression_group<='0;
      compressed_data<='0; metadata<='0; red_acc<='0; red_valid<=0;
      select_thread<=0; group_index<=0;
      cp_lane<=0; cp_column<=0; cp_source_word<=0; cp_container<=0;
      shift_row<=0; shift_column<=0;
    end else case (state)
      M_IDLE: if (req_valid) begin
        cmd<=req; response<=response_for(req,TC_OK); peer_side<=0;
        register_index<=0; thread_index<=0; pack_part<=0; pack_low<=0;
        store_fragment<=req.data; load_fragment<='0; compression_group<='0;
        compressed_data<='0; metadata<='0; red_acc<='0; red_valid<=0;
        select_thread<=0; group_index<=0;
        cp_lane<=0; cp_column<=0; cp_source_word<=0; cp_container<=0;
        shift_row<=0; shift_column<=0;
        state<=M_CHECK;
      end
      M_CHECK: begin
        if (cmd.op inside {TC_LD,TC_ST}) begin
          if (repeats==0 || repeats>128 || (repeats&(repeats-1))!=0 || register_count>128)
            fail(TC_BAD_CMD);
          else if (!(cmd.move_shape inside {TC_SHAPE_32X32B,TC_SHAPE_16X64B,
              TC_SHAPE_16X128B,TC_SHAPE_16X256B,TC_SHAPE_16X32BX2})) fail(TC_BAD_CMD);
          else if (!cmd.rf_stream && (!legacy || register_count!=1 || cmd.ld_red || cmd.spcompress))
            fail(TC_BAD_CMD);
          else if (cmd.spcompress && (cmd.move_shape!=TC_SHAPE_32X32B || repeats<4 ||
                    cmd.red_type!=TC_RED_F32 || cmd.pack16)) fail(TC_BAD_CMD);
          else if (cmd.ld_red && (repeats<2 ||
              !(cmd.move_shape inside {TC_SHAPE_32X32B,TC_SHAPE_16X32BX2}) || cmd.pack16)) fail(TC_BAD_CMD);
          else if ((cmd.ld_red || cmd.spcompress) &&
              !(cmd.red_type inside {TC_RED_F32,TC_RED_S32,TC_RED_U32})) fail(TC_BAD_CMD);
          else if (cmd.red_type!=TC_RED_F32 && (cmd.red_abs || cmd.red_nan)) fail(TC_BAD_CMD);
          else if (cmd.op==TC_ST && (cmd.ld_red || cmd.spcompress || cmd.pack16)) fail(TC_BAD_CMD);
          else if (cmd.op==TC_LD && cmd.unpack16) fail(TC_BAD_CMD);
          else state<=cmd.op==TC_LD ? M_LD_WORD : (cmd.rf_stream ? M_ST_FRAGMENT : M_ST_WORD);
        end else if (cmd.op==TC_CP) begin
          if (legacy && cmd.ncols==0) fail(TC_BAD_CMD);
          else if (!legacy && !(cmd.move_shape inside {TC_SHAPE_4X256B,TC_SHAPE_32X128B,
              TC_SHAPE_64X128B,TC_SHAPE_128X128B,TC_SHAPE_128X256B})) fail(TC_BAD_CMD);
          else if (!(cmd.cp_format inside {TC_CP_PLAIN,TC_CP_B4,TC_CP_B6})) fail(TC_BAD_CMD);
          else if (!legacy && cmd.move_shape==TC_SHAPE_32X128B && cmd.cp_multicast!=TC_WARPX4)
            fail(TC_BAD_CMD);
          else if (!legacy && cmd.move_shape==TC_SHAPE_64X128B &&
              !(cmd.cp_multicast inside {TC_WARPX2_02_13,TC_WARPX2_01_23})) fail(TC_BAD_CMD);
          else if (!legacy && !(cmd.move_shape inside {TC_SHAPE_32X128B,TC_SHAPE_64X128B}) &&
              cmd.cp_multicast!=TC_MULTICAST_NONE) fail(TC_BAD_CMD);
          else state<=M_CP_READ;
        end else if (cmd.op==TC_SHIFT) begin
          if ((base_lane&31)!=0) fail(TC_BAD_CMD);
          else state<=M_SHIFT_READ;
        end else fail(TC_BAD_CMD);
      end
      M_MEM_ISSUE: if (memory_is_smem ? smem_req_ready : tm_req_ready) state<=M_MEM_WAIT;
      M_MEM_WAIT: if (memory_is_smem ? smem_rsp_valid : tm_rsp_valid) begin
        if ((memory_is_smem ? smem_rsp.txn_id : tm_rsp.txn_id)!=memory_request.txn_id)
          fail(TC_MEM_ERROR);
        else if ((memory_is_smem ? smem_rsp.status : tm_rsp.status)!=TC_OK)
          fail(TC_MEM_ERROR);
        else begin
          memory_data<=memory_is_smem ? smem_rsp.rdata : tm_rsp.rdata;
          state<=mem_return;
        end
      end
      M_LD_WORD: tmem_access(0,word_lane,word_column,0,0,M_LD_CAPTURE);
      M_LD_CAPTURE: begin
        if (cmd.pack16 && pack_part==0) begin
          pack_low<=memory_data[15:0]; pack_part<=1; state<=M_LD_WORD;
        end else begin
          pack_part<=0;
          load_fragment[thread_index]<=loaded_word;
          if (cmd.spcompress) compression_group[register_index&3][thread_index]<=loaded_word;
          if (cmd.ld_red) begin
            if (!red_valid[thread_index]) begin
              red_acc[thread_index]<=cmd.red_abs && cmd.red_type==TC_RED_F32 ?
                {1'b0,loaded_word[30:0]} : loaded_word;
              red_valid[thread_index]<=1;
            end else red_acc[thread_index]<=red_result;
          end
          if (thread_index==31) begin
            thread_index<=0;
            if (cmd.spcompress && (register_index&3)==3) begin
              select_thread<=0; group_index<=register_index>>2; state<=M_SP_SELECT;
            end else if (cmd.spcompress) begin
              register_index<=register_index+1; state<=M_LD_WORD;
            end else state<=M_LD_EMIT;
          end else begin thread_index<=thread_index+1; state<=M_LD_WORD; end
        end
      end
      M_LD_EMIT: if (!cmd.rf_stream || rf_out_ready) begin
        if (!cmd.rf_stream) response.data<=load_fragment;
        next_load_group();
      end
      M_SP_SELECT: begin
        compressed_data[0][select_thread]<=selection_data[0];
        compressed_data[1][select_thread]<=selection_data[1];
        metadata[select_thread][4*(group_index&7)+:4]<=selection_indices;
        if (select_thread==31) state<=M_SP_EMIT0;
        else select_thread<=select_thread+1;
      end
      M_SP_EMIT0: if (rf_out_ready) state<=M_SP_EMIT1;
      M_SP_EMIT1: if (rf_out_ready) begin
        if ((group_index&7)==7 || register_index+1==register_count) state<=M_META_EMIT;
        else next_load_group();
      end
      M_META_EMIT: if (rf_out_ready) begin metadata<='0; next_load_group(); end
      M_RED_EMIT: if (rf_out_ready) state<=M_RESPOND;
      M_ST_FRAGMENT: if (rf_in_valid) begin
        if (rf_in.tag!=cmd.tag || rf_in.owner!=cmd.owner ||
            rf_in.owner_generation!=cmd.owner_generation || rf_in.kind!=TC_RF_DATA ||
            int'(rf_in.index)!=register_index || rf_in.mask!=32'hffffffff ||
            rf_in.last!=(register_index+1==register_count)) fail(TC_BAD_CMD);
        else begin store_fragment<=rf_in.data; thread_index<=0; pack_part<=0; state<=M_ST_WORD; end
      end
      M_ST_WORD: tmem_access(1,word_lane,word_column,
        cmd.unpack16 ? {16'b0,store_fragment[thread_index][16*pack_part+:16]} : store_fragment[thread_index],
        cmd.unpack16 ? 4'b0011 : 4'b1111,M_ST_NEXT);
      M_ST_NEXT: begin
        if (cmd.unpack16 && pack_part==0) begin pack_part<=1; state<=M_ST_WORD; end
        else begin
          pack_part<=0;
          if (thread_index==31) begin
            if (register_index+1==register_count) state<=M_RESPOND;
            else begin register_index<=register_index+1; thread_index<=0; state<=M_ST_FRAGMENT; end
          end else begin thread_index<=thread_index+1; state<=M_ST_WORD; end
        end
      end
      M_CP_READ: begin
        if (cp_access.bad || cp_access.bit_offset!=0 || cp_access.byte_addr[1:0]!=0)
          fail(TC_RANGE);
        else if (&transaction_sequence) fail(TC_SEQUENCE_EXHAUSTED);
        else begin
          memory_request<='0;
          memory_request.owner<=cmd.owner;
          memory_request.owner_generation<=cmd.owner_generation;
          memory_request.peer<=peer_side;
          memory_request.byte_addr<=cp_access.byte_addr;
          memory_request.txn_id<=transaction_sequence;
          transaction_sequence<=transaction_sequence+1;
          memory_is_smem<=1; mem_return<=M_CP_CAPTURE; state<=M_MEM_ISSUE;
        end
      end
      M_CP_CAPTURE: begin
        if (cmd.cp_format==TC_CP_PLAIN) state<=M_CP_WRITE;
        else begin
          cp_container[32*cp_source_word+:32]<=memory_data;
          if (cp_source_word==3) begin cp_source_word<=0; state<=M_CP_WRITE; end
          else begin cp_source_word<=cp_source_word+1; state<=M_CP_READ; end
        end
      end
      M_CP_WRITE: tmem_access(1,cp_dest_lane,int'(cmd.tmem_col)+cp_column,
        cmd.cp_format==TC_CP_PLAIN ? memory_data : cp_expanded_word,4'hf,M_CP_NEXT);
      M_CP_NEXT: begin
        if (cp_column+1==cp_width) begin
          cp_column<=0;
          if (cp_lane+1==cp_rows) finish_move();
          else begin cp_lane<=cp_lane+1; state<=M_CP_READ; end
        end else begin
          cp_column<=cp_column+1;
          if (cmd.cp_format!=TC_CP_PLAIN && (cp_column&3)!=3) state<=M_CP_WRITE;
          else state<=M_CP_READ;
        end
      end
      // PTX down-shift slides the active row window: row r takes old row r+1.
      // Ascending destination order never overwrites an unread source. The
      // excluded last row remains until CP.4x256b refreshes the four tails.
      M_SHIFT_READ: tmem_access(0,base_lane+shift_row+1,int'(cmd.tmem_col)+shift_column,0,0,M_SHIFT_CAPTURE);
      M_SHIFT_CAPTURE: state<=M_SHIFT_WRITE;
      M_SHIFT_WRITE: tmem_access(1,base_lane+shift_row,int'(cmd.tmem_col)+shift_column,memory_data,4'hf,M_SHIFT_NEXT);
      M_SHIFT_NEXT: begin
        if (shift_column==7) begin
          shift_column<=0;
          if (shift_row==30) finish_move();
          else begin shift_row<=shift_row+1; state<=M_SHIFT_READ; end
        end else begin shift_column<=shift_column+1; state<=M_SHIFT_READ; end
      end
      M_RESPOND: if (rsp_ready) state<=M_IDLE;
      default: fail(TC_BAD_CMD);
    endcase
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    rf_out_valid && !rf_out_ready |=> rf_out_valid && $stable(rf_out));
  assert property (@(posedge clk) disable iff (!rst_n)
    tm_req_valid && !tm_req_ready |=> tm_req_valid && $stable(tm_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    smem_req_valid && !smem_req_ready |=> smem_req_valid && $stable(smem_req));
`endif
endmodule
