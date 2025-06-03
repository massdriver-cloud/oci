defmodule OCI.Inspector do
  @moduledoc """
  Helper functions for debugging OCI conformance tests.

  This module provides utilities for inspecting and debugging OCI (Open Container Initiative)
  conformance tests. It allows for runtime inspection of request details and process state,
  and provides a way to set up debugging breakpoints during test execution of specific tests so
  you don't have to breakpoint through hundreds of unrelated requests.

  ## Usage

  The module is primarily used in conjunction with OCI conformance tests. When a request
  includes the `x-oci-conformance-test` header, the inspector will track the request and
  enable debugging capabilities.

  Add a `x-oci-conformance-test` header to the request to enable debugging in the appropriate
  Distribution Spec ([example: 02 Push Test](.tmp/oci-conformance/distribution-spec/conformance/02_push_test.go)):

  ```go
  req.SetHeader("x-oci-conformance-test", g.CurrentSpecReport().FullText())
  ```

  In elixir, put an `OCI.Inspector.inspect/2` call in your plug pipeline to enable debugging. When a header comes through for inspection,
  the proccess dictionary will be populated with the request id and the test name to enable granular breakpointing by specific HTTP requests,
  not just line number.

  ```elixir
  def call(conn, %{registry: registry}) do
    conn =
      conn
      |> ensure_request_id()
      |> put_private(:oci_registry, registry)
      |> authenticate()
      |> OCI.Inspector.inspect("after:authenticate/1")
  end
  ```

  Put a debugger at the line of code you want to breakpoint and pass in the `binding()`, the breakpoint will only trigger for the specific HTTP request.

  ```elixir
  def verify_digest(data, digest) do
    OCI.Inspector.pry(binding())
    # ... code
  end
  ```

  ## Features

  - Request inspection with detailed logging
  - Process state tracking
  - Runtime debugging capabilities
  - Test case identification
  """

  require IEx
  require Logger
  use TypedStruct

  @typedoc """
  Represents the state of an OCI Inspector instance.
  """
  typedstruct do
    field :request_id, String.t(), enforce: true
    field :test, String.t(), enforce: true
  end

  @doc """
  Inspects an incoming request and sets up debugging context if it's a conformance test.

  ## Parameters

    - `conn` - The Plug.Conn struct representing the incoming request
    - `label` - Optional label for the inspection output (default: "none")

  ## Returns

    - The unmodified Plug.Conn struct

  ## Examples

      iex> conn = %Plug.Conn{private: %{plug_request_id: "123"}}
      iex> conn = Plug.Conn.put_req_header(conn, "x-oci-conformance-test", "test-name")
      iex> OCI.Inspector.inspect(conn)
      %Plug.Conn{...}
  """
  @spec inspect(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def inspect(conn, label \\ "none") do
    test = Plug.Conn.get_req_header(conn, "x-oci-conformance-test") |> List.first()

    if test do
      request_id = conn.private[:plug_request_id]
      Process.put(:oci_inspector, %OCI.Inspector{request_id: request_id, test: test})

      log_info(conn, test, label)
    end

    conn
  end

  def log_info(conn, test, label) do
    digest = conn.query_params["digest"]

    authorization = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
    content_length = Plug.Conn.get_req_header(conn, "content-length") |> List.first()
    content_range = Plug.Conn.get_req_header(conn, "content-range") |> List.first()

    msg =
      "🔍 🔍 🔍 OCI Inspector — Runtime State (#{label}):\n" <>
        "\t[oci-conformance-test] (#{test}):\n" <>
        "\t\tctx:#{Kernel.inspect(conn.assigns[:oci_ctx])}\n" <>
        "\t\tauthorization:#{authorization}\n" <>
        "\t\t[#{conn.method}] #{conn.request_path} (status: #{conn.status}, halted: #{conn.halted})\n" <>
        "\t\tdigest:#{digest} content-length=#{content_length} content-range=#{content_range}\n" <>
        "\t\tpid:#{Kernel.inspect(self())}\n" <>
        "\t\trequest_id:#{conn.private[:plug_request_id]}"

    Logger.info(msg)
    conn
  end

  @doc """
  Sets up a debugging breakpoint for the current process if it's part of a conformance test.

  This function will only activate the debugger if the process has been marked
  as part of a conformance test by a previous call to `inspect/2`.

  ## Parameters

    - `binding` - The current binding context for the debugger

  ## Returns

    - `nil` if no inspector context is found
    - The result of `IEx.pry()` if inspector context exists

  """
  @spec pry(Keyword.t()) :: nil | any()
  def pry(binding) do
    case Process.get(:oci_inspector) do
      nil ->
        nil

      %OCI.Inspector{request_id: request_id, test: test} ->
        Logger.info(
          "🔧 🔧 🔧 OCI Pry — Runtime State\n" <>
            "\t[oci-conformance-test] (#{test}):\n" <>
            "\t\tpid:#{Kernel.inspect(self())}\n" <>
            "\t\trequest_id:#{request_id}"
        )

        # credo:disable-for-next-line
        IEx.pry()
    end
  end
end
