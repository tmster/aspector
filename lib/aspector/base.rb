require 'erb'

module Aspector
  class Base

    attr :target
    attr :options

    def initialize target, options = {}
      @target = target

      default_options = self.class.default_options
      if default_options and not default_options.empty?
        @options = default_options.merge(options)
      else
        @options = options
      end

      @wrapped_methods = {}
    end

    def disabled?
      # Enabled by default
    end

    def logger
      return @logger if @logger

      @logger = Logging.get_logger(self)
      @logger.level = self.class.logger.level
      @logger
    end

    def advices
      self.class.advices
    end

    def apply
      include_extension_module
      invoke_deferred_logics
      define_methods_for_advice_blocks
      add_to_instances unless @options[:old_methods_only]
      apply_to_methods unless @options[:new_methods_only]
      add_method_hooks unless @options[:old_methods_only]
      # TODO: clear deferred logic results if they are not used in any advice
    end

    def apply_to_methods
      return if advices.empty?

      # If method/methods option is set and all are String or Symbol, apply to those only, instead of
      # iterating through all methods
      methods = [@options[:method] || @options[:methods]]
      methods.compact!
      methods.flatten!

      if not methods.empty? and methods.all?{|method| method.is_a? String or method.is_a? Symbol }
        methods.each do |method|
          apply_to_method(method.to_s)
        end

        return
      end

      context.public_instance_methods.each do |method|
        apply_to_method(method.to_s, :public)
      end

      context.protected_instance_methods.each do |method|
        apply_to_method(method.to_s, :protected)
      end

      if @options[:private_methods]
        context.private_instance_methods.each do |method|
          apply_to_method(method.to_s, :private)
        end
      end
    end

    def apply_to_method method, scope = nil
      filtered_advices = filter_advices advices, method
      return if filtered_advices.empty?

      logger.log Logging::DEBUG, 'apply-to-method', method

      scope ||=
          if context.private_instance_methods.include?(RUBY_VERSION.index('1.9') ? method.to_sym : method.to_s)
            :private
          elsif context.protected_instance_methods.include?(RUBY_VERSION.index('1.9') ? method.to_sym : method.to_s)
            :protected
          else
            :public
          end

      recreate_method method, filtered_advices, scope
    end

    private

    def include_extension_module
      if self.class.const_defined?(:ToBeIncluded)
        context.send(:include, self.class.const_get(:ToBeIncluded))
      end
    end

    def deferred_logic_results logic
      @deferred_logic_results[logic]
    end

    def get_wrapped_method_of method
      @wrapped_methods[method]
    end

    # context is where advices will be applied (i.e. where methods are modified), can be different from target
    def context
      return @target if @target.is_a?(Module) and not @options[:class_methods]

      class << @target
        self
      end
    end

    def invoke_deferred_logics
      return unless (logics = self.class.send :_deferred_logics_)

      logics.each do |logic|
        result = logic.apply context, self
        if advices.detect {|advice| advice.use_deferred_logic? logic }
          @deferred_logic_results ||= {}
          @deferred_logic_results[logic] = result
        end
      end
    end

    def define_methods_for_advice_blocks
      advices.each do |advice|
        next if advice.raw?
        next unless advice.advice_block
        context.send :define_method, advice.with_method, advice.advice_block
        context.send :private, advice.with_method
      end
    end

    def add_to_instances
      return if advices.empty?

      aspect_instances = context.instance_variable_get(:@aop_instances)
      unless aspect_instances
        aspect_instances = AspectInstances.new
        context.instance_variable_set(:@aop_instances, aspect_instances)
      end
      aspect_instances << self
    end

    def add_method_hooks
      return if advices.empty?

      if @options[:class_methods]
        return unless @target.is_a?(Module)

        eigen_class = class << @target; self; end
        orig_singleton_method_added = @target.method(:singleton_method_added)

        eigen_class.send :define_method, :singleton_method_added do |method|
          aop_singleton_method_added(method) do
            orig_singleton_method_added.call(method)
          end
        end
      else
        eigen_class = class << @target; self; end

        if @target.is_a? Module
          orig_method_added = @target.method(:method_added)
        else
          orig_method_added = eigen_class.method(:method_added)
        end

        eigen_class.send :define_method, :method_added do |method|
          aop_method_added(method) do
            orig_method_added.call(method)
          end
        end
      end
    end

    def filter_advices advices, method
      advices.select do |advice|
        advice.match?(method, self)
      end
    end

    def recreate_method method, advices, scope
      context.instance_variable_set(:@aop_creating_method, true)

      raw_advices = advices.select {|advice| advice.raw? }

      if raw_advices.size > 0
        raw_advices.each do |advice|
          if @target.is_a? Module and not @options[:class_methods]
            @target.class_exec method, self, &advice.advice_block
          else
            @target.instance_exec method, self, &advice.advice_block
          end
        end

        return if raw_advices.size == advices.size
      end

      begin
        @wrapped_methods[method] = context.instance_method(method)
      rescue
        # ignore undefined method error
        if @options[:old_methods_only]
          logger.log Logging::WARN, 'method-not-found', method
        end

        return
      end

      before_advices = advices.select {|advice| advice.before? }
      after_advices  = advices.select {|advice| advice.after?  }
      around_advices = advices.select {|advice| advice.around? }

      (around_advices.size - 1).downto(1) do |i|
        advice = around_advices[i]
        recreate_method_with_advices method, [], [], advice
      end

      recreate_method_with_advices method, before_advices, after_advices, around_advices.first, true

      context.send scope, method if scope != :public
    ensure
      context.send :remove_instance_variable, :@aop_creating_method
    end

    def recreate_method_with_advices method, before_advices, after_advices, around_advice, is_outermost = false
      aspect = self

      code = METHOD_TEMPLATE.result(binding)
      aspect.logger.log Logging::DEBUG, 'generate-code', method, code
      context.class_eval code, __FILE__, __LINE__ + 4
    end

    METHOD_TEMPLATE = ERB.new <<-CODE, nil, "%<>"

    orig_method = aspect.send :get_wrapped_method_of, '<%= method %>'
% if around_advice
    wrapped_method = instance_method(:<%= method %>)
% end

    define_method :<%= method %> do |*args, &block|
% if logger.visible?(Logging::TRACE)
      aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'enter-generated-method'
% end

      if aspect.disabled?
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'exit--generated-method'
% end
        return orig_method.bind(self).call(*args, &block)
      end

% if is_outermost
      result = catch(:returns) do
% end

% before_advices.each do |advice|
        # Before advice: <%= advice.name %>
%   if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'before-invoke-advice', '<%= advice.name %>'
% end
%   if advice.advice_code
        result = (<%= advice.advice_code %>)
%   else
        result = <%= advice.with_method %> <%
          if advice.options[:aspect_arg] %>aspect, <% end %><%
          if advice.options[:method_arg] %>'<%= method %>', <% end
          %>*args
%   end
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'after--invoke-advice', '<%= advice.name %>'
% end
%   if advice.options[:skip_if_false]
        unless result
% if logger.visible?(Logging::TRACE)
          aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'exit-method-due-to-before-filter', '<%= advice.name %>'
% end
          return
        end
%   end
% end

% if around_advice
        # Around advice: <%= around_advice.name %>
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'before-invoke-advice', '<%= around_advice.name %>'
% end
%   if around_advice.advice_code
        result = (<%= around_advice.advice_code.gsub('INVOKE_PROXY', 'wrapped_method.bind(self).call(*args, &block)') %>)

%   else
% if logger.visible?(Logging::TRACE)
        proxy = lambda do |*args, &block|
          aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'before-invoke-proxy'
          res = wrapped_method.bind(self).call *args, &block
          aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'after--invoke-proxy'
          res
        end
        result = <%= around_advice.with_method %> <%
          if around_advice.options[:aspect_arg] %>aspect, <% end %><%
          if around_advice.options[:method_arg] %>'<%= method %>', <% end
          %>proxy, *args, &block
% else
        result = <%= around_advice.with_method %> <%
          if around_advice.options[:aspect_arg] %>aspect, <% end %><%
          if around_advice.options[:method_arg] %>'<%= method %>', <% end
          %>wrapped_method.bind(self), *args, &block
% end
%   end
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'after--invoke-advice', '<%= around_advice.name %>'
% end

% else

        # Invoke original method
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'before-wrapped-method'
% end
        result = orig_method.bind(self).call *args, &block
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'after--wrapped-method'
% end

% end

% unless after_advices.empty?
%   after_advices.each do |advice|
        # After advice: <%= advice.name %>
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'before-invoke-advice', '<%= advice.name %>'
% end
%  if advice.advice_code
        result = (<%= advice.advice_code %>)
%   else
%     if advice.options[:result_arg]
        result = <%= advice.with_method %> <%
          if advice.options[:aspect_arg] %>aspect, <% end %><%
          if advice.options[:method_arg] %>'<%= method %>', <% end %><%
          if advice.options[:result_arg] %>result, <% end
          %>*args
%     else
        <%= advice.with_method %> <%
          if advice.options[:aspect_arg] %>aspect, <% end %><%
          if advice.options[:method_arg] %>'<%= method %>', <% end
          %>*args
%     end
%   end
% if logger.visible?(Logging::TRACE)
        aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'after--invoke-advice', '<%= advice.name %>'
% end
%   end
% end

% if is_outermost
        result

      end # end of catch
% end

% if logger.visible?(Logging::TRACE)
      aspect.logger.log <%= Logging::TRACE %>, '<%= method %>', 'exit--generated-method'
% end
      result
    end
    CODE

  end
end

