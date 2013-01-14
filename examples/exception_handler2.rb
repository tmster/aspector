class A

  def self.test input
    puts input.upcase
  end

  def test input
    puts input.upcase
  end

end

##############################

require_relative '../lib/aspector'

class ExceptionHandler < Aspector::Base

  module ToBeIncluded
    def handle_exception proxy, *args, &block
      proxy.call *args, &block
    rescue => e
      puts "Rescued: #{e}"
    end
  end

  around :handle_exception

end

##############################

ExceptionHandler.apply A, :method => "test", :class_methods => true

A.test 'good'
A.test nil

ExceptionHandler.apply A, :method => "test"

a = A.new
a.test 'good'
a.test nil
