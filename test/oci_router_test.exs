defmodule OCI.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  setup do
    tmp = Path.join(System.tmp_dir!(), "oci_router_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Process.put(:oci_tempfs_root, tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    opts = OCI.Router.init(adapter: OCI.Storage.TempFS, auth: OCI.Auth.NoAuth)
    {:ok, opts: opts}
  end

  describe "HTTP API integration tests" do
    test "full image push and pull workflow", %{opts: opts} do
      repo = "sample/image"
      conn = conn(:post, "/v2/#{repo}/blobs/uploads/")
      conn = OCI.Router.call(conn, opts)
      assert conn.status == 202
      [location] = get_resp_header(conn, "location")
      [upload_uuid] = get_resp_header(conn, "docker-upload-uuid")
      assert String.contains?(location, upload_uuid)
      assert get_resp_header(conn, "range") == ["0-0"]

      blob_data = "Hello OCI"

      chunk_conn =
        conn(:patch, location, blob_data)
        |> put_req_header("content-type", "application/octet-stream")

      chunk_conn = OCI.Router.call(chunk_conn, opts)
      assert chunk_conn.status == 202
      assert get_resp_header(chunk_conn, "docker-upload-uuid") == [upload_uuid]
      assert get_resp_header(chunk_conn, "range") == ["0-#{byte_size(blob_data) - 1}"]

      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, blob_data), case: :lower)
      finalize_conn = conn(:put, "#{location}?digest=#{URI.encode(digest)}", "")
      finalize_conn = OCI.Router.call(finalize_conn, opts)
      assert finalize_conn.status == 201
      assert get_resp_header(finalize_conn, "docker-content-digest") == [digest]
      assert get_resp_header(finalize_conn, "location") == ["/v2/#{repo}/blobs/#{digest}"]

      manifest =
        %{
          schemaVersion: 2,
          config: %{
            mediaType: "application/vnd.oci.image.config.v1+json",
            digest: "sha256:" <> String.duplicate("0", 64),
            size: 0
          },
          layers: [
            %{
              mediaType: "application/vnd.oci.image.layer.v1.tar",
              digest: digest,
              size: byte_size(blob_data)
            }
          ]
        }
        |> Jason.encode!()

      manifest_conn =
        conn(:put, "/v2/#{repo}/manifests/latest", manifest)
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")

      manifest_conn = OCI.Router.call(manifest_conn, opts)
      assert manifest_conn.status == 201
      [manifest_digest] = get_resp_header(manifest_conn, "docker-content-digest")
      assert manifest_digest =~ "sha256:"

      get_manifest_conn = conn(:get, "/v2/#{repo}/manifests/latest")
      get_manifest_conn = OCI.Router.call(get_manifest_conn, opts)
      assert get_manifest_conn.status == 200

      assert get_resp_header(get_manifest_conn, "content-type") == [
               "application/vnd.oci.image.manifest.v1+json"
             ]

      assert Jason.decode!(get_manifest_conn.resp_body)["schemaVersion"] == 2

      get_manifest_conn2 = conn(:get, "/v2/#{repo}/manifests/#{URI.encode(manifest_digest)}")
      get_manifest_conn2 = OCI.Router.call(get_manifest_conn2, opts)
      assert get_manifest_conn2.status == 200
      assert get_manifest_conn2.resp_body == get_manifest_conn.resp_body

      get_blob_conn = conn(:get, "/v2/#{repo}/blobs/#{URI.encode(digest)}")
      get_blob_conn = OCI.Router.call(get_blob_conn, opts)
      assert get_blob_conn.status == 200
      assert get_blob_conn.resp_body == blob_data

      catalog_conn = conn(:get, "/v2/_catalog")
      catalog_conn = OCI.Router.call(catalog_conn, opts)
      assert catalog_conn.status == 200
      repos = Jason.decode!(catalog_conn.resp_body)["repositories"]
      assert repo in repos

      tags_conn = conn(:get, "/v2/#{repo}/tags/list")
      tags_conn = OCI.Router.call(tags_conn, opts)
      assert tags_conn.status == 200
      tags = Jason.decode!(tags_conn.resp_body)
      assert tags["name"] == repo
      assert "latest" in tags["tags"]

      head_manifest_conn = conn(:head, "/v2/#{repo}/manifests/latest")
      head_manifest_conn = OCI.Router.call(head_manifest_conn, opts)
      assert head_manifest_conn.status == 200
      assert head_manifest_conn.resp_body == ""
      assert get_resp_header(head_manifest_conn, "docker-content-digest") == [manifest_digest]

      head_blob_conn = conn(:head, "/v2/#{repo}/blobs/#{URI.encode(digest)}")
      head_blob_conn = OCI.Router.call(head_blob_conn, opts)
      assert head_blob_conn.status == 200
      assert head_blob_conn.resp_body == ""

      delete_manifest_conn = conn(:delete, "/v2/#{repo}/manifests/#{URI.encode(manifest_digest)}")
      delete_manifest_conn = OCI.Router.call(delete_manifest_conn, opts)
      assert delete_manifest_conn.status == 202

      get_manifest_conn3 = conn(:get, "/v2/#{repo}/manifests/latest")
      get_manifest_conn3 = OCI.Router.call(get_manifest_conn3, opts)
      assert get_manifest_conn3.status == 404

      assert Jason.decode!(get_manifest_conn3.resp_body)["errors"] |> hd() |> Map.get("code") ==
               "MANIFEST_UNKNOWN"

      delete_blob_conn = conn(:delete, "/v2/#{repo}/blobs/#{URI.encode(digest)}")
      delete_blob_conn = OCI.Router.call(delete_blob_conn, opts)
      assert delete_blob_conn.status == 202

      get_blob_conn2 = conn(:get, "/v2/#{repo}/blobs/#{URI.encode(digest)}")
      get_blob_conn2 = OCI.Router.call(get_blob_conn2, opts)
      assert get_blob_conn2.status == 404

      assert Jason.decode!(get_blob_conn2.resp_body)["errors"] |> hd() |> Map.get("code") ==
               "BLOB_UNKNOWN"
    end

    test "error responses for unknown content", %{opts: opts} do
      conn1 = conn(:get, "/v2/unknownrepo/manifests/latest")
      conn1 = OCI.Router.call(conn1, opts)
      assert conn1.status == 404
      error = Jason.decode!(conn1.resp_body)

      assert hd(error["errors"])["code"] == "MANIFEST_UNKNOWN" or
               hd(error["errors"])["code"] == "NAME_UNKNOWN"

      conn2 = conn(:get, "/v2/unknownrepo/blobs/sha256:" <> String.duplicate("0", 64))
      conn2 = OCI.Router.call(conn2, opts)
      assert conn2.status == 404
      error2 = Jason.decode!(conn2.resp_body)

      assert hd(error2["errors"])["code"] == "BLOB_UNKNOWN" or
               hd(error2["errors"])["code"] == "NAME_UNKNOWN"
    end
  end
end
