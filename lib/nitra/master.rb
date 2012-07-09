class Nitra::Master
  attr_reader :configuration, :files, :default_framework

  FILEMAP_FILE = "log/nitra_filemap"

  def initialize(configuration, files = nil)
    @configuration = configuration
    @files = (files || []).map{|f| Nitra::File.new(f)}
    load_framework_files
  end

  def load_framework_files
    configuration.frameworks.each do |framework|
      @files += Nitra::FrameworkShims::SHIMS[framework].files.map{|f| Nitra::File.new(f)}
    end
  end

  def run
    return if files.empty?

    filemap = Hash[*files.map{|f| [f.filename, f]}.flatten]
    load_filemap(filemap)
    files.sort!

    configuration.default_framework = files.first.framework
    filenames = files.map(&:filename)

    progress = Nitra::Progress.new
    progress.file_count = files.length
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
            filename = filenames.shift
            channel.write "filename" => filename
            filemap[filename].sent_at = Time.now if filename
          when "previous"
            filenames.unshift data["filename"]
          when "result"
            progress.files_completed += 1
            progress.example_count += data["example_count"] || 0
            progress.failure_count += data["failure_count"] || 0
            progress.output << data["text"]
            yield progress, data
            filemap[data["filename"]].received_at = Time.now
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

    debug "writing filemap..."
    write_filemap(filemap)

    progress
  end

  protected
  def debug(*text)
    puts "master: #{text.join}" if configuration.debug
  end

  def write_filemap(filemap)
    filemap.values.each(&:update_last_run_time)
    File.open(FILEMAP_FILE, "w"){|f| f.write YAML.dump(filemap)}
  end

  def load_filemap(filemap)
    if File.exists?(FILEMAP_FILE)
      old_filemap = YAML.load_file(FILEMAP_FILE)
      filemap.each do |key, value|
        old_file = old_filemap[key]
        value.last_run_time = old_file.last_run_time if old_file
      end
    end
  end
end
