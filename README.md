# OCI

![OCI Logo](logo.png)

[![Hex.pm](https://img.shields.io/hexpm/v/oci.svg)](https://hex.pm/packages/oci)
[![Hex.pm](https://img.shields.io/hexpm/dt/oci.svg)](https://hex.pm/packages/oci)
[![Hex.pm](https://img.shields.io/hexpm/l/oci.svg)](https://hex.pm/packages/oci)
[![CI](https://github.com/massdriver-cloud/oci/actions/workflows/ci.yml/badge.svg)](https://github.com/massdriver-cloud/oci/actions/workflows/ci.yml)
[![Credo](https://img.shields.io/badge/Credo-Enabled-brightgreen)](https://github.com/rrrene/credo)

An [OCI](https://opencontainers.org/) (Open Container Initiative) compliant V2 registry server implementation for Elixir. This library provides a plug-based solution that can be integrated into any Elixir web application, with configurable storage and authentication adapters.

**This is nowhere near production-ready.**

## Features

- Full OCI Distribution Specification V2 compliance
- Pluggable storage backend
- Configurable authentication
- Easy integration with Phoenix applications
- Support for Docker and OCI image formats
- Compatible with Docker CLI and ORAS tools
- Support for various repository naming conventions (`nginx`, `hexpm/elixir`, `big-corp/big-team/big-project`)

## Repository Naming

This registry supports the standard OCI repository naming convention with strict `namespace/name`, `org/team/project`, or whatever wild ass `/` party you can dream up.

- ✅ `myapp` - Single-level names
- ✅ `myorg/myapp` - Standard namespace/name format
- ✅ `org/team/project` - Multi-level namespaces
- IT CAN JUST KEEP GOING (I THINK)

## Installation

The package can be installed by adding `oci` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:oci, "~> 0.0.1"}
  ]
end
```

## Usage

### Basic Phoenix Integration

**config/config.ex**

```elixir
config :oci,
  max_manifest_size: 4 * 1024 * 1024,
  max_blob_upload_chunk_size: 10 * 1024 * 1024,
  enable_blob_deletion: true,
  enable_manifest_deletion: true,
  repo_name_pattern: ~r/^([a-z0-9]+(?:[._-][a-z0-9]+)*)(\/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$/
  storage: [
    adapter: OCI.Storage.Local,
    config: [
      path: "./tmp/"
    ]
  ]
```

**router.ex:**

```elixir
use Phoenix.Router
import OCI.PhoenixRouter

scope "/v2" do
  forward("/", OCI.Plug, [])
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
```

### Custom Authentication

```elixir
```

## Development

### Running Tests

This will run basic plug tests and the [conformance suite](./test/support/conformance_suite.ex) against a phoenix endpoint.

```bash
mix test
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Run the QA suite to ensure quality (`mix qa`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create new Pull Request

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## References

- [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec)
- [Docker Registry HTTP API V2](https://docs.docker.com/registry/spec/api/)
- [ORAS CLI](https://oras.land/cli/)