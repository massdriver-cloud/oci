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
  Reads the full body and stores it in `conn.assigns[:oci_blob_chunk]`.

  ### OCI manifest types
  Reads the full body, computes its SHA256 digest, decodes the JSON, and stores
  the raw body and digest in conn assigns (`:oci_raw_manifest` and `:oci_digest`).
  The decoded manifest is returned as params.

  ### Other Content Types
  Passes through to the next parser via `{:next, conn}`.
  """
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
    read_oci_manifest(conn, opts)
  end

  def parse(conn, "application", "vnd.oci.image.index.v1+json", _headers, opts) do
    read_oci_manifest(conn, opts)
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp read_oci_manifest(conn, opts) do
    case read_full_body(conn, opts, "") do
      {:ok, full_body, conn} ->
        digest = :crypto.hash(:sha256, full_body) |> Base.encode16(case: :lower)

        conn =
          conn
          |> Plug.Conn.assign(:oci_digest, "sha256:#{digest}")
          |> Plug.Conn.assign(:oci_raw_manifest, full_body)

        decoder = Keyword.fetch!(opts, :json_decoder)

        case decoder.decode(full_body) do
          {:ok, manifest} ->
            {:ok, manifest, conn}

          {:error, _} ->
            raise Plug.Parsers.ParseError, exception: %Plug.Parsers.BadEncodingError{}
        end

      {:error, _} = err ->
        err
    end
  end

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
