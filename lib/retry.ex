defmodule JumpWire.Retry do
  @moduledoc """
  Helper module that wraps Retry to avoid some boilerplate.
  """

  require Retry

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Retry, except: [retry: 2]
      import Retry.DelayStreams
      import JumpWire.Retry
    end
  end

  defmacro retry(opts, do: do_clause) do
    quote do
      Retry.retry unquote(opts) do
        unquote(do_clause)
      after
        res -> res
      else
        err -> err
      end
    end
  end

  defmacro retry(opts, do: do_clause, after: after_clause) do
    quote do
      Retry.retry unquote(opts) do
        unquote(do_clause)
      after
        unquote(after_clause)
      else
        err -> err
      end
    end
  end

  defmacro retry(opts, do: do_clause, else: else_clause) do
    quote do
      Retry.retry unquote(opts) do
        unquote(do_clause)
      after
        res -> res
      else
        unquote(else_clause)
      end
    end
  end

  defmacro retry(opts, clauses) do
    quote do
      Retry.retry(unquote(opts), unquote(clauses))
    end
  end
end
