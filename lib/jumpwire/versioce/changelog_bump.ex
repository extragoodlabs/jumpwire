if Code.ensure_loaded?(Versioce.PostHook) do
  defmodule JumpWire.Versioce.ChangelogBump do
    @moduledoc """
    Bump the changelog with the new version.
    """

    use Versioce.PostHook

    @path "CHANGELOG.md"

    def run(version) do
      data = File.read!(@path)
      |> String.replace("## UNRELEASED", "## UNRELEASED\n\n## #{version}")

      File.write!(@path, data)

      {:ok, version}
    end
  end
end
