defmodule OCI.PlugTest do
  @moduledoc """
  This is more of a convenience module for recreating conformance tests HTTP calls
  for debugging purposes.
  """
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias OCI.Registry

  setup do
    opts = plug_opts()

    on_exit(fn ->
      tmp_path = opts.registry.storage.path
      File.rm_rf!(tmp_path)
    end)

    conn =
      :get
      |> conn("/")
      |> Map.put(:script_name, ["v2"])
      |> Map.put(:assigns, %{oci_opts: opts})
      |> basic_auth("myuser", "mypass")

    %{conn: conn}
  end

  describe "GET /" do
    test "returns 200 for base endpoint", %{conn: conn} do
      conn = conn |> get("/")
      assert conn.status == 200
    end
  end

  describe "supports various repo name formats" do
    test "one-level naming (nginx)", %{conn: conn} do
      conn = conn |> post("/nginx/blobs/uploads")
      assert conn.status == 202
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/v2/nginx/blobs/uploads/")
    end

    test "two-level naming (hexpm/elixir)", %{conn: conn} do
      conn = conn |> post("/hexpm/elixir/blobs/uploads")
      assert conn.status == 202
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/v2/hexpm/elixir/blobs/uploads/")
    end

    test "three-level naming (big-org/big-team/big-project)", %{conn: conn} do
      conn = conn |> post("/big-org/big-team/big-project/blobs/uploads")
      assert conn.status == 202
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/v2/big-org/big-team/big-project/blobs/uploads/")
    end
  end

  defp get(conn, path, query_params \\ nil) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:get, path, query_params)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  defp post(conn, path, body \\ nil) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:post, path, body)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  defp put(conn, path, body \\ nil) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:put, path, body)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  defp head(conn, path) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:head, path, nil)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  defp delete(conn, path) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:delete, path, nil)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  defp patch(conn, path, body) do
    conn
    |> Plug.Adapters.Test.Conn.conn(:patch, path, body)
    |> OCI.Plug.call(conn.assigns.oci_opts)
  end

  defp plug_opts() do
    {:ok, tmp_path} = Temp.path()
    registry = Registry.init(storage: OCI.Storage.Local.init(path: tmp_path))
    OCI.Plug.init(registry: registry)
  end

  defp digest(data) do
    digest = OCI.Registry.sha256(data)
    "sha256:#{digest}"
  end

  defp initiate_blob_upload(%Plug.Conn{} = conn, repo) do
    conn =
      conn
      |> post("/#{repo}/blobs/uploads/")

    assert conn.status == 202
    [location] = get_resp_header(conn, "location")
    uuid = location |> String.split("/") |> List.last()
    {conn, uuid}
  end

  # Helper function to upload a chunk to a blob upload
  defp upload_chunk(%Plug.Conn{} = conn, repo, uuid, chunk, start_range \\ 0) do
    end_range = start_range + String.length(chunk) - 1

    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("content-range", "#{start_range}-#{end_range}")
      |> put_req_header("content-length", "#{String.length(chunk)}")
      |> patch("/#{repo}/blobs/uploads/#{uuid}", chunk)

    assert conn.status == 202
    assert [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, "/v2/#{repo}/blobs/uploads/")
    assert [range] = get_resp_header(conn, "range")
    assert range == "#{start_range}-#{end_range}"
    {conn, end_range}
  end

  # Helper function to complete a blob upload
  defp complete_blob_upload(%Plug.Conn{} = conn, repo, uuid, digest, final_chunk \\ "") do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("content-length", "#{String.length(final_chunk)}")
      |> put("/#{repo}/blobs/uploads/#{uuid}?digest=#{digest}", final_chunk)

    assert conn.status == 201
    assert [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, "/v2/#{repo}/blobs/")
    assert String.ends_with?(location, digest)
    conn
  end

  defp basic_auth(conn, username, password) do
    put_req_header(conn, "authorization", "Basic #{Base.encode64("#{username}:#{password}")}")
  end

  defp override_registry_setting(conn, setting, value) do
    registry = %{conn.assigns.oci_opts.registry | setting => value}

    %{
      conn
      | assigns: %{
          conn.assigns
          | oci_opts: %{conn.assigns.oci_opts | registry: registry}
        }
    }
  end
end
