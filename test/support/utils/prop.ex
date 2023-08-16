defmodule JumpWire.TestUtils.Prop do
  @moduledoc """
  Collection of generators to be used on tests.
  """

  use PropCheck

  @doc """
  Generator that produces a valid-looking blob of text. Alphanumeric
  with a few allowed special characters.
  """
  def char_like(vocabulary \\ :all)
  def char_like(:no_special_chars) do
    let l <- non_empty(list(union([range(?A, ?Z), range(?a, ?z), range(?0, ?9)]))) do
      to_string(l)
    end
  end
  def char_like(_) do
    let l <- non_empty(list(
          union([
            range(?A, ?Z),
            range(?a, ?z),
            range(?0, ?9),
            oneof([?., ?-, ?,, ?*]),
          ]))
    ) do
      to_string(l)
    end
  end


  def text_like(vocabulary \\ :all, opts \\ []) do
    size = opts[:size] || Enum.random(1..8)

    let l <- vector(size, char_like(vocabulary)) do
      to_string(l)
    end
  end

  @doc """
  Generator for producing MIME content type strings.
  """
  def mime_type() do
    let {first, second} <- {text_like(), text_like()} do
      first <> "/" <> second
    end
  end

  def http_header() do
    let l <- non_empty(
      list(
        union([
          range(?A, ?Z),
          range(?a, ?z),
          oneof([?-]),
        ])
      )
    ) do
      to_string(l)
    end
  end

  @doc """
  Generator for a properly formatted, random UUIDv4 string.
  """
  def uuid4() do
    let chars <- [hex_string(8), hex_string(4), hex_string(4), hex_string(4), hex_string(12)] do
      Enum.join(chars, "-")
    end
  end

  @doc """
  Generator a single lowercase hex digit as a char.
  """
  def hex_digit() do
    union([range(?a, ?f), range(?0, ?9)])
  end

  @doc """
  Generator a string of the specified size containing only valid hex digits.
  """
  def hex_string(size) do
    let l <- vector(size, hex_digit()) do
      to_string(l)
    end
  end

  def path() do
    size = Enum.random(1..8)
    let l <- vector(size, text_like(:no_special_chars)) do
      "/" <> Enum.join(l, "/")
    end
  end
end
