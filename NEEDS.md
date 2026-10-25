# Needs from sibling libraries

What ex_audio still cannot express with the ExHdl of `../exhdl` (commit
ad0abe4), in order of importance for the target: an AES67 mixer with 1024
channels on one 250 MHz pipeline (5208 cycles per 48 kHz frame, 1024 of
them taken by one channel per cycle through the strips). Nothing was
patched outside this repository. The first version of this file (commit
e72ec87 of ExHdl) listed what the mixer needed; since then ExHdl has
state in RAM, per-channel coefficient banks, `tid`/`tuser`, per-group
recurrences, `ExHdl.DSP.cascade/1`, UltraScale+ timing, the RTL DSL and
`defregs`. The mixer is built on those (`ExAudio.Mixer`, see the README);
what is left, with the workaround in use:

## ExHdl

### 1. Multiplier sharing and RAM gather in the scan backend

The matrix mixer is RTL (`ExAudio.Mixer.Matrix`): 13 MAC lanes, each a
crosspoint RAM read, a gather from a frame RAM by the source index, one
multiply and a 48-bit accumulator. `ExAudio.Matrix.step/3` and `mac/3` are
the same arithmetic as scan kernels, but the scan backend cannot yet

- read a RAM at an address that is a stream value (`frame[src]`),
- share one multiplier between the terms of a row under `ii: k` (every
  multiply of the graph is still instantiated: 8 DSP at `ii: 1` and at
  `ii: 8` for `Matrix.step/3`),
- take the number of terms and the frame boundary from the stream
  (`mac/3` has the slot count as a compile-time constant), or leave out the
  clamp in the accumulator loop (the state must be provably inside its
  range; `mac/3` clamps and needs `ii: 2`, see item 10).

When these exist, `Matrix.mac/3` with a gather should replace the
hand-written lane and the two should be co-simulated against each other
(the RTL lane is already checked against `ExAudio.Matrix.mix_clip/2`).

### 2. Wide multiplies as 25 x 18 (27 x 18) partial products

`*` with operands wider than the multiplier is emitted as one expression
and Yosys maps it as it likes. A biquad (three products 32 x 24, two
32 x 32) takes 20 DSP48 where 14 would do: the strip of one channel
bank is 106 DSP48E2 in the Yosys numbers (README), the whole mixer 245 of
the 1368 on the XCKU3P. `ExHdl.Target.Timing` costs such a multiply as two
DSPs in a cascade, which is optimistic for 32 x 32, so the latencies
and loop lengths of the strips are estimates. Needed: explicit splitting
into partial products with a pipelined adder tree (and the cost model to
match), now for the 27 x 18 DSP48E2. (Wave 5: ExHdl now splits wide
products, `Design.dsp`; Yosys counts 77 DSP48E2 per strip bank instead of
106. Not re-checked against the 14-per-biquad target.)

### 3. DSP48E2 as an RTL primitive

The MAC of a lane is written as registers around `a * b` and
`acc <~ add_wrap(mux(first, round, acc), m)`. Yosys (`synth_xilinx -family
xcup`, 0.69) maps the 24 x 18 multiply to one DSP48E2 per lane (13 in the
matrix) but leaves the input registers, the product register, the
accumulator and its 48-bit adder in fabric: the netlist of a lane has
`AREG = BREG = MREG = PREG = 0` (reproduce with
`mix ex_hdl.gen.sv ExAudio.Mixer` and `write_verilog` after `synth_xilinx`
on `ea_matrix_32x8_l3`, `ExAudio.Mixer.Config.new(channels: 32, slots: 8,
frame_cycles: 100)`). Vivado normally absorbs such registers, but that is not
checked here. Needed: a DSP48E2 black box with a model in `ExHdl.RTL`
(`Model` for the BEAM simulator, `sources` for Verilator, the registers,
`OPMODE` and `C` as parameters) next to `ExHdl.RTL.CDC`, so that a
DSP pipeline is explicit and does not depend on inference, and a way to
read its latency into `ExHdl.Target.Timing`.

### 4. A `count_leading_zeros` op

`ExAudio.Q.log2_q16/2` finds the leading one by comparing with `2^k` and
summing (35 comparators for the compressor, 40 for the RMS meter);
`Nx.count_leading_zeros` is not in the backend's op list. A priority
encoder would replace the comparators and adder tree and shorten the
compressor's 45-cycle pipeline, which sets the latency of the strip
(120 cycles at 1024 channels).

### 5. Stream harness: `pc_data` is limited to 1024 bits

`ExHdl.Sim.Verilator.build_stream/2` refuses designs with more than 1024
bits of `pc_data` (and of parameters and `tdata`). The per-channel word
of the full strip (4 biquads, gate, compressor: 35 x 32 bit) is 1120 bits, so
the strip cannot use the harness with its reactive handshakes and
backpressure traffic. Reproducer:

```elixir
spec = ExAudio.Strip.cascade_spec()
{:ok, d} = ExHdl.DSP.scan_to_sv(spec[:fun], spec[:args],
  Keyword.drop(spec, [:fun, :args]) ++
    [name: "strip", channels: 1024, state_mem: :block, channel_params: :all, tid: true])
d.pc_width                              #=> 1120
ExHdl.Sim.Verilator.build_stream(d)
#=> {:error, "stream simulation supports up to 1024 parameter, pc_data and tuser bits"}
```

Workaround: `ExAudio.Mixer.Strip` wraps the kernel in RTL (`Wrap.scan/1`) and
the tests drive it through `ExHdl.RTL.Cosim` with stimulus built from the
protocol (no backpressure on the output, random gaps on the input). The
parameter widths follow the Nx types (32 bit) and not the proven ranges; the
gate's eight and the compressor's seven parameters need 17 to 28 bit each,
so `pc_data` with the width of the ranges would be about 1000 bits (the
biquad coefficients need all 32).

### 6. No BEAM model for stream kernel black boxes

`Wrap.scan/1` has no `ExHdl.RTL.Model`, so `ExAudio.Mixer` (which contains
six kernels) runs only in Verilator, and `Cosim.check_model/4` with the
BEAM backend is possible for the matrix but not for the top level. A model
that runs the Nx reference per channel with the kernel's latency and
handshake would let the top level be checked cycle by cycle in both
backends. A model would also give the strips' latency (120 cycles) without
generating SystemVerilog.

### 7. Timing is a model

No place and route. `Timing` assumes the UltraScale+ delays of
`ExHdlXilinx.Device` and 250 MHz is what the generator schedules for; the RTL
parts (matrix lanes, sequencer, window logic) were written for short paths
(registered RAM outputs, DSP input/product/P registers, one level of
logic between registers) but nothing here says the design closes at 250 MHz.
Needed at some point: a Vivado run on `mix ex_hdl.gen.sv ExAudio.Mixer`
output (`ExHdlXilinx.Vivado`), with the clock crossing in front of
`s_axil` and the placement of 13 frame RAM copies.

### 8. RTL memories: addresses wider than the depth

`ExHdl.RTL` documents that an out-of-range address reads 0 and is not
written, but a port address wider than `ceil_log2(depth)` is a
`WidthError`:

```elixir
module "m" do
  a = input(:a, 4)
  q = output(:q, 8)
  mem = memory(:mem, width: 8, depth: 3)
  q <~ read_port(mem, addr: a, en: 1)
end
#=> ExHdl.RTL.WidthError: mem read address: u4 value does not fit u2 (2 bit(s) too wide)
```

`ExAudio.Mixer.Matrix` has memories whose depth is not a power of two (the
last lane has 76 of 79 outputs) and truncates the address by hand next to
an explicit range check on the write enable. Accepting the wider address
(upper bits make it out of range) would save that code. Low priority.

### 9. Read-modify-write memories (sticky per-channel flags)

Sticky per-channel flags (clip memory that the host clears) need a read
port and a write port on the same address with a one-cycle pipeline and
hazard rule. It is easy but every design writes it again; the peak meter
here stores only the clip bit of the last sample for that reason (the held
peak reaches the clip level and stays for the hold time, which serves
as the indicator). Low priority.

## nx_fixed

### 10. Range analysis loses correlation

- `left_shift(v, k)` with `k = 35 - msb(v)` is proven as `v * 2^35`, which
  overflows `s64`; `ExAudio.Q.log2_q16/2` normalises with a right shift for
  large values and a left shift of the clamped small values instead. A
  `count_leading_zeros` primitive (item 4) or a relational shift rule would
  keep the single barrel shifter.
- An accumulator over a counted number of terms (`acc + g * x`, reset after
  `k`) cannot be proven inside `k` times the product range, so kernels clamp
  it (item 1). A counter-indexed bound would remove the clamp from the loop.
- Tensor arguments of a step function carry one range per tensor; a vector
  of coefficients with different ranges has to be split into scalar leaves
  (one port each).

### 11. Integer types of any width

Nx has no `s24` or `s48`. Samples live in `s32` and accumulators in `s64`, and
every kernel needs `param_ranges` to say what they hold; the generated ports
have the width of the Nx type (32 bit), not of the range, and the checked
reference (`run_scan_stacked`) does not verify at run time that inputs and
parameters respect their ranges. Wanted: an option to assert declared ranges
on every input and parameter in the reference (catches a bad coefficient word
on the BEAM side), and ports with the width of their range. The mixer's
24-bit streams are sign-extended to 32 bit at the kernel boundary
(`ExAudio.Mixer.Strip`) and `Host.strip_words/2` is where a coefficient
outside its range would have to be caught.

## Resolved since the first version

State in RAM, coefficient banks with a host port, channel sideband,
per-group recurrences, kernel composition, the UltraScale+ timing family
and `Nx.abs/1` under Yosys 0.69 (`ExAudio.Q.absolute/1` is `Nx.abs/1`
again; its range `0..2^23` is proven directly).

## Open work (wave 3 hand-off, updated in wave 5)

* URAM budget. Done in wave 5. The strip state was 646 bits per channel
  (not 1200 as written here before; the 1120 bits are the coefficient
  word), 636 after the narrowing below, in 13 memories, one per pipeline stage that reads state: two per
  biquad (48 and 83 bits), five for gate and compressor. A memory takes at
  least one URAM, so unfolded that is 17 URAM per bank at 1024 channels.
  ExHdl's `state_fold: k` (exhdl wave 5) spreads a channel's state over
  `k` rows of a memory and merges consecutive memories while a row stays
  within `state_row_bits` (72); the kernel then accepts one sample every
  `k` cycles. `Config.new/1` uses `k = 4` above 512 channels (4096 of
  5208 cycles per frame): 3 URAM per bank (66, 66 and 28 bits by 4096
  rows) instead of 17, 6 instead of 34 for the mixer, for about 13500
  more pipeline register bits per bank (delay lines without reset, SRL
  candidates). `state_row_bits: 36` gives 5 URAM per bank for 6200 bits.
  Up to 512 channels the state stays unfolded in block RAM. Yosys
  (`synth_xilinx -family xcup`) counts 3 URAM per strip bank and 10 210 FF
  (4787 in wave 3); the run of the whole top exited with status 1 without
  a message, so the README table sums the parts. No Vivado run.
  Open: the datapath is not shared over the `k` cycles (same DSP count at
  a quarter of the rate); multiplier sharing under `channels:` would be
  the next saving (item 1). A gather-kernel matrix would trade the
  matrix's block RAM for URAM (13 URAM, 48 RAMB18 for 1024x64), so it
  helps the block RAM budget only.
* Strip clamps and state width. Done in wave 5. The clamps that only
  served the range proof are gone from the feedback loops: the envelope
  follower and the gate's gain use `ExAudio.Q.wrap_unsigned/2` (the
  smoother never overshoots, so the wrap is the identity on reachable
  values and the hardware keeps the low bits), the biquad's history
  saturation is `NxFixed.Primitives.saturate(:s32)`. The envelope is 35
  bits (was 36; `|x|` saturates to `2^23 - 1` before the follower, outside
  the loop), the gate's hold counter 16 bits (was 24; `hold_ms` at most
  65535 samples, 1365 ms at 48 kHz, `gate_params/1` raises above). The
  gate thresholds are at most `2^23 - 1`.
* Test suite: the untagged co-simulation tests in `mixer_matrix_test.exs`
  are tagged `:verilator` with a 600 s timeout (Verilator builds on the
  shared host take over 60 s).
