# ExAudio

Audio processing written once as fixed-point step functions: they run on the
BEAM (Nx) and go through ExHdl's scan backend into time-multiplexed hardware,
bit-identical.

## Status

| Module | State |
|---|---|
| `ExAudio.Filter`: Audio EQ Cookbook designs (low/high pass, band pass, notch, peaking, shelves, all pass), magnitude and phase, float direct form I | done |
| `ExAudio.Biquad`: Q5.27 / Q2.30 coefficient quantisation, direct form I kernel with 8 guard bits and error feedback, proven error bound | done |
| `ExAudio.Strip`: cascade of biquads, optional gate and compressor; `cascade_spec/1` for many channels | done |
| `ExAudio.Dynamics`: envelope follower, gate (hysteresis, hold), compressor and limiter (soft knee, log2/exp2 tables) | done |
| `ExAudio.Meter`: peak hold with clip flag, RMS (log2 level) | done |
| `ExAudio.Matrix`: sparse crosspoint table and mixer on the BEAM, kernels for one output row (parallel, and one multiplier streaming) | done |
| Verilator co-simulation of all kernels, Yosys estimates (`mix ex_hdl.gen.sv ExAudio.Kernels --synth`) | done |
| `ExAudio.Mixer`: 1024 channels on UltraScale+ 250 MHz: 4 biquads, gate and compressor per channel in and out (state folded in UltraRAM, one sample every 4 cycles; coefficients in RAM), 13 lane MAC matrix with 64 crosspoints per output, meters, AXI4-Stream and AXI4-Lite; Verilator against the Nx references, Yosys estimates | done, see [The mixer](#the-1024-channel-mixer) |
| `ExAudio.Mixer.Host`: Hz, dB, ms and gains to register and window writes | done |
| Matrix lanes as scan kernels (RAM gather, multiplier sharing in ExHdl) | waits for ExHdl, see [NEEDS.md](NEEDS.md) |
| Place and route (Vivado), clock crossing for the bus side, AES67 and PCIe attachment | later |
| Sample-rate tools | later |

## API

```elixir
# design in floats, quantise, run the fixed-point kernel
coef = ExAudio.Filter.design(:peaking, 1000, 48_000, q: 1.0, gain_db: 6)
ExAudio.Filter.magnitude_db(coef, 1000, 48_000)          #=> 6.0
cq = ExAudio.Biquad.quantize(coef)                       # {b0, b1, b2, a1, a2} integers
{ys, _state} = ExAudio.Biquad.run(samples_24bit, cq)

# every kernel has a spec for the hardware flow
spec = ExAudio.Dynamics.spec(:compressor, threshold_db: -20, ratio: 4, knee_db: 6)
{:ok, scan} = ExAudio.Q.analyze(spec, ii: :auto)         # ranges proven, loop latency
{:ok, design} = ExAudio.Q.to_sv(spec, name: "comp", channels: scan.loop_latency)
{y, _} = ExAudio.Q.run(spec, samples)                    # the Nx reference
```

| Kernel | Step function | State |
|---|---|---|
| `Biquad.step/3` | `(x, state, {b0, b1, b2, a1, a2})` | `{x1, x2, y1, y2, res}` |
| `Strip.eq/3`, `Strip.step/3` | cascade, cascade + gate + compressor | per section, gate, envelope |
| `Dynamics.envelope/3`, `gate/3`, `compressor/3` | parameters from `gate_params/1`, `compressor_params/1` | envelope, gate state |
| `Meter.peak/3`, `Meter.rms/3` | `{hold, decay, clip}`, `k` | peak and hold, mean square |
| `Matrix.step/3`, `Matrix.mac/3` | one output row at once; as a stream of `{sample, gain}` pairs | saturation count; accumulator and slot |

Samples are 24 bit (Q1.23) in `s32`; audio, state and parameters are narrowed
with `param_ranges`, so the width check proves every intermediate. Formats,
error bounds and the reasons for direct form I are in the moduledocs of
`ExAudio.Biquad` and `ExAudio.Dynamics`.

## Tests

`mix test` runs the unit and property tests (cookbook responses against the
analog prototypes, quantisation error, fixed point against the float
direct form I within a proven bound, no limit cycles, saturation, gate and
compressor curves and time constants, meters, mixer, register helpers) and,
with Verilator in `PATH`, the co-simulations (tag `:verilator`): the kernels
(biquad with parameter ports and with `channels: n`, strip with baked
constants, envelope, gate, compressor, limiter, meters, the mixer row, parallel
and streaming) bit for bit against the Nx reference with and without
backpressure, and the mixer (see [The mixer](#the-1024-channel-mixer)): strip
banks and the whole top level at 1024 channels against the per-channel Nx
references, the matrix cycle by cycle against `ExAudio.Matrix` in both
simulators.

The three 1024 channel co-simulations are tagged `:slow` (strip bank 20 s, matrix
50 s, top level 70 to 90 s on a shared 14 core machine); `mix test` runs
everything in about 90 s, `mix test --exclude slow` leaves them out,
`mix test --only verilator` runs the co-simulations alone.

## Hardware estimates

Yosys `synth_xilinx` (7 series, synthesis only, no timing), 48 kHz audio,
`mix ex_hdl.gen.sv ExAudio.Kernels --synth`. Since ExHdl splits the state
into groups with their own recurrence, a cascade of sections loops as one
section does: the whole strip runs at `ii` 8 (it was 53). Rows with
`channels: n` take one sample per cycle (`ii` 1) from `n` interleaved
streams with the state in registers:

| Kernel | latency | ii | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|---|
| biquad (coefficient ports) | 16 | 8 | 816 | 477 | 20 | 0 |
| biquad, `channels: 8` | 16 | 1 | 1273 | 1491 | 20 | 0 |
| gate | 17 | 7 | 795 | 669 | 12 | 0 |
| gate, `channels: 7` | 17 | 1 | 1151 | 1295 | 12 | 0 |
| compressor, 6 dB knee | 45 | 7 | 1026 | 735 | 17 | 3 |
| compressor, `channels: 7` | 45 | 1 | 1193 | 993 | 17 | 3 |
| peak meter | 3 | 7 | 361 | 323 | 4 | 0 |
| RMS meter | 24 | 7 | 605 | 442 | 6 | 1 |
| RMS meter, `channels: 7` | 24 | 1 | 781 | 735 | 6 | 1 |
| mixer row, 8 sources in parallel | 8 | 1 | 499 | 472 | 8 | 0 |
| mixer row as a stream (`mac`, 8 slots), `channels: 2` | 7 | 1 | 232 | 219 | 1 | 0 |
| strip: 4 biquads, constants | 61 | 8 | 2252 | 1220 | 78 | 0 |
| strip: 4 biquads, gate, compressor, constants | 110 | 8 | 3211 | 1806 | 97 | 3 |

Latency includes ExHdl's output buffer; the parameter ports include the
`p_load` shadow registers. The 1024 channel versions of the strip, with
state and coefficients in RAM, are in the mixer table below.

Independent of networking: the same kernels serve an AES67 mixer, a PCIe DSP
card or plain software.

## The 1024 channel mixer

`ExAudio.Mixer` is the whole signal path as RTL (`ExHdl.RTL`), built from
the kernels above plus a matrix written directly in the RTL DSL (the scan
backend cannot share multipliers or gather from a RAM yet, see
[NEEDS.md](NEEDS.md)):

```
s_axis ─ in strip ─┬─ frame RAM ─ 13 MAC lanes ─ sequencer ─ out strip ─┬─ m_axis
 TDM, tid = channel │   (2 banks)   (crosspoint RAMs)                    │
                    └─ in meters                                         └─ out meters
                    AXI4-Lite: ctrl, status, bank swap, meter parameters,
                    windows for coefficients, crosspoints and meter words
```

| Part | Module | What it is |
|---|---|---|
| Strip bank (twice) | `ExAudio.Mixer.Strip` | `ExAudio.Strip.cascade_spec/1` (4 biquads, gate, compressor) as one kernel with `channels: 1024`, state in UltraRAM folded over 4 rows per channel (`state_fold: 4`, one sample every 4 cycles), a two-bank RAM of 35 coefficient words per channel, `tid` and `tuser`; 32-bit window with a staging register file that commits a channel when its last word is written |
| Matrix | `ExAudio.Mixer.Matrix` | frame RAM written by the input strip (double buffered), `lanes` MAC pipelines, output RAM, sequencer; reference `ExAudio.Matrix.mix_clip/2` |
| Meters (twice) | `ExAudio.Mixer.Meters` | `Meter.peak/3` and `Meter.rms/3` for every channel, results in RAMs the host reads |
| Registers | `ExAudio.Mixer.Layout`, `ExAudio.Mixer.Regs` | `defregs` map: AXI4-Lite slave, C header (`Regs.c_header/0`), Markdown (`Regs.markdown/0`) |
| Host | `ExAudio.Mixer.Host` | musical units to register and window writes |
| Sizes | `ExAudio.Mixer.Config` | channels, slots, lanes and everything derived |

### Ports

| Port | |
|---|---|
| `clk`, `rst_n` | one clock, synchronous active-low reset |
| `s_axis` | AXI4-Stream in: `tdata` 24 bit (Q1.23), `tid` 10 bit channel, `tuser[0]` frame start (channel 0), `tvalid`/`tready`. Every frame carries all channels in increasing order, at most one frame per 5208 cycles, gaps in `tvalid` allowed. Taken only when `ctrl.enable` is set, at most one sample every 4 cycles (`tready`) |
| `m_axis` | AXI4-Stream out: `tdata` 24 bit, `tid`, `tuser[0]` frame start, `tuser[1]` the sample saturated in the matrix |
| `s_axil` | AXI4-Lite slave, 21-bit byte addresses |

### Cycle budget

At 48 kHz and 250 MHz a frame is 250 000 000 / 48 000 = 5208 cycles.

- Strips: one sample every 4 cycles, 4096 cycles per frame (79 %), 110
  cycles deep. The state of a channel is spread over 4 rows of the state
  memory (`ExAudio.Mixer.Config`, ExHdl's `state_fold`), which is what lets
  it fit 3 UltraRAMs per bank instead of 17. The loop of a section is 8
  cycles in the 250 MHz UltraScale+ model, far below the 4096 cycles
  between two samples of a channel, so the state RAM needs no forwarding.
- Matrix: 1024 outputs x 64 sources = 65 536 products per frame.
  `lanes = ceil(65 536 / 5208) = 13` (12.6). Lane `l` computes outputs
  `79 l ... 79 l + 78` (`ceil(1024 / 13) = 79`, the last lane 76), each
  64 cycles: `79 x 64 = 5056` cycles plus a 7 cycle pipeline: **5063 cycles
  of 5208** (97.2 %, 145 spare). `Config.new/1` adds lanes until the
  compute time fits the frame (16 outputs x 4 slots in 20 cycles gets 6
  lanes of 3 outputs, 19 cycles).
- Latency without stalls from the first accepted input sample to the first
  output sample: `1023 x 4 + 110 + 5065 + 110 = 9377` cycles (37.5 µs, 1.8
  frames): the rest of the input frame, the input strip, the matrix (starts
  when channel 1023 has left the input strip, first result 5065 cycles
  later), the output strip. Checked in the top-level co-simulation
  (`Mixer.latency/2`). Unfolded (`state_fold: 1`, 17 UltraRAMs per bank)
  it is `1023 + 107 + 5065 + 107 = 6302` cycles (25.2 µs).
- The output sequencer streams the 1024 results in channel order as fast
  as the output strip takes them (one every 4 cycles), while the lanes
  already compute the next frame (output RAM and frame RAM are double
  buffered).

The MAC is a 24 x 18 bit multiply (Q1.23 sample, Q3.15 gain as 18-bit two's
complement), input registers, product register and a 48-bit accumulator
that starts with the rounding constant `2^14` (one DSP48E2 per lane). Sixty-four
products of at most `2^40` fit in 48 bits. The result is `>> 15`,
saturated to 24 bit, and the saturation flag travels in `tuser[1]`.

### Resources

Yosys `synth_xilinx -family xcup` (synthesis only, no placement or timing;
`mix ex_hdl.gen.sv ExAudio.Mixer --synth --family xcup`), with the XCKU3P
(162 720 LUT, 325 440 FF, 1368 DSP48E2, 720 RAMB18, 48 URAM) for scale. SRL
shift registers (pipeline delays) are counted separately, not as LUT:

| Part | LUT | FF | DSP48E2 | RAMB18 | URAM | SRL | LUTRAM |
|---|---|---|---|---|---|---|---|
| input strip bank (4 biquads, gate, compressor, 1024 channels, state folded over 4 rows) | 4551 | 10 210 | 77 | 131 | 3 | 2301 | 4 |
| output strip bank | 4554 | 10 210 | 77 | 131 | 3 | 2305 | 4 |
| matrix (13 lanes) | 2508 | 2751 | 13 | 169 | 0 | 0 | 208 |
| meters (one side) | 1105 | 1426 | 9 | 12 | 0 | 250 | 9 |
| **whole top** (`ea_mixer_1024`: both strips, matrix, both meters, register file) | 14 090 | 26 237 | 185 | 455 | 6 | 5106 | 234 |
| XCKU3P share | 8.7 % | 8.1 % | 13.5 % | 63.2 % | 12.5 % | | |

Numbers of wave 5 (ExHdl with split DSP products and `state_fold`). The
whole top synthesises in 6 - 11 minutes with about 1.1 GB of memory; the
register file and glue cost about 270 LUT and 214 FF over the parts. An
earlier run of the top on the shared host exited with status 1 and an empty
message; it did not reproduce in three reruns.

The block RAMs of a strip bank are the coefficient banks (35 words x 32 bit
x 1024 channels x 2 banks, 2.3 Mbit); its state is in 3 UltraRAMs (17
unfolded, wave 3). Folding costs flip-flops: the state of the later
sections waits in pipeline registers for its stage (about 13 500 bits per
bank, most of the FF growth since wave 3); `state_row_bits: 36` gives 5
UltraRAMs per bank for about 6200 bits. The matrix has 13 copies of the
frame RAM (one read port per lane, 2 x 1024 x 24 bit) and the crosspoint
RAMs (65 536 x 28 bit in 13 pieces).

### Host side

```elixir
host = ExAudio.Mixer.Host.new()
alias ExAudio.Mixer.Host

strip = [
  eq: [{:highpass, 80}, {:peaking, 1000, q: 2.0, gain_db: 4}, {:highshelf, 8000, gain_db: -3}],
  gate: [open_db: -55, hold_ms: 80],
  compressor: [threshold_db: -18, ratio: 3, knee_db: 6, attack_ms: 5, release_ms: 120]
]

matrix =
  ExAudio.Matrix.new(n_in: 1024, n_out: 1024, slots: 64)
  |> ExAudio.Matrix.connect(0, 17, ExAudio.Matrix.db(-6))      # output 0 gets input 17 at -6 dB

writes =
  Host.meter_writes(host, hold_ms: 500, decay_ms: 300, tau_ms: 300) ++
    Host.strip_writes(host, :in, 17, strip) ++
    Host.matrix_writes(host, matrix) ++
    Host.swap(host, :inputs) ++ Host.enable(host)             # [{byte_offset, 32_bit_value}]
```

Every function returns `{byte_offset, value}` lists (AXI4-Lite writes); the
offsets and encodings come from the register map through `ExHdl.Regs`.
Reads: `Host.offset(host, :status)` and `Host.decode_status/2`,
`Host.meter_offsets/3`, `Host.decode_peak/1` (dB, linear, clip) and
`Host.decode_rms/1` (dB re full scale).

Procedure and rules (details in the moduledocs):

1. After reset wait for `status.busy` = 0 (the state RAMs are cleared, 1024 cycles).
2. Write the strips (they go to the idle bank), the crosspoints and the meter
   parameters, then `swap` (the written bank becomes the active one at the
   next frame start; the first swap is not optional), then `ctrl.enable`.
3. To change a strip while running: write its words (the last word commits
   the channel into the idle bank) for every channel that changes, then
   `swap`; `status.in_pending`/`out_pending` read 0 when the old bank can
   be written again. A swap switches all channels at one frame start.
4. Crosspoints are written live (`Host.matrix_diff/3`: only the outputs whose
   row changed). A row being rewritten can be mixed from old and new
   entries for one frame.
5. Sticky status bits: `overrun_compute` (a frame ended while the lanes
   were busy: frames closer than 5063 cycles; the frame is not mixed),
   `overrun_output` (the output stream was still busy with the previous frame:
   the downstream stalled for most of a frame; the frame is dropped),
   `sync_error` (the frame start flag and channel 0 disagree). Write 1 to clear.

### What the tests check

- `mixer_strip_test.exs`: the strip bank (RTL wrapper with the staging window)
  in Verilator for 24 and for **1024 channels**: every channel has its own
  strip (distinct filters, gate and compressor settings), a bank swap in the middle of the
  stream while part of the idle bank is still being written, random gaps, a
  sideband per sample; every output sample against the Nx reference of
  its channel (`ExAudio.Strip.spec/2` run with the channel's parameters and
  state across the swap).
- `mixer_matrix_test.exs`: the matrix cycle by cycle against a model
  built on `ExAudio.Matrix.mix_clip/2` with `Cosim.check_model/4` (the
  model sees only the ports and predicts every output beat, `busy`, `clip`
  and the overrun flags), in the BEAM simulator and Verilator, with output
  backpressure, frames back to back, overrun cases, 1 lane and uneven
  lanes, and the full 1024 x 64 x 13 lane geometry with three frames at
  the 5208-cycle frame budget.
- `mixer_top_test.exs`: the top level in Verilator, driven only through its
  ports with `Host` writes: configuration over AXI4-Lite, a refused frame
  while disabled, nine frames with a bank swap on both strip banks, a bad
  frame start flag. Expected: Nx strips, `Matrix.mix_clip/2`, Nx strips; the
  meter words read through the windows against `ExAudio.Meter` over the
  same samples; `frames`, `clips`, status; latency of 6328 cycles at 1024 channels. The
  same at 1024 channels (3 frames at 5208 cycles, ~70 s, tagged `:slow`).
- `mixer_host_test.exs`: the register slave in the BEAM simulator: every
  host write lands in its field or window word, strips and crosspoints
  encode what the kernels expect, bypassed gate and compressor are transparent.

### Limits

- One clock; the bus side needs a clock crossing in a real design
  (`pc_clock: :separate` of the kernels and `ExHdl.RTL.CDC` exist for it).
- A frame carries all 1024 channels in increasing order; a channel missing
  or a repeated channel within the loop window breaks the state RAM rule.
- The 250 MHz target is a timing model (NEEDS.md, 6): nothing was placed.
- Meters keep the clip flag of the last sample only; the held peak
  stays at the clip level for the hold time and serves as the indicator.
- 24-bit wide streams; no sample rate conversion, no dither.

## The hardware library set

ExHdl itself only provides the basics (RTL DSL, simulation, SystemVerilog,
targets, tool drivers). Function lives in these siblings:

| Library | Scope |
|---|---|
| [ex_hdl_cores](https://github.com/marcnnn/ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](https://github.com/marcnnn/ex_hdl_xilinx) | Xilinx primitives, constraints, boards |
| [ex_net](https://github.com/marcnnn/ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](https://github.com/marcnnn/ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](https://github.com/marcnnn/ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](https://github.com/marcnnn/ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](https://github.com/marcnnn/ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Development

Sibling libraries come from a checkout next to this one when there is one
(`../exhdl` for ex_hdl, `../<name>` for the others), otherwise from GitHub.

```sh
mix test
```


## License

Apache-2.0, see `LICENSE`.
