defmodule OCITest do
  use ExUnit.Case, async: true

  setup do
    tmp = Path.join(System.tmp_dir!(), "oci_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Process.put(:oci_tempfs_root, tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    :ok
  end

  describe "TempFS adapter unit tests" do
    test "storing and retrieving blobs" do
      mod = OCI.Storage.TempFS
      repo = "myrepo"
      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)
      assert mod.blob_exists?(repo, digest) == false
      :ok = mod.put_blob(repo, digest, "abc")
      assert mod.blob_exists?(repo, digest) == true
      assert {:ok, "abc"} = mod.get_blob(repo, digest)
    end

    test "storing and retrieving manifests with tags and digests" do
      mod = OCI.Storage.TempFS
      repo = "testrepo"
      manifest_json = ~s({"schemaVersion":2,"config":{},"layers":[]})

      manifest_digest =
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, manifest_json), case: :lower)

      :ok =
        mod.put_manifest(repo, "v1", manifest_json, "application/vnd.oci.image.manifest.v1+json")

      assert {:ok, ^manifest_json, _ctype} = mod.get_manifest(repo, "v1")
      assert {:ok, ^manifest_json, _ctype} = mod.get_manifest(repo, manifest_digest)

      {:ok, tags} = mod.list_tags(repo)
      assert "v1" in tags
    end

    test "delete manifest removes tag reference" do
      mod = OCI.Storage.TempFS
      repo = "deleterepo"
      manifest = "{}"

      :ok =
        mod.put_manifest(repo, "latest", manifest, "application/vnd.oci.image.manifest.v1+json")

      {:ok, tags_before} = mod.list_tags(repo)
      assert tags_before == ["latest"]

      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)
      assert :ok = mod.delete_manifest(repo, "latest")

      {:ok, tags_after} = mod.list_tags(repo)
      assert tags_after == [] or tags_after == nil

      assert :error == mod.get_manifest(repo, digest)
    end
  end
end
