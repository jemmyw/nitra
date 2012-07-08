class Nitra::Master
  attr_reader :configuration, :files, :default_framework

  def initialize(configuration, files = nil)
    @configuration = configuration
    @files = files || []
  end

  def run
    configuration.frameworks.each do |framework|
      @files += Nitra::FrameworkShims::SHIMS[framework].files
    end
    return if files.empty?
    @files = @files.sort_by{|f| File.size(f)}.reverse.sort_by{|f| Nitra::FrameworkShims.shim_for_file(f).order }
    configuration.default_framework = Nitra::FrameworkShims.shim_for_file(files.first).name

    progress = Nitra::Progress.new
    progress.file_count = @files.length
    yield progress, nil

    runners = []

    if configuration.process_count > 0
      client, runner = Nitra::Channel.pipe
      fork do
        runner.close
        Nitra::Runner.new(configuration, client, "A").run
      end
      client.close
      runners << runner
    end

    slave = Nitra::Slave::Client.new(configuration)
    runners += slave.connect

    while runners.length > 0
      Nitra::Channel.read_select(runners).each do |channel|
        if data = channel.read
          case data["command"]
          when "next"
            channel.write "filename" => files.shift
          when "previous"
            files.unshift data["filename"]
          when "result"
            progress.files_completed += 1
            progress.example_count += data["example_count"] || 0
            progress.failure_count += data["failure_count"] || 0
            progress.output << data["text"]
            yield progress, data
          when "debug"
            if configuration.debug
              puts "[DEBUG] #{data["text"]}"
            end
          when "stdout"
            if configuration.debug
              puts "STDOUT for #{data["process"]} #{data["filename"]}:\n#{data["text"]}" unless data["text"].empty?
            end
          end
        else
          runners.delete channel
        end
      end
    end

    debug "waiting for all children to exit..."
    Process.waitall
    progress
  end

  protected
  def debug(*text)
    puts "master: #{text.join}" if configuration.debug
  end
end
