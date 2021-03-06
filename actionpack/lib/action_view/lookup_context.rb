require 'active_support/core_ext/array/wrap'
require 'active_support/core_ext/object/blank'

module ActionView
  # LookupContext is the object responsible to hold all information required to lookup
  # templates, i.e. view paths and details. The LookupContext is also responsible to
  # generate a key, given to view paths, used in the resolver cache lookup. Since
  # this key is generated just once during the request, it speeds up all cache accesses.
  class LookupContext #:nodoc:
    mattr_accessor :fallbacks
    @@fallbacks = [FileSystemResolver.new(""), FileSystemResolver.new("/")]

    mattr_accessor :registered_details
    self.registered_details = []

    def self.register_detail(name, options = {}, &block)
      self.registered_details << name
      Accessors.send :define_method, :"_#{name}_defaults", &block
      Accessors.module_eval <<-METHOD, __FILE__, __LINE__ + 1
        def #{name}
          @details[:#{name}]
        end

        def #{name}=(value)
          value = Array.wrap(value.presence || _#{name}_defaults)
          @details_key = nil unless value == @details[:#{name}]
          # Always set the value to handle frozen arrays
          @details[:#{name}] = value
        end
      METHOD
    end

    # Holds accessors for the registered details.
    module Accessors #:nodoc:
    end

    register_detail(:formats) { Mime::SET.symbols }
    register_detail(:locale)  { [I18n.locale] }

    class DetailsKey #:nodoc:
      alias :eql? :equal?
      alias :object_hash :hash

      attr_reader :hash
      @details_keys = Hash.new

      def self.get(details)
        @details_keys[details] ||= new
      end

      def initialize
        @hash = object_hash
      end
    end

    def initialize(view_paths, details = {})
      @details, @details_key = { :handlers => default_handlers }, nil
      self.view_paths = view_paths
      self.update_details(details, true)
    end

    module ViewPaths
      attr_reader :view_paths

      # Whenever setting view paths, makes a copy so we can manipulate then in
      # instance objects as we wish.
      def view_paths=(paths)
        @view_paths = ActionView::Base.process_view_paths(paths)
      end

      def find(name, prefix = nil, partial = false)
        @view_paths.find(*args_for_lookup(name, prefix, partial))
      end
      alias :find_template :find

      def find_all(name, prefix = nil, partial = false)
        @view_paths.find_all(*args_for_lookup(name, prefix, partial))
      end

      def exists?(name, prefix = nil, partial = false)
        @view_paths.exists?(*args_for_lookup(name, prefix, partial))
      end
      alias :template_exists? :exists?

      # Add fallbacks to the view paths. Useful in cases you are rendering a :file.
      def with_fallbacks
        added_resolvers = 0
        self.class.fallbacks.each do |resolver|
          next if view_paths.include?(resolver)
          view_paths.push(resolver)
          added_resolvers += 1
        end
        yield
      ensure
        added_resolvers.times { view_paths.pop }
      end

    protected

      def args_for_lookup(name, prefix, partial) #:nodoc:
        name, prefix = normalize_name(name, prefix)
        [name, prefix, partial || false, @details, details_key]
      end

      # Support legacy foo.erb names even though we now ignore .erb
      # as well as incorrectly putting part of the path in the template
      # name instead of the prefix.
      def normalize_name(name, prefix) #:nodoc:
        name  = name.to_s.gsub(handlers_regexp, '')
        parts = name.split('/')
        return parts.pop, [prefix, *parts].compact.join("/")
      end

      def default_handlers #:nodoc:
        @detault_handlers ||= Template::Handlers.extensions
      end

      def handlers_regexp #:nodoc:
        @handlers_regexp ||= /\.(?:#{default_handlers.join('|')})$/
      end
    end

    module Details
      # Calculate the details key. Remove the handlers from calculation to improve performance
      # since the user cannot modify it explicitly.
      def details_key #:nodoc:
        @details_key ||= DetailsKey.get(@details)
      end

      # Overload formats= to reject [:"*/*"] values.
      def formats=(value)
        value = nil    if value == [:"*/*"]
        value << :html if value == [:js]
        super(value)
      end

      # Overload locale to return a symbol instead of array
      def locale
        @details[:locale].first
      end

      # Overload locale= to also set the I18n.locale. If the current I18n.config object responds
      # to i18n_config, it means that it's has a copy of the original I18n configuration and it's
      # acting as proxy, which we need to skip.
      def locale=(value)
        if value
          config = I18n.config.respond_to?(:i18n_config) ? I18n.config.i18n_config : I18n.config
          config.locale = value
        end
        super(I18n.locale)
      end

      # Update the details keys by merging the given hash into the current
      # details hash. If a block is given, the details are modified just during
      # the execution of the block and reverted to the previous value after.
      def update_details(new_details, force=false)
        old_details = @details.dup

        registered_details.each do |key|
          send(:"#{key}=", new_details[key]) if force || new_details.key?(key)
        end

        if block_given?
          begin
            yield
          ensure
            @details = old_details
          end
        end
      end
    end

    include Accessors
    include Details
    include ViewPaths
  end
end