class Nitra::FrameworkShims
  module Cucumber
    class << self
      def order
        1
      end

      def name
        "cucumber"
      end

      def load_environment
        require 'cucumber'
        require 'nitra/ext/cucumber'
      end

      def files
        Dir["features/**/*.feature"].sort_by {|f| File.size(f)}.reverse
      end

      def matching_file?(filename)
        filename =~ /\.feature/
      end

      def minimal_file
        <<-EOS
        Feature: cucumber preloading
          Scenario: a fake scenario
            Given every step is unimplemented
            When we run this file
            Then Cucumber will load it's environment
        EOS
      end
    end
  end
  module Rspec
    class << self
      def order
        0
      end

      def name
        "rspec"
      end
      
      def load_environment
        require './spec/spec_helper'
        RSpec::Core::Runner.disable_autorun!
      end

      def files
        Dir["spec/**/*_spec.rb"].sort_by {|f| File.size(f)}.reverse
      end

      def matching_file?(filename)
        filename =~ /_spec/
      end

      def minimal_file
        <<-EOS
        require 'spec_helper'
        describe('nitra preloading') do
          it('preloads the fixtures') do
            1.should == 1
          end
        end
        EOS
      end
    end
  end
  SHIMS = {:rspec => Nitra::FrameworkShims::Rspec, :cucumber => Nitra::FrameworkShims::Cucumber}

  def self.shim_for_file(filename)
    SHIMS.values.detect{|s| s.matching_file?(filename) }
  end
end
