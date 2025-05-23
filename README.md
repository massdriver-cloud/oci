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

This registry supports the standard OCI repository naming convention with strict `namespace/name` format:

- ✅ `myorg/myapp` - Standard namespace/name format
- ✅ `library/nginx` - Library namespace
- ✅ `company/project` - Company namespace
- ❌ `myapp` - Single-level names not supported
- ❌ `org/team/project` - Multi-level namespaces not supported

Repository names must follow the pattern `{namespace}/{name}` where:
- `namespace`: Organization, user, or library identifier
- `name`: The specific image/artifact name

This ensures consistent routing and storage organization while maintaining compatibility with standard container registry conventions.

## Installation

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
# Example router.ex configuration
# TODO: Add router configuration example
```

### Docker CLI Interaction

```bash
# Example Docker CLI commands
# TODO: Add Docker CLI examples
```

### ORAS CLI Interaction

```bash
# Example ORAS CLI commands
# TODO: Add ORAS CLI examples
```

### Custom Storage Adapter

```elixir
# Example storage adapter implementation
# TODO: Add storage adapter example
```

### Custom Authentication

```elixir
# Example authentication implementation
# TODO: Add authentication example
```

## Configuration

The following configuration options are available:

```elixir
# Example config.exs configuration
# TODO: Add configuration examples
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

