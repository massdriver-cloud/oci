# OCI

![OCI Plug Logo](assets/logo.png)

[![Hex.pm](https://img.shields.io/hexpm/v/oci.svg)](https://hex.pm/packages/oci)
[![Hex.pm](https://img.shields.io/hexpm/dt/oci.svg)](https://hex.pm/packages/oci)
[![Hex.pm](https://img.shields.io/hexpm/l/oci.svg)](https://hex.pm/packages/oci)
[![CI](https://github.com/massdriver-cloud/oci/actions/workflows/ci.yml/badge.svg)](https://github.com/massdriver-cloud/oci/actions/workflows/ci.yml)
[![Credo](https://img.shields.io/badge/Credo-Enabled-brightgreen)](https://github.com/rrrene/credo)

An [OCI](https://opencontainers.org/) (Open Container Initiative) compliant V2 registry server implementation for Elixir. This library provides a plug-based solution that can be integrated into any Elixir web application, with configurable storage and authentication adapters.

**The included adapters are nowhere near production-ready. Make sure to implement your own before you go and have a bad time.**

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
    {:oci, "~> 0.0.2"}
  ]
end
```

## Usage

### Basic Phoenix Integration

See an example in [the test setup](./test/support/router.ex).

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

**endpoint.ex**
```elixir
defmodule Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :oci

  plug(Plug.Parsers,
    parsers: [OCI.Plug.Parser, :json], # <- stick this bad boi in here. It'll full body read blob uploads and parse/digest manifests.
    pass: ["*/*"],
    json_decoder: Jason,
    length: 20_000_000
  )

  plug(TestRegistryWeb.Router)
end
```

**router.ex:**

```elixir
use Phoenix.Router
import OCI.PhoenixRouter

scope "/v2" do
  forward("/", OCI.Plug, [])
end
```

### ORAS CLI Interaction

```bash
# Push an artifact
oras push localhost:5000/myorg/myapp:latest ./my-artifact.txt

# Pull an artifact
oras pull localhost:5000/myorg/myapp:latest
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

### Custom Storage Adapter

**TODO** See [adapter](./lib/oci/storage/adapter.ex) and [local fs example](./lib/oci/storage/local.ex)

### Custom Authentication

**TODO** See [adapter](./lib/oci/auth/adapter.ex) and [basic/static example](./lib/oci/auth/static.ex)

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