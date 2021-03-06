defmodule Benchee.BenchmarkTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  import Benchee.TestHelpers
  alias Benchee.Statistics
  alias Benchee.Benchmark

  doctest Benchee.Benchmark

  test ".benchmark adds the job to the jobs to be executed" do
    one_fun = fn -> 1 end
    suite = %{jobs: %{"one" => one_fun}}
    two_fun = fn -> 2 end
    new_suite = Benchee.benchmark(suite, "two", two_fun)
    assert new_suite == %{jobs: %{"two" => two_fun, "one" => one_fun}}
  end

  test ".benchmark warns when adding a job with the same name again" do
    output = capture_io fn ->
      one_fun = fn -> 1 end
      suite = %{jobs: %{"one" => one_fun}}
      new_suite = Benchee.benchmark(suite, "one", fn -> 42 end)

      assert new_suite == %{jobs: %{"one" => one_fun}}
    end

    assert output =~ ~r/same name/
  end

  @config %{parallel: 1,
            time: 40_000,
            warmup: 20_000,
            inputs: nil,
            print: %{fast_warning: false, configuration: true}}
  test ".measure runs a benchmark suite and enriches it with measurements" do
    retrying fn ->
      capture_io fn ->
        config = Map.merge @config, %{time: 60_000, warmup: 10_000}
        suite = %{config: config, jobs: %{}}
        new_suite =
          suite
          |> Benchee.benchmark("Name", fn -> :timer.sleep(10) end)
          |> Benchee.measure

        assert new_suite.config == suite.config
        run_times_hash = new_suite.run_times |> no_input_access

        # should be 6 but gotta give it a bit leeway
        assert length(run_times_hash["Name"]) >= 5
      end
    end
  end

  test ".measure runs a suite with multiple jobs and gathers results" do
    retrying fn ->
      capture_io fn ->
        config = Map.merge @config, %{time: 60_000, warmup: 10_000}
        suite = %{config: config, jobs: %{}}
        new_suite =
          suite
          |> Benchee.benchmark("Name", fn -> :timer.sleep(10) end)
          |> Benchee.benchmark("Name 2", fn -> :timer.sleep(5) end)
          |> Benchee.measure

        run_times_hash = new_suite.run_times |> no_input_access

        # should be 6 but gotta give it a bit leeway
        assert length(run_times_hash["Name"]) >= 5
        # should be 12, but gotta give it some leeway
        assert length(run_times_hash["Name 2"]) >= 9
      end
    end
  end

  test ".measure can run multiple benchmarks in parallel" do
    capture_io fn ->
      config = Map.merge @config, %{parallel: 6, time: 60_000}
      suite = %{
        config: config,
        jobs: %{"" => fn -> :timer.sleep 10 end}
      }
      new_suite = Benchee.measure suite

      assert %{"" => run_times} = new_suite.run_times |> no_input_access

      # it does more work when working in parallel than it does alone
      assert length(run_times) >= 12
    end
  end

  test ".measure doesn't take longer than advertised for very fast funs" do
    retrying fn ->
      capture_io fn ->
        time = 20_000
        warmup = 10_000
        projected = time + warmup
         # if the system is too busy there are too many false positives
        leeway = projected * 0.4
        config = Map.merge @config, %{time: time, warmup: warmup}
        suite = %{config: config,
                  jobs:   %{"" => fn -> :timer.sleep(1) end}}
        {time, _} = :timer.tc fn -> Benchee.measure(suite) end

        assert_in_delta projected, time, leeway,
                        "excution took too long #{time} vs. #{projected} +- #{leeway}"
      end
    end
  end

  test "variance does not skyrocket on very fast functions" do
    retrying fn ->
      capture_io fn ->
        range = 0..10
        config = Map.merge @config, %{time: 100_000, warmup: 10_000}
        stats = %{config: config, jobs: %{}}
                |> Benchee.benchmark("noop", fn -> 0 end)
                |> Benchee.benchmark("map", fn ->
                     Enum.map(range, fn(i) -> i end)
                   end)
                |> Benchee.measure
                |> Statistics.statistics
                |> Map.get(:statistics)
                |> no_input_access

        Enum.each stats, fn({_, %{std_dev_ratio: std_dev_ratio}}) ->
          assert std_dev_ratio <= 2.0
        end
      end
    end
  end

  test ".measure doesn't print out information about warmup (annoying)" do
    output = capture_io fn ->
      config = Map.merge @config, %{time: 1_000, warmup: 500}
      %{config: config, jobs: %{}}
      |> Benchee.benchmark("noop", fn -> 0 end)
      |> Benchee.measure
    end

    refute output =~ ~r/running.+warmup/i
  end

  test ".measure never calls the function if warmup and time are 0" do
    output = capture_io fn ->
      config = Map.merge @config, %{time: 0, warmup: 0}
      %{config: config, jobs: %{"" => fn -> IO.puts "called" end}}
      |> Benchmark.measure
    end

    refute output =~ ~r/called/i
  end

  test ".measure prints configuration information about the suite" do
    output = capture_io fn ->
      config = Map.merge @config, %{parallel: 2, time: 10_000, warmup: 0}
      %{config: config, jobs: %{}}
      |> Benchee.benchmark("noop", fn -> 0 end)
      |> Benchee.benchmark("dontcare", fn -> 0 end)
      |> Benchee.measure
    end

    assert output =~ "Erlang/OTP"
    assert output =~ "Elixir #{System.version}"
    assert output =~ ~r/following configuration/i
    assert output =~ "warmup: 0.0s"
    assert output =~ "time: 0.01s"
    assert output =~ "parallel: 2"
    assert output =~ "Estimated total run time: 0.02s"
  end

  @inputs %{"Arg 1" => "Argument 1", "Arg 2" => "Argument 2"}
  test ".measure respects multiple inputs in suite information" do
    output = capture_io fn ->
      config = Map.merge @config, %{
                                    parallel: 2,
                                    time: 10_000,
                                    warmup: 0,
                                    inputs: @inputs
                                  }
      %{config: config, jobs: %{}}
      |> Benchee.benchmark("noop", fn(_) -> 0 end)
      |> Benchee.benchmark("dontcare", fn(_) -> 0 end)
      |> Benchee.measure
    end

    assert output =~ "time: 0.01s"
    assert output =~ "parallel: 2"
    assert output =~ "inputs: Arg 1, Arg 2"
    assert output =~ "Estimated total run time: 0.04s"
  end

  test ".measure does not print configuration information when disabled" do
    output = capture_io fn ->
      custom = %{
                  parallel: 2,
                  time: 1_000,
                  warmup: 0
                 }
      config = Map.merge @config, custom
      config = update_in(config, [:print, :configuration], fn(_) -> false end)
      %{config: config, jobs: %{}}
      |> Benchee.benchmark("noop", fn -> 0 end)
      |> Benchee.benchmark("dontcare", fn -> 0 end)
      |> Benchee.measure
    end

    refute output =~ "Erlang"
    refute output =~ "Elxir"
    refute output =~ ~r/following configuration/i
    refute output =~ "warmup:"
    refute output =~ "time:"
    refute output =~ "parallel:"
    refute output =~ "Estimated total run time"
  end

  test ".measure prints out information what is currently benchmarking" do
    output = capture_io fn ->
      %{config: @config, jobs: %{}}
      |> Benchee.benchmark("Something", fn -> :timer.sleep 10 end)
      |> Benchee.measure
    end

    assert output =~ "Benchmarking Something"
  end

  test ".measure doesn't print out currently benchmarking info if disabled" do
    output = capture_io fn ->
      config = update_in @config, [:print, :benchmarking], fn(_) -> false end
      %{config: config, jobs: %{}}
      |> Benchee.benchmark("Something", fn -> :timer.sleep 10 end)
      |> Benchee.measure
    end

    refute output =~ "Benchmarking Something"
  end

  test ".measure calls the functions with the different inputs arguments" do
    output = capture_io fn ->
      config = Map.merge @config, %{inputs: @inputs}
      jobs = %{
        "one" => fn(input) -> IO.puts "Called one with #{input}" end,
        "two" => fn(input) -> IO.puts "Called two with #{input}" end
      }
      %{config: config, jobs: jobs}
      |> Benchee.measure
    end

    Enum.each @inputs, fn({_name, value}) ->
      assert output =~ "Called one with #{value}"
      assert output =~ "Called two with #{value}"
    end
  end

  test ".measure notifies which input is being benchmarked now" do
    output = capture_io fn ->
      config = Map.merge @config, %{inputs: @inputs}
      jobs = %{
        "one" => fn(input) -> IO.puts "Called one with #{input}" end,
        "two" => fn(input) -> IO.puts "Called two with #{input}" end
      }
      %{config: config, jobs: jobs}
      |> Benchee.measure
    end

    Enum.each @inputs, fn({name, _value}) ->
      assert output =~ "with input #{name}"
    end
  end

  test ".measure populates results for all inputs" do
    retrying fn ->
      capture_io fn ->
        inputs = %{
          "Short wait"  => 5,
          "Longer wait" => 10
        }
        config = Map.merge @config, %{time: 60_000,
                                      warmup: 10_000,
                                      inputs: inputs}
        jobs = %{
          "sleep" => fn(input) -> :timer.sleep(input) end
        }
        results = Benchee.measure(%{config: config, jobs: jobs}).run_times

        # should be 12 but the good old leeway
        assert length(results["Short wait"]["sleep"]) >= 9
        # should be 6 but the good old leeway
        assert length(results["Longer wait"]["sleep"]) >= 5
      end
    end
  end

  test ".measure runs the job exactly once if its time exceeds given time" do
    capture_io fn ->
      config = Map.merge @config, %{time: 1_000, warmup: 0}
      jobs = %{"Sleeps" => fn -> :timer.sleep(2) end}
      run_times = Benchee.measure(%{config: config, jobs: jobs})
                  |> get_in([:run_times, Benchmark.no_input, "Sleeps"])

      assert length(run_times) == 1
    end
  end

  test ".measure stores run times in the right order" do
    capture_io fn ->
      config = Map.merge @config, %{time: 25_000, warmup: 0}
      {:ok, agent} = Agent.start fn -> 1 end
      increasing_function = fn ->
        Agent.update agent, fn(state) ->
          :timer.sleep state
          state * 5
        end
      end
      jobs = %{"Sleep more" => increasing_function}
      run_times = Benchee.measure(%{config: config, jobs: jobs})
                  |> get_in([:run_times, Benchmark.no_input, "Sleep more"])

      assert length(run_times) >= 2 # should be 3 but good old leeway
      # as the function takes more time each time called run times should be
      # as if sorted ascending
      assert run_times == Enum.sort(run_times)
    end
  end
end
