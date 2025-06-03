defmodule OCI.Plug.Parser do
  @behaviour Plug.Parsers

  # TODO: probably add octet stream support here, dont need to, but we need to read the body
  # later in the pipeline, and it will be easier to reason about if we have one parser handling the
  # body reading rather than two (and wondering if the other swallowed it).

  def init(opts), do: opts

  def parse(conn, "application", "vnd.oci.image.manifest.v1+json", _headers, opts) do
    read_full_body(conn, opts, "")
    |> case do
      {:ok, full_body, conn} ->
        digest = :crypto.hash(:sha256, full_body) |> Base.encode16(case: :lower)
        conn = Plug.Conn.assign(conn, :oci_digest, "sha256:#{digest}")

        decoder = Keyword.fetch!(opts, :json_decoder)

        case decoder.decode(full_body) do
          {:ok, manifest} ->
            {:ok, manifest, conn}

          {:error, _} ->
            raise Plug.Parsers.ParseError, exception: %Plug.Parsers.BadEncodingError{}
        end

      {:error, reason} ->
        {:error, reason}
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
