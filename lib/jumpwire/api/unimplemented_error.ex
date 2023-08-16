defmodule JumpWire.API.UnimplementedError do
  defexception message: "Not implemented"

  defimpl String.Chars, for: __MODULE__ do
    def to_string(err), do: err.message
  end
end
