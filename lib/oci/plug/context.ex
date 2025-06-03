defmodule OCI.Plug.Context do
  @moduledoc """
  Sets up the OCI context for the request.

  This is used to track the subject, endpoint, resource, repo, and method for the request.

  The context is stored in the `conn.assigns[:oci_ctx]` map.
  """

  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts \\ []) do
    segments = conn.path_info |> Enum.reverse()

    {rest, endpoint, id} =
      case segments do
        [] -> {[], :ping, nil}
        ["list", "tags" | rest] -> {rest, :tags_list, nil}
        ["uploads", "blobs" | rest] -> {rest, :blobs_uploads, nil}
        [uuid, "uploads", "blobs" | rest] -> {rest, :blobs_uploads, uuid}
        [digest, "blobs" | rest] -> {rest, :blobs, digest}
        [reference, "manifests" | rest] -> {rest, :manifests, reference}
      end

    # Reverse the path info, and the last parts after the known API path portions is the repo name.
    # V2 is plucked off by the "script_name" when scope/forwarding from Phoenix
    repo = rest |> Enum.reverse() |> Enum.join("/")

    ctx = %OCI.Context{
      subject: nil,
      endpoint: endpoint,
      resource: id,
      repo: repo,
      method: conn.method
    }

    conn |> assign(:oci_ctx, ctx)
  end
end
