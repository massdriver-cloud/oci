# TODO: remove
defmodule OCI.Plug.DigestBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case read_full_body(conn, opts, []) do
      {:ok, full_body, conn} ->
        digest = :crypto.hash(:sha256, full_body) |> Base.encode16(case: :lower)

        conn = Plug.Conn.assign(conn, :oci_digest, "sha256:#{digest}")
        {:ok, full_body, conn}

      {:error, :timeout} = err ->
        err
    end
  end

  defp read_full_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, opts, [chunk | acc])

      error ->
        error
    end
  end
end
