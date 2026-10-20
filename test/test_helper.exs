# :verilator - co-simulation, needs verilator in PATH
exclude = if System.find_executable("verilator"), do: [], else: [verilator: true]
ExUnit.start(exclude: exclude)
