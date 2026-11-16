`timescale 1ns/1ps
module tb_tcgen05_tmem #(
  parameter int COLS = 576
);
  import tcgen05_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  logic req_valid = 0, req_ready;
  tc_mem_req_t req = '0;
  logic rsp_valid, rsp_ready = 0;
  tc_mem_rsp_t rsp;
  // Independent oracle: flat column-major logical storage, not bank/row math.
  logic [31:0] expected_word [0:COLS*128-1];
  bit initialized [0:COLS*128-1];
  logic [31:0] rng = 32'h5eed1201;
  int transfers = 0, reads = 0, writes = 0, ranges = 0;
  int partial_masks = 0, zero_masks = 0, held_cycles = 0;
  int queued_checks = 0, reset_checks = 0;
  always #5 clk <= ~clk;

  tcgen05_tmem #(.COLS(COLS)) dut(.*);

  function automatic logic [31:0] next_rng(input logic [31:0] value);
    logic [31:0] r;
    r = value ^ (value << 13);
    r = r ^ (r >> 17);
    return r ^ (r << 5);
  endfunction

  function automatic tc_mem_req_t command(input bit wr, input int col,
      input int lane, input logic [31:0] data, input logic [3:0] strb);
    tc_mem_req_t r;
    r = '0;
    r.write = wr;
    r.col = 10'(col);
    r.lane = 7'(lane);
    r.wdata = data;
    r.wstrb = strb;
    // Different metadata must not affect this already-authorized word port.
    r.owner = 3'(lane);
    r.owner_generation = 16'(col + 37);
    r.byte_addr = 32'hfedcba98;
    r.txn_id = 64'hcafe123400000000 ^ 64'(col*128+lane) ^
      (wr ? 64'h80000000 : 64'h40000000);
    return r;
  endfunction

  task automatic expected_accept(input tc_mem_req_t r,
                                  output tc_mem_rsp_t answer);
    int index;
    answer = '0;
    answer.txn_id = r.txn_id;
    if (int'(r.col) >= COLS) begin
      answer.status = TC_RANGE;
      ranges++;
    end else begin
      index = int'(r.col)*128 + int'(r.lane);
      answer.status = TC_OK;
      if (r.write) begin
        if (r.wstrb != 4'hf && !initialized[index])
          $fatal(1, "Test attempted partial write of uninitialized oracle word");
        for (int q = 0; q < 4; q++)
          if (r.wstrb[q]) expected_word[index][q*8 +: 8] = r.wdata[q*8 +: 8];
        initialized[index] = 1;
        writes++;
        if (r.wstrb == 0) zero_masks++;
        else if (r.wstrb != 4'hf) partial_masks++;
      end else begin
        if (!initialized[index]) $fatal(1, "Test attempted uninitialized read");
        answer.rdata = expected_word[index];
        reads++;
      end
    end
    transfers++;
  endtask

  task automatic check_response(input tc_mem_rsp_t answer);
    if (!rsp_valid || rsp !== answer)
      $fatal(1, "TMEM response mismatch col=%0d lane=%0d got=%h expected=%h valid=%b",
             req.col, req.lane, rsp, answer, rsp_valid);
  endtask

  task automatic transact(input tc_mem_req_t request, input int stall_cycles);
    tc_mem_rsp_t answer;
    int watchdog;
    @(negedge clk);
    req = request;
    req_valid = 1;
    rsp_ready = 0;
    watchdog = 0;
    do begin
      @(posedge clk);
      watchdog++;
      if (watchdog > 16) $fatal(1, "TMEM request did not become ready");
    end while (!req_ready);
    expected_accept(request, answer);
    #1;
    check_response(answer);
    @(negedge clk);
    req_valid = 0;
    repeat (stall_cycles) begin
      @(posedge clk);
      #1;
      check_response(answer);
      if (req_ready) $fatal(1, "TMEM accepted while response blocked");
      held_cycles++;
    end
    @(negedge clk);
    rsp_ready = 1;
    @(posedge clk);
    #1;
    if (rsp_valid) $fatal(1, "TMEM response was not consumed");
    @(negedge clk);
    rsp_ready = 0;
    req = '0;
  endtask

  task automatic queued_request_test;
    tc_mem_req_t first, second;
    tc_mem_rsp_t first_answer, second_answer;
    first = command(0, 0, 0, 0, 0);
    second = command(1, COLS-1, 127, 32'h89abcdef, 4'hf);
    @(negedge clk);
    req = first;
    req_valid = 1;
    rsp_ready = 0;
    @(posedge clk);
    if (!req_ready) $fatal(1, "Initial queued-test request not ready");
    expected_accept(first, first_answer);
    #1;
    check_response(first_answer);
    @(negedge clk);
    req = second;
    // Keep next request valid and unchanged while the old response is blocked.
    repeat (5) begin
      @(posedge clk);
      if (req_ready) $fatal(1, "Queued request accepted before old response");
      #1;
      check_response(first_answer);
      held_cycles++;
    end
    @(negedge clk);
    rsp_ready = 1;
    @(posedge clk);
    if (req_ready) $fatal(1, "Unexpected same-cycle response/request bypass");
    #1;
    if (rsp_valid) $fatal(1, "Old queued-test response not consumed");
    @(negedge clk);
    rsp_ready = 0;
    @(posedge clk);
    if (!req_ready) $fatal(1, "Queued request did not become ready");
    expected_accept(second, second_answer);
    #1;
    check_response(second_answer);
    @(negedge clk);
    req_valid = 0;
    rsp_ready = 1;
    @(posedge clk);
    #1;
    if (rsp_valid) $fatal(1, "Second queued response not consumed");
    @(negedge clk);
    rsp_ready = 0;
    req = '0;
    queued_checks++;
  endtask

  task automatic reset_pending_response(input bit write_before_reset,
                                        input bit queue_unaccepted_write);
    tc_mem_req_t r;
    tc_mem_rsp_t answer;
    r = command(write_before_reset, 0, 31, 32'h1234abcd, 4'hf);
    @(negedge clk);
    req = r;
    req_valid = 1;
    rsp_ready = 0;
    @(posedge clk);
    if (!req_ready) $fatal(1, "Reset-test request not accepted");
    expected_accept(r, answer);
    #1;
    check_response(answer);
    @(negedge clk);
    if (queue_unaccepted_write) begin
      req = command(1, 0, 31, 32'hbad0bad0, 4'hf);
      req_valid = 1;
      @(posedge clk);
      if (req_ready) $fatal(1, "Reset-test queued write was accepted");
      @(negedge clk);
    end else req_valid = 0;
    rst_n = 0;
    #1;
    if (rsp_valid || rsp !== '0 || req_ready)
      $fatal(1, "Reset did not clear response/disable request");
    repeat (2) @(negedge clk);
    req_valid = 0;
    req = '0;
    rst_n = 1;
    // Accepted writes committed before reset persist. A queued unaccepted
    // write must not modify the retained memory. No RAM-zero assumption.
    transact(command(0, 0, 31, 0, 0), 1);
    reset_checks++;
  endtask

  initial begin : test_sequence
    int unused;
    unused = $value$plusargs("SEED=%h", rng);
    for (int i = 0; i < COLS*128; i++) initialized[i] = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    // Exhaustive bijection check: each logical address gets a unique pattern.
    for (int col = 0; col < COLS; col++)
      for (int lane = 0; lane < 128; lane++)
        transact(command(1, col, lane,
          32'h80000000 ^ 32'(col*128+lane), 4'hf), 0);
    for (int col = COLS-1; col >= 0; col--)
      for (int lane = 127; lane >= 0; lane--)
        transact(command(0, col, lane, 0, 0), 0);

    // All byte masks, including a no-op zero-strobe write, at all quarters.
    for (int strb = 0; strb < 16; strb++) begin
      transact(command(1, 0, strb*8, 32'h55aa12ef, 4'(strb)), strb % 3);
      transact(command(0, 0, strb*8, 0, 0), 0);
    end
    for (int i = 0; i < 4096; i++) begin
      tc_mem_req_t r;
      int col, lane, stalls;
      rng = next_rng(rng);
      col = int'(rng % 32'(COLS));
      rng = next_rng(rng);
      lane = int'(rng % 128);
      rng = next_rng(rng);
      stalls = int'(rng[5:4]);
      r = command((i % 2) == 0, col, lane, rng, rng[3:0]);
      transact(r, stalls);
    end

    // Every invalid request responds with TC_RANGE, rdata=0, no RAM access.
    transact(command(1, COLS, 0, 32'hffffffff, 4'hf), 3);
    transact(command(0, COLS, 0, 0, 0), 1);
    transact(command(1, 1023, 127, 32'hffffffff, 4'hf), 2);
    transact(command(0, 1023, 127, 0, 0), 0);
    queued_request_test();
    transact(command(0, COLS-1, 127, 0, 0), 2);
    reset_pending_response(0, 0);
    reset_pending_response(1, 0);
    reset_pending_response(0, 1);
    // Check all initialized data after invalid operations, byte updates/reset.
    for (int col = 0; col < COLS; col++)
      for (int lane = 0; lane < 128; lane++)
        transact(command(0, col, lane, 0, 0), 0);
    if (partial_masks == 0 || zero_masks == 0 || held_cycles == 0 ||
        ranges != 4 || queued_checks != 1 || reset_checks != 3)
      $fatal(1, "TMEM protocol tests did not execute");
    $display("TCGEN05_TMEM_PASS cols=%0d transfers=%0d reads=%0d writes=%0d ranges=%0d partial=%0d zero=%0d held=%0d queued=%0d reset=%0d final_rng=%h",
      COLS, transfers, reads, writes, ranges, partial_masks, zero_masks,
      held_cycles, queued_checks, reset_checks, rng);
    $finish;
  end

  initial begin
    repeat (3000000) @(posedge clk);
    $fatal(1, "TMEM independent test global watchdog");
  end
endmodule
