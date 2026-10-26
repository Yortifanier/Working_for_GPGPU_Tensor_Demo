"""Recompute proposal budgets. This is neither RTL simulation nor a PPA report."""
from fractions import Fraction
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent


def ceil_div(a, b):
    return (a + b - 1) // b


def main():
    columns, lanes, banks = 576, 128, 32
    addresses = {(lane % banks, 4 * col + lane // banks)
                 for col in range(columns) for lane in range(lanes)}
    assert len(addresses) == columns * lanes == 73728
    assert min(row for _, row in addresses) == 0
    assert max(row for _, row in addresses) == 2303
    assert columns * lanes * 4 == 288 * 1024
    assert columns // 32 == 18
    assert 2 * columns // 32 == 36

    high_bricks = 2 * ceil_div(11, 4) ** 2
    fp4_raw_bricks, coefficient_bricks = 8, 1
    scaled_bricks = ceil_div(14, 4) * ceil_div(8, 4)
    assert high_bricks == fp4_raw_bricks + coefficient_bricks + scaled_bricks + 1 == 18
    bricks = 8 * high_bricks + 6 + coefficient_bricks + scaled_bricks
    assert bricks == 159

    terms = {'tf32': 8, 'f16_bf16': 16, 'f8f6f4_mxf8f6f4': 70,
             'mxf4_mxf4nvf4': 140}
    ratios = {k: Fraction(v, terms['f16_bf16']) for k, v in terms.items()}
    assert list(ratios.values()) == [Fraction(1, 2), Fraction(1), Fraction(35, 8), Fraction(35, 4)]
    minimum_dense_k = dict(zip(terms, [8, 16, 32, 64]))
    closures = {k: Fraction(v, minimum_dense_k[k]) for k, v in terms.items()}
    assert ceil_div(max(closures.values()).numerator, max(closures.values()).denominator) == 3

    q = [0, 1, 2, 3, 4, 6, 8, 12]
    q_product = max(q) ** 2
    block_sum = q_product * 32
    scale_product = 15 * 15
    assert q_product == 144 and q_product <= (1 << 8) - 1
    assert q_product > (1 << 7) - 1  # signed8 is insufficient.
    assert block_sum == 4608 and block_sum <= (1 << 13) - 1
    assert scale_product == 225 and scale_product <= 255
    assert block_sum * scale_product == 1036800 < (1 << 20)
    assert ceil_div(140, 16) == 9
    assert Fraction(140, 8) > 9  # Misaligned segments cannot claim the same budget.

    # A finite low-precision product is <2^32, in units of 2^-32.
    low_group_bound = 64 * ((1 << 64) - 1)
    low_group_signed_bits = low_group_bound.bit_length() + 1
    assert low_group_signed_bits == 71 and low_group_signed_bits <= 80
    accumulator_base, accumulator_bits = -300, 640
    signed_upper_exponent = accumulator_base + accumulator_bits - 1
    assert -286 >= accumulator_base
    assert 292 < signed_upper_exponent
    assert 260 < signed_upper_exponent

    dot_contexts = 8 * 4 + 6 * 2
    assert dot_contexts == 44 and dot_contexts * 192 == 8448
    assert 16 * 128 * 8 == 16 * 1024  # One A snapshot version.
    assert 16 * 64 * 8 == 8 * 1024  # One B collector slot.
    assert 8 * 128 * 8 == 8 * 1024  # Auxiliary cache.
    assert 32 // 2 == 16  # Nominal RTT window at two SMEM requests/cycle.
    examples = {
        'f16_m128_n64_k16': (128 * 64 * 16, 16),
        'fp8_m128_n64_k32': (128 * 64 * 32, 70),
        'mxf4_m128_n64_k64': (128 * 64 * 64, 140),
    }
    example_results = {k: {'terms': n, 'raw_only_lower_bound_cycles': ceil_div(n, rate)}
                       for k, (n, rate) in examples.items()}
    assert [v['raw_only_lower_bound_cycles'] for v in example_results.values()] == [8192, 3745, 3745]

    report = {
        'passed': True,
        'scope': 'Project proposal arithmetic and capacity checks only; not RTL, synthesis, timing, or end-to-end performance validation.',
        'tool_source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'bank_mapping': {'unique_cells': len(addresses), 'banks': banks,
                         'words_per_bank': 2304, 'endpoint_bytes': columns * lanes * 4,
                         'pair_bytes': 2 * columns * lanes * 4,
                         'allocation_records_per_endpoint': 18, 'pair_records': 36},
        'compute': {'base_bricks': high_bricks, 'total_4x4_equivalent_bricks': bricks,
                    'raw_terms_per_cycle': terms,
                    'relative_to_f16': {k: str(v) for k, v in ratios.items()},
                    'ideal_average_dot_closures_per_cycle': {k: str(v) for k, v in closures.items()},
                    'finalizer_minimum_ideal_II1_count': 3,
                    'dot_contexts': dot_contexts, 'dot_context_bytes': 8448},
        'operand_buffers': {'a_version_banks': 16, 'a_bank_words_64bit': 128,
                            'b_slot_banks': 16, 'b_bank_words_64bit': 64,
                            'aux_banks': 8, 'aux_bank_words_64bit': 128,
                            'smem_outstanding_tags': 32, 'smem_response_slots': 8,
                            'nominal_round_trip_cycles_at_two_requests_per_cycle': 16},
        'numeric': {'q_product_magnitude_bound': q_product, 'q_product_signed_bits': 9,
                    'block32_sum_magnitude_bound': block_sum, 'block_sum_signed_bits': 14,
                    'scale_product_unsigned_bits': 8, 'scaled_magnitude_bound': block_sum * scale_product,
                    'fp4_injection_exponent_adjustment': -2,
                    'low_group_signed_bits_bound': low_group_signed_bits, 'low_group_storage_bits': 80,
                    'accumulator_base': accumulator_base, 'accumulator_bits': accumulator_bits,
                    'signed_upper_exclusive_exponent': signed_upper_exponent},
        'examples': example_results,
        'unverified': ['PERF pipeline and forwarding', 'queue liveness and fairness',
                       'native recipe correctness', 'SRAM macro and PPA', 'end-to-end throughput'],
    }
    output = ROOT / 'research/design_budget.json'
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'Budget checks passed; wrote {output.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
