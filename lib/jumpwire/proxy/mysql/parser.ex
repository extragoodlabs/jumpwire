defmodule JumpWire.Proxy.MySQL.Parser do
  defmacro uint(size) do
    quote do
      size(unquote(size)) - unit(8) - little
    end
  end

  defmacro int1(), do: quote(do: 8 - signed)
  defmacro uint1(), do: quote(do: 8)
  defmacro int2(), do: quote(do: 16 - little - signed)
  defmacro uint2(), do: quote(do: 16 - little)
  defmacro int3(), do: quote(do: 24 - little - signed)
  defmacro uint3(), do: quote(do: 24 - little)
  defmacro int4(), do: quote(do: 32 - little - signed)
  defmacro uint4(), do: quote(do: 32 - little)
  defmacro int8(), do: quote(do: 64 - little - signed)
  defmacro uint8(), do: quote(do: 64 - little)

  def next(""), do: :eof
  def next(<<len::uint3, seq, payload::binary-size(len), rest::binary>>) do
    {payload, seq, rest}
  end
  def next(_), do: :error
end
