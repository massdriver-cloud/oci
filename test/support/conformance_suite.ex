# credo:disable-for-this-file
defmodule ConformanceSuite do
  @moduledoc """
  A module for running the OCI Distribution Specification conformance tests.
  """

  require Logger

  def clone_repo(repo, branch, opts \\ []) do
    path = conformance_dir()
    force = Keyword.get(opts, :force, false)

    if force || !File.exists?(path) do
      File.rm_rf!(path)
      Logger.info("🔄 Cloning distribution-spec repo to #{path}")

      {output, status} =
        System.cmd("git", [
          "clone",
          "--depth",
          "1",
          "--branch",
          branch,
          repo,
          path
        ])

      case status do
        0 ->
          :ok

        err ->
          Logger.error("🚨 Error cloning distribution-spec repo: #{inspect(err)}")
          Logger.error("🚨 Output: #{output}")
          {:error, inspect(err)}
      end
    else
      :ok
    end
  end

  def build(opts \\ []) do
    force = Keyword.get(opts, :force, false)
    path = conformance_bin_path()

    if force or !File.exists?(path) do
      Logger.info("🚢 Building conformance test binary to #{path}")

      dir = Path.dirname(path)
      {output, status} = System.cmd("go", ["test", "-c"], cd: dir, stderr_to_stdout: true)

      case status do
        0 ->
          :ok

        err ->
          Logger.error("🚨 Error building conformance test binary: #{inspect(err)}")
          Logger.error("🚨 Output: #{output}")
          {:error, inspect(err)}
      end
    else
      :ok
    end
  end

  def generate_report() do
    env = [
      {"OCI_ROOT_URL", "http://localhost:4002"},
      {"OCI_NAMESPACE", "myorg/myrepo"},
      {"OCI_CROSSMOUNT_NAMESPACE", "myorg/other"},
      {"OCI_USERNAME", "myuser"},
      {"OCI_PASSWORD", "mypass"},
      {"OCI_TEST_PULL", "1"},
      {"OCI_TEST_PUSH", "1"},
      {"OCI_TEST_CONTENT_DISCOVERY", "0"},
      {"OCI_TEST_CONTENT_MANAGEMENT", "0"},
      {"OCI_AUTOMATIC_CROSSMOUNT", "0"},
      {"OCI_DELETE_MANIFEST_BEFORE_BLOBS", "0"},
      {"OCI_HIDE_SKIPPED_WORKFLOWS", "0"},
      {"OCI_DEBUG", "0"},
      {"OCI_REPORT_DIR", conformance_report_dir()}
    ]

    Logger.info("🧪 Generating conformance JSON report to #{conformance_json_report_path()}")
    Logger.info("🧪 Generating conformance HTML report to #{conformance_html_report_path()}")

    System.cmd(
      conformance_bin_path(),
      [
        "--ginkgo.json-report",
        conformance_json_report_path()
      ],
      env: env,
      stderr_to_stdout: true
    )
  end

  def failures() do
    conformance_json_report_path()
    |> File.read!()
    |> Jason.decode!()
    |> List.first()
    |> Map.get("SpecReports")
    |> Enum.filter(fn test -> test["State"] == "failed" end)
    |> Enum.sort_by(fn test ->
      file_path = test["Failure"]["Location"]["FileName"]
      line_no = test["Failure"]["Location"]["LineNumber"]

      {file_path, line_no}
    end)
  end

  def reports() do
    conformance_json_report_path()
    |> File.read!()
    |> Jason.decode!()
    |> List.first()
    |> Map.get("SpecReports")
  end

  def conformance_dir() do
    ".tmp/oci-conformance"
  end

  def conformance_report_dir() do
    "#{conformance_dir()}/reports"
  end

  def conformance_html_report_path() do
    "#{conformance_report_dir()}/report.html"
  end

  def conformance_json_report_path() do
    "#{conformance_report_dir()}/report.json"
  end

  def conformance_bin_path() do
    Path.expand("#{conformance_dir()}/conformance/conformance.test")
  end
end
