defmodule JumpWire.ACMETest do
  use ExUnit.Case, async: true
  alias JumpWire.ACME

  test "checking of domain validity" do
    assert ACME.validate_domain("") == :invalid

    long_hostname = String.duplicate("a", 65)
    assert ACME.validate_domain(long_hostname) == :invalid

    assert ACME.validate_domain("example.com") == :ok

    subdomain = String.duplicate("a", 63)
    assert ACME.validate_domain("#{subdomain}.example.com") == :ok
  end
end
