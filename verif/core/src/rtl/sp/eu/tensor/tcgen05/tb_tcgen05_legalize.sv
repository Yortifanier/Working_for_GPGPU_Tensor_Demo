module tb_tcgen05_legalize;
  import malu_pkg::*;
  import tcgen05_pkg::*;
  tc_cmd_t cmd, normalized;
  tc_caps_t caps;
  logic strict_isa;
  tc_status_e status;
  malu_cfg_t effective_cfg;
  logic [3:0] scale_count_a,scale_count_b;
  int checks=0;
  tcgen05_legalize dut(.cmd(cmd),.caps(caps),.strict_isa(strict_isa),
    .status(status),.normalized_cmd(normalized),.effective_cfg(effective_cfg),
    .scale_count_a(scale_count_a),.scale_count_b(scale_count_b));

  function automatic tc_cmd_t base(input tc_opcode_e op);
    tc_cmd_t c;
    c='0; c.op=op; c.recipe=TC_RECIPE_CANONICAL;
    c.participants=is_collective(op) ? 32'hffffffff : 1;
    c.owner_generation=1; c.kind=TC_KIND_F16; c.repeat_num=1;
    c.m=64; c.n=8; c.cfg.k=16;
    c.cfg.a_fmt=FMT_F16; c.cfg.b_fmt=FMT_F16;
    c.cfg.c_fmt=FMT_F32; c.cfg.d_fmt=FMT_F32;
    c.a_desc=64'd1<<46; c.b_desc=64'd1<<46; c.smem_desc=64'd1<<46;
    c.ncols=32;
    return c;
  endfunction
  task automatic expect_status(input tc_status_e expected,input string name);
    #1;
    if (status != expected) $fatal(1,"%s expected=%0d actual=%0d",name,expected,status);
    checks=checks+1;
  endtask
  task automatic expect_scale(input int expected,input string name);
    #1;
    if (scale_count_a != 4'(expected) || scale_count_b != 4'(expected))
      $fatal(1,"%s expected scale=%0d A=%0d B=%0d",name,expected,scale_count_a,scale_count_b);
    checks=checks+1;
  endtask
  task automatic low_kind(input tc_kind_e kind,input int k,input bit sparse);
    cmd=base(TC_MMA); cmd.kind=kind; cmd.cfg.a_fmt=FMT_E4M3; cmd.cfg.b_fmt=FMT_E4M3;
    cmd.m=128; cmd.cfg.k=16'(k); cmd.sparse=sparse;
    if (kind == TC_KIND_MXF8F6F4) begin
      cmd.cfg.block_scale_en=1;cmd.cfg.block_size=BLOCK32;
      cmd.cfg.a_scale_fmt=SCALE_UE8M0;cmd.cfg.b_scale_fmt=SCALE_UE8M0;
    end
  endtask
  initial begin
    caps='1; strict_isa=1;
    cmd=base(TC_MMA); expect_status(TC_OK,"F16 m64n8k16");
    cmd.m=128; cmd.n=256; expect_status(TC_OK,"F16 m128n256k16");
    cmd.cta_pair=1; cmd.m=256; expect_status(TC_OK,"F16 pair m256");
    cmd.n=8; expect_status(TC_BAD_CMD,"pair N minimum16");
    cmd.n=16; cmd.sparse=1; cmd.cfg.k=32; expect_status(TC_OK,"F16 pair sparse K32");
    cmd.cfg.k=16; expect_status(TC_BAD_CMD,"sparse K is logical K");
    cmd=base(TC_MMA);cmd.cfg.a_fmt=FMT_BF16;cmd.cfg.b_fmt=FMT_BF16;
    expect_status(TC_OK,"BF16 F32");
    cmd.cfg.c_fmt=FMT_F16;cmd.cfg.d_fmt=FMT_F16;expect_status(TC_BAD_CMD,"BF16 cannot D F16");
    cmd=base(TC_MMA);cmd.kind=TC_KIND_TF32;cmd.cfg.a_fmt=FMT_TF32;cmd.cfg.b_fmt=FMT_TF32;cmd.cfg.k=8;
    expect_status(TC_OK,"TF32 K8");
    cmd.sparse=1;cmd.cfg.k=16;expect_status(TC_OK,"TF32 sparse K16");
    low_kind(TC_KIND_F8F6F4,32,0);expect_status(TC_OK,"F8 K32");
    cmd.cfg.k=64;expect_status(TC_OK,"F8 large K64 M128");
    cmd.m=64;expect_status(TC_BAD_CMD,"dense large K requires M128");
    cmd.m=128;caps.large_k_f8=0;expect_status(TC_UNSUPPORTED,"large K capability independent");caps='1;
    cmd.cfg.a_fmt=FMT_E2M3;expect_status(TC_BAD_CMD,"nonMX dense K64 only FP8");
    low_kind(TC_KIND_F8F6F4,64,1);expect_status(TC_OK,"F8 sparse K64");
    low_kind(TC_KIND_MXF8F6F4,32,0);expect_status(TC_OK,"MX F8 K32");expect_scale(1,"MX vec1");
    cmd.scale_mode=TC_SCALE_VEC1;cmd.cfg.block_size=BLOCK16;
    expect_status(TC_OK,"vec1 derives its block rather than inheriting a caller default");
    if(effective_cfg.block_size!=BLOCK32)$fatal(1,"vec1 normalized block must32");checks++;
    cmd.cfg.a_block_offset=1;expect_status(TC_BAD_CMD,"native scale data ID is not an element block offset");
    cmd.cfg.a_block_offset=0;cmd.scale_mode=TC_SCALE_DEFAULT;
    cmd.cfg.k=64;expect_status(TC_OK,"MX F8 large dense K64");expect_scale(1,"Table70 MX K64 still one scale");
    cmd.cta_pair=1;cmd.m=128;expect_status(TC_BAD_CMD,"MX large pair M256");
    cmd.m=256;cmd.n=16;expect_status(TC_OK,"MX large pair M256 accepted");
    cmd.sparse=1;cmd.cfg.k=128;expect_status(TC_OK,"MX sparse logical K128");
    cmd.m=128;expect_status(TC_BAD_CMD,"MX sparse pair only M256");

    cmd=base(TC_MMA);cmd.kind=TC_KIND_I8;cmd.cfg.a_fmt=FMT_S8;cmd.cfg.b_fmt=FMT_U8;
    cmd.cfg.c_fmt=FMT_S32;cmd.cfg.d_fmt=FMT_S32;cmd.cfg.k=32;
    cmd.n=24;expect_status(TC_OK,"I8 N24");
    cmd.n=40;expect_status(TC_BAD_CMD,"I8 N40 not allowed");
    cmd.n=48;expect_status(TC_OK,"I8 N48 allowed");
    cmd.cta_pair=1;cmd.m=128;expect_status(TC_BAD_CMD,"I8 pair N48 not multiple32");
    cmd.n=64;expect_status(TC_OK,"I8 pair N64");
    caps.mma_i8=0;expect_status(TC_UNSUPPORTED,"I8 capability separate from float");caps='1;
    cmd.negate_a=1;expect_status(TC_BAD_CMD,"I8 negate forbidden");
    cmd=base(TC_MMA);cmd.kind=TC_KIND_TI16;cmd.cfg.a_fmt=FMT_TI16;cmd.cfg.b_fmt=FMT_TI16;
    cmd.cfg.c_fmt=FMT_S32;cmd.cfg.d_fmt=FMT_S32;cmd.cfg.ti16_decoded=1;
    expect_status(TC_OK,"Ti16 m64n8");
    cmd.m=128;expect_status(TC_BAD_CMD,"Ti16 m128 N must16");
    cmd.n=16;expect_status(TC_OK,"Ti16 m128n16");
    cmd.cfg.int_sat=1;expect_status(TC_UNSUPPORTED,"Ti16 saturation forbidden");

    cmd=base(TC_MMA);cmd.kind=TC_KIND_MXF4NVF4;cmd.m=128;cmd.cfg.k=64;
    cmd.cfg.a_fmt=FMT_E2M1;cmd.cfg.b_fmt=FMT_E2M1;cmd.cfg.block_scale_en=1;
    cmd.cfg.a_scale_fmt=SCALE_UE8M0;cmd.cfg.b_scale_fmt=SCALE_UE8M0;
    expect_status(TC_BAD_CMD,"NVFP4 scale mode explicit");
    cmd.scale_mode=TC_SCALE_BLOCK16;expect_status(TC_OK,"NVFP4 BLOCK16");expect_scale(4,"NVFP4 K64 block16 4");
    cmd.cfg.k=96;expect_status(TC_OK,"NVFP4 K96");expect_scale(6,"NVFP4 K96 block16 6");
    cmd.scale_mode=TC_SCALE_VEC4;expect_status(TC_OK,"NVFP4 vec4");expect_scale(4,"vec4 stays4 at K96");
    cmd.scale_mode=TC_SCALE_VEC2;cmd.cfg.block_size=BLOCK16;
    expect_status(TC_OK,"vec2 derives BLOCK32");
    if(effective_cfg.block_size!=BLOCK32)$fatal(1,"vec2 normalized block must32");checks++;
    cmd.scale_mode=TC_SCALE_BLOCK32;expect_status(TC_OK,"NVFP4 K96 block32");expect_scale(3,"NVFP4 K96 block32 3");
    cmd.cfg.a_scale_fmt=SCALE_UE4M3;cmd.cfg.b_scale_fmt=SCALE_UE4M3;
    expect_status(TC_OK,"NVFP4 UE4M3 block32");caps.ue4m3_block32=0;
    expect_status(TC_UNSUPPORTED,"UE4M3 block32 capability");caps='1;
    cmd.cfg.k=128;cmd.cta_pair=1;cmd.m=256;cmd.n=16;expect_status(TC_OK,"NVFP4 pair K128");expect_scale(4,"K128 block32 4");
    cmd.transpose_a=1;expect_status(TC_BAD_CMD,"FP4 transpose forbidden");
    // Scale byte-plane IDs follow the normalized vector length, independently
    // of AB format and BLOCK16/32. K96/count3 explicitly permits odd IDs.
    cmd.transpose_a=0;cmd.cfg.k=64;cmd.cta_pair=0;cmd.m=128;cmd.n=8;
    for(int mode=0;mode<4;mode++) begin
      cmd.scale_mode=mode==0 ? TC_SCALE_VEC2 : mode==1 ? TC_SCALE_VEC4 :
        mode==2 ? TC_SCALE_BLOCK16 : TC_SCALE_BLOCK32;
      for(int side=0;side<2;side++) for(int id=0;id<4;id++) begin
        cmd.scale_a_id=side==0 ? 2'(id) : 0;
        cmd.scale_b_id=side==1 ? 2'(id) : 0;
        expect_status((mode inside {1,2} ? id==0 : (id%2)==0) ? TC_OK : TC_BAD_CMD,
          "scale ID alignment for vec2/vec4/block16/block32");
      end
    end
    cmd.cfg.k=96;
    for(int mode=0;mode<2;mode++) begin
      cmd.scale_mode=mode==0 ? TC_SCALE_BLOCK16 : TC_SCALE_BLOCK32;
      for(int side=0;side<2;side++) for(int id=0;id<4;id++) begin
        cmd.scale_a_id=side==0 ? 2'(id) : 0;
        cmd.scale_b_id=side==1 ? 2'(id) : 0;
        expect_status(mode==1 || id%2==0 ? TC_OK : TC_BAD_CMD,"K96 six/three scale IDs");
      end
    end
    cmd.cfg.k=128;cmd.cta_pair=1;cmd.m=256;cmd.n=16;cmd.scale_mode=TC_SCALE_BLOCK16;
    for(int side=0;side<2;side++) for(int id=0;id<4;id++) begin
      cmd.scale_a_id=side==0 ? 2'(id) : 0;
      cmd.scale_b_id=side==1 ? 2'(id) : 0;
      expect_status(id==0 ? TC_OK : TC_BAD_CMD,"eight-scale ID must0");
    end
    low_kind(TC_KIND_MXF8F6F4,32,0);
    for(int id=0;id<4;id++) begin
      cmd.scale_a_id=2'(id);cmd.scale_b_id=2'(id);
      expect_status(TC_OK,"one-scale ID permits all four byte planes");
    end
    cmd=base(TC_MMA);cmd.ws=1;cmd.m=32;cmd.n=64;
    expect_status(TC_OK,"WS m32n64");cmd.cta_pair=1;expect_status(TC_UNSUPPORTED,"WS pair invalid");
    cmd.cta_pair=0;cmd.sparse=1;cmd.cfg.k=32;cmd.n=256;expect_status(TC_BAD_CMD,"WS sparse N256 invalid");
    cmd=base(TC_MMA);cmd.ashift=1;cmd.a_from_tmem=1;cmd.m=128;
    expect_status(TC_OK,"ashift TMEM M128");cmd.collector_a=TC_COLLECT_FILL;
    expect_status(TC_BAD_CMD,"ashift Afill invalid");cmd.collector_a=TC_COLLECT_LASTUSE;
    expect_status(TC_OK,"ashift Alastuse allowed");
    cmd.transpose_a=1;expect_status(TC_BAD_CMD,"ashift cannot use a transposed TMEM row recipe");
    low_kind(TC_KIND_F8F6F4,32,0);cmd.lut=1;
    expect_status(TC_OK,"LUT E4M3 M128");cmd.lut_col=1;expect_status(TC_BAD_CMD,"LUT two-column align");
    cmd.lut_col=0;cmd.transpose_b=1;expect_status(TC_BAD_CMD,"LUT B transpose invalid");

    cmd=base(TC_LD);expect_status(TC_OK,"LD 32x32 x1");
    cmd.repeat_num=128;cmd.rf_stream=1;expect_status(TC_OK,"LD x128 full fragments");
    cmd.move_shape=TC_SHAPE_16X128B;expect_status(TC_BAD_CMD,"16x128 maxrepeat64");
    cmd.repeat_num=64;expect_status(TC_OK,"16x128 repeat64");
    cmd.move_shape=TC_SHAPE_16X256B;expect_status(TC_BAD_CMD,"16x256 maxrepeat32");
    cmd.repeat_num=32;expect_status(TC_OK,"16x256 repeat32");
    cmd.move_shape=TC_SHAPE_32X32B;cmd.repeat_num=4;cmd.spcompress=1;
    expect_status(TC_OK,"spcompress x4");cmd.repeat_num=2;expect_status(TC_BAD_CMD,"spcompress minrepeat4");
    cmd.repeat_num=4;cmd.ld_red=1;expect_status(TC_OK,"red spcompress");cmd.red_type=TC_RED_S32;
    expect_status(TC_BAD_CMD,"spcompress F32 only");
    cmd=base(TC_LD);cmd.ld_red=1;expect_status(TC_BAD_CMD,"red minrepeat2");
    cmd.repeat_num=2;cmd.rf_stream=1;cmd.red_type=TC_RED_S32;expect_status(TC_OK,"integer minmax");
    cmd.red_abs=1;expect_status(TC_BAD_CMD,"integer abs invalid");
    cmd=base(TC_ST);cmd.pack16=1;expect_status(TC_BAD_CMD,"store cannot pack");
    cmd.pack16=0;cmd.unpack16=1;expect_status(TC_OK,"store unpack");
    cmd=base(TC_CP);cmd.move_shape=TC_SHAPE_64X128B;
    expect_status(TC_BAD_CMD,"cp64 mandatory warpx2");cmd.cp_multicast=TC_WARPX2_01_23;
    expect_status(TC_OK,"cp64 warpx2");cmd.move_shape=TC_SHAPE_32X128B;
    expect_status(TC_BAD_CMD,"cp32 mandatory warpx4");cmd.cp_multicast=TC_WARPX4;
    expect_status(TC_OK,"cp32 warpx4");cmd.move_shape=TC_SHAPE_128X256B;
    expect_status(TC_BAD_CMD,"cp128 forbids warpx4");
    cmd.cp_multicast=TC_MULTICAST_NONE;cmd.cp_format=TC_CP_B6;expect_status(TC_OK,"cp b6 expansion");
    cmd=base(TC_ALLOC);cmd.ncols=96;expect_status(TC_BAD_CMD,"nonexclusive power2");
    cmd.exclusive=1;expect_status(TC_OK,"exclusive96");cmd.ncols=576;expect_status(TC_OK,"exclusive576");
    caps.exclusive_576=0;expect_status(TC_UNSUPPORTED,"576 target cap");caps='1;
    cmd=base(TC_COMMIT);cmd.restricted=1;expect_status(TC_OK,"restricted commit");
    caps.restricted_commit=0;expect_status(TC_UNSUPPORTED,"restricted cap");caps='1;
    cmd.multicast=1;cmd.mask_width32=1;cmd.cta_mask=32'h80000001;
    expect_status(TC_OK,"multicast32 high bit");cmd.mask_width32=0;
    expect_status(TC_BAD_CMD,"multicast16 high bits reject");
    cmd=base(TC_PAIR_PREPARE);expect_status(TC_BAD_CMD,"internal pair operation not core instruction");
    cmd=base(TC_SHIFT);caps.shift=0;expect_status(TC_UNSUPPORTED,"SHIFT not inherited from base family");caps='1;
    cmd=base(TC_ALLOC);cmd.exclusive=1;caps.exclusive=0;
    expect_status(TC_UNSUPPORTED,"exclusive32 has independent capability");caps='1;
    cmd=base(TC_MMA);cmd.cfg.c_scale_shift=3;caps.scale_input_d=0;
    expect_status(TC_UNSUPPORTED,"scale-input-d target capability");caps='1;
    low_kind(TC_KIND_MXF8F6F4,32,0);cmd.scale_mode=TC_SCALE_VEC1;caps.scale_vec_legacy=0;
    expect_status(TC_UNSUPPORTED,"legacy scale_vec target capability");caps='1;
    cmd.scale_mode=TC_SCALE_BLOCK32;caps.block_qualifier=0;
    expect_status(TC_UNSUPPORTED,"block qualifier target capability");
    strict_isa=0;expect_status(TC_OK,"canonical ignores native qualifier syntax gate");caps='1;strict_isa=1;
    cmd=base(TC_MMA);cmd.recipe=TC_RECIPE_NATIVE;cmd.a_desc[15]=1;
    expect_status(TC_BAD_CMD,"descriptor reserved bit");
    strict_isa=0;cmd=base(TC_MMA);cmd.m=2;cmd.n=3;cmd.cfg.k=4;
    expect_status(TC_OK,"canonical small geometry distinct from ISA");
    strict_isa=1;expect_status(TC_BAD_CMD,"small geometry not native");
    strict_isa=0;low_kind(TC_KIND_MXF8F6F4,450,0);cmd.cfg.b_block_offset=31;
    expect_status(TC_RANGE,"canonical B scale count overflow rejected before narrowing");
    cmd.cfg.b_block_offset=0;expect_status(TC_OK,"canonical both scale counts fit15");
    expect_scale(15,"canonical fifteen scale vectors retained");
    $display("TCGEN05_LEGALIZE_PASS checks=%0d",checks);
    $finish;
  end
endmodule
