defmodule OCI.PlugTest.Helpers do
  @moduledoc """
  Helpers for the OCI.Plug test suite.

  This module is used to test the OCI.Plug module.
  It provides a set of functions that can be used to make requests to the OCI.Plug module.

  The functions are named after the HTTP methods they correspond to.
  """

  import Plug.Conn

  def get(conn, path, query_params \\ nil) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:get, path, query_params)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  def post(conn, path, body \\ nil) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:post, path, body)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  def put(conn, path, body \\ nil) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:put, path, body)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  def head(conn, path) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:head, path, nil)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  def delete(conn, path) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:delete, path, nil)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  def patch(conn, path, body) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:patch, path, body)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  def digest(data) do
    digest = OCI.Registry.sha256(data)
    "sha256:#{digest}"
  end

  # Helper function to upload a chunk to a blob upload
  def upload_chunk(%Plug.Conn{} = conn, repo, uuid, chunk, start_range \\ 0) do
    end_range = start_range + byte_size(chunk) - 1

    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("content-range", "#{start_range}-#{end_range}")
    |> put_req_header("content-length", "#{byte_size(chunk)}")
    |> patch("/#{repo}/blobs/uploads/#{uuid}", chunk)
  end

  # Helper function to complete a blob upload
  def complete_blob_upload(%Plug.Conn{} = conn, repo, uuid, digest, final_chunk \\ "") do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("content-length", "#{byte_size(final_chunk)}")
    |> put("/#{repo}/blobs/uploads/#{uuid}?digest=#{digest}", final_chunk)
  end

  def override_registry_setting(conn, setting, value) do
    registry = %{conn.assigns.oci_opts.registry | setting => value}

    %{
      conn
      | assigns: %{
          conn.assigns
          | oci_opts: %{conn.assigns.oci_opts | registry: registry}
        }
    }
  end

  def basic_auth(conn, username, password) do
    put_req_header(conn, "authorization", "Basic #{Base.encode64("#{username}:#{password}")}")
  end
end
