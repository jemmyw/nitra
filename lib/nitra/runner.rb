require 'stringio'

class Nitra::Runner
  attr_reader :configuration, :server_channel, :runner_id, :framework
  attr_reader :workers

  def initialize(configuration, server_channel, runner_id)
    @configuration = configuration
    @server_channel = server_channel
    @runner_id = runner_id
    @framework = configuration.default_framework_shim
    @workers = []

    configuration.calculate_default_process_count
    server_channel.raise_epipe_on_write_error = true
  end

  def run
    ENV["RAILS_ENV"] = configuration.environment

    initialise_database

    load_rails_environment

    start_workers

    trap("SIGTERM") { $aborted = true }
    trap("SIGINT") { $aborted = true }

    hand_out_files_to_workers
  rescue Errno::EPIPE
  ensure
    trap("SIGTERM", "DEFAULT")
    trap("SIGINT", "DEFAULT")
  end

  protected
  def initialise_database
    if configuration.load_schema || configuration.migrate
      require 'rake'
      Rake.load_rakefile("Rakefile") 
    end

    if configuration.load_schema
      pids, ios = configuration.process_count.times.to_a.map do |index|
        debug "initialising database #{index+1}..."
        rd, wr = IO.pipe

        pid = fork do
          $stdout.reopen(wr)
          $stderr.reopen(wr)
          rd.close

          ENV["TEST_ENV_NUMBER"] = (index + 1).to_s

          Rake::Task["db:drop"].invoke
          Rake::Task["db:create"].invoke
          Rake::Task["db:schema:load"].invoke

          wr.close
          exit!
        end

        wr.close
        [pid, rd]
      end.transpose

      output = ""
      loop do
        rios, _ = IO.select(ios)
        break if rios.nil? || rios.empty?
        text = rios.map(&:read).join
        break if text.nil? || text.length.zero?
        output << text
      end
      ios.each(&:close)

      pids.each{|pid| Process.waitpid(pid) }
      server_channel.write("command" => "stdout", "process" => "db:schema:load", "text" => output)
    end

    if configuration.migrate
      pids, ios = configuration.process_count.times.to_a.map do |index|
        debug "migrating database #{index+1}..."
        rd, wr = IO.pipe

        pid = fork do
          $stdout.reopen(wr)
          $stderr.reopen(wr)
          rd.close
           
          ENV["TEST_ENV_NUMBER"] = (index + 1).to_s
          Rake::Task["db:migrate"].invoke

          wr.close
          exit!
        end

        wr.close
        [pid, rd]
      end.transpose

      output = ""
      loop do
        rios, _ = IO.select(ios)
        break if rios.nil? || rios.empty?
        text = rios.map(&:read).join
        break if text.nil? || text.length.zero?
        output << text
      end
      ios.each(&:close)

      pids.each{|pid| Process.waitpid(pid) }
      server_channel.write("command" => "stdout", "process" => "db:schema:load", "text" => output)
    end
  end

  def load_rails_environment
    debug "Loading rails environment..."

    ENV["TEST_ENV_NUMBER"] = "1"

    output = Nitra::Utils.capture_output do
      require './config/application'
      Rails.application.require_environment!
    end

    server_channel.write("command" => "stdout", "process" => "rails initialisation", "text" => output)

    ActiveRecord::Base.connection.disconnect!
  end

  def start_workers
    (0...configuration.process_count).collect do |index|
      start_worker(index, framework)
    end
  end

  def start_worker(index, framework)
    worker = Nitra::Worker.new(runner_id, index, configuration, framework)
    worker.fork_and_run
    workers << worker
  end

  def running_workers
    workers.select(&:running?)
  end

  def pipes
    workers.select(&:running?).map(&:pipe) + [server_channel]
  end

  def hand_out_files_to_workers
    while !$aborted && running_workers.any?
      Nitra::Channel.read_select(pipes).each do |worker_channel|
        # This is our back-channel that lets us know in case the master is dead.
        kill_workers if worker_channel == server_channel && server_channel.rd.eof?

        unless data = worker_channel.read
          debug "Worker #{worker_channel} unexpectedly died."
          running_workers.detect{|w|w.pipe == worker_channel}.close
          next
        end

        case data['command']
        when "debug", "stdout"
          server_channel.write(data)

        when "result"
          # Rspec result
          if m = data['text'].match(/(\d+) examples?, (\d+) failure/)
            example_count = m[1].to_i
            failure_count = m[2].to_i
          # Cucumber result
          elsif m = data['text'].match(/(\d+) scenarios?.+$/)
            example_count = m[1].to_i
            if m = data['text'].match(/\d+ scenarios? \(.*(\d+) [failed|undefined].*\)/)
              failure_count = m[1].to_i
            else
              failure_count = 0
            end
          end

          stripped_data = data['text'].gsub(/^[.FP*]+$/, '').gsub(/\nFailed examples:.+/m, '').gsub(/^Finished in.+$/, '').gsub(/^\d+ example.+$/, '').gsub(/^No examples found.$/, '').gsub(/^Failures:$/, '')

          server_channel.write(
            "command"       => "result",
            "filename"      => data["filename"],
            "return_code"   => data["return_code"],
            "example_count" => example_count,
            "failure_count" => failure_count,
            "text"          => stripped_data)

        when "ready"
          server_channel.write("command" => "next")
          next_file = server_channel.read.fetch("filename")

          if next_file
            shim = Nitra::FrameworkShims.shim_for_file(next_file)

            if data["framework"] == shim.name
              debug "Sending #{next_file} to channel #{worker_channel}"
              worker_channel.write "command" => "process", "filename" => next_file
            else
              debug "Wrong framework for #{next_file}, closing worker and creating for #{shim.name}"
              server_channel.write("command" => "previous", "filename" => next_file)
              worker_channel.write("command" => "close")
              worker = running_workers.detect{|w|w.pipe == worker_channel}
              worker.close
              start_worker(worker.worker_number, shim)
            end
          else
            debug "Sending close message to channel #{worker_channel}"
            worker_channel.write "command" => "close"
            running_workers.detect{|w|w.pipe == worker_channel}.close
          end
        end
      end
    end
  end

  def debug(*text)
    if configuration.debug
      server_channel.write("command" => "debug", "text" => "runner #{runner_id}: #{text.join}")
    end
  end

  ##
  # Kill the workers.
  #
  def kill_workers
    workers.each(&:kill)
    Process.waitall
    exit
  end
end
