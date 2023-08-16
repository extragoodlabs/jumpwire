defmodule TupleEncoder do
  defimpl Jason.Encoder, for: Tuple do
    def encode(data, opts) when is_tuple(data) do
      data
      |> Tuple.to_list()
      |> Jason.Encoder.List.encode(opts)
    end
  end
end
