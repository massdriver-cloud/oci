defmodule OCI.PhoenixRouter do
  @moduledoc """
  Phoenix router for OCI.
  """

  @spec oci_routes(Keyword.t()) :: Macro.t()
  defmacro oci_routes(opts \\ []) do
    repo_pattern =
      Keyword.get(opts, :repo, ":namespace/:name")

    quote bind_quoted: [repo_pattern: repo_pattern] do
      get("/", OCI.Plug, [])

      post("/#{repo_pattern}/blobs/uploads/", OCI.Plug, [])
      get("/#{repo_pattern}/blobs/uploads/:upload_uuid", OCI.Plug, [])
      patch("/#{repo_pattern}/blobs/uploads/:upload_uuid", OCI.Plug, [])
      put("/#{repo_pattern}/blobs/uploads/:upload_uuid", OCI.Plug, [])
      delete("/#{repo_pattern}/blobs/uploads/:upload_uuid", OCI.Plug, [])

      get("/#{repo_pattern}/blobs/:digest", OCI.Plug, [])
      head("/#{repo_pattern}/blobs/:digest", OCI.Plug, [])
      delete("/#{repo_pattern}/blobs/:digest", OCI.Plug, [])

      put("/#{repo_pattern}/manifests/:reference", OCI.Plug, [])
      get("/#{repo_pattern}/manifests/:reference", OCI.Plug, [])
      head("/#{repo_pattern}/manifests/:reference", OCI.Plug, [])
      delete("/#{repo_pattern}/manifests/:reference", OCI.Plug, [])

      get("/#{repo_pattern}/tags/list", OCI.Plug, [])
    end
  end
end
