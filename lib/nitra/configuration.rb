class Nitra::Configuration
  attr_accessor :load_schema, :migrate, :debug, :quiet, :print_failures
  attr_accessor :process_count, :environment, :slaves, :slave_mode, :frameworks, :default_framework

  def initialize
    self.environment = "nitra"
    self.slaves = []
    self.frameworks = []
    calculate_default_process_count
  end

  def calculate_default_process_count
    self.process_count ||= Nitra::Utils.processor_count
  end

  def set_process_count(n)
    if slaves.empty?
      self.process_count = n
    else
      slaves.last[:cpus] = n
    end
  end

  def default_framework_shim
    Nitra::FrameworkShims::SHIMS[default_framework.to_sym]
  end
end
