class A

  def test
    puts 'test'
    raise
  end

end

##############################

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'aspector'

class RetryAspect < Aspector::Base

  target do
    def retry_this proxy, &block
      proxy.call &block
    rescue
      @retry_count ||= 3
      @retry_count -= 1

      if @retry_count == 0
        @retry_count = nil
        raise
      end

      retry
    end
  end

  around :retry_this

end

##############################

RetryAspect.apply A, :method => "test"

a = A.new
a.test

