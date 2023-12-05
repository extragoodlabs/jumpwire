defmodule JumpWire.MixProject do
  use Mix.Project

  @docker_image "ghcr.io/extragoodlabs/jumpwire"
  @version "4.0.0"

  def project do
    [
      app: :jumpwire,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      build_embedded: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        # use MIX_ENV=test automatically when running mix coveralls tasks
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :hydrax],
      mod: {JumpWire.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/mocks"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:uniq, "~> 0.1"},
      {:external_service, "~> 1.1.2"},
      {:ecto, "~> 3.9"},
      {:typed_struct, "~> 0.2.1"},
      {:ecto_morph, "~> 0.1.25"},
      {:typed_ecto_schema, "~> 0.4.1"},
      {:polymorphic_embed, "~> 3.0.5"},
      {:socket, "~> 0.3"},
      # Using a git reference until a release is pushed containing this PR:
      # https://github.com/J0/phoenix_gen_socket_client/pull/64
      {:phoenix_gen_socket_client, github: "J0/phoenix_gen_socket_client", ref: "11ca72274437e48e4cbacc713e7e5300dcb78abc"},
      {:websocket_client, "~> 1.5"},
      {:warpath, "~> 0.6.2"},
      {:ex_aws, "~> 2.2.4", override: true},
      {:configparser_ex, "~> 4.0"},
      {:ex_aws_sts, "~> 2.2"},
      # xml_builder 2.1.4 works fine but has deprecation notices printed to stderr on
      # every use of ex_aws_route53
      # https://github.com/ex-aws/ex_aws_route53/issues/10
      {:xml_builder, "~> 2.0.0"},
      {:rustler, "~> 0.30.0"},
      {:phoenix_pubsub, "~> 2.0.0"},

      # Read config files
      {:yaml_elixir, "~> 2.9"},

      # Clustering
      {:hydrax, "~> 0.7"},
      {:libcluster, "~> 3.3.0"},
      {:libcluster_ec2, "~> 0.6.0"},

      # Cryptography
      {:cloak, "~> 1.1.1"},
      {:jose, "~> 1.11"},
      {:bcrypt_elixir, "~> 3.0"},
      {:libvault, "~> 0.2.4"},
      {:x509, "~> 0.8.4"},
      {:ex_aws_kms, "~> 2.2"},

      # Certificate management
      {:site_encrypt, github: "jumpwire-ai/site_encrypt"},

      # HTTP client
      {:tesla, "~> 1.4.0"},
      {:castore, "~> 1.0", override: true},
      {:mint, "~> 1.4"},
      {:jason, "~> 1.4.0"},
      {:oauth2, "~> 2.0"},

      # HTTP server
      {:plug_cowboy, "~> 2.6"},
      # bypass uses a very old version of ranch
      {:ranch, "~> 2.1.0", override: true},
      {:guardian, "~> 2.3"},
      {:plug_crypto, "~> 1.2"},
      {:samly, "~> 1.3.0"},

      # Database clients
      {:postgrex, "~> 0.16.1"},
      {:myxql, "~> 0.6.0"},

      # Observability
      {:telemetry, ">= 0.4.3"},
      {:telemetry_metrics, "~> 0.6"},
      {:cloud_watch, "~> 0.4.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:telemetry_metrics_statsd, "~> 0.6.1"},
      {:telemetry_metrics_cloudwatch, "~> 0.3.1"},
      {:flex_logger, "~> 0.2.1"},
      {:logger_file_backend, "~> 0.0.12"},
      {:sentry, "~> 8.0"},
      {:honeybadger, "~> 0.18"},

      # test and local dev tools
      {:mox, "~> 1.0", only: :test},
      {:mock, "~> 0.3.8", only: :test},
      {:git_hooks, "~> 0.6.3", only: :dev, runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:versioce, "~> 2.0.0", only: :dev},
      {:git_cli, "~> 0.3.0", only: :dev},
      {:excoveralls, "~> 0.10", only: :test},
      {:propcheck, "~> 1.4", only: [:test, :dev]},
      {:excontainers, github: "dallagi/excontainers", only: :test},

      # benchmarking and profiling tools
      {:benchee, "~> 1.1"},
      {:faker, "~> 0.17"}
    ]
  end

  defp aliases do
    [
      "release.docker": "cmd DOCKER_BUILDKIT=1 docker build -t #{@docker_image}:#{@version} -t #{@docker_image}:latest ."
    ]
  end

  defp releases do
    [
      jumpwire: [
        steps: [:assemble, :tar]
      ]
    ]
  end
end
