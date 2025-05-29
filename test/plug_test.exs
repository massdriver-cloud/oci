defmodule OCI.PlugTest do
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

    conn = conn(:get, "/") |> Map.put(:assigns, %{oci_opts: opts})
    authed_conn = conn |> basic_auth("myuser", "mypass")

    %{conn: conn, authed_conn: authed_conn}
  end

  describe "GET /v2" do
    test "returns 200 for base endpoint", %{authed_conn: authed_conn} do
      conn = authed_conn |> get("/v2")
      assert conn.status == 200
    end
  end

  describe "POST /v2/:repo/blobs/uploads/" do
    test "initiates blob upload", %{authed_conn: authed_conn} do
      conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")

      assert conn.status == 202
      assert location = get_resp_header(conn, "location")
      assert [location] = location
      assert String.starts_with?(location, "/v2/my-org/my-api/blobs/uploads/")
      uuid = location |> String.split("/") |> List.last()
      assert String.length(uuid) > 0
    end

    # https://github.com/opencontainers/distribution-spec/blob/main/spec.md#post-then-put
    test "monolithic blob upload (POST then PUT)", %{authed_conn: authed_conn} do
      chunk = "test chunk data"
      digest = digest(chunk)

      # First initiate upload
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Then complete it with the blob
      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201
      assert [location] = get_resp_header(complete_blob_upload_conn, "location")
      assert String.starts_with?(location, "/v2/my-org/my-api/blobs/")
      assert String.ends_with?(location, digest)

      # Verify blob exists
      get_blob_conn = authed_conn |> get("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 200
      assert get_blob_conn.resp_body == chunk
    end

    # https://github.com/opencontainers/distribution-spec/blob/main/spec.md#single-post
    test "monolithic blob upload (Single POST)", %{authed_conn: authed_conn} do
      chunk = "test chunk data"
      digest = digest(chunk)

      # Upload blob in a single request with digest in URL
      single_post_conn =
        authed_conn
        |> post("/v2/my-org/my-api/blobs/uploads/?digest=#{digest}", chunk)

      assert single_post_conn.status == 201
      assert [location] = get_resp_header(single_post_conn, "location")
      assert String.starts_with?(location, "/v2/my-org/my-api/blobs/")
      assert String.ends_with?(location, digest)

      # Verify blob exists
      get_blob_conn = authed_conn |> get("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 200
      assert get_blob_conn.resp_body == chunk
    end

    test "mounts blob from another repository", %{authed_conn: authed_conn} do
      # First create a blob in the source repository
      source_repo = "test/source"
      target_repo = "test/target"
      blob = "test blob content"
      digest = digest(blob)

      # Upload blob to source repo
      initiate_blob_upload_conn =
        authed_conn |> post("/v2/#{source_repo}/blobs/uploads/?digest=#{digest}", blob)

      assert initiate_blob_upload_conn.status == 201

      # Now mount it to target repo
      mount_blob_conn =
        authed_conn
        |> post("/v2/#{target_repo}/blobs/uploads/?mount=#{digest}&from=#{source_repo}")

      assert mount_blob_conn.status == 201

      assert get_resp_header(mount_blob_conn, "location") |> List.first() =~
               ~r|/v2/#{target_repo}/blobs/#{digest}$|

      # Verify blob exists in target repo
      head_blob_conn = authed_conn |> head("/v2/#{target_repo}/blobs/#{digest}")
      assert head_blob_conn.status == 200
    end

    test "returns 202 if blob cannot be mounted", %{authed_conn: authed_conn} do
      # create an unrelated blob in the source repo, such that the repo exists,
      # but doesnt have the referenced blob
      unrelated_digest = digest("unrelated content")

      unrelated_blob_conn =
        authed_conn
        |> post("/v2/test/source/blobs/uploads/?digest=#{unrelated_digest}", "unrelated content")

      assert unrelated_blob_conn.status == 201

      digest = digest("test blob content")

      mount_blob_conn =
        authed_conn
        |> post("/v2/test/target/blobs/uploads/?mount=#{digest}&from=test/source")

      assert mount_blob_conn.status == 202

      assert get_resp_header(mount_blob_conn, "location") |> List.first() =~
               ~r|/v2/test/target/blobs/uploads/[^/]+$|
    end

    test "returns 404 when source repository does not exist", %{authed_conn: authed_conn} do
      mount_blob_conn =
        authed_conn
        |> post("/v2/test/target/blobs/uploads/?mount=sha256:123&from=nonexistent/source")

      assert mount_blob_conn.status == 404
    end

    test "returns 400 for invalid digest", %{authed_conn: authed_conn} do
      chunk = "test chunk data"
      invalid_digest = "sha256:invalid"

      invalid_digest_conn =
        authed_conn
        |> post("/v2/my-org/my-api/blobs/uploads/?digest=#{invalid_digest}", chunk)

      assert invalid_digest_conn.status == 400

      assert invalid_digest_conn.resp_body
             |> Jason.decode!()
             |> Map.get("errors")
             |> List.first()
             |> Map.get("code") == "DIGEST_INVALID"
    end
  end

  describe "PATCH /v2/:repo/blobs/uploads/:upload_uuid" do
    test "uploads a blob chunk", %{authed_conn: authed_conn} do
      repo = "my-org/my-api"
      {_conn, uuid} = initiate_blob_upload(authed_conn, repo)
      chunk = "test chunk data"
      {upload_chunk_conn, end_range} = upload_chunk(authed_conn, repo, uuid, chunk)

      assert upload_chunk_conn.status == 202
      assert [location] = get_resp_header(upload_chunk_conn, "location")
      assert String.starts_with?(location, "/v2/#{repo}/blobs/uploads/")
      assert [range] = get_resp_header(upload_chunk_conn, "range")
      assert range == "0-#{end_range}"
    end
  end

  describe "GET /v2/:repo/blobs/uploads/:upload_uuid" do
    test "gets upload status", %{authed_conn: authed_conn} do
      repo = "my-org/my-api"
      {_conn, uuid} = initiate_blob_upload(authed_conn, repo)
      chunk = "test chunk data"
      {_conn, end_range} = upload_chunk(authed_conn, repo, uuid, chunk)

      # Get upload status
      get_upload_status_conn = authed_conn |> get("/v2/#{repo}/blobs/uploads/#{uuid}")

      assert get_upload_status_conn.status == 204
      assert [range] = get_resp_header(get_upload_status_conn, "range")
      assert range == "0-#{end_range}"
    end

    test "returns 404 for unknown upload", %{authed_conn: authed_conn} do
      get_upload_status_conn = authed_conn |> get("/v2/my-org/my-api/blobs/uploads/unknown-uuid")
      assert get_upload_status_conn.status == 404
    end
  end

  describe "PUT /v2/:repo/blobs/uploads/:upload_uuid" do
    test "completes blob upload with empty PUT", %{authed_conn: authed_conn} do
      repo = "my-org/my-api"
      {_conn, uuid} = initiate_blob_upload(authed_conn, repo)
      chunk = "test chunk data"
      {_conn, _end_range} = upload_chunk(authed_conn, repo, uuid, chunk)

      # Complete the upload with empty PUT
      digest = digest(chunk)
      complete_blob_upload_conn = complete_blob_upload(authed_conn, repo, uuid, digest)

      assert complete_blob_upload_conn.status == 201
      assert [location] = get_resp_header(complete_blob_upload_conn, "location")
      assert String.starts_with?(location, "/v2/#{repo}/blobs/")
      assert String.ends_with?(location, digest)
    end

    test "completes blob upload with final chunk in PUT", %{authed_conn: authed_conn} do
      repo = "my-org/my-api"
      {_conn, uuid} = initiate_blob_upload(authed_conn, repo)
      chunk1 = "test chunk data"
      {_conn, end_range} = upload_chunk(authed_conn, repo, uuid, chunk1)

      # Upload final chunk and complete in PUT
      chunk2 = " and final chunk"
      final_data = chunk1 <> chunk2
      digest = digest(final_data)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "#{end_range}-#{String.length(final_data) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk2)}")
        |> put("/v2/#{repo}/blobs/uploads/#{uuid}?digest=#{digest}", chunk2)

      assert complete_blob_upload_conn.status == 201
      assert [location] = get_resp_header(complete_blob_upload_conn, "location")
      assert String.starts_with?(location, "/v2/#{repo}/blobs/")
      assert String.ends_with?(location, digest)
    end

    test "returns 400 for missing digest", %{authed_conn: authed_conn} do
      repo = "my-org/my-api"
      {_conn, uuid} = initiate_blob_upload(authed_conn, repo)

      # Try to complete without digest
      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "0")
        |> put("/v2/#{repo}/blobs/uploads/#{uuid}", "")

      assert complete_blob_upload_conn.status == 400
    end

    test "returns 404 for unknown upload", %{authed_conn: authed_conn} do
      digest = digest("test")
      uuid = "00000000-0000-0000-0000-000000000000"

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "0")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}")

      assert complete_blob_upload_conn.status == 404
    end

    test "returns 400 for invalid digest", %{authed_conn: authed_conn} do
      repo = "my-org/my-api"
      {_conn, uuid} = initiate_blob_upload(authed_conn, repo)
      chunk = "test chunk data"
      invalid_digest = "sha256:invalid"

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{invalid_digest}", chunk)

      assert complete_blob_upload_conn.status == 400

      assert complete_blob_upload_conn.resp_body
             |> Jason.decode!()
             |> Map.get("errors")
             |> List.first()
             |> Map.get("code") == "DIGEST_INVALID"
    end
  end

  describe "DELETE /v2/:repo/blobs/uploads/:upload_uuid" do
    test "cancels blob upload", %{authed_conn: authed_conn} do
      # First initiate an upload
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"

      upload_chunk_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> patch("/v2/my-org/my-api/blobs/uploads/#{uuid}", chunk)

      assert upload_chunk_conn.status == 202

      # Cancel the upload
      cancel_blob_upload_conn = authed_conn |> delete("/v2/my-org/my-api/blobs/uploads/#{uuid}")
      assert cancel_blob_upload_conn.status == 204

      # Verify upload is gone by trying to get status
      get_upload_status_conn = authed_conn |> get("/v2/my-org/my-api/blobs/uploads/#{uuid}")
      assert get_upload_status_conn.status == 404
    end

    test "returns 404 for unknown upload", %{authed_conn: authed_conn} do
      cancel_blob_upload_conn =
        authed_conn |> delete("/v2/my-org/my-api/blobs/uploads/unknown-uuid")

      assert cancel_blob_upload_conn.status == 404
    end
  end

  describe "HEAD /v2/:repo/blobs/:digest" do
    # First upload a blob
    test "returns 200 for existing blob", %{authed_conn: authed_conn} do
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Check if blob exists
      get_blob_conn = authed_conn |> head("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 200
      assert [content_length] = get_resp_header(get_blob_conn, "content-length")
      assert content_length == "#{String.length(chunk)}"
    end

    test "returns 404 for non-existent blob", %{authed_conn: authed_conn} do
      digest = digest("nonexistent")
      get_blob_conn = authed_conn |> head("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 404
    end

    test "returns 404 for invalid digest format", %{authed_conn: authed_conn} do
      get_blob_conn = authed_conn |> head("/v2/my-org/my-api/blobs/invalid-digest")
      assert get_blob_conn.status == 404
    end
  end

  describe "GET /v2/:repo/blobs/:digest" do
    test "returns 200 for existing blob", %{authed_conn: authed_conn} do
      # First upload a blob
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Get blob
      get_blob_conn = authed_conn |> get("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 200
      assert get_blob_conn.resp_body == chunk
      assert [content_length] = get_resp_header(get_blob_conn, "content-length")
      assert content_length == "#{String.length(chunk)}"
    end

    test "returns 404 for non-existent blob", %{authed_conn: authed_conn} do
      digest = digest("nonexistent")
      get_blob_conn = authed_conn |> get("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 404
    end

    test "returns 404 for invalid digest format", %{authed_conn: authed_conn} do
      get_blob_conn = authed_conn |> get("/v2/my-org/my-api/blobs/invalid-digest")
      assert get_blob_conn.status == 404
    end
  end

  describe "DELETE /v2/:repo/blobs/:digest" do
    test "returns 202 for existing blob", %{authed_conn: authed_conn} do
      # First upload a blob
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Delete blob
      delete_blob_conn = authed_conn |> delete("/v2/my-org/my-api/blobs/#{digest}")
      assert delete_blob_conn.status == 202

      # Verify blob is gone
      get_blob_conn = authed_conn |> get("/v2/my-org/my-api/blobs/#{digest}")
      assert get_blob_conn.status == 404
    end

    test "returns 404 for non-existent blob", %{authed_conn: authed_conn} do
      digest = digest("nonexistent")
      delete_blob_conn = authed_conn |> delete("/v2/my-org/my-api/blobs/#{digest}")
      assert delete_blob_conn.status == 404
    end

    test "returns 404 for invalid digest format", %{authed_conn: authed_conn} do
      delete_blob_conn = authed_conn |> delete("/v2/my-org/my-api/blobs/invalid-digest")
      assert delete_blob_conn.status == 404
    end

    test "returns 405 when blob deletion is disabled", %{authed_conn: authed_conn} do
      # Create a registry with blob deletion disabled

      authed_conn = override_registry_setting(authed_conn, :enable_blob_deletion, false)

      # First upload a blob
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Try to delete blob when deletion is disabled
      delete_blob_conn = authed_conn |> delete("/v2/my-org/my-api/blobs/#{digest}")
      assert delete_blob_conn.status == 405

      assert delete_blob_conn.resp_body
             |> Jason.decode!()
             |> Map.get("errors")
             |> List.first()
             |> Map.get("code") == "UNSUPPORTED"
    end
  end

  describe "PUT /v2/:repo/manifests/:reference" do
    test "returns 201 for valid manifest", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/latest", manifest_json)

      assert put_manifest_conn.status == 201
      assert [location] = get_resp_header(put_manifest_conn, "location")
      assert String.ends_with?(location, "/v2/my-org/my-api/manifests/latest")
    end

    @tag :wip
    test "returns 413 for oversized manifest", %{authed_conn: authed_conn} do
      # Create a registry with a smaller max_manifest_size
      authed_conn = override_registry_setting(authed_conn, :max_manifest_size, 1 * 1024 * 1024)

      # Create a manifest that exceeds the registry's size limit
      oversized_manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => "sha256:123",
          "size" => 1
        },
        "layers" => []
      }

      # Make the manifest oversized by adding a large string
      oversized_manifest =
        Map.put(oversized_manifest, "largeString", String.duplicate("a", 5_000_000))

      manifest_json = Jason.encode!(oversized_manifest)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/latest", manifest_json)

      assert put_manifest_conn.status == 413
    end
  end

  describe "GET /v2/:repo/manifests/:reference" do
    test "returns 200 for existing manifest by tag", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/latest", manifest_json)

      assert put_manifest_conn.status == 201

      # Get manifest by tag
      get_manifest_conn = authed_conn |> get("/v2/my-org/my-api/manifests/latest")
      assert get_manifest_conn.status == 200
      assert get_manifest_conn.resp_body == manifest_json
      assert [content_type] = get_resp_header(get_manifest_conn, "content-type")
      assert content_type == "application/vnd.oci.image.manifest.v1+json"
    end

    test "returns 200 for existing manifest by digest", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)
      manifest_digest = digest(manifest_json)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/#{manifest_digest}", manifest_json)

      assert put_manifest_conn.status == 201

      # Get manifest by digest
      get_manifest_conn = authed_conn |> get("/v2/my-org/my-api/manifests/#{manifest_digest}")
      assert get_manifest_conn.status == 200
      assert get_manifest_conn.resp_body == manifest_json
      assert [content_type] = get_resp_header(get_manifest_conn, "content-type")
      assert content_type == "application/vnd.oci.image.manifest.v1+json"
    end

    test "returns 404 for non-existent manifest", %{authed_conn: authed_conn} do
      get_manifest_conn = authed_conn |> get("/v2/my-org/my-api/manifests/nonexistent")
      assert get_manifest_conn.status == 404
    end
  end

  describe "HEAD /v2/:repo/manifests/:reference" do
    test "returns 200 for existing manifest by tag", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/latest", manifest_json)

      assert put_manifest_conn.status == 201

      # Check manifest by tag
      get_manifest_conn = authed_conn |> head("/v2/my-org/my-api/manifests/latest")
      assert get_manifest_conn.status == 200
      assert get_manifest_conn.resp_body == ""
      assert [content_type] = get_resp_header(get_manifest_conn, "content-type")
      assert content_type == "application/vnd.oci.image.manifest.v1+json"
      assert [content_length] = get_resp_header(get_manifest_conn, "content-length")
      assert content_length == "#{String.length(manifest_json)}"
    end

    test "returns 200 for existing manifest by digest", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)
      manifest_digest = digest(manifest_json)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/#{manifest_digest}", manifest_json)

      assert put_manifest_conn.status == 201

      # Check manifest by digest
      get_manifest_conn = authed_conn |> head("/v2/my-org/my-api/manifests/#{manifest_digest}")
      assert get_manifest_conn.status == 200
      assert get_manifest_conn.resp_body == ""
      assert [content_type] = get_resp_header(get_manifest_conn, "content-type")
      assert content_type == "application/vnd.oci.image.manifest.v1+json"
      assert [content_length] = get_resp_header(get_manifest_conn, "content-length")
      assert content_length == "#{String.length(manifest_json)}"
    end

    test "returns 404 for non-existent manifest", %{authed_conn: authed_conn} do
      get_manifest_conn = authed_conn |> head("/v2/my-org/my-api/manifests/nonexistent")
      assert get_manifest_conn.status == 404
    end
  end

  describe "DELETE /v2/:repo/manifests/:digest" do
    test "returns 202 for existing manifest by digest", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)
      manifest_digest = digest(manifest_json)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/#{manifest_digest}", manifest_json)

      assert put_manifest_conn.status == 201

      # Delete manifest by digest
      delete_manifest_conn =
        authed_conn |> delete("/v2/my-org/my-api/manifests/#{manifest_digest}")

      assert delete_manifest_conn.status == 202

      # Verify manifest is gone
      get_manifest_conn = authed_conn |> get("/v2/my-org/my-api/manifests/#{manifest_digest}")
      assert get_manifest_conn.status == 404
    end

    test "returns 404 for non-existent manifest", %{authed_conn: authed_conn} do
      digest = digest("nonexistent")
      delete_manifest_conn = authed_conn |> delete("/v2/my-org/my-api/manifests/#{digest}")
      assert delete_manifest_conn.status == 404
    end

    test "returns 405 when manifest deletion is disabled", %{authed_conn: authed_conn} do
      # Create a registry with manifest deletion disabled
      authed_conn = override_registry_setting(authed_conn, :enable_manifest_deletion, false)

      # First upload a manifest
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)
      manifest_digest = digest(manifest_json)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/#{manifest_digest}", manifest_json)

      assert put_manifest_conn.status == 201

      # Try to delete manifest when deletion is disabled
      delete_manifest_conn =
        authed_conn |> delete("/v2/my-org/my-api/manifests/#{manifest_digest}")

      assert delete_manifest_conn.status == 405

      assert delete_manifest_conn.resp_body
             |> Jason.decode!()
             |> Map.get("errors")
             |> List.first()
             |> Map.get("code") == "UNSUPPORTED"
    end
  end

  describe "GET /v2/:repo/tags/list" do
    test "returns 200 for existing repository with tags", %{authed_conn: authed_conn} do
      # First upload a manifest with a tag
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest with tag
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)

      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/latest", manifest_json)

      assert put_manifest_conn.status == 201

      # List tags
      get_tags_conn = authed_conn |> get("/v2/my-org/my-api/tags/list")
      assert get_tags_conn.status == 200
      tags = get_tags_conn.resp_body |> Jason.decode!() |> Map.get("tags")
      assert tags == ["latest"]
    end

    test "returns 200 for existing repository with multiple tags", %{authed_conn: authed_conn} do
      # First upload a blob that will be referenced
      initiate_blob_upload_conn = authed_conn |> post("/v2/my-org/my-api/blobs/uploads/")
      assert initiate_blob_upload_conn.status == 202
      [location] = get_resp_header(initiate_blob_upload_conn, "location")
      uuid = location |> String.split("/") |> List.last()

      # Upload a chunk
      chunk = "test chunk data"
      digest = digest(chunk)

      complete_blob_upload_conn =
        authed_conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-range", "0-#{String.length(chunk) - 1}")
        |> put_req_header("content-length", "#{String.length(chunk)}")
        |> put("/v2/my-org/my-api/blobs/uploads/#{uuid}?digest=#{digest}", chunk)

      assert complete_blob_upload_conn.status == 201

      # Upload manifest with multiple tags
      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "config" => %{
          "mediaType" => "application/vnd.oci.image.config.v1+json",
          "digest" => digest,
          "size" => String.length(chunk)
        },
        "layers" => []
      }

      manifest_json = Jason.encode!(manifest)

      # Upload with tag v1.0.0
      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/v1.0.0", manifest_json)

      assert put_manifest_conn.status == 201

      # Upload with tag latest
      put_manifest_conn =
        authed_conn
        |> put_req_header("content-type", "application/vnd.oci.image.manifest.v1+json")
        |> put("/v2/my-org/my-api/manifests/latest", manifest_json)

      assert put_manifest_conn.status == 201

      # List tags with pagination
      get_tags_conn =
        authed_conn |> get("/v2/my-org/my-api/tags/list", %{"n" => 1, "last" => "latest"})

      assert get_tags_conn.status == 200
      tags = get_tags_conn.resp_body |> Jason.decode!() |> Map.get("tags")
      assert tags == ["v1.0.0"]
    end

    test "returns 404 for non-existent repository", %{authed_conn: authed_conn} do
      get_tags_conn = authed_conn |> get("/v2/nonexistent/tags/list")
      assert get_tags_conn.status == 404
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
    "sha256:#{:crypto.hash(:sha256, data) |> Base.encode16(case: :lower)}"
  end

  defp initiate_blob_upload(%Plug.Conn{} = conn, repo) do
    conn =
      conn
      |> post("/v2/#{repo}/blobs/uploads/")

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
      |> patch("/v2/#{repo}/blobs/uploads/#{uuid}", chunk)

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
      |> put("/v2/#{repo}/blobs/uploads/#{uuid}?digest=#{digest}", final_chunk)

    assert conn.status == 201
    assert [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, "/v2/#{repo}/blobs/")
    assert String.ends_with?(location, digest)
    conn
  end

  defp basic_auth(conn, username, password) do
    put_req_header(conn, "authorization", "Basic #{Base.encode64("#{username}:#{password}")}")
  end

  defp override_registry_setting(authed_conn, setting, value) do
    registry = %{authed_conn.assigns.oci_opts.registry | setting => value}

    %{
      authed_conn
      | assigns: %{
          authed_conn.assigns
          | oci_opts: %{authed_conn.assigns.oci_opts | registry: registry}
        }
    }
  end
end
