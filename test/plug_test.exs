defmodule OCI.PlugTest do
  @moduledoc """
  This is more of a convenience module for recreating conformance tests HTTP calls
  for debugging purposes.
  """
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  import OCI.PlugTest.Helpers

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

  defp plug_opts() do
    {:ok, tmp_path} = Temp.path()
    {:ok, storage} = OCI.Storage.Local.init(%{path: tmp_path})

    user = %OCI.Auth.Static.User{
      username: "myuser",
      password: "mypass",
      permissions: %{
        "myimage" => ["pull", "push"],
        "nginx" => ["pull", "push"],
        "hexpm/elixir" => ["pull", "push"],
        "big-org/big-team/big-project" => ["pull", "push"],
        "nosinglelevelnames" => ["pull", "push"]
      }
    }

    {:ok, auth} =
      OCI.Auth.Static.init(%{
        users: [
          user
        ]
      })

    {:ok, registry} = OCI.Registry.init(storage: storage, auth: auth)
    OCI.Plug.init(registry: registry)
  end

  describe "GET /" do
    test "returns 200 for base endpoint", %{conn: conn} do
      conn = conn |> get("/")
      assert conn.status == 200
    end
  end

  describe "challenge" do
    test "challenges unauthenticated requests" do
      conn =
        :get
        |> conn("/")
        |> Map.put(:script_name, ["v2"])
        |> Map.put(:assigns, %{oci_opts: plug_opts()})

      conn = conn |> get("/")

      assert conn.status == 401
      header = get_resp_header(conn, "www-authenticate") |> List.first()
      assert String.starts_with?(header, "Basic")
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

  describe "validates the repo name format" do
    test "invalid repo name", %{conn: conn} do
      conn = override_registry_setting(conn, :repo_name_pattern, ~r/^[a-z0-9]+\/[a-z0-9]+$/)
      conn = conn |> post("/nosinglelevelnames/blobs/uploads")
      assert conn.status == 400

      error = Jason.decode!(conn.resp_body)

      assert error == %{
               "errors" => [
                 %{
                   "code" => "NAME_INVALID",
                   "detail" => %{
                     "repo" => "nosinglelevelnames",
                     "pattern" => "~r/^[a-z0-9]+\\/[a-z0-9]+$/"
                   },
                   "message" => "invalid repository name"
                 }
               ]
             }
    end
  end

  describe "PUT /v2/<name>/blobs/uploads/<uuid> closing PUT" do
    test "finalizes a zero-byte blob when Content-Length header is omitted", %{conn: conn} do
      open = post(conn, "/myimage/blobs/uploads")
      assert open.status == 202
      [location] = get_resp_header(open, "location")
      uuid = location |> String.split("/") |> List.last()

      empty_digest = digest("")

      assert empty_digest ==
               "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      closing =
        :put
        |> conn("/myimage/blobs/uploads/#{uuid}?digest=#{empty_digest}", nil)
        |> Map.put(:script_name, ["v2"])
        |> Map.put(:assigns, %{oci_opts: conn.assigns.oci_opts})
        |> basic_auth("myuser", "mypass")
        |> OCI.Plug.call(conn.assigns.oci_opts)

      assert get_req_header(closing, "content-length") == []
      assert closing.status == 201
      assert [blob_location] = get_resp_header(closing, "location")
      assert blob_location == "/v2/myimage/blobs/#{empty_digest}"
    end
  end
end
