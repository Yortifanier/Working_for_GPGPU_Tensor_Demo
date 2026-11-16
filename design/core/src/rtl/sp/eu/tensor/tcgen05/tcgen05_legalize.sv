// Stateless PTX semantic-form checker. Resource ownership, live references and
// address footprints are checked by the endpoint before it dispatches a job.
// strict_isa selects Table50 instruction geometry; canonical test geometry may
// be smaller, but modifier consistency and finite object bounds still apply.
module tcgen05_legalize #(
  parameter int MAX_K = 65535,
  parameter int MAX_M = 256,
  parameter int MAX_N = 256,
  parameter bit ENABLE_FP64 = 1'b1
) (
  input tcgen05_pkg::tc_cmd_t cmd,
  input tcgen05_pkg::tc_caps_t caps,
  input logic strict_isa,
  output tcgen05_pkg::tc_status_e status,
  output tcgen05_pkg::tc_cmd_t normalized_cmd,
  output malu_pkg::malu_cfg_t effective_cfg,
  output logic [3:0] scale_count_a,
  output logic [3:0] scale_count_b
);
  import malu_pkg::*;
  import tcgen05_pkg::*;

  function automatic logic valid_desc(input logic [63:0] d);
    return !d[15] && !d[31] && d[48:46] == 3'b001 && d[60:54] == 0 &&
      (d[63:61] inside {3'd0,3'd1,3'd2,3'd4,3'd6});
  endfunction
  function automatic logic pow2(input int unsigned n);
    return n != 0 && (n & (n-1)) == 0;
  endfunction
  function automatic logic matrix_types(input tc_cmd_t c);
    if (c.cfg.c_fmt != c.cfg.d_fmt) return 1'b0;
    case (c.kind)
      TC_KIND_F16: return c.cfg.a_fmt inside {FMT_F16,FMT_BF16} &&
        c.cfg.b_fmt inside {FMT_F16,FMT_BF16} &&
        ((c.cfg.d_fmt == FMT_F32) ||
         (c.cfg.d_fmt == FMT_F16 && c.cfg.a_fmt == FMT_F16 && c.cfg.b_fmt == FMT_F16));
      TC_KIND_TF32: return c.cfg.a_fmt == FMT_TF32 && c.cfg.b_fmt == FMT_TF32 && c.cfg.d_fmt == FMT_F32;
      TC_KIND_F8F6F4: return is_low_fp(c.cfg.a_fmt) && is_low_fp(c.cfg.b_fmt) &&
        c.cfg.d_fmt inside {FMT_F16,FMT_F32};
      TC_KIND_MXF8F6F4: return is_low_fp(c.cfg.a_fmt) && is_low_fp(c.cfg.b_fmt) && c.cfg.d_fmt == FMT_F32;
      TC_KIND_MXF4,TC_KIND_MXF4NVF4: return c.cfg.a_fmt == FMT_E2M1 &&
        c.cfg.b_fmt == FMT_E2M1 && c.cfg.d_fmt == FMT_F32;
      TC_KIND_I8: return c.cfg.a_fmt inside {FMT_S8,FMT_U8} &&
        c.cfg.b_fmt inside {FMT_S8,FMT_U8} && c.cfg.d_fmt == FMT_S32;
      TC_KIND_TI16: return c.cfg.a_fmt == FMT_TI16 && c.cfg.b_fmt == FMT_TI16 && c.cfg.d_fmt == FMT_S32;
      default: return 1'b0;
    endcase
  endfunction
  function automatic logic matrix_shape(input tc_cmd_t c);
    int unsigned m,n,k,kbase;
    logic mx;
    m=int'(c.m); n=int'(c.n); k=int'(c.cfg.k);
    mx=c.kind inside {TC_KIND_MXF8F6F4,TC_KIND_MXF4,TC_KIND_MXF4NVF4};
    case (c.kind)
      TC_KIND_F16,TC_KIND_TI16: kbase=16;
      TC_KIND_TF32: kbase=8;
      TC_KIND_F8F6F4,TC_KIND_MXF8F6F4,TC_KIND_I8: kbase=32;
      TC_KIND_MXF4,TC_KIND_MXF4NVF4: kbase=64;
      default: return 1'b0;
    endcase
    if (c.sparse) kbase=kbase*2;
    if (c.ws) begin
      if (c.cta_pair || mx || !(m inside {32,64,128})) return 1'b0;
      if (!(n inside {64,128}) && !(n == 256 && !c.sparse)) return 1'b0;
      return k == kbase || (c.kind == TC_KIND_F8F6F4 && k == kbase*2);
    end
    if (c.cta_pair) begin
      if (!(m inside {128,256}) || n < 16 || n > 256 || n%16 != 0) return 1'b0;
      if (c.kind inside {TC_KIND_I8,TC_KIND_TI16} && n%32 != 0) return 1'b0;
      if (mx && c.sparse && m != 256) return 1'b0;
    end else begin
      if (mx) begin
        if (m != 128) return 1'b0;
      end else if (!(m inside {64,128})) return 1'b0;
      if (n < 8 || n > 256 || n%8 != 0) return 1'b0;
      if (c.kind == TC_KIND_I8 && n > 32 && n%16 != 0) return 1'b0;
      if (c.kind == TC_KIND_TI16 && m == 128 && n%16 != 0) return 1'b0;
    end
    if (k == kbase) return 1'b1;
    if (c.kind inside {TC_KIND_F8F6F4,TC_KIND_MXF8F6F4}) begin
      if (k != kbase*2) return 1'b0;
      // The explicit dense K1 shape is M128/group1 or M256/group2.
      if (!c.sparse && m != (c.cta_pair ? 256 : 128)) return 1'b0;
      return 1'b1;
    end
    if (c.kind inside {TC_KIND_MXF4,TC_KIND_MXF4NVF4}) begin
      if (c.sparse) return k == 192;
      if (k == 96) return !c.cta_pair || m == 256;
      if (k == 128) return c.cta_pair && m == 256;
    end
    return 1'b0;
  endfunction

  always_comb begin : p_legalize
    int unsigned num,registers,scales,scales_b,block_len;
    logic mx, native_form;
    tc_status_e result;
    tc_cmd_t c;
    c=cmd;
    result=TC_OK;
    num=int'(c.repeat_num);
    registers=1; scales=0;scales_b=0;
    block_len=c.cfg.block_size == BLOCK16 ? 16 : 32;
    mx=c.kind inside {TC_KIND_MXF8F6F4,TC_KIND_MXF4,TC_KIND_MXF4NVF4};
    native_form=strict_isa || c.recipe == TC_RECIPE_NATIVE;
    if (num == 0 && !native_form) begin num=1; c.repeat_num=1; end
    if (!caps.base && !(c.op inside {TC_CTX_INIT,TC_CTX_RELEASE})) result=TC_UNSUPPORTED;
    if (c.cta_pair && !caps.pair) result=TC_UNSUPPORTED;
    if (is_collective(c.op) && (c.participants != 32'hffffffff || c.thread_lane != 0)) result=TC_BAD_CMD;
    if (c.recipe == tc_recipe_e'(3)) result=TC_BAD_CMD;
    case (c.op)
      TC_CTX_INIT,TC_CTX_RELEASE,TC_RELINQUISH: begin end
      TC_PAIR_PREPARE,TC_PAIR_PUBLISH,TC_PAIR_ROLLBACK: result=TC_BAD_CMD;
      TC_ALLOC,TC_DEALLOC: begin
        if (int'(c.ncols) < 32 || int'(c.ncols) > 576 || c.ncols[4:0] != 0)
          result=TC_RANGE;
        if (!c.exclusive && (!pow2(int'(c.ncols)) || int'(c.ncols) > 512)) result=TC_BAD_CMD;
        if (c.exclusive && !caps.exclusive) result=TC_UNSUPPORTED;
        if (int'(c.ncols) > 512 && !caps.exclusive_576) result=TC_UNSUPPORTED;
      end
      TC_LD,TC_ST: begin
        if (!pow2(num) || num > 128) result=TC_BAD_CMD;
        case (c.move_shape)
          TC_SHAPE_32X32B,TC_SHAPE_16X64B,TC_SHAPE_16X32BX2: registers=num;
          TC_SHAPE_16X128B: begin registers=2*num; if (num > 64) result=TC_BAD_CMD; end
          TC_SHAPE_16X256B: begin registers=4*num; if (num > 32) result=TC_BAD_CMD; end
          default: result=TC_BAD_CMD;
        endcase
        if (registers > 1 && !c.rf_stream) result=TC_BAD_CMD;
        if ((c.op == TC_ST && (c.pack16 || c.ld_red || c.spcompress)) ||
            (c.op == TC_LD && c.unpack16)) result=TC_BAD_CMD;
        if (c.ld_red) begin
          if (!caps.ld_red) result=TC_UNSUPPORTED;
          if (!(c.move_shape inside {TC_SHAPE_32X32B,TC_SHAPE_16X32BX2}) || num < 2)
            result=TC_BAD_CMD;
          if (!(c.red_type inside {TC_RED_F32,TC_RED_S32,TC_RED_U32})) result=TC_BAD_CMD;
          if (c.red_type != TC_RED_F32 && (c.red_abs || c.red_nan)) result=TC_BAD_CMD;
          if (c.pack16) result=TC_BAD_CMD;
        end
        if (c.spcompress) begin
          if (!caps.spcompress) result=TC_UNSUPPORTED;
          if (c.move_shape != TC_SHAPE_32X32B || num < 4 || c.red_type != TC_RED_F32 || c.pack16)
            result=TC_BAD_CMD;
        end
        if (c.move_shape != TC_SHAPE_16X32BX2 && c.half_splitoff != 0) result=TC_BAD_CMD;
      end
      TC_WAIT_LD,TC_WAIT_ST: begin end
      TC_CP: begin
        if (!(c.move_shape inside {TC_SHAPE_4X256B,TC_SHAPE_32X128B,
            TC_SHAPE_64X128B,TC_SHAPE_128X256B,TC_SHAPE_128X128B})) begin
          // Legacy WORD32_REF columns are a separate canonical transport.
          if (c.recipe != TC_RECIPE_WORD32_REF || native_form) result=TC_BAD_CMD;
        end else if (c.move_shape == TC_SHAPE_64X128B) begin
          if (!(c.cp_multicast inside {TC_WARPX2_02_13,TC_WARPX2_01_23})) result=TC_BAD_CMD;
        end else if (c.move_shape == TC_SHAPE_32X128B) begin
          if (c.cp_multicast != TC_WARPX4) result=TC_BAD_CMD;
        end else if (c.cp_multicast != TC_MULTICAST_NONE) result=TC_BAD_CMD;
        if (!(c.cp_format inside {TC_CP_PLAIN,TC_CP_B4,TC_CP_B6})) result=TC_BAD_CMD;
        if (c.recipe == TC_RECIPE_NATIVE && !valid_desc(c.smem_desc)) result=TC_BAD_CMD;
      end
      TC_SHIFT: begin
        if (!caps.shift) result=TC_UNSUPPORTED;
        if (c.tmem_lane[4:0] != 0) result=TC_BAD_CMD;
      end
      TC_MMA: begin
        if (c.m == 0 || int'(c.m) > MAX_M || c.n == 0 || int'(c.n) > MAX_N ||
            c.cfg.k == 0 || int'(c.cfg.k) > MAX_K) result=TC_RANGE;
        if (native_form && (!matrix_shape(c) || !matrix_types(c))) result=TC_BAD_CMD;
        if (native_form && c.kind == TC_KIND_I8 && !caps.mma_i8) result=TC_UNSUPPORTED;
        if (native_form && c.kind == TC_KIND_TI16 && !caps.mma_ti16) result=TC_UNSUPPORTED;
        if (c.ws && (!caps.ws || c.cta_pair || mx)) result=TC_UNSUPPORTED;
        if (c.sparse && !caps.sparse) result=TC_UNSUPPORTED;
        if (c.cfg.block_scale_en && !caps.block_scale) result=TC_UNSUPPORTED;
        if (native_form && c.cfg.block_scale_en != mx) result=TC_BAD_CMD;
        if (native_form && c.cfg.block_scale_en &&
            (c.cfg.a_block_offset!=0 || c.cfg.b_block_offset!=0)) result=TC_BAD_CMD;
        if (c.ashift) begin
          if (!caps.ashift) result=TC_UNSUPPORTED;
          if (!c.a_from_tmem || c.transpose_a || !(c.m inside {16'd128,16'd256}) || c.ws || mx ||
              c.collector_a inside {TC_COLLECT_FILL,TC_COLLECT_USE}) result=TC_BAD_CMD;
        end
        if (!c.ws && c.collector_b != TC_COLLECT_DISCARD && !caps.collector_b)
          result=TC_UNSUPPORTED;
        if (!c.ws && c.collector_b_id != 0) result=TC_BAD_CMD;
        if (c.ws && (c.collector_a != TC_COLLECT_DISCARD || c.ashift || c.lut)) result=TC_BAD_CMD;
        if (!c.ws && c.zero_column_mask_desc != 0) result=TC_BAD_CMD;
        if (c.cfg.block_scale_en && c.disable_d_lanes != 0) result=TC_BAD_CMD;
        if (c.cfg.c_scale_shift != 0 &&
            (c.ws || !(c.kind inside {TC_KIND_F16,TC_KIND_TF32}))) result=TC_BAD_CMD;
        if (native_form && c.cfg.c_scale_shift != 0 && !caps.scale_input_d) result=TC_UNSUPPORTED;
        if (native_form && c.kind == TC_KIND_I8 && (c.negate_a || c.negate_b)) result=TC_BAD_CMD;
        if (native_form && c.kind inside {TC_KIND_MXF4,TC_KIND_MXF4NVF4} &&
            (c.transpose_a || c.transpose_b)) result=TC_BAD_CMD;
        if (c.kind inside {TC_KIND_F8F6F4,TC_KIND_MXF8F6F4} &&
            ((!c.sparse && c.cfg.k == 64) || (c.sparse && c.cfg.k == 128))) begin
          if (!caps.large_k_f8 && native_form) result=TC_UNSUPPORTED;
          if (!c.sparse && c.kind == TC_KIND_F8F6F4 && native_form &&
              (!(c.cfg.a_fmt inside {FMT_E4M3,FMT_E5M2}) ||
               !(c.cfg.b_fmt inside {FMT_E4M3,FMT_E5M2}))) result=TC_BAD_CMD;
          if ((c.transpose_a && !(c.cfg.a_fmt inside {FMT_E4M3,FMT_E5M2})) ||
              (c.transpose_b && !(c.cfg.b_fmt inside {FMT_E4M3,FMT_E5M2}))) result=TC_BAD_CMD;
        end
        if (c.kind inside {TC_KIND_MXF4,TC_KIND_MXF4NVF4} && native_form) begin
          if (c.cfg.k == 96 && !caps.k96) result=TC_UNSUPPORTED;
          if ((c.cfg.k == 128 && !c.sparse || c.cfg.k == 192 && c.sparse) &&
              !caps.large_k_f4) result=TC_UNSUPPORTED;
        end
        if (c.lut) begin
          if (!caps.lut) result=TC_UNSUPPORTED;
          if (!(c.kind inside {TC_KIND_F8F6F4,TC_KIND_MXF8F6F4}) ||
              c.cfg.b_fmt != FMT_E4M3 || c.transpose_b || c.ws ||
              c.lut_col[0] || (!c.cta_pair && c.m == 64) ||
              (c.cta_pair && c.m == 128)) result=TC_BAD_CMD;
          if (c.kind == TC_KIND_MXF8F6F4 &&
              !(c.scale_mode inside {TC_SCALE_DEFAULT,TC_SCALE_BLOCK32})) result=TC_BAD_CMD;
        end
        if (c.cfg.block_scale_en) begin
          if (native_form) begin
            if (c.scale_mode inside {TC_SCALE_VEC1,TC_SCALE_VEC2,TC_SCALE_VEC4} && !caps.scale_vec_legacy)
              result=TC_UNSUPPORTED;
            if (c.scale_mode inside {TC_SCALE_BLOCK16,TC_SCALE_BLOCK32} && !caps.block_qualifier)
              result=TC_UNSUPPORTED;
            case (c.scale_mode)
              TC_SCALE_DEFAULT: begin
                if (c.kind == TC_KIND_MXF4NVF4) result=TC_BAD_CMD;
                scales=c.kind == TC_KIND_MXF8F6F4 ? 1 : 2;
                c.cfg.block_size=BLOCK32;
              end
              TC_SCALE_VEC1: begin scales=1;c.cfg.block_size=BLOCK32; if (c.kind != TC_KIND_MXF8F6F4) result=TC_BAD_CMD; end
              TC_SCALE_VEC2: begin scales=2;c.cfg.block_size=BLOCK32; if (!(c.kind inside {TC_KIND_MXF4,TC_KIND_MXF4NVF4})) result=TC_BAD_CMD; end
              TC_SCALE_VEC4: begin scales=4; c.cfg.block_size=BLOCK16; if (c.kind != TC_KIND_MXF4NVF4) result=TC_BAD_CMD; end
              TC_SCALE_BLOCK16: begin
                c.cfg.block_size=BLOCK16;
                scales=c.cfg.k == 96 ? 6 : c.cfg.k == 128 ? 8 : 4;
                if (c.kind != TC_KIND_MXF4NVF4) result=TC_BAD_CMD;
              end
              TC_SCALE_BLOCK32: begin
                c.cfg.block_size=BLOCK32;
                scales=c.kind == TC_KIND_MXF8F6F4 ? 1 : c.cfg.k == 96 ? 3 : c.cfg.k == 128 ? 4 : 2;
              end
              default: result=TC_BAD_CMD;
            endcase
          end else begin
            scales=(int'(c.cfg.k)+int'(c.cfg.a_block_offset)+block_len-1)/block_len;
          end
          scales_b=native_form ? scales :
            (int'(c.cfg.k)+int'(c.cfg.b_block_offset)+block_len-1)/block_len;
          if (scales == 0 || scales > 15 || scales_b == 0 || scales_b > 15)
            result=TC_RANGE;
          // Scale-data IDs select byte planes, independently of element block
          // offsets. PTX9.4 PDF782-811: 2/6 vectors use IDs0/2; 4/8 use0.
          // The K96 three-vector diagrams explicitly permit every ID0..3.
          if (native_form) begin
            if (scales inside {2,6} && (c.scale_a_id[0] || c.scale_b_id[0]))
              result=TC_BAD_CMD;
            if (scales inside {4,8} && (c.scale_a_id!=0 || c.scale_b_id!=0))
              result=TC_BAD_CMD;
          end
          c.scale_count_a=4'(scales);
          c.scale_count_b=4'(scales_b);
          if (c.cfg.a_scale_fmt != c.cfg.b_scale_fmt || c.cfg.a_scale_fmt == SCALE_NONE)
            result=TC_BAD_CMD;
          if (native_form && c.kind inside {TC_KIND_MXF8F6F4,TC_KIND_MXF4} &&
              c.cfg.a_scale_fmt != SCALE_UE8M0) result=TC_BAD_CMD;
          if (c.cfg.a_scale_fmt == SCALE_UE5M3 && !caps.scale_ue5m3) result=TC_UNSUPPORTED;
          if (c.cfg.a_scale_fmt == SCALE_UE4M3 && c.cfg.block_size == BLOCK32 &&
              !caps.ue4m3_block32) result=TC_UNSUPPORTED;
        end else begin
          c.scale_count_a=0; c.scale_count_b=0;
          if (native_form && c.scale_mode != TC_SCALE_DEFAULT) result=TC_BAD_CMD;
        end
        if (cfg_status(c.cfg,MAX_K,ENABLE_FP64) != STATUS_OK) result=TC_UNSUPPORTED;
        if (c.recipe == TC_RECIPE_NATIVE &&
            ((!c.a_from_tmem && !valid_desc(c.a_desc)) || !valid_desc(c.b_desc))) result=TC_BAD_CMD;
      end
      TC_FENCE: begin end
      TC_COMMIT: begin
        if (c.barrier_addr[2:0] != 0) result=TC_BAD_CMD;
        if (c.restricted && !caps.restricted_commit) result=TC_UNSUPPORTED;
        if (c.mask_width32 && !caps.multicast32) result=TC_UNSUPPORTED;
        if (c.mask_width32 && !c.multicast) result=TC_BAD_CMD;
        if (!c.mask_width32 && c.cta_mask[31:16] != 0) result=TC_BAD_CMD;
      end
      default: result=TC_BAD_CMD;
    endcase
    status=result;
    normalized_cmd=c;
    effective_cfg=c.cfg;
    scale_count_a=c.scale_count_a;
    scale_count_b=c.scale_count_b;
  end
endmodule
