module tb_tcgen05_layout;
  import malu_pkg::*;
  import tcgen05_pkg::*;
  import tcgen05_layout_pkg::*;
  int checks=0, native_outputs=0;
  bit seen[262144];

  function automatic tc_cmd_t base;
    tc_cmd_t c;
    c='0;c.op=TC_MMA;c.recipe=TC_RECIPE_NATIVE;c.m=128;c.n=128;
    c.cfg.a_fmt=FMT_F16;c.cfg.b_fmt=FMT_F16;c.cfg.c_fmt=FMT_F32;c.cfg.d_fmt=FMT_F32;c.cfg.k=16;
    c.a_packing=TC_PACK_BITS;c.b_packing=TC_PACK_BITS;
    c.a_from_tmem=1;
    c.a_col=256;c.d_col=16;c.a_addr=32'h100;c.b_addr=32'h1000;
    c.sparse_meta_col=400;c.scale_a_col=420;c.scale_b_col=440;c.lut_col=460;
    return c;
  endfunction
  function automatic logic [63:0] desc(input int unsigned start,input int unsigned lbo,
      input int unsigned sbo,input int unsigned sw,input int unsigned phase=0,input bit absolute_lbo=0);
    logic [63:0] d;
    d='0;d[14:0]=15'(start>>4);d[30:16]=15'(lbo>>4);d[45:32]=14'(sbo>>4);
    d[46]=1;d[63:61]=3'(sw);d[51:49]=3'(phase);d[52]=absolute_lbo;return d;
  endfunction
  task automatic check(input bit condition,input string why);
    if (!condition) $fatal(1,"%s",why);
    checks=checks+1;
  endtask
  task automatic taddr(input tc_access_t a,input int unsigned lane,input int unsigned column,
      input int unsigned bit_index,input bit peer,input string why);
    if (a.bad || a.lane!=7'(lane) || a.col!=10'(column) || a.bit_offset!=5'(bit_index) || a.peer!=peer)
      $fatal(1,"%s actual bad=%0d lane=%0d col=%0d bit=%0d peer=%0d expected %0d %0d %0d %0d",
        why,a.bad,a.lane,a.col,a.bit_offset,a.peer,lane,column,bit_index,peer);
    checks=checks+1;
  endtask
  task automatic saddr(input tc_access_t a,input int unsigned address,input int unsigned bit_index,input string why);
    if (a.bad || a.byte_addr!=address || a.bit_offset!=5'(bit_index))
      $fatal(1,"%s actual bad=%0d address=%h bit=%0d expected %h %0d",why,a.bad,a.byte_addr,a.bit_offset,address,bit_index);
    checks=checks+1;
  endtask

  initial begin : tests
    tc_cmd_t c;
    tc_access_t a,b;
    logic [63:0] d;
    int unsigned rows,cols,lane,column,key,local_m;
    bit target_odd,expected_peer;
    #1;
    // PTX Figures211-224. The independent reference below enumerates the seven
    // documented tile placements, then checks every output has a unique word.
    for (int layout_id=0;layout_id<7;layout_id++) begin
      for (int odd=0;odd<2;odd++) begin
        c=base();c.n=256;c.pair_local_is_odd=1'(odd);
        case (layout_id)
          0: begin c.cta_pair=1;c.m=256;end
          1: begin c.cta_pair=1;c.m=128;end
          2: begin c.cta_pair=1;c.m=128;c.sparse=1;end
          3: begin c.m=128;end
          4: begin c.ws=1;c.m=64;end
          5: begin c.m=64;end
          6: begin c.ws=1;c.m=32;end
        endcase
        rows=int'(c.m);cols=int'(c.n);foreach(seen[i]) seen[i]=0;
        for (int unsigned m=0;m<rows;m++) begin
          for (int unsigned n=0;n<cols;n++) begin
            lane=m;column=16+n;target_odd=0;local_m=m;
            case (layout_id)
              0: begin target_odd=m>=128;lane=m%128;end
              1: begin target_odd=m>=64;lane=m%64+(n>=128?64:0);column=16+n%128;end
              2: begin target_odd=m>=64;local_m=m%64;lane=(local_m/16)*32+local_m%16;end
              3: begin end
              4: begin lane=m+(n>=128?64:0);column=16+n%128;end
              5: begin lane=(m/16)*32+m%16;end
              6: begin lane=m+(n/64)*32;column=16+n%64;end
            endcase
            expected_peer=c.cta_pair && (target_odd ^ 1'(odd));
            a=mma_d_access(c,m,n);
            taddr(a,lane,column,0,expected_peer,"native A-G D placement");
            key=((expected_peer?128:0)+lane)*1024+column;
            check(!seen[key],"native layout output alias");seen[key]=1;
            native_outputs=native_outputs+1;
            if (n%64==0) begin
              b=mma_a_access(c,m,2,n);
              taddr(b,lane,257,0,expected_peer,"native A duplicate/quarter placement");
            end
          end
        end
      end
    end
    // Half-utilization alignment is an additive sixteen-lane choice.
    c=base();c.m=64;c.a_lane=16;c.d_lane=16;c.sparse_meta_lane=16;
    taddr(mma_d_access(c,63,7),127,23,0,0,"Layout F alignment16");
    taddr(mma_a_access(c,16,1,7),48,256,16,0,"Layout F A alignment16");

    // Canonical split objects: A/C/D by M half; B by N half, independent owner.
    c=base();c.recipe=TC_RECIPE_CANONICAL;c.cta_pair=1;c.m=4;c.n=6;c.cfg.k=4;
    c.a_from_tmem=1;c.a_lane=0;c.a_col=32;c.d_col=0;
    taddr(mma_a_access(c,3,2,5),1,33,0,1,"canonical peer A local row");
    taddr(mma_d_access(c,3,5),1,5,0,1,"canonical peer D full N");
    a=mma_b_access(c,2,5);saddr(a,32'h1010,0,"canonical B local N stride");check(a.peer,"B owner follows N");
    c.pair_local_is_odd=1;
    a=mma_a_access(c,3,2,5);check(!a.peer,"canonical odd issuer reverses peer");
    a=mma_b_access(c,2,0);check(a.peer,"canonical B even owner from odd issuer");
    c.cta_pair=0;c.transpose_a=1;c.a_from_tmem=0;
    saddr(mma_a_access(c,3,2,0),32'h114,16,"canonical transposed A");
    c.transpose_a=0;c.cfg.b_fmt=FMT_E4M3;c.lut=1;c.b_packing=TC_PACK_BITS;
    saddr(mma_b_access(c,2,5),32'h1004,19,"canonical 3-bit LUT indices");
    c.lut=0;c.ws=1;c.m=32;c.n=8;c.b_packing=TC_PACK_WORD32;
    saddr(mma_b_access(c,0,8),32'h1020,0,"WS physical B shift may exceed N");

    c=base();c.recipe=TC_RECIPE_WORD32_REF;c.cfg.a_fmt=FMT_F64;c.cfg.d_fmt=FMT_F64;
    c.a_from_tmem=1;c.a_lane=127;c.a_col=4;c.d_col=4;c.cfg.k=2;c.n=2;
    taddr(mma_a_access(c,1,0,0),3,5,0,0,"WORD32 F64 flatten lane carry");
    taddr(mma_d_access(c,1,1),6,4,0,0,"WORD32 D F64 stride");
    a=tc_flat_tmem(4,127,0);b=tc_word_advance(c,a,1,0);
    taddr(b,0,5,0,0,"WORD32 second F64 word lane carry");

    // Literal address vectors from PTX shared-layout examples (Table49).
    d=desc(0,256,128,0);
    saddr(tc_smem_access(d,0,0,1,32),0,0,"K-major no-swizzle origin");
    saddr(tc_smem_access(d,7,96,1,32),124,0,"K-major first8rows");
    saddr(tc_smem_access(d,8,0,1,32),128,0,"K-major SBO");
    saddr(tc_smem_access(d,0,128,1,32),256,0,"K-major LBO");
    d=desc(0,16,256,6);
    saddr(tc_smem_access(d,4,0,1,32),144,0,"K-major32B row xor");
    saddr(tc_smem_access(d,0,128,1,32),16,0,"K-major32B leading atom");
    d=desc(0,256,512,6);
    saddr(tc_smem_access(d,8,0,0,16),16,0,"MN32B inner row atom");
    saddr(tc_smem_access(d,16,0,0,16),256,0,"MN32B LBO");
    saddr(tc_smem_access(d,0,128,0,16),512,0,"MN32B SBO");
    saddr(tc_smem_access(d,0,64,0,16),144,0,"MN32B xor");
    saddr(tc_smem_access(d,8,64,0,16),128,0,"MN32B xor inverse neighbor");
    d=desc(0,512,1024,4);
    saddr(tc_smem_access(d,8,0,0,16),16,0,"MN64B inner row");
    saddr(tc_smem_access(d,32,0,0,16),512,0,"MN64B LBO");
    saddr(tc_smem_access(d,0,64,0,16),288,0,"MN64B xor");
    d=desc(0,1024,2048,2);
    saddr(tc_smem_access(d,4,0,0,32),16,0,"MN128B inner row");
    saddr(tc_smem_access(d,0,32,0,32),144,0,"MN128B16atom xor");
    d=desc(0,1024,2048,1);
    saddr(tc_smem_access(d,0,64,0,32),160,0,"MN128B32atom xor");
    saddr(tc_smem_access(d,8,64,0,32),128,0,"MN128B32atom neighbor");
    a=tc_smem_access(d,0,0,1,32);check(a.bad,"32B atomicity only MN-major");
    d=desc(32'h1000,32'h800,128,0,0,1);
    saddr(tc_smem_access(d,0,128,1,32),32'h800,0,"absolute leading before base uses signed offset");
    d=desc(128,1024,2048,2,1,0);
    saddr(tc_smem_access(d,0,0,1,32),128,0,"pattern origin phase");
    saddr(tc_smem_access(d,1,0,1,32),272,0,"phase relocation preserves relative xor");
    d=desc(0,256,128,0);
    a=tc_smem_access(d,0,126,1,6);saddr(a,12,30,"native FP6 split at bit126");
    check(a.next_word_valid && a.next_byte_addr==256,"next FP6 fragment follows LBO not byte+4");
    c=base();b=tc_word_advance(c,a,1,1);saddr(b,256,30,"SMEM next-word redirect");
    d[15]=1;a=tc_smem_access(d,0,0,1,16);check(a.bad,"reserved descriptor bit rejected");
    d=desc(0,16,16,3);a=tc_smem_access(d,0,0,1,16);check(a.bad,"reserved swizzle code rejected");
    a=tc_byte_access(32'hfffffff0,256);check(a.bad,"byte-address overflow rejected");
    a=tc_tmem_access(1023,127,32);check(a.bad,"TMEM column carry overflow rejected");
    a=tc_tmem_access(0,128,0);check(a.bad,"TMEM row overflow rejected");
    d=desc(0,16,65536,0);a=tc_smem_access(d,32'hffffffff,0,1,32);
    check(a.bad,"SMEM extent arithmetic does not truncate before range check");

    // Metadata point labels from PTX Figures286-291 / official fragment layout.
    c=base();c.sparse=1;c.kind=TC_KIND_F16;c.cfg.k=32;
    taddr(mma_meta_access(c,8,0),0,400,16,0,"FP16 meta row8 low group");
    taddr(mma_meta_access(c,0,4),8,400,0,0,"FP16 meta high K group");
    taddr(mma_meta_access(c,16,7),24,400,12,0,"FP16 meta row16 high group");
    c.sparsity_selector=1;taddr(mma_meta_access(c,8,0),0,401,16,0,"metadata selector sub-column");
    c.sparsity_selector=0;c.m=64;taddr(mma_meta_access(c,16,0),32,400,0,0,"half-util metadata row16");
    c=base();c.sparse=1;c.kind=TC_KIND_F8F6F4;c.cfg.k=64;
    taddr(mma_meta_access(c,33,9),33,401,4,0,"lowp metadata contiguous nibbles");
    c=base();c.ws=1;c.sparse=1;c.m=32;c.n=256;
    taddr(mma_meta_access(c,0,0,192),96,400,0,0,"WS metadata replicated quarter");

    // Scale points from Figures237-278: ID is a byte offset, and overflow
    // planes are separated by4(A32) or4/8(B) columns, not adjacent row tiles.
    c=base();c.scale_count_a=2;c.scale_a_id=2;
    taddr(mma_scale_a_access(c,33,1),1,421,24,0,"SFA32 ID2 SF1");
    c.scale_a_layout=1;taddr(mma_scale_a_access(c,33,1),33,420,24,0,"SFA128 ID2 SF1");
    c.scale_a_layout=0;c.scale_count_a=6;
    taddr(mma_scale_a_access(c,96,5),0,427,24,0,"SFA overflow plane");
    c.scale_count_a=3;c.scale_a_id=3;
    taddr(mma_scale_a_access(c,0,1),0,424,0,0,"SFA ID3 crosses column plane");
    c.scale_count_b=6;c.scale_b_id=2;c.n=256;
    taddr(mma_scale_b_access(c,224,5),0,455,24,0,"SFB N256 overflow plane");
    c.n=128;c.scale_count_b=3;c.scale_b_id=3;
    taddr(mma_scale_b_access(c,96,2),0,447,8,0,"SFB N128 overflow plane");
    c.n=256;c.cta_pair=1;c.scale_b_id=0;
    taddr(mma_scale_b_access(c,160,2),0,441,16,1,"SFB pair N split");
    c=base();taddr(mma_lut_access(c,63,7),7,461,24,0,"LUT eight values across two words");
    c.cta_pair=1;c.n=256;taddr(mma_lut_access(c,136,0),1,460,0,1,"LUT pair N split");
    a=mma_lut_access(c,0,8);check(a.bad,"LUT index range");
    $display("TCGEN05_LAYOUT_PASS checks=%0d native_outputs=%0d layouts=7",checks,native_outputs);
    $finish;
  end
endmodule
