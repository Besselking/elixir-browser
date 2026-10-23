# Tests tagged `:slow` (the JS differential oracles over the whole corpus and a few others, each
# over 1 s) are left out of a local `mix test`. CI sets CI=true and runs them; locally use
# `mix test --include slow` or `mix test --only slow`.
slow = if System.get_env("CI") in [nil, "", "false"], do: [:slow], else: []
ExUnit.start(exclude: [:corpus | slow])
