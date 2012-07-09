class Nitra::File
  include Comparable

  attr_reader :filename, :framework, :size
  attr_accessor :last_run_time, :sent_at, :received_at

  def initialize(filename, last_run_time = nil)
    @filename = filename
    @framework = Nitra::FrameworkShims.shim_for_file(filename).name
    @size = File.size(filename)
    @last_run_time = last_run_time
  end

  def <=>(other)
    if framework != other
      framework_shim.order <=> other.framework_shim.order
    elsif last_run_time.nil? && other.last_run_time.nil?
      other.size <=> size
    elsif last_run_time.nil?
      1
    elsif other.last_run_time.nil?
      -1
    else
      other.last_run_time <=> last_run_time
    end
  end

  def new_run_time
    received_at - sent_at if received_at && sent_at
  end

  def update_last_run_time
    self.last_run_time = new_run_time
  end

  def framework_shim
    Nitra::FrameworkShims::SHIMS[framework.to_sym]
  end
end
