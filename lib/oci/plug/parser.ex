defmodule OCI.Plug.Parser do
  @behaviour Plug.Parsers

  def init(opts), do: opts

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
