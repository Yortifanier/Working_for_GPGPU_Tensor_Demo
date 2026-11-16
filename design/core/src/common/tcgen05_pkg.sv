package tcgen05_pkg;
  // Internal commands after the core's PTX/collective bridge, not NVIDIA binary
  // instruction encoding. PTX descriptors and canonical test objects coexist.
  import malu_pkg::*;
  localparam int TC_OWNERS = 8;
  localparam int TC_LANES = 128;
  typedef enum logic [4:0] {
    TC_CTX_INIT=0, TC_CTX_RELEASE=1, TC_ALLOC=2, TC_DEALLOC=3,
    TC_RELINQUISH=4, TC_LD=5, TC_ST=6, TC_WAIT_LD=7, TC_WAIT_ST=8,
    TC_CP=9, TC_SHIFT=10, TC_MMA=11, TC_FENCE=12, TC_COMMIT=13,
    TC_PAIR_PREPARE=14, TC_PAIR_PUBLISH=15, TC_PAIR_ROLLBACK=16,
    TC_PAIR_PIN=17,TC_PAIR_UNPIN=18,TC_PAIR_FREE_PREPARE=19,
    TC_PAIR_FREE_COMMIT=20,TC_PAIR_FREE_CANCEL=21
  } tc_opcode_e;
  typedef enum logic [1:0] {
    TC_RECIPE_NATIVE=0, TC_RECIPE_WORD32_REF=1, TC_RECIPE_CANONICAL=2
  } tc_recipe_e;
  typedef enum logic [3:0] {
    TC_OK=0, TC_BAD_CMD=1, TC_UNSUPPORTED=2, TC_BAD_OWNER=3,
    TC_BAD_ALLOC=4, TC_NO_PERMIT=5, TC_BUSY=6, TC_MEM_ERROR=7,
    TC_MALU_ERROR=8, TC_RANGE=9, TC_SEQUENCE_EXHAUSTED=10,
    TC_ORDER=11, TC_PRIOR_ERROR=12
  } tc_status_e;
  typedef enum logic [3:0] {
    TC_KIND_F16=0, TC_KIND_TF32=1, TC_KIND_F8F6F4=2, TC_KIND_MXF8F6F4=3,
    TC_KIND_I8=4, TC_KIND_MXF4=5, TC_KIND_MXF4NVF4=6, TC_KIND_TI16=7
  } tc_kind_e;
  typedef enum logic [3:0] {
    TC_SHAPE_32X32B=0, TC_SHAPE_16X64B=1, TC_SHAPE_16X128B=2,
    TC_SHAPE_16X256B=3, TC_SHAPE_16X32BX2=4, TC_SHAPE_4X256B=5,
    TC_SHAPE_32X128B=6, TC_SHAPE_64X128B=7, TC_SHAPE_128X256B=8,
    TC_SHAPE_128X128B=9
  } tc_move_shape_e;
  typedef enum logic [1:0] {TC_RED_F32=0,TC_RED_S32=1,TC_RED_U32=2} tc_red_type_e;
  typedef enum logic [1:0] {TC_CP_PLAIN=0,TC_CP_B4=1,TC_CP_B6=2} tc_cp_format_e;
  typedef enum logic [1:0] {
    TC_MULTICAST_NONE=0,TC_WARPX2_02_13=1,TC_WARPX2_01_23=2,TC_WARPX4=3
  } tc_multicast_e;
  typedef enum logic [1:0] {
    TC_COLLECT_DISCARD=0,TC_COLLECT_FILL=1,TC_COLLECT_USE=2,TC_COLLECT_LASTUSE=3
  } tc_collector_e;
  typedef enum logic [2:0] {
    TC_SCALE_DEFAULT=0,TC_SCALE_VEC1=1,TC_SCALE_VEC2=2,TC_SCALE_VEC4=3,
    TC_SCALE_BLOCK16=4,TC_SCALE_BLOCK32=5
  } tc_scale_mode_e;
  typedef enum logic [1:0] {TC_PACK_WORD32=0,TC_PACK_BITS=1,TC_PACK_BYTE=2} tc_packing_e;
  typedef struct packed {
    logic base;
    logic pair;
    logic ws;
    logic sparse;
    logic block_scale;
    logic large_k_f8;
    logic large_k_f4;
    logic k96;
    logic lut;
    logic collector_b;
    logic ashift;
    logic ld_red;
    logic spcompress;
    logic scale_ue5m3;
    logic ue4m3_block32;
    logic exclusive_576;
    logic mma_i8;
    logic mma_ti16;
    logic restricted_commit;
    logic multicast32;
    logic shift;
    logic exclusive;
    logic scale_input_d;
    logic scale_vec_legacy;
    logic block_qualifier;
  } tc_caps_t;

  typedef struct packed {
    tc_opcode_e op;
    tc_recipe_e recipe;
    logic [15:0] tag;
    logic [2:0] owner;
    logic [15:0] owner_generation;
    logic [5:0] warp;
    logic [4:0] thread_lane;
    logic [31:0] participants;
    logic cta_pair;
    logic pair_local_is_odd;
    logic exclusive;
    logic [9:0] tmem_col;
    logic [9:0] ncols;
    logic [31:0] smem_addr;
    logic [31:0] peer_smem_addr;
    tc_kind_e kind;
    tc_move_shape_e move_shape;
    logic [7:0] repeat_num;
    logic [15:0] half_splitoff;
    logic [6:0] tmem_lane;
    logic pack16;
    logic unpack16;
    logic rf_stream;
    tc_red_type_e red_type;
    logic red_max;
    logic red_abs;
    logic red_nan;
    tc_cp_format_e cp_format;
    tc_multicast_e cp_multicast;
    logic [63:0] smem_desc;
    logic [31:0] src_row_stride_bits;
    logic [31:0] src_col_stride_bits;
    // Project row-major recipe: a logical element is one 32-bit word (64-bit
    // formats use two low-word-first words). TMEM flattening uses lane=index%128,
    // column=base+index/128. B and scales are owner-relative SMEM objects.
    logic a_from_tmem;
    logic [9:0] a_col;
    logic [31:0] a_addr;
    logic [31:0] b_addr;
    logic [31:0] scale_a_addr;
    logic [31:0] scale_b_addr;
    logic [9:0] d_col;
    logic [15:0] m;
    logic [15:0] n;
    malu_cfg_t cfg;
    logic enable_input_d;
    logic [63:0] a_desc;
    logic [63:0] b_desc;
    logic a_major;
    logic b_major;
    tc_packing_e a_packing;
    tc_packing_e b_packing;
    logic [31:0] a_row_stride_bits;
    logic [31:0] a_col_stride_bits;
    logic [31:0] b_row_stride_bits;
    logic [31:0] b_col_stride_bits;
    logic [6:0] a_lane;
    logic [6:0] d_lane;
    logic negate_a;
    logic negate_b;
    logic transpose_a;
    logic transpose_b;
    logic ashift;
    tc_collector_e collector_a;
    tc_collector_e collector_b;
    logic [1:0] collector_b_id;
    logic [9:0] sparse_meta_col;
    logic [6:0] sparse_meta_lane;
    logic [1:0] sparsity_selector;
    logic sparse_version;
    logic [9:0] scale_a_col;
    logic [9:0] scale_b_col;
    logic [6:0] scale_a_lane;
    logic [6:0] scale_b_lane;
    logic [1:0] scale_a_id;
    logic [1:0] scale_b_id;
    logic scale_a_layout;
    tc_scale_mode_e scale_mode;
    logic [3:0] scale_count_a;
    logic [3:0] scale_count_b;
    logic [9:0] lut_col;
    logic [6:0] lut_lane;
    logic [255:0] disable_d_lanes;
    logic [63:0] zero_column_mask_desc;
    // Variants requiring native recipes are explicitly rejected, never no-ops.
    logic sparse;
    logic ws;
    logic ld_red;
    logic spcompress;
    logic collector;
    logic lut;
    logic restricted;
    logic fence_after;
    logic [31:0] barrier_addr;
    logic barrier_remote;
    logic [4:0] barrier_target;
    logic multicast;
    logic [31:0] cta_mask;
    logic mask_width32;
    logic [2:0] peer_owner;
    logic [15:0] peer_generation;
    logic [31:0] peer_participants;
    logic [31:0] reservation_id;
    logic alloc_exact;
    logic [31:0][31:0] data;
  } tc_cmd_t;

  typedef struct packed {
    tc_opcode_e op;
    logic [15:0] tag;
    logic [2:0] owner;
    logic [15:0] owner_generation;
    tc_status_e status;
    malu_status_e malu_status;
    logic [9:0] tmem_col;
    logic [9:0] ncols;
    logic [31:0][31:0] data;
    tc_recipe_e recipe;
    logic [31:0] return_addr;
    logic [31:0] peer_return_addr;
    logic cta_pair;
    logic [2:0] peer_owner;
    logic [15:0] peer_generation;
  } tc_rsp_t;

  typedef struct packed {
    logic live;
    logic [2:0] owner;
    logic [15:0] owner_generation;
    logic [9:0] base_col;
    logic [9:0] ncols;
    logic exclusive;
    logic provisional;
    logic [31:0] reservation_id;
    logic release_pending;
  } tc_alloc_record_t;

  typedef struct packed {
    logic write;
    logic [2:0] owner;
    logic [15:0] owner_generation;
    logic [31:0] byte_addr;
    logic [6:0] lane;
    logic [9:0] col;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic peer;
    logic smem;
    logic [63:0] txn_id;
  } tc_mem_req_t;
  typedef struct packed {
    logic [31:0] rdata;
    tc_status_e status;
    logic [63:0] txn_id;
  } tc_mem_rsp_t;
  typedef struct packed {
    logic [15:0] tag;
    logic [2:0] owner;
    logic [15:0] owner_generation;
    logic [5:0] warp;
    logic [4:0] thread_lane;
    logic [31:0] barrier_addr;
    logic restricted;
    logic [31:0] cutoff;
    tc_status_e status;
    logic multicast;
    logic [31:0] cta_mask;
    logic mask_width32;
    logic target_valid;
    logic [4:0] target_cta;
    logic [31:0] arrive_count;
  } tc_event_t;
  typedef enum logic [1:0] {TC_RF_DATA=0,TC_RF_META=1,TC_RF_RED=2} tc_rf_kind_e;
  typedef struct packed {
    logic [15:0] tag;
    logic [2:0] owner;
    logic [15:0] owner_generation;
    tc_rf_kind_e kind;
    logic [7:0] index;
    logic [31:0] mask;
    logic [31:0][31:0] data;
    logic last;
  } tc_rf_fragment_t;
  typedef struct packed {
    logic [31:0] byte_addr;
    logic [6:0] lane;
    logic [9:0] col;
    logic [4:0] bit_offset;
    logic peer;
    logic bad;
    logic next_word_valid;
    logic [31:0] next_byte_addr;
  } tc_access_t;

  function automatic tc_rsp_t response_for(input tc_cmd_t cmd,
                                           input tc_status_e status);
    tc_rsp_t result;
    result = '0;
    result.op = cmd.op;
    result.tag = cmd.tag;
    result.owner = cmd.owner;
    result.owner_generation = cmd.owner_generation;
    result.tmem_col = cmd.tmem_col;
    result.ncols = cmd.ncols;
    result.status = status;
    result.malu_status = STATUS_OK;
    result.recipe = cmd.recipe;
    result.return_addr = cmd.smem_addr;
    result.peer_return_addr = cmd.peer_smem_addr;
    result.cta_pair = cmd.cta_pair;
    result.peer_owner = cmd.peer_owner;
    result.peer_generation = cmd.peer_generation;
    return result;
  endfunction
  function automatic logic is_mcs(input tc_opcode_e op);
    return op inside {TC_MMA,TC_CP,TC_SHIFT};
  endfunction
  function automatic logic is_execution(input tc_opcode_e op);
    return op inside {TC_MMA,TC_CP,TC_SHIFT,TC_LD,TC_ST};
  endfunction
  function automatic logic is_allocator(input tc_opcode_e op);
    return op inside {TC_CTX_INIT,TC_CTX_RELEASE,TC_ALLOC,TC_DEALLOC,TC_RELINQUISH,
                      TC_PAIR_PREPARE,TC_PAIR_PUBLISH,TC_PAIR_ROLLBACK,
                      TC_PAIR_FREE_PREPARE,TC_PAIR_FREE_COMMIT,TC_PAIR_FREE_CANCEL};
  endfunction
  function automatic logic is_collective(input tc_opcode_e op);
    return op inside {TC_ALLOC,TC_DEALLOC,TC_RELINQUISH,TC_LD,TC_ST,TC_WAIT_LD,TC_WAIT_ST};
  endfunction
endpackage
