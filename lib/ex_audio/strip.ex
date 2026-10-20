defmodule ExAudio.Strip do
  @moduledoc """
  Channel strip: a cascade of biquads, then optionally the gate and the
  compressor/limiter. One sample in, one out, 24 bit throughout.

  The cascade passes the rounded 24-bit output of each section to the
  next (each section adds its 0.5 LSB rounding; the 8 guard bits stay
  inside a section). Sections run in the order given: put the sections
  with the largest gain last only if the signal cannot clip before them;
  clipping inside the cascade saturates, it does not wrap.

  State: `{sections, gate, compressor}`, `sections` a tuple of
  `ExAudio.Biquad` states; parameters `{coefs, gate_params, comp_params}`
  with `coefs` a tuple of `ExAudio.Biquad` coefficient tuples. With
  `dynamics: false` the kernel is only the cascade (`eq/3`: state and
  parameters are just the tuples of sections).

      iex> spec = ExAudio.Strip.spec([ExAudio.Biquad.identity(), ExAudio.Biquad.identity()])
      iex> {y, _} = ExAudio.Q.run(spec, [1000, -2000, 3000])
      iex> Nx.to_flat_list(y)
      [1000, -2000, 3000]
  """
  import Nx.Defn

  alias ExAudio.{Biquad, Dynamics, Q}

  @doc "Cascade of biquads, `eq(x, sections, coefs)`; returns `{y, next_sections}`."
  defn eq(x, sections, coefs), do: cascade(x, sections, coefs)

  deftransformp cascade(x, sections, coefs) do
    {y, next} =
      sections
      |> Tuple.to_list()
      |> Enum.zip(Tuple.to_list(coefs))
      |> Enum.map_reduce(x, fn {state, coef}, x ->
        {y, next} = Biquad.step(x, state, coef)
        {next, y}
      end)
      |> then(fn {states, y} -> {y, states} end)

    {y, List.to_tuple(next)}
  end

  @doc """
  Full strip `step(x, {sections, gate, comp}, {coefs, gate_params, comp_params})`.
  Returns `{y, next_state}`.
  """
  defn step(x, state, params) do
    {sections, gate, comp} = state
    {coefs, gate_params, comp_params} = params
    {y, sections} = cascade(x, sections, coefs)
    {y, gate} = Dynamics.gate(y, gate, gate_params)
    {y, comp} = Dynamics.compressor(y, comp, comp_params)
    {y, {sections, gate, comp}}
  end

  @doc """
  Kernel specification (see `ExAudio.Biquad.spec/1`) for a strip with the
  given quantised biquads `coefs` (a list). Options: `:dynamics` (default
  `false`: only the cascade), `:gate` and `:compressor` (design options for
  `ExAudio.Dynamics`), `:baked` (default `false`; `true` makes the coefficients and
  dynamics parameters constants of the kernel, so the module has no
  parameter ports).
  """
  def spec(coefs, opts \\ []) do
    n = length(coefs)
    r = Biquad.ranges()
    sections = List.duplicate(Biquad.init_state(), n) |> List.to_tuple()

    eq_ranges = %{
      sample: r.sample,
      state: List.duplicate(r.state, n),
      params: List.duplicate(r.params, n)
    }

    spec =
      if Keyword.get(opts, :dynamics, false) do
        {g, c} = {Dynamics.gate_ranges(), Dynamics.compressor_ranges()}
        gate = opts |> Keyword.get(:gate, []) |> Dynamics.gate_params()
        comp = opts |> Keyword.get(:compressor, []) |> Dynamics.compressor_params()

        Q.spec(
          &step/3,
          {sections, Dynamics.init_gate(), Dynamics.init_compressor()},
          {List.to_tuple(coefs), gate, comp},
          %{
            eq_ranges
            | state: eq_ranges.state ++ [g.state, c.state],
              params: eq_ranges.params ++ [g.params, c.params]
          },
          ["coefs", "gate", "comp"]
        )
      else
        Q.spec(&eq/3, sections, List.to_tuple(coefs), eq_ranges, ["coefs"])
      end

    if Keyword.get(opts, :baked, false), do: bake(spec), else: spec
  end

  # The parameters become constants of a two-argument kernel; their ranges are
  # then exact and the width check sees the values.
  defp bake(spec) do
    {fun, params} = {spec[:fun], spec[:params]}
    n = 1 + length(Nx.Defn.Composite.flatten_list([spec[:init]]))

    Keyword.merge(spec,
      fun: fn x, state -> fun.(x, state, params) end,
      args: Enum.take(spec[:args], 2),
      param_ranges: Map.filter(spec[:param_ranges], fn {i, _} -> i < n end),
      param_names: [],
      params: nil
    )
  end
end
