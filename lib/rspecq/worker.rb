require "json"
require "pathname"
require "pp"

module RSpecQ
  class Worker
    HEARTBEAT_FREQUENCY = WORKER_LIVENESS_SEC / 6

    # If true, job timings will be populated in the global Redis timings key
    #
    # Defaults to false
    attr_accessor :populate_timings

    # If set, spec files that are known to take more than this value to finish,
    # will be split and scheduled on a per-example basis.
    attr_accessor :file_split_threshold

    # Retry failed examples up to N times (with N being the supplied value)
    # before considering them legit failures
    #
    # Defaults to 3
    attr_accessor :max_requeues

    attr_reader :queue

    def initialize(build_id:, worker_id:, redis_host:, files_or_dirs_to_run:)
      @build_id = build_id
      @worker_id = worker_id
      @queue = Queue.new(build_id, worker_id, redis_host)
      @files_or_dirs_to_run = files_or_dirs_to_run
      @populate_timings = false
      @file_split_threshold = 999999
      @heartbeat_updated_at = nil
      @max_requeues = 3

      RSpec::Core::Formatters.register(Formatters::JobTimingRecorder, :dump_summary)
      RSpec::Core::Formatters.register(Formatters::ExampleCountRecorder, :dump_summary)
      RSpec::Core::Formatters.register(Formatters::FailureRecorder, :example_failed, :message)
      RSpec::Core::Formatters.register(Formatters::WorkerHeartbeatRecorder, :example_finished)
    end

    def work
      puts "Working for build #{@build_id} (worker=#{@worker_id})"

      try_publish_queue!(queue)
      queue.wait_until_published

      loop do
        # we have to bootstrap this so that it can be used in the first call
        # to `requeue_lost_job` inside the work loop
        update_heartbeat

        lost = queue.requeue_lost_job
        puts "Requeued lost job: #{lost}" if lost

        # TODO: can we make `reserve_job` also act like exhausted? and get
        # rid of `exhausted?` (i.e. return false if no jobs remain)
        job = queue.reserve_job

        # build is finished
        return if job.nil? && queue.exhausted?

        next if job.nil?

        puts
        puts "Executing #{job}"

        reset_rspec_state!

        # reconfigure rspec
        RSpec.configuration.detail_color = :magenta
        RSpec.configuration.seed = srand && srand % 0xFFFF
        RSpec.configuration.backtrace_formatter.filter_gem('rspecq')
        RSpec.configuration.add_formatter(Formatters::FailureRecorder.new(queue, job, max_requeues))
        RSpec.configuration.add_formatter(Formatters::ExampleCountRecorder.new(queue))
        RSpec.configuration.add_formatter(Formatters::WorkerHeartbeatRecorder.new(self))

        if populate_timings
          RSpec.configuration.add_formatter(Formatters::JobTimingRecorder.new(queue, job))
        end

        opts = RSpec::Core::ConfigurationOptions.new(["--format", "progress", job])
        _result = RSpec::Core::Runner.new(opts).run($stderr, $stdout)

        queue.acknowledge_job(job)
      end
    end

    # Update the worker heartbeat if necessary
    def update_heartbeat
      if @heartbeat_updated_at.nil? || elapsed(@heartbeat_updated_at) >= HEARTBEAT_FREQUENCY
        queue.record_worker_heartbeat
        @heartbeat_updated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def try_publish_queue!(queue)
      return if !queue.become_master

      RSpec.configuration.files_or_directories_to_run = @files_or_dirs_to_run
      files_to_run = RSpec.configuration.files_to_run.map { |j| relative_path(j) }

      timings = queue.timings
      if timings.empty?
        q_size = queue.publish(files_to_run.shuffle)
        log_event(
          "No timings found! Published queue in random order (size=#{q_size})",
          "warning"
        )
        return
      end

      slow_files = timings.take_while do |_job, duration|
        duration >= file_split_threshold
      end.map(&:first) & files_to_run

      if slow_files.any?
        log_event(
          "Slow files detected (threshold=#{file_split_threshold}): #{slow_files}",
          "info",
          slow_files: slow_files,
          slow_files_count: slow_files.count,
        )
      end

      # prepare jobs to run
      jobs = []
      jobs.concat(files_to_run - slow_files)
      jobs.concat(files_to_example_ids(slow_files)) if slow_files.any?

      # assign timings to all of them
      default_timing = timings.values[timings.values.size/2]

      jobs = jobs.each_with_object({}) do |j, h|
        # heuristic: put untimed jobs in the middle of the queue
        puts "New/untimed job: #{j}" if timings[j].nil?
        h[j] = timings[j] || default_timing
      end

      # finally, sort them based on their timing (slowest first)
      jobs = jobs.sort_by { |_j, t| -t }.map(&:first)

      puts "Published queue (size=#{queue.publish(jobs)})"
    end

    private

    def reset_rspec_state!
      RSpec.clear_examples

      # TODO: remove after https://github.com/rspec/rspec-core/pull/2723
      RSpec.world.instance_variable_set(:@example_group_counts_by_spec_file, Hash.new(0))

      # RSpec.clear_examples does not reset those, which causes issues when
      # a non-example error occurs (subsequent jobs are not executed)
      # TODO: upstream
      RSpec.world.non_example_failure = false

      # we don't want an error that occured outside of the examples (which
      # would set this to `true`) to stop the worker
      RSpec.world.wants_to_quit = false
    end

    # NOTE: RSpec has to load the files before we can split them as individual
    # examples. In case a file to be splitted fails to be loaded
    # (e.g. contains a syntax error), we return the slow files unchanged,
    # thereby falling back to scheduling them normally.
    #
    # Their errors will be reported in the normal flow, when they're picked up
    # as jobs by a worker.
    def files_to_example_ids(files)
      cmd = "DISABLE_SPRING=1 bundle exec rspec --dry-run --format json #{files.join(' ')} 2>&1"
      out = `#{cmd}`
      cmd_result = $?

      if !cmd_result.success?
        rspec_output = begin
                         JSON.parse(out)
                       rescue JSON::ParserError
                         out
                       end

        log_event(
          "Failed to split slow files, falling back to regular scheduling",
          "error",
          rspec_output: rspec_output,
          cmd_result: cmd_result.inspect,
        )

        pp rspec_output

        return files
      end

      JSON.parse(out)["examples"].map { |e| e["id"] }
    end

    def relative_path(job)
      @cwd ||= Pathname.new(Dir.pwd)
      "./#{Pathname.new(job).relative_path_from(@cwd)}"
    end

    def elapsed(since)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - since
    end

    # Prints msg to standard output and emits an event to Sentry, if the
    # SENTRY_DSN environment variable is set.
    def log_event(msg, level, additional={})
      puts msg

      Raven.capture_message(msg, level: level, extra: {
        build: @build_id,
        worker: @worker_id,
        queue: queue.inspect,
        files_or_dirs_to_run: @files_or_dirs_to_run,
        populate_timings: populate_timings,
        file_split_threshold: file_split_threshold,
        heartbeat_updated_at: @heartbeat_updated_at,
        object: self.inspect,
        pid: Process.pid,
      }.merge(additional))
    end
  end
end
