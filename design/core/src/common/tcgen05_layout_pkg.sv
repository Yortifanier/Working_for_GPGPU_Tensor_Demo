package tcgen05_layout_pkg;
  import malu_pkg::*;
  import tcgen05_pkg::*;

  // Address results are aligned 32-bit memory requests plus an intra-word bit
  // offset. A bad result MUST be rejected before a request reaches memory.
  function automatic tc_access_t tc_byte_access(input logic [31:0] base,
                                                input longint unsigned bit_index);
    tc_access_t a;
    longint unsigned byte_address;
    a='0;
    byte_address=64'(base)+(bit_index>>3);
    a.byte_addr=32'(byte_address)&32'hfffffffc;
    a.bit_offset=5'((64'(base[1:0])*8+bit_index)%32);
    a.bad=byte_address > 64'hffffffff;
    return a;
  endfunction

  function automatic tc_access_t tc_tmem_access(input int unsigned base_col,
                                                input int unsigned lane,
                                                input longint unsigned bit_index);
    tc_access_t a;
    longint unsigned column;
    a='0;
    column=64'(base_col)+(bit_index>>5);
    a.col=10'(column); a.lane=7'(lane); a.bit_offset=5'(bit_index%32);
    a.bad=lane >= 128 || column > 1023;
    return a;
  endfunction

  function automatic int unsigned tc_storage_bits(input malu_fmt_e fmt,
                                                   input tc_packing_e packing);
    int unsigned bits_per_element;
    bits_per_element=fmt_width(fmt);
    if (packing == TC_PACK_WORD32) return fmt == FMT_F64 ? 64 : 32;
    if (packing == TC_PACK_BYTE) return ((bits_per_element+7)/8)*8;
    return bits_per_element;
  endfunction

  function automatic tc_access_t tc_flat_tmem(input int unsigned base_col,
                                              input int unsigned base_lane,
                                              input longint unsigned word_index);
    longint unsigned linear;
    tc_access_t a;
    linear=word_index+64'(base_lane);
    a=tc_tmem_access(base_col+32'(linear/128),32'(linear%128),0);
    return a;
  endfunction

  // Table49 canonical SMEM layout and Table51 descriptor. The currently
  // address composition follows the descriptor's relative/absolute leading
  // mode, repeating-pattern origin and the public canonical swizzle layouts.
  function automatic tc_access_t tc_smem_access_one(input logic [63:0] desc,
                                                input int unsigned row,
                                                input int unsigned col_bits,
                                                input bit k_major,
                                                input int unsigned element_bits=32,
                                                input int unsigned mn_bit_adjust=0);
    tc_access_t a;
    longint signed bit_position,byte_position,lbo,swizzle_source;
    longint unsigned start,sbo,mn_bit_position;
    int unsigned swizzle,row_inner,row_outer,k_inner,k_outer;
    logic valid;
    a='0;
    start=64'(desc[14:0])<<4;
    lbo=$signed(64'(desc[30:16])<<4);
    if (desc[52]) lbo=lbo-$signed(start);
    sbo=64'(desc[45:32])<<4;
    swizzle=int'(desc[63:61]);
    valid=!desc[15] && !desc[31] && desc[48:46] == 3'b001 &&
      desc[60:54] == 0 && swizzle inside {0,1,2,4,6} &&
      element_bits != 0 && element_bits <= 32;
    if (!valid) begin a.bad=1'b1;return a;end
    bit_position=0;
    if (k_major) begin
      row_inner=row%8; row_outer=row/8;
      k_inner=col_bits%128; k_outer=col_bits/128;
      case (swizzle)
        0: bit_position=64'(row_inner)*128+64'(row_outer)*sbo*8+64'(k_outer)*lbo*8+64'(k_inner);
        6: bit_position=64'(row_inner)*256+64'(row_outer)*sbo*8+64'(k_outer)*128+64'(k_inner);
        4: bit_position=64'(row_inner)*512+64'(row_outer)*sbo*8+64'(k_outer)*128+64'(k_inner);
        2: bit_position=64'(row_inner)*1024+64'(row_outer)*sbo*8+64'(k_outer)*128+64'(k_inner);
        default: valid=1'b0; // 32B atomicity transpose is a distinct recipe.
      endcase
    end else begin
      mn_bit_position=64'(row)*64'(element_bits)+64'(mn_bit_adjust);
      row_inner=32'(mn_bit_position%128);
      row_outer=32'(mn_bit_position/128);
      k_inner=element_bits == 0 ? 0 : (col_bits/element_bits)%8;
      k_outer=element_bits == 0 ? 0 : (col_bits/element_bits)/8;
      case (swizzle)
        0: bit_position=64'(row_inner)+64'(row_outer)*sbo*8+
             64'(k_inner)*128+64'(k_outer)*lbo*8+64'(col_bits%element_bits);
        6: bit_position=64'(row_inner)+64'(row_outer%2)*128+
             64'(row_outer/2)*lbo*8+64'(k_inner)*256+64'(k_outer)*sbo*8+64'(col_bits%element_bits);
        4: bit_position=64'(row_inner)+64'(row_outer%4)*128+
             64'(row_outer/4)*lbo*8+64'(k_inner)*512+64'(k_outer)*sbo*8+64'(col_bits%element_bits);
        2: bit_position=64'(row_inner)+64'(row_outer%8)*128+
             64'(row_outer/8)*lbo*8+64'(k_inner)*1024+64'(k_outer)*sbo*8+64'(col_bits%element_bits);
        1: begin
          k_inner=element_bits == 0 ? 0 : (col_bits/element_bits)%4;
          k_outer=element_bits == 0 ? 0 : (col_bits/element_bits)/4;
          bit_position=64'(row_inner)+64'(row_outer%8)*128+
            64'(row_outer/8)*lbo*8+64'(k_inner)*512+64'(k_outer)*sbo*8+64'(col_bits%element_bits);
          if (element_bits != 32) valid=1'b0;
        end
        default: valid=1'b0;
      endcase
    end
    byte_position=$signed(start)+(bit_position>>>3);
    swizzle_source=byte_position-($signed(64'(desc[51:49]))<<7);
    // CuTe Swizzle<B,4,3>: XOR row-address bits into the 16B atom index.
    case (swizzle)
      6: byte_position=byte_position^((swizzle_source>>>3)&64'h10);
      4: byte_position=byte_position^((swizzle_source>>>3)&64'h30);
      2: byte_position=byte_position^((swizzle_source>>>3)&64'h70);
      1: byte_position=byte_position^((swizzle_source>>>2)&64'h60);
      default: begin end
    endcase
    a=tc_byte_access(32'(byte_position),64'(bit_position)&7);
    a.bad=!valid || byte_position < 0 || byte_position > 64'shffffffff;
    return a;
  endfunction

  function automatic tc_access_t tc_smem_access(input logic [63:0] desc,
                                                input int unsigned row,
                                                input int unsigned col_bits,
                                                input bit k_major,
                                                input int unsigned element_bits=32);
    tc_access_t a,next_a;
    int unsigned remaining;
    a=tc_smem_access_one(desc,row,col_bits,k_major,element_bits,0);
    if (!a.bad && int'(a.bit_offset)+element_bits > 32) begin
      remaining=32-int'(a.bit_offset);
      next_a=tc_smem_access_one(desc,row,k_major ? col_bits+remaining : col_bits,
        k_major,element_bits,k_major ? 0 : remaining);
      a.next_word_valid=1'b1;
      a.next_byte_addr=next_a.byte_addr;
      a.bad=a.bad || next_a.bad;
    end
    return a;
  endfunction

  function automatic tc_access_t tc_word_advance(input tc_cmd_t c,input tc_access_t original,
                                                 input int unsigned words,input bit is_smem);
    tc_access_t a;
    a=original;
    if (is_smem) begin
      if (words == 1 && original.next_word_valid) begin
        a.byte_addr=original.next_byte_addr;
        a.next_word_valid=1'b0;
      end else begin
        a.byte_addr=original.byte_addr+32'(words*4);
        a.bad=a.bad || 64'(original.byte_addr)+64'(words)*4 > 64'hffffffff;
      end
    end else if (c.recipe == TC_RECIPE_WORD32_REF) begin
      a=tc_flat_tmem(int'(original.col),int'(original.lane),64'(words));
      a.bit_offset=original.bit_offset; a.peer=original.peer; a.bad=a.bad || original.bad;
    end else begin
      a.col=10'(int'(original.col)+words);
      a.bad=a.bad || int'(original.col)+words > 1023;
    end
    return a;
  endfunction

  function automatic int unsigned mma_local_row(input tc_cmd_t c,input int unsigned row);
    if (c.cta_pair && c.m != 0) return row%(int'(c.m)/2);
    return row;
  endfunction
  function automatic logic mma_row_peer(input tc_cmd_t c,input int unsigned row);
    return c.cta_pair && ((row >= int'(c.m)/2) ^ c.pair_local_is_odd);
  endfunction
  function automatic logic mma_col_peer(input tc_cmd_t c,input int unsigned col);
    return c.cta_pair && ((col >= int'(c.n)/2) ^ c.pair_local_is_odd);
  endfunction
  function automatic int unsigned mma_native_lane(input tc_cmd_t c,input int unsigned row,
                                                   input int unsigned col=0);
    int unsigned local_row,columns_per_partition;
    local_row=mma_local_row(c,row);
    columns_per_partition=int'(c.n);
    if (c.cta_pair && c.m == 128 && !c.sparse) begin
      columns_per_partition=int'(c.n)/2;
      return local_row+(columns_per_partition != 0 ? col/columns_per_partition : 0)*64;
    end
    if (c.ws && c.m inside {16'd32,16'd64}) begin
      columns_per_partition=int'(c.n)/(128/int'(c.m));
      return local_row+(columns_per_partition != 0 ? col/columns_per_partition : 0)*int'(c.m);
    end
    if ((!c.cta_pair && !c.ws && c.m == 64) ||
        (c.cta_pair && c.sparse && c.m == 128))
      return (local_row/16)*32+local_row%16;
    return local_row;
  endfunction
  function automatic int unsigned mma_native_column(input tc_cmd_t c,input int unsigned col);
    int unsigned columns_per_partition;
    columns_per_partition=int'(c.n);
    if (c.cta_pair && c.m == 128 && !c.sparse) columns_per_partition=int'(c.n)/2;
    if (c.ws && c.m inside {16'd32,16'd64}) columns_per_partition=int'(c.n)/(128/int'(c.m));
    return columns_per_partition == 0 ? 0 : col%columns_per_partition;
  endfunction
  function automatic logic mma_native_shape(input tc_cmd_t c);
    if (c.cta_pair) return !c.ws && c.m inside {16'd128,16'd256};
    if (c.ws) return c.m inside {16'd32,16'd64,16'd128};
    return c.m inside {16'd64,16'd128};
  endfunction

  function automatic tc_access_t mma_a_access(input tc_cmd_t c,input int unsigned row,
                                              input int unsigned stored_k,input int unsigned output_n=0);
    tc_access_t a;
    longint unsigned index_bits,row_stride,col_stride;
    int unsigned bits_per_element,stored_length,physical_row,physical_col,rows_extent;
    bits_per_element=tc_storage_bits(c.cfg.a_fmt,c.a_packing);
    stored_length=c.sparse ? int'(c.cfg.k)/2 : int'(c.cfg.k);
    rows_extent=c.cta_pair ? int'(c.m)/2 : int'(c.m);
    physical_row=c.transpose_a ? stored_k : mma_local_row(c,row);
    physical_col=c.transpose_a ? mma_local_row(c,row) : stored_k;
    row_stride=c.a_row_stride_bits != 0 ? 64'(c.a_row_stride_bits) :
      64'(c.transpose_a ? rows_extent : stored_length)*64'(bits_per_element);
    col_stride=c.a_col_stride_bits != 0 ? 64'(c.a_col_stride_bits) : 64'(bits_per_element);
    index_bits=64'(physical_row)*row_stride+64'(physical_col)*col_stride;
    if (c.recipe == TC_RECIPE_WORD32_REF) begin
      if (c.a_from_tmem) a=tc_flat_tmem(int'(c.a_col),int'(c.a_lane),
        (64'(mma_local_row(c,row))*64'(stored_length)+64'(stored_k))*(c.cfg.a_fmt == FMT_F64 ? 2 : 1));
      else a=tc_byte_access(c.a_addr,(64'(mma_local_row(c,row))*64'(stored_length)+64'(stored_k))*(c.cfg.a_fmt == FMT_F64 ? 64 : 32));
      a.peer=mma_row_peer(c,row);return a;
    end
    if (c.recipe == TC_RECIPE_CANONICAL) begin
      if (c.a_from_tmem) begin
        a=tc_tmem_access(int'(c.a_col),int'(c.a_lane)+physical_row,64'(physical_col)*col_stride);
        a.peer=mma_row_peer(c,row);
        return a;
      end
      a=tc_byte_access(c.a_addr,index_bits);a.peer=mma_row_peer(c,row);return a;
    end
    if (c.a_from_tmem) begin
      bits_per_element=fmt_width(c.cfg.a_fmt);
      if (c.kind == TC_KIND_MXF8F6F4 && stored_length == 32 && is_low_fp(c.cfg.a_fmt)) bits_per_element=8;
      physical_row=c.transpose_a ? stored_k : row;
      physical_col=c.transpose_a ? mma_local_row(c,row) : stored_k;
      a=tc_tmem_access(int'(c.a_col),int'(c.a_lane)+mma_native_lane(c,physical_row,output_n),64'(physical_col)*64'(bits_per_element));
      a.peer=mma_row_peer(c,row);
      a.bad=a.bad || !mma_native_shape(c);
      return a;
    end
    bits_per_element=fmt_width(c.cfg.a_fmt);
    if (c.kind == TC_KIND_MXF8F6F4 && stored_length == 32 && bits_per_element < 8)
      physical_col=(stored_k/16)*128+(stored_k%16)*bits_per_element;
    else physical_col=stored_k*bits_per_element;
    a=tc_smem_access(c.a_desc,mma_local_row(c,row),physical_col,!c.transpose_a,bits_per_element);
    a.peer=mma_row_peer(c,row);
    return a;
  endfunction

  function automatic tc_access_t mma_b_access(input tc_cmd_t c,input int unsigned k,
                                              input int unsigned n);
    longint unsigned row_stride,col_stride,index_bits;
    int unsigned bits_per_element,physical_row,physical_col,local_n,n_extent;
    tc_access_t a;
    bits_per_element=tc_storage_bits(c.cfg.b_fmt,c.b_packing);
    if (c.lut && c.b_packing == TC_PACK_BITS) bits_per_element=3;
    n_extent=c.cta_pair ? int'(c.n)/2 : int'(c.n);
    local_n=c.cta_pair ? (n_extent != 0 ? n%n_extent : 0) : n;
    physical_row=c.transpose_b ? local_n : k;
    physical_col=c.transpose_b ? k : local_n;
    row_stride=c.b_row_stride_bits != 0 ? 64'(c.b_row_stride_bits) :
      64'(c.transpose_b ? int'(c.cfg.k) : n_extent)*64'(bits_per_element);
    col_stride=c.b_col_stride_bits != 0 ? 64'(c.b_col_stride_bits) : 64'(bits_per_element);
    index_bits=64'(physical_row)*row_stride+64'(physical_col)*col_stride;
    if (c.recipe == TC_RECIPE_WORD32_REF) begin
      a=tc_byte_access(c.b_addr,(64'(k)*64'(n_extent)+64'(local_n))*(c.cfg.b_fmt == FMT_F64 ? 64 : 32));
      a.peer=mma_col_peer(c,n);return a;
    end
    if (c.recipe == TC_RECIPE_CANONICAL) begin
      a=tc_byte_access(c.b_addr,index_bits);a.peer=mma_col_peer(c,n);return a;
    end
    bits_per_element=fmt_width(c.cfg.b_fmt);
    if (c.lut) begin
      // Table51 bit53 selects either24B half of the48B compressed K128 block.
      a=tc_smem_access(c.b_desc,local_n,k*3+(c.b_desc[53] ? 192 : 0),1'b1,8);
    end else begin
      if (c.kind == TC_KIND_MXF8F6F4 &&
          (c.sparse ? int'(c.cfg.k)/2 : int'(c.cfg.k)) == 32 && bits_per_element < 8)
        physical_col=(k/16)*128+(k%16)*bits_per_element;
      else physical_col=k*bits_per_element;
      a=tc_smem_access(c.b_desc,local_n,physical_col,!c.transpose_b,bits_per_element);
    end
    a.peer=mma_col_peer(c,n);
    return a;
  endfunction

  function automatic tc_access_t mma_d_access(input tc_cmd_t c,input int unsigned m,
                                              input int unsigned n);
    tc_access_t a;
    if (c.recipe == TC_RECIPE_WORD32_REF) begin
      a=tc_flat_tmem(int'(c.d_col),int'(c.d_lane),
        (64'(mma_local_row(c,m))*64'(c.n)+64'(n))*(c.cfg.d_fmt == FMT_F64 ? 2 : 1));
      a.peer=mma_row_peer(c,m);return a;
    end
    a=tc_tmem_access(int'(c.d_col),int'(c.d_lane)+
      (c.recipe == TC_RECIPE_NATIVE ? mma_native_lane(c,m,n) : mma_local_row(c,m)),
      64'(c.recipe == TC_RECIPE_NATIVE ? mma_native_column(c,n) : n)*(c.cfg.d_fmt == FMT_F64 ? 64 : 32));
    a.peer=mma_row_peer(c,m);
    if (c.recipe == TC_RECIPE_NATIVE) a.bad=a.bad || !mma_native_shape(c);
    return a;
  endfunction

  function automatic tc_access_t mma_meta_access(input tc_cmd_t c,input int unsigned m,
                                                 input int unsigned group,input int unsigned output_n=0);
    tc_access_t a;
    int unsigned row,native_lane,bit_position,ncopy;
    a=tc_tmem_access(int'(c.sparse_meta_col),int'(c.sparse_meta_lane)+mma_local_row(c,m),64'(group)*4);
    a.peer=mma_row_peer(c,m);
    if (c.recipe == TC_RECIPE_NATIVE) begin
      row=mma_local_row(c,m); ncopy=0;
      if (c.cta_pair && c.m == 128 && !c.sparse && c.n != 0) ncopy=(output_n/(int'(c.n)/2))*64;
      if (c.ws && c.m inside {16'd32,16'd64} && c.n != 0)
        ncopy=(output_n/(int'(c.n)/(128/int'(c.m))))*int'(c.m);
      if (c.kind inside {TC_KIND_F16,TC_KIND_TF32,TC_KIND_TI16}) begin
        native_lane=row%8+(row/16)*
          (((!c.ws && !c.cta_pair && c.m == 64) || (c.cta_pair && c.m == 128 && c.sparse)) ? 32 : 16)+
          ((group/4)%2)*8+ncopy;
        bit_position=(group%4)*4+((row/8)%2)*16+int'(c.sparsity_selector)*32+(group/8)*64;
      end else begin
        native_lane=mma_native_lane(c,m,output_n);
        bit_position=group*4;
      end
      a=tc_tmem_access(int'(c.sparse_meta_col),int'(c.sparse_meta_lane)+native_lane,64'(bit_position));
      a.peer=mma_row_peer(c,m);
      a.bad=a.bad || !mma_native_shape(c);
    end
    return a;
  endfunction

  function automatic tc_access_t mma_scale_a_access(input tc_cmd_t c,input int unsigned m,
                                                    input int unsigned group);
    tc_access_t a;
    int unsigned count,block_len,row,byte_index,column;
    block_len=c.cfg.block_size == BLOCK16 ? 16 : 32;
    count=c.scale_count_a != 0 ? int'(c.scale_count_a) :
      (int'(c.cfg.k)+int'(c.cfg.a_block_offset)+block_len-1)/block_len;
    if (c.recipe == TC_RECIPE_WORD32_REF) begin
      a=tc_byte_access(c.scale_a_addr,(64'(mma_local_row(c,m))*64'(count)+64'(group))*32);
      a.peer=mma_row_peer(c,m);return a;
    end
    a=tc_tmem_access(int'(c.scale_a_col),int'(c.scale_a_lane)+mma_local_row(c,m),
      (64'(c.scale_a_id)*4+64'(group))*8);
    a.peer=mma_row_peer(c,m);
    if (c.recipe == TC_RECIPE_NATIVE) begin
      row=mma_local_row(c,m); byte_index=int'(c.scale_a_id)+group;
      column=c.scale_a_layout ? byte_index/4 : row/32+(byte_index/4)*4;
      a=tc_tmem_access(int'(c.scale_a_col)+column,int'(c.scale_a_lane)+(c.scale_a_layout ? row : row%32),64'(byte_index%4)*8);
      a.peer=mma_row_peer(c,m);a.bad=a.bad || group >= count;
    end
    return a;
  endfunction

  function automatic tc_access_t mma_scale_b_access(input tc_cmd_t c,input int unsigned n,
                                                    input int unsigned group);
    tc_access_t a;
    int unsigned count,block_len,local_n,n_extent,byte_index,column;
    block_len=c.cfg.block_size == BLOCK16 ? 16 : 32;
    count=c.scale_count_b != 0 ? int'(c.scale_count_b) :
      (int'(c.cfg.k)+int'(c.cfg.b_block_offset)+block_len-1)/block_len;
    local_n=c.cta_pair && c.n != 0 ? n%(int'(c.n)/2) : n;
    if (c.recipe == TC_RECIPE_WORD32_REF) begin
      a=tc_byte_access(c.scale_b_addr,(64'(local_n)*64'(count)+64'(group))*32);
      a.peer=mma_col_peer(c,n);return a;
    end
    a=tc_tmem_access(int'(c.scale_b_col),int'(c.scale_b_lane)+local_n,
      (64'(c.scale_b_id)*4+64'(group))*8);
    a.peer=mma_col_peer(c,n);
    if (c.recipe == TC_RECIPE_NATIVE) begin
      n_extent=c.cta_pair ? int'(c.n)/2 : int'(c.n);
      byte_index=int'(c.scale_b_id)+group;
      column=local_n/32+(byte_index/4)*(n_extent <= 128 ? 4 : 8);
      a=tc_tmem_access(int'(c.scale_b_col)+column,int'(c.scale_b_lane)+local_n%32,64'(byte_index%4)*8);
      a.peer=mma_col_peer(c,n);a.bad=a.bad || group >= count;
    end
    return a;
  endfunction

  function automatic tc_access_t mma_lut_access(input tc_cmd_t c,input int unsigned n,
                                                input int unsigned index);
    tc_access_t a;
    int unsigned local_n;
    local_n=c.cta_pair && c.n != 0 ? n%(int'(c.n)/2) : n;
    a=tc_tmem_access(int'(c.lut_col),int'(c.lut_lane)+local_n/8,64'(index)*8);
    a.peer=mma_col_peer(c,n);
    a.bad=a.bad || index >= 8;
    return a;
  endfunction
endpackage
