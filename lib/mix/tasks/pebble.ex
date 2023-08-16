defmodule Mix.Tasks.Local.Pebble do
  @moduledoc """
  Run a local ACME server using Pebble.
  """

  use Mix.Task

  @impl true
  def run(args) do
    force = "force" in args

    if force or not File.exists?(JumpWire.ACME.Pebble.binary()) do
      System.cmd("go", ["install", "github.com/letsencrypt/pebble/...@latest"])
    end
  end
end
