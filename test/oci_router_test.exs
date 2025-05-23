defmodule OCI.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts OCI.Router.init(adapter: :memory)

  test "GET / returns welcome message" do
    conn = conn(:get, "/") |> OCI.Router.call(@opts)
    assert conn.status == 200
    assert conn.resp_body == "Welcome to the OCI Plug Router!"
  end

  test "GET /notfound returns 404" do
    conn = conn(:get, "/notfound") |> OCI.Router.call(@opts)
    assert conn.status == 404
    assert conn.resp_body == "Not found"
  end

  test "error handler returns generic error message" do
    # Simulate an error by calling a non-existent route with a method not allowed
    conn = conn(:post, "/") |> OCI.Router.call(@opts)
    assert conn.status == 404
    assert conn.resp_body == "Not found"
  end

  test "GET / with custom header" do
    conn =
      conn(:get, "/")
      |> put_req_header("x-custom-header", "my-value")
      |> OCI.Router.call(@opts)

    assert conn.status == 200
    assert get_req_header(conn, "x-custom-header") == ["my-value"]
  end
end
