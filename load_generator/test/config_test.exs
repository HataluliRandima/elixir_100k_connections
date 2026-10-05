defmodule LoadGenerator.ConfigTest do
  use ExUnit.Case, async: true

  alias LoadGenerator.Config

  defp parse!(argv) do
    {:ok, config, warnings} = Config.parse(argv)
    {config, warnings}
  end

  describe "required target" do
    test "--connections is required" do
      assert {:error, message} = Config.parse([])
      assert message =~ "--connections is required"
    end

    test "--connections must be positive" do
      assert {:error, _} = Config.parse(["--connections", "0"])
    end

    test "unknown options are rejected" do
      assert {:error, message} = Config.parse(["--connections", "10", "--bogus", "1"])
      assert message =~ "--bogus"
    end
  end

  describe "safety" do
    test "loopback targets are accepted" do
      for url <- ["ws://127.0.0.1:4000/socket/websocket", "ws://localhost:4000/socket/websocket"] do
        assert {:ok, _config, _} = Config.parse(["--connections", "1", "--url", url])
      end
    end

    test "non-loopback targets are refused by default" do
      assert {:error, message} =
               Config.parse([
                 "--connections",
                 "1",
                 "--url",
                 "ws://192.0.2.10:4000/socket/websocket"
               ])

      assert message =~ "only loopback targets"
    end

    test "--allow-remote permits a non-loopback target" do
      assert {:ok, config, _} =
               Config.parse([
                 "--connections",
                 "1",
                 "--url",
                 "ws://192.0.2.10:4000/socket/websocket",
                 "--allow-remote"
               ])

      assert config.host == "192.0.2.10"
    end

    test "wss is not supported" do
      assert {:error, message} =
               Config.parse(["--connections", "1", "--url", "wss://127.0.0.1/socket/websocket"])

      assert message =~ "wss://"
    end

    test "source IPs must be loopback" do
      assert {:error, message} = Config.parse(["--connections", "1", "--source-ips", "10.0.0.5"])
      assert message =~ "loopback"
    end
  end

  describe "options" do
    test "defaults" do
      {config, _} = parse!(["--connections", "100"])

      assert config.host == "127.0.0.1"
      assert config.port == 4000
      assert config.path == "/socket/websocket"
      assert config.ramp_up_s == 10.0
      assert config.duration_s == 60.0
      assert config.message_interval_ms == 30_000
      assert config.metrics_url == "http://127.0.0.1:4000/metrics"
      assert Config.request_path(config) == "/socket/websocket?vsn=2.0.0"
    end

    test "parses timing options" do
      {config, _} =
        parse!([
          "--connections",
          "100",
          "--ramp-up",
          "5",
          "--duration",
          "30",
          "--message-interval",
          "1000",
          "--connection-duration",
          "12.5"
        ])

      assert config.ramp_up_s == 5.0
      assert config.duration_s == 30.0
      assert config.message_interval_ms == 1000
      assert config.connection_duration_s == 12.5
    end

    test "a query string in --url is kept alongside the serializer version" do
      {config, _} =
        parse!(["--connections", "1", "--url", "ws://127.0.0.1:4000/socket/websocket?reject=true"])

      assert Config.request_path(config) == "/socket/websocket?reject=true&vsn=2.0.0"
    end

    test "--message-rate is converted to a per-client interval" do
      {config, _} = parse!(["--connections", "1000", "--message-rate", "500"])
      assert config.message_interval_ms == 2000
    end

    test "source IPs are assigned round-robin" do
      {config, _} = parse!(["--connections", "4", "--source-ips", "127.0.0.1,127.0.0.2"])

      assert Config.source_ip(config, 0) == {127, 0, 0, 1}
      assert Config.source_ip(config, 1) == {127, 0, 0, 2}
      assert Config.source_ip(config, 2) == {127, 0, 0, 1}
    end

    test "no source IP means the kernel chooses" do
      {config, _} = parse!(["--connections", "4"])
      assert Config.source_ip(config, 0) == nil
    end
  end

  describe "warnings" do
    test "warns when pings are slower than the server idle timeout" do
      {_config, warnings} = parse!(["--connections", "1", "--message-interval", "60000"])
      assert Enum.any?(warnings, &(&1 =~ "idle timeout"))
    end

    @tag :linux
    test "warns when connections exceed the ephemeral port range" do
      case Config.local_port_range() do
        {:ok, {low, high}} ->
          too_many = high - low + 2
          {_config, warnings} = parse!(["--connections", Integer.to_string(too_many)])
          assert Enum.any?(warnings, &(&1 =~ "ephemeral port"))

          {_config, warnings} =
            parse!([
              "--connections",
              Integer.to_string(too_many),
              "--source-ips",
              "127.0.0.1,127.0.0.2"
            ])

          refute Enum.any?(warnings, &(&1 =~ "ephemeral port"))

        :error ->
          :ok
      end
    end
  end

  test "parses the kernel port range format", %{} do
    path = Path.join(System.tmp_dir!(), "port_range_#{System.unique_integer([:positive])}")
    File.write!(path, "32768\t60999\n")
    assert Config.local_port_range(path) == {:ok, {32768, 60999}}
    File.rm!(path)
  end
end
