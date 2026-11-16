module tb_tcgen05_allocator;
  timeunit 1ns;
  timeprecision 1ps;
  import malu_pkg::*;
  import tcgen05_pkg::*;
  parameter int MAX_COLS = 576;
  parameter int OWNERS = 8;
  parameter int RECORDS = 18;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */
  logic cmd_valid, cmd_ready, rsp_valid, rsp_ready;
  tc_cmd_t cmd;
  tc_rsp_t rsp;
  logic [OWNERS-1:0] owner_busy, owner_fault, owner_live;
  logic [15:0] owner_generation [OWNERS];
  tc_alloc_record_t records [RECORDS];
  tc_alloc_record_t reference_records [RECORDS];
  logic [OWNERS-1:0] reference_live;
  logic [15:0] reference_generation [OWNERS];
  integer next_tag = 1;
  integer checked = 0;
  integer cycles = 0;
  integer seed = 1907;
  integer bases [RECORDS];
  // One reusable SV transaction worker keeps the driver/checker implementation
  // in one process instead of cloning the complete timed task at every call.
  logic job_valid = 1'b0;
  logic job_done = 1'b0;
  tc_cmd_t job_request;
  tc_status_e job_expected;
  tc_rsp_t job_response;

  tcgen05_allocator #(.MAX_COLS(MAX_COLS), .OWNERS(OWNERS), .RECORDS(RECORDS)) dut(
    .clk, .rst_n, .cmd_valid, .cmd_ready, .cmd, .rsp_valid, .rsp_ready,
    .rsp, .owner_busy, .owner_fault, .owner_live, .owner_generation, .records
  );

  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (cycles > 200000) $fatal(1, "Allocator test global watchdog");
  end

  function automatic tc_cmd_t request(input tc_opcode_e op, input int owner,
      input int generation, input int ncols = 0, input bit exclusive = 0,
      input int base_col = 0);
    tc_cmd_t result;
    result = '0;
    result.op = op;
    result.recipe = TC_RECIPE_WORD32_REF;
    result.owner = 3'(owner);
    result.owner_generation = 16'(generation);
    result.ncols = 10'(ncols);
    result.tmem_col = 10'(base_col);
    result.exclusive = exclusive;
    result.participants = 32'hffff_ffff;
    return result;
  endfunction

  task automatic clear_reference;
    reference_live = '0;
    for (int o = 0; o < OWNERS; o++) reference_generation[o] = '0;
    for (int r = 0; r < RECORDS; r++) reference_records[r] = '0;
  endtask

  // This model compares the unordered allocation set, not the DUT's choice of
  // free record index or its first-fit/round-robin algorithm.
  task automatic check_views;
    integer match_count, actual_count, expected_count;
    if (owner_live !== reference_live) $fatal(1, "Owner live mismatch");
    for (int o = 0; o < OWNERS; o++)
      if (owner_generation[o] !== reference_generation[o])
        $fatal(1, "Owner generation mismatch owner=%0d", o);
    actual_count = 0;
    expected_count = 0;
    for (int r = 0; r < RECORDS; r++) begin
      if (reference_records[r].live) expected_count++;
      if (records[r].live) begin
        actual_count++;
        match_count = 0;
        for (int m = 0; m < RECORDS; m++)
          if (reference_records[m].live && reference_records[m] === records[r])
            match_count++;
        if (match_count != 1) $fatal(1, "Unexpected/duplicate allocation r=%0d", r);
      end
    end
    if (actual_count != expected_count)
      $fatal(1, "Record count got=%0d expected=%0d", actual_count, expected_count);
  endtask

  task automatic send(input tc_cmd_t requested, output tc_cmd_t sent);
    integer guard_count;
    sent = requested;
    sent.tag = 16'(next_tag);
    next_tag++;
    @(negedge clk);
    cmd = sent;
    cmd_valid = 1'b1;
    guard_count = 0;
    do begin
      @(posedge clk);
      guard_count++;
      if (guard_count > 1000) $fatal(1, "Command timeout tag=%0d", sent.tag);
    end while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 1'b0;
  endtask

  task automatic update_reference(input tc_cmd_t sent, input tc_rsp_t received);
    integer chosen;
    chosen = -1;
    if (received.status == TC_OK) begin
      case (sent.op)
        TC_CTX_INIT: begin
          reference_live[sent.owner] = 1'b1;
          reference_generation[sent.owner] = sent.owner_generation;
        end
        TC_CTX_RELEASE: reference_live[sent.owner] = 1'b0;
        TC_ALLOC: begin
          if (int'(received.tmem_col) + int'(sent.ncols) > MAX_COLS ||
              received.tmem_col[4:0] != 0)
            $fatal(1, "Allocated range invalid");
          for (int r = 0; r < RECORDS; r++) begin
            if (!reference_records[r].live && chosen < 0) chosen = r;
            if (reference_records[r].live) begin
              if (sent.exclusive || reference_records[r].exclusive)
                $fatal(1, "Exclusive allocation coexists with another allocation");
              if (!(int'(received.tmem_col) + int'(sent.ncols) <=
                    int'(reference_records[r].base_col) ||
                    int'(reference_records[r].base_col) +
                    int'(reference_records[r].ncols) <= int'(received.tmem_col)))
                $fatal(1, "Allocation overlap");
            end
          end
          if (chosen < 0) $fatal(1, "Record capacity exceeded");
          reference_records[chosen].live = 1'b1;
          reference_records[chosen].owner = sent.owner;
          reference_records[chosen].owner_generation = sent.owner_generation;
          reference_records[chosen].base_col = received.tmem_col;
          reference_records[chosen].ncols = sent.ncols;
          reference_records[chosen].exclusive = sent.exclusive;
        end
        TC_DEALLOC: begin
          for (int r = 0; r < RECORDS; r++)
            if (reference_records[r].live &&
                reference_records[r].owner == sent.owner &&
                reference_records[r].owner_generation == sent.owner_generation &&
                reference_records[r].base_col == sent.tmem_col &&
                reference_records[r].ncols == sent.ncols &&
                reference_records[r].exclusive == sent.exclusive) chosen = r;
          if (chosen < 0) $fatal(1, "Deallocation did not match reference record");
          reference_records[chosen] = '0;
        end
        default: begin end
      endcase
    end
  endtask

  task automatic receive(input tc_cmd_t sent, input tc_status_e expected,
                          output tc_rsp_t received);
    integer guard_count;
    guard_count = 0;
    while (!rsp_valid) begin
      @(negedge clk);
      guard_count++;
      if (guard_count > 1000) $fatal(1, "Response timeout tag=%0d", sent.tag);
    end
    received = rsp;
    if (received.status !== expected || received.tag !== sent.tag ||
        received.op !== sent.op || received.owner !== sent.owner ||
        received.owner_generation !== sent.owner_generation ||
        received.ncols !== sent.ncols || received.data !== '0 ||
        received.malu_status !== STATUS_OK)
      $fatal(1, "Response mismatch tag=%0d expected=%0d got tag=%0d status=%0d",
          sent.tag, expected, received.tag, received.status);
    update_reference(sent, received);
    check_views();
    repeat (3) begin
      @(negedge clk);
      if (!rsp_valid || rsp !== received)
        $fatal(1, "Backpressured response changed tag=%0d", sent.tag);
      check_views();
    end
    rsp_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rsp_ready = 1'b0;
    checked++;
  endtask

  task automatic transact(input tc_cmd_t requested, input tc_status_e expected,
                           output tc_rsp_t received);
    @(negedge clk);
    job_request = requested;
    job_expected = expected;
    job_valid = 1'b1;
    do @(negedge clk); while (!job_done);
    received = job_response;
    job_valid = 1'b0;
    do @(negedge clk); while (job_done);
  endtask

  initial begin : transaction_worker
    tc_cmd_t issued;
    forever begin
      wait (job_valid);
      send(job_request, issued);
      receive(issued, job_expected, job_response);
      job_done = 1'b1;
      wait (!job_valid);
      job_done = 1'b0;
    end
  end

  task automatic quiet(input int count);
    repeat (count) begin
      @(negedge clk);
      if (rsp_valid) $fatal(1, "Unexpected/early response while capacity unavailable");
      check_views();
    end
  endtask

  task automatic reset_all;
    @(negedge clk);
    rst_n = 1'b0;
    cmd_valid = 1'b0;
    rsp_ready = 1'b0;
    owner_busy = '0;
    owner_fault = '0;
    clear_reference();
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    quiet(2);
  endtask

  initial begin : tests
    tc_rsp_t a, b, temp;
    tc_cmd_t pa, pb, sent, bad;
    integer slots, size, generation;
    bit seen_a, seen_b;
    if (OWNERS < 4 || MAX_COLS < 512)
      $fatal(1, "This test campaign requires OWNERS>=4, MAX_COLS>=512");
    cmd_valid = 0;
    rsp_ready = 0;
    owner_busy = '0;
    owner_fault = '0;
    cmd = '0;
    void'($value$plusargs("SEED=%d", seed));
    void'($urandom(seed));
    reset_all();

    // Context identities, transport-independent local allocation, collective
    // and shape checking. Native legality belongs to the top legalizer and
    // atomic group2 coordination to tcgen05_pair, both tested separately.
    transact(request(TC_ALLOC, 0, 1, 32), TC_BAD_OWNER, temp);
    transact(request(TC_CTX_INIT, 0, 0), TC_BAD_OWNER, temp);
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 0, 2), TC_BUSY, temp);
    transact(request(TC_ALLOC, 0, 0, 32), TC_BAD_OWNER, temp);
    transact(request(TC_CTX_INIT, 3, 1), TC_OK, temp);
    bad = request(TC_ALLOC, 3, 1, 64);
    bad.recipe = TC_RECIPE_NATIVE;
    transact(bad, TC_OK, a);
    transact(request(TC_DEALLOC, 3, 1, 64, 0, int'(a.tmem_col)), TC_OK, temp);
    bad = request(TC_ALLOC, 3, 1, 64);
    bad.cta_pair = 1;
    transact(bad, TC_OK, a);
    transact(request(TC_DEALLOC, 3, 1, 64, 0, int'(a.tmem_col)), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 3, 1), TC_OK, temp);
    bad = request(TC_ALLOC, 0, 1, 32);
    bad.participants = 32'hffff_fffe;
    transact(bad, TC_BAD_CMD, temp);
    transact(request(TC_LD, 0, 1), TC_BAD_CMD, temp);
    transact(request(TC_ALLOC, 0, 1, 0), TC_BAD_ALLOC, temp);
    transact(request(TC_ALLOC, 0, 1, 33), TC_BAD_ALLOC, temp);
    transact(request(TC_ALLOC, 0, 1, 96), TC_BAD_ALLOC, temp);
    transact(request(TC_ALLOC, 0, 1, 608, 1), TC_BAD_ALLOC, temp);
    transact(request(TC_ALLOC, 0, 1, 64), TC_OK, a);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_BUSY, temp);
    transact(request(TC_DEALLOC, 0, 1, 32, 0, int'(a.tmem_col)), TC_BAD_ALLOC, temp);
    transact(request(TC_DEALLOC, 0, 1, 64, 1, int'(a.tmem_col)), TC_BAD_ALLOC, temp);
    owner_busy[0] = 1;
    transact(request(TC_DEALLOC, 0, 1, 64, 0, int'(a.tmem_col)), TC_BUSY, temp);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_BUSY, temp);
    owner_busy[0] = 0;
    transact(request(TC_DEALLOC, 0, 1, 64, 0, int'(a.tmem_col)), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, 128), TC_ORDER, temp);
    transact(request(TC_ALLOC, 0, 1, 64), TC_OK, a);
    transact(request(TC_RELINQUISH, 0, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, 32), TC_NO_PERMIT, temp);
    transact(request(TC_DEALLOC, 0, 1, 64, 0, int'(a.tmem_col)), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 0, 1), TC_BAD_OWNER, temp);
    transact(request(TC_CTX_INIT, 0, 2), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 2, 96, 1), TC_OK, a);
    transact(request(TC_DEALLOC, 0, 2, 96, 1, int'(a.tmem_col)), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 2, 128, 1), TC_ORDER, temp);
    transact(request(TC_CTX_RELEASE, 0, 2), TC_OK, temp);

    // Pending capacity cannot hold up independent busy/free/permit/context work.
    reset_all();
    for (int o = 0; o < 3; o++)
      transact(request(TC_CTX_INIT, o, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, 512), TC_OK, a);
    send(request(TC_ALLOC, 1, 1, 128), pa);
    quiet(5);
    transact(request(TC_CTX_RELEASE, 1, 1), TC_BUSY, temp);
    transact(request(TC_RELINQUISH, 1, 1), TC_BUSY, temp);
    transact(request(TC_RELINQUISH, 2, 1), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 2, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 2, 2), TC_OK, temp);
    if (MAX_COLS > 512) begin
      transact(request(TC_ALLOC, 2, 2, 32), TC_OK, b);
      transact(request(TC_DEALLOC, 2, 2, 32, 0, int'(b.tmem_col)), TC_OK, temp);
    end
    owner_busy[0] = 1;
    transact(request(TC_DEALLOC, 0, 1, 512, 0, int'(a.tmem_col)), TC_BUSY, temp);
    owner_busy[0] = 0;
    transact(request(TC_DEALLOC, 0, 1, 512, 0, int'(a.tmem_col)), TC_OK, temp);
    receive(pa, TC_OK, b);
    transact(request(TC_DEALLOC, 1, 1, 128, 0, int'(b.tmem_col)), TC_OK, temp);
    for (int o = 0; o < 2; o++)
      transact(request(TC_CTX_RELEASE, o, 1), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 2, 2), TC_OK, temp);

    // An exclusive owns the entire local permit, even if its range is small.
    reset_all();
    for (int o = 0; o < 3; o++)
      transact(request(TC_CTX_INIT, o, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, MAX_COLS, 1), TC_OK, a);
    send(request(TC_ALLOC, 1, 1, 32), pa);
    send(request(TC_ALLOC, 2, 1, 32), pb);
    quiet(5);
    transact(request(TC_DEALLOC, 0, 1, MAX_COLS, 1, int'(a.tmem_col)), TC_OK, temp);
    seen_a = 0;
    seen_b = 0;
    repeat (2) begin
      while (!rsp_valid) @(negedge clk);
      if (rsp.tag == pa.tag && !seen_a) begin
        receive(pa, TC_OK, a);
        seen_a = 1;
      end else if (rsp.tag == pb.tag && !seen_b) begin
        receive(pb, TC_OK, b);
        seen_b = 1;
      end else $fatal(1, "Duplicate/unknown pending completion");
    end
    transact(request(TC_DEALLOC, 1, 1, 32, 0, int'(a.tmem_col)), TC_OK, temp);
    transact(request(TC_DEALLOC, 2, 1, 32, 0, int'(b.tmem_col)), TC_OK, temp);

    // A small exclusive still excludes other allocations despite free chunks;
    // relinquishing its owner's permit does not free the existing allocation.
    reset_all();
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, 96, 1), TC_OK, a);
    send(request(TC_ALLOC, 1, 1, 32), pa);
    quiet(4);
    transact(request(TC_RELINQUISH, 0, 1), TC_OK, temp);
    quiet(4);
    transact(request(TC_DEALLOC, 0, 1, 96, 1, int'(a.tmem_col)), TC_OK, temp);
    receive(pa, TC_OK, b);
    transact(request(TC_DEALLOC, 1, 1, 32, 0, int'(b.tmem_col)), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 1, 1), TC_OK, temp);

    // Conversely, an exclusive must wait for even one small live allocation.
    reset_all();
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, 32), TC_OK, a);
    send(request(TC_ALLOC, 1, 1, 96, 1), pa);
    quiet(4);
    transact(request(TC_DEALLOC, 0, 1, 32, 0, int'(a.tmem_col)), TC_OK, temp);
    receive(pa, TC_OK, b);
    transact(request(TC_DEALLOC, 1, 1, 96, 1, int'(b.tmem_col)), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 1, 1), TC_OK, temp);

    // A fault must terminate a blocked allocation without waiting for capacity,
    // so this owner can release. Cleanup never clears its generation history.
    reset_all();
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_OK, temp);
    slots = (RECORDS < MAX_COLS/32) ? RECORDS : MAX_COLS/32;
    for (int r = 0; r < slots; r++) begin
      transact(request(TC_ALLOC, 0, 1, 32), TC_OK, temp);
      bases[r] = int'(temp.tmem_col);
    end
    send(request(TC_ALLOC, 1, 1, 32), pa);
    quiet(3);
    owner_fault[1] = 1'b1;
    receive(pa, TC_PRIOR_ERROR, b);
    transact(request(TC_ALLOC, 1, 1, 32), TC_PRIOR_ERROR, temp);
    transact(request(TC_RELINQUISH, 1, 1), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 1, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_BAD_OWNER, temp);
    owner_fault[1] = 1'b0;
    transact(request(TC_CTX_INIT, 1, 2), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 1, 2), TC_OK, temp);
    owner_fault[0] = 1'b1;
    transact(request(TC_RELINQUISH, 0, 1), TC_OK, temp);
    for (int r = 0; r < slots; r++)
      transact(request(TC_DEALLOC, 0, 1, 32, 0, bases[r]), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_OK, temp);

    // Independently exhaust record metadata, even when physical chunks remain.
    reset_all();
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_OK, temp);
    slots = (RECORDS < MAX_COLS/32) ? RECORDS : MAX_COLS/32;
    for (int r = 0; r < slots; r++) begin
      transact(request(TC_ALLOC, 0, 1, 32), TC_OK, temp);
      bases[r] = int'(temp.tmem_col);
    end
    send(request(TC_ALLOC, 1, 1, 32), pa);
    quiet(5);
    transact(request(TC_DEALLOC, 0, 1, 32, 0, bases[0]), TC_OK, temp);
    receive(pa, TC_OK, a);
    transact(request(TC_DEALLOC, 1, 1, 32, 0, int'(a.tmem_col)), TC_OK, temp);
    for (int r = 1; r < slots; r++)
      transact(request(TC_DEALLOC, 0, 1, 32, 0, bases[r]), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 1, 1), TC_OK, temp);

    // A second same-owner request must not hold the sole core bus and block the
    // other owner's dealloc. BUSY is the project's explicit retry diagnostic.
    reset_all();
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, MAX_COLS, 1), TC_OK, a);
    send(request(TC_ALLOC, 1, 1, 32), pa);
    quiet(4);
    transact(request(TC_ALLOC, 1, 1, 32), TC_BUSY, temp);
    transact(request(TC_DEALLOC, 0, 1, MAX_COLS, 1, int'(a.tmem_col)), TC_OK, temp);
    receive(pa, TC_OK, b);
    transact(request(TC_DEALLOC, 1, 1, 32, 0, int'(b.tmem_col)), TC_OK, temp);
    // Reset cancellation is a joint-port contract, not cross-reset generation
    // isolation. The queued command must not reappear after reset.
    reset_all();
    transact(request(TC_CTX_INIT, 0, 1), TC_OK, temp);
    transact(request(TC_CTX_INIT, 1, 1), TC_OK, temp);
    transact(request(TC_ALLOC, 0, 1, MAX_COLS, 1), TC_OK, a);
    send(request(TC_ALLOC, 1, 1, 32), pa);
    quiet(3);
    reset_all();
    quiet(8);
    transact(request(TC_CTX_INIT, 0, 32'h0000_ffff), TC_OK, temp);
    transact(request(TC_CTX_RELEASE, 0, 32'h0000_ffff), TC_OK, temp);
    transact(request(TC_CTX_INIT, 0, 1), TC_SEQUENCE_EXHAUSTED, temp);
    transact(request(TC_CTX_INIT, 0, 32'h0000_ffff), TC_SEQUENCE_EXHAUSTED, temp);

    // Data-independent randomized resource reuse, with explicit safe cleanup.
    reset_all();
    for (int trial = 0; trial < 100; trial++) begin
      generation = trial + 1;
      size = 32 * (1 + int'($urandom_range(7, 0)));
      transact(request(TC_CTX_INIT, 0, generation), TC_OK, temp);
      transact(request(TC_ALLOC, 0, generation, size, 1), TC_OK, a);
      owner_busy[0] = 1;
      transact(request(TC_DEALLOC, 0, generation, size, 1, int'(a.tmem_col)), TC_BUSY, temp);
      owner_busy[0] = 0;
      transact(request(TC_DEALLOC, 0, generation, size, 1, int'(a.tmem_col)), TC_OK, temp);
      transact(request(TC_ALLOC, 0, generation, size+32, 1), TC_ORDER, temp);
      transact(request(TC_RELINQUISH, 0, generation), TC_OK, temp);
      transact(request(TC_ALLOC, 0, generation, 32), TC_NO_PERMIT, temp);
      transact(request(TC_CTX_RELEASE, 0, generation), TC_OK, temp);
    end
    quiet(10);
    if (checked < 850) $fatal(1, "Zero/partial test campaign");
    $display("TCGEN05_ALLOCATOR_PASS max_cols=%0d records=%0d checked=%0d cycles=%0d",
             MAX_COLS, RECORDS, checked, cycles);
    $finish;
  end
endmodule
