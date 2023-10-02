We welcome everyone interested to contribute to JumpWire! The codebase is organized as follows:

- `lib` - Elixir source code
- `tests` - automated testing suite
- `native` - Rust code that interfaces with Elixir as NIFs
- `config` - Application configuration, separated by environment
- `priv` - Static non-code files that are compiled into releases

## Requirements

Elixir and Rust are required to build the project. The exact versions needed can vary - the minimal Elixir version supported can be found in [mix.exs](mix.exs), but the [Dockerfile](Dockerfile) used to build a release will have the versions known to work. There is also a `.tools-versions` with the proper versions. Checkout [asdf](https://asdf-vm.com/) for more info.

Before starting a dev environment for the first time, you must generate local secrets by running `mix deps.get` followed by `mix jumpwire.gen.secrets`. This will create a file at `config/dev.secrets.exs` which is omitted from source control.

[Pebble](https://github.com/letsencrypt/pebble/) is used as local ACME server for generating TLS certificates. It requires golang and can be setup with `mix local.pebble`.

JumpWire can be started from the source code with `iex -S mix`. This will use the `dev` environment and start a REPL shell for interacting with the BEAM. You can skip

## Testing

You can run all tests in the root directory with `mix test`. The tests expect to interact with a MySQL and PostgreSQL server on localhost.

Some tests are grouped to allow including or excluding them for faster iteration. For example, you run just PostgreSQL related tests with `mix test --only db:postgres`.

After your changes are done, please remember to run the linter against your updates: `mix credo diff origin/trunk`

## Reviewing changes

Once a pull request is sent, the JumpWire team will review your changes. We outline our process below to clarify the roles of everyone involved.

All pull requests must be approved by at least one committer before being merged into the repository. If any changes are necessary, the team will leave appropriate comments requesting changes to the code. Unfortunately, we cannot guarantee a pull request will be merged, even when modifications are requested, as the JumpWire team will re-evaluate the contribution as it changes.

Committers may also push style changes directly to your branch. If you would rather manage all changes yourself, you can disable the "Allow edits from maintainers" feature when submitting your pull request.

When the review finishes, your pull request will be squashed and merged into the repository. If you have carefully organized your commits and believe they should be merged without squashing, please mention it in a comment.
