# Needs from sibling libraries

What ex_audio cannot express with the current ExHdl scan backend (state of
`../exhdl` at commit e72ec87), in order of importance for the target: an AES67
mixer with 1024 channels on one 250 MHz pipeline. At 48 kHz a frame is 5208
cycles, so one engine that takes one channel per cycle is busy for 1024 of
them (20 %) and the rest of the frame is free for the matrix. Everything below
was found by generating and co-simulating the kernels in `ExAudio.Kernels`.
Nothing was patched outside this repository.

## ExHdl

### 1. Per-channel state in block RAM

`channels: n` keeps `n` copies of the state in registers. Yosys numbers for
the biquad (5 state words, 131 bit): 588 FF with `ii: 9`, 2665 FF with
`channels: 9`; the gate (4 words) 743 FF against 2070 FF with `channels: 15`.
For 1024 channels that is about 134 k FF per biquad section, 4 sections per
strip, per direction. The new memories (`ExHdl.Backends.SystemVerilog.Fir`)
only hold delay lines. Needed: an option such as `state: :ram` (RAMB36/URAM,
depth `n`, one wide word per channel) that

- reads the word of channel `c` in the state stage and writes it back at the
  write stage; no forwarding is needed when `n >= write_stage - state_stage + 1`
  (checked at generation time);
- clears the RAM after reset with a sweep over the channels, or takes an init
  value per channel; the reset today loads `:init` into registers.

### 2. Per-channel parameters from RAM

`p_load` now gives an atomic update, but of one parameter set for the whole
kernel. A mixer needs a coefficient set per channel (biquad: 5 x 32 bit,
gate 8 x 32, compressor 7 x 32) that the host rewrites at run time without
tearing. Needed: `params: :ram` generating a RAM of depth `n` indexed by the
channel counter at the stage where the parameter is first used, with a
write port (address, whole-word data). The write port needs an option for a
second clock (PCIe AXI clock) or an exposed bus the user wires through a CDC.

### 3. Channel index and sideband through the pipeline

The module has no `tuser`, `tlast` or channel number: channel `c` is "the
c-th sample since reset" and a dropped beat shifts all channels. With RAM
state and parameters the generator needs the channel number anyway. Needed:
`s_axis_tuser`/`m_axis_tuser` passed through the pipeline unchanged (width as
option, e.g. `{channel, timestamp, flags}`), and an input channel index
(`s_axis_tid`) used as the RAM address instead of a free-running counter.

### 4. Separate recurrences for independent states

`ExAudio.Strip` composes sections in one step function. The recurrence
analysis takes the longest path from any state read to any state write, so a
cascade of `k` biquads reports `ii`/`loop_latency` of `k` times one section
(9 for one, 18 for two, 36 for four, 53 with gate and compressor) although each
section's loop is 9 cycles. With `channels: n` that sets the minimum `n` (and
with RAM state a hazard window); with `ii` it is a plain throughput loss.
Needed: loop analysis per state leaf (strongly connected components of
state -> next state), state read and write stages per leaf.

### 5. Multiplier sharing under `ii: k`; the mixer

`ii: n` only spaces the samples; every multiply of the graph is still
instantiated. A mixer row with 8 sources (`ExAudio.Matrix.step/3`): 8 DSP48E1
at `ii: 1` and 8 at `ii: 8`. 1024 outputs x 64 sources per frame is 65536 MACs,
about 13 per cycle at 5208 cycles per frame.

What works today: `ExAudio.Matrix.mac/3` takes one `{sample, gain}` pair per
beat and gives one output (with clip flag) every `slots` beats through the
variable-rate output (`lanes: 1`, count 0 or 1): 1 DSP48E1, co-simulated
bit-identical. What is missing for the mixer:

- a runtime number of slots per output and the frame boundary from the stream
  (`first`/`last` sideband as step arguments, see 3); `mac/3` has the slot count
  as a compile-time constant;
- a way to write the accumulator loop without the clamp: the backend requires
  the next state to be provably inside the state's range ("next state can leave
  the state's range"), so the accumulator needs a `clip` in its loop, and
  `ii` becomes 2 (`channels: 2` interleaves two outputs). A wrap to a given
  bit width (`s48`) or an accumulator type whose range follows from the
  counter would remove it (see nx_fixed, 12);
- 13 or more `mac` lanes in parallel with a final adder, as a composition of
  kernels (see 6).

### 6. Kernel composition

A strip, or the mixer's lanes plus adder, is several kernels. Today the only
composition is inlining into one step function (done in `ExAudio.Strip`),
which hits item 4. Needed: a way to connect generated modules (AXI4-Stream
between them, sideband passed through, `channels:`/`ii:` consistent) or a
combinator in ExHdl that generates the connection from the kernels' designs.

### 7. Gather: RAM read indexed by data

The crosspoint table gives a source channel; the sample is read from a
double-buffered frame RAM (bank bit per frame). `Nx.take` takes a constant
table, a delay line or a computed value of up to 1024 entries (a multiplexer).
Needed: a table argument that is a RAM (read port address from a stream value,
optional write port, registered read of 1-2 cycles in the schedule) so a kernel
can read `frame[src]` and `gain_table[...]`.

### 8. Wide multiplies

`*` with operands wider than 25 x 18 is emitted as one expression; Yosys maps
it to as many DSP48E1 as it likes: the biquad (3 products 32 x 24, 2 products
32 x 32) uses 20 DSP48E1 where 14 would do, and `ExHdl.Target.Timing` costs
every such multiply as two DSPs in a cascade (5 cycles), which is optimistic
for 32 x 32 (four DSPs, three levels). Loop latencies and the generated
pipeline depth are therefore estimates. Needed: explicit splitting into
25 x 18 partial products with a pipelined adder tree (and the cost model to
match), and a DSP48E2 (27 x 18) target for UltraScale+.

### 9. A `count_leading_zeros` op

`ExAudio.Q.log2_q16/2` finds the leading one by comparing with 2^k and summing
(35 comparators for the compressor, 40 for the RMS meter).
`Nx.count_leading_zeros` is not in the backend's op list; a priority encoder
would replace comparators and adder tree and shorten the compressor's
46-cycle pipeline.

### 10. Generated SystemVerilog that Yosys 0.69 rejects

`Nx.abs/1` (and `Nx.negate/1` on a sign-extended operand) is emitted as
`-25'(n1)`; Yosys 0.69 reads `-25` as the cast width:
`ERROR: Static cast with zero or negative size!` (Verilator accepts it). The
backend should emit `-(25'(n1))`. ex_audio avoids `Nx.abs`
(`ExAudio.Q.absolute/1`: `max(max(x, 0 - x), 0)`) so that the resource numbers
in the README could be produced.

### 11. Stream harness limits (test infrastructure)

`Verilator.build_stream/2` allows 256 bits of parameters and of `tdata`.
Four coefficient sets of a strip are 640 bits, so the strip is co-simulated
with the coefficients baked in as constants (`ExAudio.Strip.spec/2` with
`baked: true`), not with parameter ports; the mixer row is limited to 8
sources.

### 12. Timing is a model

No place and route: `Timing` assumes 0.6 ns per LUT level and 150 MHz
unless overridden, so nothing here says the kernels close at 250 MHz. Needed
at some point: a Vivado or openXC7 run on the generated modules.

## nx_fixed

### 13. Range analysis loses correlation

- `max(x, 0 - x)` is `[-(2^23 - 1), 2^23]` for `x` in 24 bits while `abs` is
  `[0, 2^23]`. `ExAudio.Q.absolute/1` adds an outer `max(., 0)`; the analysis
  could handle `max(x, negate(x))` directly.
- `left_shift(v, k)` with `k = 35 - msb(v)` is proven as `v * 2^35`, which
  overflows `s64`; `ExAudio.Q.log2_q16/2` normalises with a right shift for
  large values and a left shift of the clamped small values instead. A
  `count_leading_zeros` primitive (item 9) or a relational shift rule would
  keep the single barrel shifter.
- An accumulator over a counted number of terms (`acc + g * x`, reset after
  `k`) cannot be proven inside `k` times the product range, so kernels clamp
  it (item 5). A counter-indexed bound would remove the clamp from the loop.
- Tensor arguments of a step function carry one range per tensor; a vector
  of coefficients with different ranges has to be split into scalar leaves
  (one port each).

### 14. Integer types of any width

Nx has no `s24` or `s48`. Samples live in `s32` and accumulators in `s64`, and
every kernel needs `param_ranges` to say what they hold; the generated ports
have the width of the Nx type (32 bit), not of the range, and the checked
reference (`run_scan_stacked`) does not verify at run time that inputs and
parameters respect their ranges. Wanted: an option to assert declared ranges
on every input and parameter in the reference (catches a bad coefficient word
on the BEAM side), and ports with the width of their range.
