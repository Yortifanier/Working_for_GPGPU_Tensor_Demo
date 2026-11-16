module tcgen05_allocator #(
  parameter int MAX_COLS = 576,
  parameter int OWNERS = 8,
  parameter int RECORDS = 18
) (
  input logic clk,
  input logic rst_n,
  input logic cmd_valid,
  output logic cmd_ready,
  input tcgen05_pkg::tc_cmd_t cmd,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp,
  input logic [OWNERS-1:0] owner_busy,
  input logic [OWNERS-1:0] owner_fault,
  output logic [OWNERS-1:0] owner_live,
  output logic [15:0] owner_generation [OWNERS],
  output tcgen05_pkg::tc_alloc_record_t records [RECORDS]
);
  import tcgen05_pkg::*;
  localparam int CHUNKS = MAX_COLS / 32;
  localparam int RR_W = (OWNERS > 1) ? $clog2(OWNERS) : 1;

  // A blocked allocation keeps only command metadata, never a response slot or
  // a partially owned range. At most one allocation is pending per owner.
  logic [OWNERS-1:0] pending_valid;
  tc_cmd_t pending_cmd [OWNERS];
  logic [OWNERS-1:0] permit;
  logic [9:0] last_ncols [OWNERS];
  logic [RR_W-1:0] grant_rr;
  logic prefer_command;

  logic [CHUNKS-1:0] used_chunks;
  logic [OWNERS-1:0] has_allocation;
  logic any_allocation, any_exclusive;
  logic response_space;
  tc_status_e command_status;
  integer free_record;
  integer dealloc_record;
  integer reservation_record;
  integer grant_owner;
  integer grant_base;
  logic grant_valid;
  logic grant_faulted;
  logic service_grant;
  logic owner_in_range;
  logic exact_available;

  function automatic integer first_free_base(
      input logic [CHUNKS-1:0] occupied, input logic [9:0] count);
    integer result;
    integer count_chunks;
    logic fits;
    result = -1;
    count_chunks = int'(count) / 32;
    fits = 1'b0;
    for (int base = 0; base < CHUNKS; base++) begin
      fits = base + count_chunks <= CHUNKS;
      for (int c = 0; c < CHUNKS; c++)
        if (c >= base && c < base + count_chunks && occupied[c])
          fits = 1'b0;
      if (result < 0 && fits) result = base * 32;
    end
    return result;
  endfunction

  // This local reset clears ownership and queued commands. It is not an epoch
  // fence for the rest of the system: all external users must drain/cancel with
  // reset. Owner generations are protected against reuse within one reset epoch.
  initial begin
    if (MAX_COLS < 32 || MAX_COLS > 576 || (MAX_COLS % 32) != 0)
      $fatal(1, "tcgen05_allocator: MAX_COLS must be a 32-column multiple <=576");
    if (OWNERS < 1 || OWNERS > TC_OWNERS || RECORDS < 1)
      $fatal(1, "tcgen05_allocator: invalid owner/record configuration");
  end

  always_comb begin
    response_space = !rsp_valid || rsp_ready;
    service_grant = 1'b0;
    cmd_ready = 1'b0;
    used_chunks = '0;
    has_allocation = '0;
    any_allocation = 1'b0;
    any_exclusive = 1'b0;
    free_record = -1;
    dealloc_record = -1;
    reservation_record = -1;
    for (int r = 0; r < RECORDS; r++) begin
      if (records[r].live) begin
        any_allocation = 1'b1;
        any_exclusive |= records[r].exclusive;
        if (int'(records[r].owner) < OWNERS)
          has_allocation[int'(records[r].owner)] = 1'b1;
        for (int c = 0; c < CHUNKS; c++)
          if (c * 32 >= int'(records[r].base_col) &&
              c * 32 < int'(records[r].base_col) + int'(records[r].ncols))
            used_chunks[c] = 1'b1;
        if (records[r].owner == cmd.owner &&
            records[r].owner_generation == cmd.owner_generation &&
            records[r].base_col == cmd.tmem_col &&
            records[r].ncols == cmd.ncols &&
            records[r].exclusive == cmd.exclusive)
          dealloc_record = r;
        if (records[r].owner == cmd.owner &&
            records[r].owner_generation == cmd.owner_generation &&
            records[r].reservation_id == cmd.reservation_id &&
            records[r].base_col == cmd.tmem_col && records[r].ncols == cmd.ncols &&
            cmd.reservation_id != 0)
          reservation_record = r;
      end else if (free_record < 0) begin
        free_record = r;
      end
    end

    owner_in_range = int'(cmd.owner) < OWNERS;
    exact_available = free_record >= 0 && cmd.tmem_col[4:0] == 0 &&
      int'(cmd.tmem_col)+int'(cmd.ncols) <= MAX_COLS && !any_exclusive &&
      (!cmd.exclusive || !any_allocation);
    for (int c=0; c<CHUNKS; c++)
      if (c*32 >= int'(cmd.tmem_col) &&
          c*32 < int'(cmd.tmem_col)+int'(cmd.ncols) && used_chunks[c])
        exact_available = 1'b0;
    command_status = TC_OK;
    if (!is_allocator(cmd.op)) begin
      command_status = TC_BAD_CMD;
    end else if (!owner_in_range) begin
      command_status = TC_BAD_OWNER;
    end else if (is_collective(cmd.op) && cmd.participants != 32'hffff_ffff) begin
      command_status = TC_BAD_CMD;
    end else if (cmd.op == TC_CTX_INIT) begin
      if (owner_generation[int'(cmd.owner)] == 16'hffff)
        command_status = TC_SEQUENCE_EXHAUSTED;
      else if (owner_live[int'(cmd.owner)])
        command_status = TC_BUSY;
      else if (cmd.owner_generation == 0 ||
               cmd.owner_generation <= owner_generation[int'(cmd.owner)])
        command_status = TC_BAD_OWNER;
    end else if (!owner_live[int'(cmd.owner)] ||
                 cmd.owner_generation != owner_generation[int'(cmd.owner)]) begin
      command_status = TC_BAD_OWNER;
    end else begin
      case (cmd.op)
        TC_CTX_RELEASE: begin
          if (owner_busy[int'(cmd.owner)] || has_allocation[int'(cmd.owner)] ||
              pending_valid[int'(cmd.owner)]) command_status = TC_BUSY;
        end
        TC_ALLOC,TC_PAIR_PREPARE: begin
          if (owner_fault[int'(cmd.owner)]) command_status = TC_PRIOR_ERROR;
          else if (!permit[int'(cmd.owner)]) command_status = TC_NO_PERMIT;
          // Project retry diagnostic, not a PTX exception: accepting a second
          // request as BUSY prevents it holding the sole core command bus while
          // the earlier allocation needs another owner's dealloc to progress.
          else if (pending_valid[int'(cmd.owner)]) command_status = TC_BUSY;
          else if (cmd.ncols == 0 || int'(cmd.ncols) > MAX_COLS ||
                   cmd.ncols[4:0] != 0)
            command_status = TC_BAD_ALLOC;
          else if (!cmd.exclusive &&
                   !(cmd.ncols inside {10'd32,10'd64,10'd128,10'd256,10'd512}))
            command_status = TC_BAD_ALLOC;
          else if (last_ncols[int'(cmd.owner)] != 0 &&
                   cmd.ncols > last_ncols[int'(cmd.owner)])
            command_status = TC_ORDER;
          else if (cmd.op == TC_PAIR_PREPARE && cmd.reservation_id == 0)
            command_status = TC_BAD_CMD;
          else if (cmd.op == TC_PAIR_PREPARE && !exact_available)
            command_status = TC_BUSY;
        end
        TC_PAIR_PUBLISH: begin
          if (reservation_record < 0 || !records[reservation_record].provisional)
            command_status = TC_BAD_ALLOC;
          else if (owner_fault[int'(cmd.owner)]) command_status = TC_PRIOR_ERROR;
        end
        TC_PAIR_ROLLBACK: begin
          if (reservation_record < 0) command_status = TC_BAD_ALLOC;
        end
        TC_PAIR_FREE_PREPARE: begin
          if (dealloc_record < 0 || records[dealloc_record].provisional ||
              records[dealloc_record].release_pending || cmd.reservation_id == 0)
            command_status = TC_BAD_ALLOC;
          else if (owner_busy[int'(cmd.owner)]) command_status = TC_BUSY;
        end
        TC_PAIR_FREE_COMMIT,TC_PAIR_FREE_CANCEL: begin
          if (reservation_record < 0 || !records[reservation_record].release_pending)
            command_status = TC_BAD_ALLOC;
        end
        TC_DEALLOC: begin
          if (dealloc_record < 0) command_status = TC_BAD_ALLOC;
          else if (owner_busy[int'(cmd.owner)]) command_status = TC_BUSY;
        end
        TC_RELINQUISH: begin
          // Do not cancel or reorder an earlier blocked allocation. The core
          // retries this project control command after that allocation closes.
          if (pending_valid[int'(cmd.owner)]) command_status = TC_BUSY;
        end
        default: command_status = TC_BAD_CMD;
      endcase
    end

    grant_valid = 1'b0;
    grant_faulted = 1'b0;
    grant_owner = 0;
    grant_base = 0;
    // Round-robin among currently feasible requests. A waiting exclusive does
    // not retain provisional chunks and cannot block an independent dealloc.
    for (int off = 0; off < OWNERS; off++) begin
      int p;
      int candidate_base;
      p = int'(grant_rr) + off;
      if (p >= OWNERS) p = p - OWNERS;
      candidate_base = first_free_base(used_chunks, pending_cmd[p].ncols);
      if (!grant_valid && pending_valid[p]) begin
        // Fault termination must not require a free allocation record or range:
        // those resources may be the reason this request is still pending.
        if (owner_fault[p]) begin
          grant_valid = 1'b1;
          grant_faulted = 1'b1;
          grant_owner = p;
        end else if (owner_live[p] && permit[p] &&
                     pending_cmd[p].owner_generation == owner_generation[p] &&
                     free_record >= 0 && !any_exclusive &&
                     (!pending_cmd[p].exclusive || !any_allocation) &&
                     candidate_base >= 0) begin
          grant_valid = 1'b1;
          grant_owner = p;
          grant_base = candidate_base;
        end
      end
    end

    // Each transition produces at most one response. New commands and feasible
    // pending grants alternate when both can run, preventing either starvation.
    service_grant = grant_valid && response_space &&
                    (!prefer_command || !cmd_valid);
    cmd_ready = response_space && !service_grant;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      owner_live <= '0;
      permit <= '0;
      pending_valid <= '0;
      grant_rr <= '0;
      prefer_command <= 1'b1;
      rsp_valid <= 1'b0;
      rsp <= '0;
      for (int o = 0; o < OWNERS; o++) begin
        owner_generation[o] <= '0;
        last_ncols[o] <= '0;
        pending_cmd[o] <= '0;
      end
      for (int r = 0; r < RECORDS; r++) records[r] <= '0;
    end else begin
      if (rsp_valid && rsp_ready) rsp_valid <= 1'b0;
      if (service_grant) begin
        pending_valid[grant_owner] <= 1'b0;
        if (grant_faulted) begin
          rsp <= response_for(pending_cmd[grant_owner], TC_PRIOR_ERROR);
        end else begin
          records[free_record].live <= 1'b1;
          records[free_record].owner <= pending_cmd[grant_owner].owner;
          records[free_record].owner_generation <=
              pending_cmd[grant_owner].owner_generation;
          records[free_record].base_col <= 10'(grant_base);
          records[free_record].ncols <= pending_cmd[grant_owner].ncols;
          records[free_record].exclusive <= pending_cmd[grant_owner].exclusive;
          records[free_record].provisional <= 1'b0;
          records[free_record].reservation_id <= 0;
          records[free_record].release_pending <= 1'b0;
          rsp <= response_for(pending_cmd[grant_owner], TC_OK);
          rsp.tmem_col <= 10'(grant_base);
        end
        rsp_valid <= 1'b1;
        grant_rr <= (grant_owner == OWNERS-1) ? '0 : RR_W'(grant_owner + 1);
        prefer_command <= 1'b1;
      end else if (cmd_valid && cmd_ready) begin
        prefer_command <= 1'b0;
        if (command_status != TC_OK) begin
          rsp <= response_for(cmd, command_status);
          rsp_valid <= 1'b1;
        end else if (cmd.op == TC_ALLOC) begin
          pending_cmd[int'(cmd.owner)] <= cmd;
          pending_valid[int'(cmd.owner)] <= 1'b1;
          // PTX applies non-increase to allocations in CTA execution order,
          // including exclusive. Dealloc does not reset this history.
          last_ncols[int'(cmd.owner)] <= cmd.ncols;
        end else begin
          rsp <= response_for(cmd, TC_OK);
          rsp_valid <= 1'b1;
          case (cmd.op)
            TC_PAIR_PREPARE: begin
              records[free_record].live <= 1'b1;
              records[free_record].owner <= cmd.owner;
              records[free_record].owner_generation <= cmd.owner_generation;
              records[free_record].base_col <= cmd.tmem_col;
              records[free_record].ncols <= cmd.ncols;
              records[free_record].exclusive <= cmd.exclusive;
              records[free_record].provisional <= 1'b1;
              records[free_record].reservation_id <= cmd.reservation_id;
              records[free_record].release_pending <= 1'b0;
            end
            TC_PAIR_PUBLISH: begin
              records[reservation_record].provisional <= 1'b0;
              last_ncols[int'(cmd.owner)] <= cmd.ncols;
            end
            TC_PAIR_ROLLBACK: records[reservation_record] <= '0;
            TC_PAIR_FREE_PREPARE: begin
              records[dealloc_record].release_pending <= 1'b1;
              records[dealloc_record].reservation_id <= cmd.reservation_id;
            end
            TC_PAIR_FREE_COMMIT: records[reservation_record] <= '0;
            TC_PAIR_FREE_CANCEL: begin
              records[reservation_record].release_pending <= 1'b0;
              records[reservation_record].reservation_id <= 0;
            end
            TC_CTX_INIT: begin
              owner_live[int'(cmd.owner)] <= 1'b1;
              owner_generation[int'(cmd.owner)] <= cmd.owner_generation;
              permit[int'(cmd.owner)] <= 1'b1;
              last_ncols[int'(cmd.owner)] <= '0;
            end
            TC_CTX_RELEASE: begin
              owner_live[int'(cmd.owner)] <= 1'b0;
              permit[int'(cmd.owner)] <= 1'b0;
              last_ncols[int'(cmd.owner)] <= '0;
              // Keep the last generation to reject old-slot reuse.
            end
            TC_RELINQUISH: permit[int'(cmd.owner)] <= 1'b0;
            TC_DEALLOC: records[dealloc_record] <= '0;
            default: begin end
          endcase
        end
      end
    end
  end

`ifndef SYNTHESIS
  logic stalled_response;
  tc_rsp_t held_response;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stalled_response <= 1'b0;
      held_response <= '0;
    end else begin
      assert (!stalled_response || (rsp_valid && rsp == held_response));
      stalled_response <= rsp_valid && !rsp_ready;
      held_response <= rsp;
      for (int r = 0; r < RECORDS; r++) begin
        if (records[r].live) begin
          assert (int'(records[r].owner) < OWNERS);
          assert (owner_live[int'(records[r].owner)]);
          assert (records[r].owner_generation ==
                  owner_generation[int'(records[r].owner)]);
          assert (records[r].ncols != 0 && records[r].base_col[4:0] == 0 &&
                  records[r].ncols[4:0] == 0 &&
                  int'(records[r].base_col) + int'(records[r].ncols) <= MAX_COLS);
          for (int s = r+1; s < RECORDS; s++) begin
            if (records[s].live) begin
              assert (!records[r].exclusive && !records[s].exclusive);
              assert (int'(records[r].base_col) + int'(records[r].ncols) <=
                      int'(records[s].base_col) ||
                      int'(records[s].base_col) + int'(records[s].ncols) <=
                      int'(records[r].base_col));
            end
          end
        end
      end
    end
  end
`endif
endmodule
