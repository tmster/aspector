module Aspector
  class Base

    def disabled?
      # Enabled by default
    end

    def apply target, options = {}
      default_options = self.class.default_options
      if default_options and not default_options.empty?
        options = default_options.merge(options)
      end
      Interception.new(self, target, options).apply
    end

  end
end

