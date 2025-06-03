defmodule OCI.Plug.Parser do
  @moduledoc """
  Parses the request body for OCI requests.

  This module is responsible for parsing the request body for OCI requests.
  It implements the `Plug.Parsers` behaviour to handle different content types
  specific to OCI (Open Container Initiative) operations.

  ## Content Types Handled
  - `application/octet-stream`: For binary blob uploads
  - `application/vnd.oci.image.manifest.v1+json`: For OCI image manifests
  """

  @behaviour Plug.Parsers

  @type opts :: keyword()

  @doc false
  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @doc """
  Parses the request body based on the content type.

  ## Content Types Handled

  ### application/octet-stream
  Handles binary blob uploads by reading the full body and storing
  it in the connection assigns under the `:oci_blob_chunk` key.

  ### application/vnd.oci.image.manifest.v1+json
  Handles OCI image manifest uploads by:
  1. Reading the full body
  2. Computing its SHA256 digest
  3. Storing the digest in the connection assigns
  4. Decoding the JSON manifest

  ### Other Content Types
  Passes through to the next parser in the chain.

  ## Parameters
    - conn: The Plug.Conn struct
    - type: The content type
    - subtype: The content subtype
    - headers: The request headers
    - opts: Parser options containing a :json_decoder key for manifest parsing

  ## Returns
    - For octet-stream: `{:ok, %{}, conn}` on successful parsing
    - For manifest: `{:ok, manifest, conn}` on successful parsing
    - For other types: `{:next, conn}` to pass to the next parser
    - `{:error, reason}` on failure
    - Raises `Plug.Parsers.ParseError` on JSON decode failure for manifests
  """
  @spec parse(Plug.Conn.t(), String.t(), String.t(), map(), opts()) ::
          {:ok, map(), Plug.Conn.t()} | {:error, term()} | {:next, Plug.Conn.t()}
  def parse(conn, "application", "octet-stream", _headers, opts) do
    read_full_body(conn, opts, "")
    |> case do
      {:ok, full_body, conn} ->
        conn = Plug.Conn.assign(conn, :oci_blob_chunk, full_body)

        {:ok, %{}, conn}

      err ->
        err
    end
  end

  def parse(conn, "application", "vnd.oci.image.manifest.v1+json", _headers, opts) do
    read_full_body(conn, opts, "")
    |> case do
      {:ok, full_body, conn} ->
        digest = :crypto.hash(:sha256, full_body) |> Base.encode16(case: :lower)

        # Note: this is not the 'digest' as is in the query string, but the byte-for-byte digest of the body.
        # before it is ready by the json decoder.
        conn = Plug.Conn.assign(conn, :oci_digest, "sha256:#{digest}")

        decoder = Keyword.fetch!(opts, :json_decoder)

        case decoder.decode(full_body) do
          {:ok, manifest} ->
            {:ok, manifest, conn}

          {:error, _} ->
            raise Plug.Parsers.ParseError, exception: %Plug.Parsers.BadEncodingError{}
        end

      err ->
        err
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  @spec read_full_body(Plug.Conn.t(), opts(), String.t()) ::
          {:ok, String.t(), Plug.Conn.t()} | {:error, term()}
  defp read_full_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, acc <> body, conn}

      {:more, chunk, conn} ->
        read_full_body(conn, opts, acc <> chunk)

      {:error, _} = err ->
        err
    end
  end
end
