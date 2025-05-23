defmodule OCITest do
  use ExUnit.Case, async: true

  setup do
    # Ensure a fresh start for the in-memory storage before each test
    OCI.StorageAdapter.Memory.reset()
    :ok
  end

  describe "MemoryAdapter unit tests" do
    test "storing and retrieving blobs" do
      mem = OCI.StorageAdapter.Memory
      mem.reset()
      repo = "myrepo"
      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)
      assert mem.blob_exists?(repo, digest) == false
      :ok = mem.put_blob(repo, digest, "abc")
      assert mem.blob_exists?(repo, digest) == true
      assert {:ok, "abc"} = mem.get_blob(repo, digest)
    end

    test "storing and retrieving manifests with tags and digests" do
      mem = OCI.StorageAdapter.Memory
      mem.reset()
      repo = "testrepo"
      manifest_json = ~s({"schemaVersion":2,"config":{},"layers":[]})
      # Compute digest of manifest
      manifest_digest =
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, manifest_json), case: :lower)

      # Put manifest with a tag
      :ok =
        mem.put_manifest(repo, "v1", manifest_json, "application/vnd.oci.image.manifest.v1+json")

      # It should be retrievable by tag and by digest
      assert {:ok, ^manifest_json, _ctype} = mem.get_manifest(repo, "v1")
      assert {:ok, ^manifest_json, _ctype} = mem.get_manifest(repo, manifest_digest)
      # Tag "v1" should map to the content digest
      {:ok, tags} = mem.list_tags(repo)
      assert "v1" in tags
    end

    test "delete manifest removes tag reference" do
      mem = OCI.StorageAdapter.Memory
      repo = "deleterepo"
      # Store a dummy manifest under tag "latest"
      manifest = "{}"

      :ok =
        mem.put_manifest(repo, "latest", manifest, "application/vnd.oci.image.manifest.v1+json")

      # Ensure tag exists
      {:ok, tags_before} = mem.list_tags(repo)
      assert tags_before == ["latest"]
      # Compute the digest of the manifest
      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)
      # Delete by tag
      assert :ok = mem.delete_manifest(repo, "latest")
      {:ok, tags_after} = mem.list_tags(repo)
      assert tags_after == [] or tags_after == nil
      # Manifest should also be removed
      assert :error == mem.get_manifest(repo, digest)
    end
  end
end
