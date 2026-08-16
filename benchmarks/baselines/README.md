# Benchmark baselines

Each file is tied to one Zig version, optimization mode, operating system, and
CPU architecture. Update it only from the matching isolated CI job or a known
equivalent machine.

An omitted `max_regression_basis_points` is deliberate: the timing is
published but cannot fail CI. Add a numeric threshold only after reviewing
multiple runs on that platform. Workload-set, checksum, and environment drift
always fail because they mean the comparison is no longer valid.
