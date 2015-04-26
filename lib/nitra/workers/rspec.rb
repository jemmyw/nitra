module Nitra::Workers
  class Rspec < Worker
    def self.files
      Dir["spec/**/*_spec.rb"].sort_by {|f| File.size(f)}.reverse
    end

    def self.filename_match?(filename)
      filename =~ /_spec\.rb/
    end

    def initialize(runner_id, worker_number, configuration)
      super(runner_id, worker_number, configuration)
    end

    def load_environment
      require 'rspec'
      RSpec::Core::Runner.disable_autorun!
      RSpec.configuration.output_stream = io
    end

    def minimal_file
      <<-EOS
      require 'spec_helper'
      describe('nitra preloading') do
        it('preloads the fixtures') do
          expect(1).to eq(1)
        end
      end
      EOS
    end

    ##
    # Run an rspec file.
    #
    def run_file(filename, preloading = false)
      runner = runner_for(filename)
      failure = runner.run(io, io).to_i != 0

      if failure && @configuration.exceptions_to_retry && @attempt && @attempt < @configuration.max_attempts &&
         io.string =~ @configuration.exceptions_to_retry
        raise RetryException
      end

      if m = io.string.match(/(\d+) examples?, (\d+) failure/)
        test_count = m[1].to_i
        failure_count = m[2].to_i
      else
        test_count = failure_count = 0
      end

      {
        "failure"       => failure,
        "test_count"    => test_count,
        "failure_count" => failure_count,
      }
    end

    def runner_for(filename)
      args = ["-f", "p", filename]
      if RSpec::Core::const_defined?(:CommandLine) && RSpec::Core::Version::STRING < "2.99"
        RSpec::Core::CommandLine.new(args)
      else
        options = RSpec::Core::ConfigurationOptions.new(args)
        options.parse_options if options.respond_to?(:parse_options) # only for 2.99
        RSpec::Core::Runner.new(options)
      end
    end

    def clean_up
      super

      # Rspec.reset in 2.6 didn't destroy your rspec_rails fixture loading, we can't use it anymore for it's intended purpose.
      # This means our world object will be slightly polluted by the preload_framework code, but that's a small price to pay
      # to upgrade.
      #
      # RSpec.reset
      #
      RSpec.instance_variable_set(:@world, nil)

      # reset the reporter so we don't end up with two when we reuse the Configuration
      # RSpec.configuration.reset
    end
  end
end
