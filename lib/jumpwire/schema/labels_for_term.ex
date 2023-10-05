defmodule JumpWire.Schema.LabelsForTerm do
  @spec labels(String.t()) :: {:ok, String.t() | nil, [String.t()]}
  def labels(string = <<?a, _::binary>>) do
    labels =
      case ["address", "address one", "address 1", "address two", "address 2"]
           |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end) do
        nil -> []
        _ -> ["pii"]
      end

    labels =
      case ["account id", "account secret", "account number", "aws access key", "aws key secret", "access key", "access secret"]
           |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end) do
        nil -> labels
        _ -> ["secret" | labels]
      end

    if length(labels) > 0 do
      labels
    else
      nil
    end
  end

  def labels(string = <<?c, _::binary>>) do
    match =
      ["cc", "credit card", "credit card number", "credit card num", "city"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    if is_nil(match) do
      nil
    else
      ["pii"]
    end
  end

  def labels(string = <<?d, _::binary>>) do
    match =
      ["dob", "date of birth"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    if is_nil(match) do
      nil
    else
      ["pii"]
    end
  end

  def labels(string = <<?f, _::binary>>) do
    match =
      ["first name", "f name"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    if is_nil(match) do
      nil
    else
      ["pii"]
    end
  end

  def labels(string = <<?g, _::binary>>) do
    keywords = ["gender"]

    case Enum.find(keywords, fn t -> String.jaro_distance(t, string) > 0.8 end) do
      nil -> nil
      _ -> ["pii"]
    end
  end

  def labels(string = <<?l, _::binary>>) do
    match =
      ["last name", "l name"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    case match do
      nil -> nil
      _ -> ["pii"]
    end
  end

  def labels(string = <<?o, _::binary>>) do
    match =
      ["oauth token", "oauth access token", "oauth refresh token"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    case match do
      nil -> nil
      _ -> ["secret"]
    end
  end

  def labels(string = <<?p, _::binary>>) do
    match =
      ["password", "pword"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    case match do
      nil -> nil
      _ -> ["secret"]
    end
  end

  def labels(string = <<?r, _::binary>>) do
    match =
      ["refresh token"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    case match do
      nil -> nil
      _ -> ["secret"]
    end
  end

  def labels(string = <<?s, _::binary>>) do
    match =
      ["social", "ssn", "social security number", "ss number", "street", "sex", "street one", "street two"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    case match do
      nil -> nil
      _ -> ["pii"]
    end
  end

  def labels(string = <<?u, _::binary>>) do
    match =
      ["username"]
      |> Enum.find(fn t -> String.jaro_distance(t, string) > 0.8 end)

    case match do
      nil -> nil
      _ -> ["sensitive"]
    end
  end

  def labels(_), do: nil
end
