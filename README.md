# ExAudio

Audio processing written once as fixed-point step functions: they run on the
BEAM (Nx) and go through ExHdl's scan backend into time-multiplexed hardware,
bit-identical.

## Status

| Module | State |
|---|---|
| `ExAudio.Filter`: Audio EQ Cookbook designs (low/high pass, band pass, notch, peaking, shelves, all pass), magnitude and phase, float direct form I | done |
| `ExAudio.Biquad`: Q5.27 / Q2.30 coefficient quantisation, direct form I kernel with 8 guard bits and error feedback, proven error bound | done |
| `ExAudio.Strip`: cascade of biquads, optional gate and compressor | done |
| `ExAudio.Dynamics`: envelope follower, gate (hysteresis, hold), compressor and limiter (soft knee, log2/exp2 tables) | done |
| `ExAudio.Meter`: peak hold with clip flag, RMS (log2 level) | done |
| `ExAudio.Matrix`: sparse crosspoint table and mixer on the BEAM, kernels for one output row (parallel, and one multiplier streaming) | done |
| Verilator co-simulation of all kernels, Yosys estimates (`mix ex_hdl.gen.sv ExAudio.Kernels --synth`) | done |
| 1024 channel engine (state and coefficients in RAM, matrix with MAC sharing) | blocked on ExHdl, see [NEEDS.md](NEEDS.md) |
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
compressor curves and time constants, meters, mixer) and, with Verilator in
`PATH`, the co-simulations: biquad (parameter ports, `channels: n`), strip
(baked constants, gate and compressor), envelope, gate, compressor, limiter,
meters and the mixer row (parallel and streaming), bit for bit against the Nx reference with
and without backpressure. `mix test --only verilator` runs those alone (about
two minutes).

## Hardware estimates

Yosys `synth_xilinx` (7 series, synthesis only, no timing), 48 kHz audio;
`mix ex_hdl.gen.sv ExAudio.Kernels --synth`:

| Kernel | latency | ii | LUT | FF | DSP48E1 | RAMB18 |
|---|---|---|---|---|---|---|
| biquad (coefficient ports) | 16 | 9 | 760 | 588 | 20 | 0 |
| biquad, `channels: 9` | 16 | 1 | 1493 | 2665 | 20 | 0 |
| gate | 9 | 15 | 831 | 743 | 12 | 0 |
| gate, `channels: 15` | 9 | 1 | 1431 | 2070 | 12 | 0 |
| compressor, 6 dB knee | 46 | 7 | 1052 | 761 | 17 | 3 |
| compressor, `channels: 7` | 46 | 1 | 1206 | 1022 | 17 | 3 |
| peak meter | 4 | 7 | 357 | 349 | 4 | 0 |
| RMS meter | 24 | 7 | 605 | 442 | 6 | 1 |
| RMS meter, `channels: 7` | 24 | 1 | 782 | 735 | 6 | 1 |
| mixer row, 8 sources in parallel | 8 | 1 | 499 | 472 | 8 | 0 |
| mixer row as a stream (`mac`, 8 slots), `channels: 2` | 7 | 1 | 231 | 220 | 1 | 0 |
| strip: 4 biquads, constants | 43 | 36 | 2031 | 1403 | 78 | 0 |
| strip: 4 biquads, gate, compressor, constants | 83 | 53 | 3034 | 2186 | 97 | 3 |

Latency includes ExHdl's output buffer; the parameter ports include the
`p_load` shadow registers.

The step functions are what will run in the final design; the structure
around them (state and coefficients in RAM for 1024 channels, the matrix with
shared multipliers, channel sideband) does not exist in the scan backend yet.
[NEEDS.md](NEEDS.md) lists what it needs and why.

Independent of networking: the same kernels serve an AES67 mixer, a PCIe DSP
card or plain software.

## The hardware library set

ExHdl itself only provides the basics (RTL DSL, simulation, SystemVerilog,
targets, tool drivers). Function lives in these siblings:

| Library | Scope |
|---|---|
| [ex_hdl_cores](../ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](../ex_hdl_xilinx) | Xilinx primitives, constraints, boards |
| [ex_net](../ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](../ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](../ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](../ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](../ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Development

```sh
./scripts/checkout_siblings.sh   # path dependencies
mix test
```

