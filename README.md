# OCI

![OCI Logo](logo.png)

[![Hex.pm](https://img.shields.io/hexpm/v/oci.svg)](https://hex.pm/packages/oci)
[![Hex.pm](https://img.shields.io/hexpm/dt/oci.svg)](https://hex.pm/packages/oci)
[![Hex.pm](https://img.shields.io/hexpm/l/oci.svg)](https://hex.pm/packages/oci)
[![CI](https://github.com/massdriver-cloud/oci/actions/workflows/ci.yml/badge.svg)](https://github.com/massdriver-cloud/oci/actions/workflows/ci.yml)
[![Credo](https://img.shields.io/badge/Credo-Enabled-brightgreen)](https://github.com/rrrene/credo)

An [OCI](https://opencontainers.org/) (Open Container Initiative) compliant V2 registry server implementation for Elixir. This library provides a plug-based solution that can be integrated into any Elixir web application, with configurable storage and authentication adapters.

## Features

- Full OCI Distribution Specification V2 compliance
- Pluggable storage backend
- Configurable authentication
- Easy integration with Phoenix applications
- Support for Docker and OCI image formats
- Compatible with Docker CLI and ORAS tools
- Support for hierarchical repository naming (namespace/name)

## Repository Naming

This registry supports the standard OCI repository naming convention with strict `namespace/name`, `org/team/project`, or whatever wild ass `/` party you can dream up.

- ✅ `myapp` - Single-level names
- ✅ `myorg/myapp` - Standard namespace/name format
- ✅ `org/team/project` - Multi-level namespaces
- IT CAN JUST KEEP GOING (I THINK)

This ensures consistent routing and storage organization while maintaining compatibility with standard container registry conventions.

## Installation

**This is not yet production-ready.**

The package can be installed by adding `oci` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:oci, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Phoenix Integration

```elixir
# In your router.ex
use Phoenix.Router
import OCI.PhoenixRouter

scope "/v2" do
  oci_routes(repo: ":namespace/:name")
end
```

### Docker CLI Interaction

```bash
# Pull an image
docker pull localhost:5000/myorg/myapp:latest

# Push an image
docker push localhost:5000/myorg/myapp:latest

# List tags
curl -X GET http://localhost:5000/v2/myorg/myapp/tags/list
```

### ORAS CLI Interaction

```bash
# Push an artifact
oras push localhost:5000/myorg/myapp:latest ./my-artifact.txt

# Pull an artifact
oras pull localhost:5000/myorg/myapp:latest
```

### Custom Storage Adapter

```elixir
defmodule MyStorageAdapter do
  @behaviour OCI.Storage.Adapter

  defstruct [:path]

  def init(config) do
    %__MODULE__{path: Keyword.fetch!(config, :path)}
  end

  # Implement required callbacks...
end
```

### Custom Authentication

```elixir
defmodule MyAuthAdapter do
  @behaviour OCI.Auth.Adapter

  def authenticate(authorization) do
    # Implement your authentication logic
  end

  def authorize(ctx, action, resource) do
    # Implement your authorization logic
  end

  def challenge(registry) do
    {"Basic", ~s(realm="#{registry.realm}")}
  end
end
```

## Configuration

The following configuration options are available in your `config.exs`:

```elixir
config :oci,
  storage: [
    adapter: OCI.Storage.Local,
    config: [
      path: "./tmp/"
    ]
  ],
  json_library: Jason
```

## Development

### Running Tests

```bash
mix test
```

### Running Tests in Watch Mode

To automatically run tests when files change:

```bash
mix test.watch
```

### Running Credo

```bash
mix credo
```

### Running Dialyzer

```bash
mix dialyzer
```

### Running Documentation Generation

```bash
mix docs
```

### Running Full QA Suite

To run all quality assurance checks (tests, credo, dialyzer, and docs generation):

```bash
mix qa
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Run the QA suite to ensure quality (`mix qa`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create new Pull Request

Note: Before submitting a PR, please ensure all QA checks pass by running `mix qa`. This will run:
- Unit tests
- Code style checks (Credo)
- Static type checking (Dialyzer)
- Documentation generation

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## References

- [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec)
- [Docker Registry HTTP API V2](https://docs.docker.com/registry/spec/api/)
- [ORAS CLI](https://oras.land/cli/)

## TODO

* [ ] Expand registry error results to include details from storage adapters so provide more helpful http responses.
* [ ] move a check for the registry to the top of the plug and return {:error, :NAME_UNKNOWN} so the reset of the registry doesnt have to be so defensive.
* [ ] NAME_INVALID - Registry should be able to validate the name (storage adapter?
* [ ] Conformance [Github Action](https://github.com/opencontainers/distribution-spec/tree/main/conformance#github-action)
  * [ ] Include conformance report in PR comment
  * [ ] Publish report on hex release
* Config for optional registry configs
  * [ ] disable mounting
  * [ ] Support OCI-Chunk-Min-Length: <size>
  * [ ] Referrers API