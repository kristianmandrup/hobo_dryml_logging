module Hobo
  module Dryml
    class Taglib
      # include TraceCalls
      
      @cache = {}

      class << self
        # include TraceUtils

        def get(options)
          src_file = taglib_filename(options)
          taglib = @cache[src_file]
          if taglib
            log "reload"
            taglib.reload
          else
            bundle = options[:bundle] && Bundle.bundles[options[:bundle]]
            taglib = Taglib.new(src_file, bundle)
            log "created new taglib and cached it!"            
            @cache[src_file] = taglib
          end
          taglib
        end

        def clear_cache
          @cache = {}
        end

        private

        def taglib_filename(options)
          plugin = options[:plugin]
          str = ""
          str += " plugin=#{plugin}" if !plugin.blank?
          str += " bundle=#{options[:bundle]}" if !options[:bundle].blank?
          base = if plugin == "hobo"
                   "#{HOBO_ROOT}/taglibs"
                 elsif plugin
                   "#{RAILS_ROOT}/vendor/plugins/#{plugin}/taglibs"
                 elsif (bundle_name = options[:bundle])
                   bundle = Bundle.bundles[bundle_name] or raise ArgumentError, "No such bundle: #{options[:bundle]}"
                   "#{RAILS_ROOT}/vendor/plugins/#{bundle.plugin}/taglibs"
                 elsif options[:src] =~ /\//
                   "#{RAILS_ROOT}/app/views"
                 elsif options[:template_dir] =~ /^#{HOBO_ROOT}/
                   options[:template_dir]
                 else
                   "#{RAILS_ROOT}/#{options[:template_dir].gsub(/^\//, '')}" # remove leading / if there is one
                 end

          src = options[:src] || plugin
          filename = "#{base}/#{src}.dryml"
          raise DrymlException, "No such taglib: #{base} #{options.inspect} #{filename}" unless File.exists?(filename)
        end

      end

      def initialize(src_file, bundle)                
        @src_file = src_file
        @bundle = bundle
        load
      end

      def reload
        if File.mtime(@src_file) > @last_load_time
          log "file: #{@src_file} modified since last time. Requires reload"
          load
        else
          log "file: #{@src_file} not modified since last time. NO reload required"          
        end 
      end

      def load  
        @module = Module.new do

          @tag_attrs = {}
          @tag_aliases = []

          class << self

            def included(base)
              @tag_aliases.each do |tag, feature|
                if base.respond_to? :alias_method_chain_on_include
                  base.alias_method_chain_on_include tag, feature
                else
                  base.send(:alias_method_chain, tag, feature)
                end
              end
            end

            def _register_tag_attrs(tag, attrs)
              @tag_attrs[tag] = attrs
            end
            attr_reader :tag_attrs

            def alias_method_chain_on_include(tag, feature)
              @tag_aliases << [tag, feature]
            end

          end

        end
        template = Template.new(File.read(@src_file), @module, @src_file, @bundle)
        template.compile([], [])
        
        # template.set_context(@context) 
        @last_load_time = File.mtime(@src_file)
      end

      def import_into(class_or_module, as)
        if as
          # Define a method on class_or_module named whatever 'as'
          # is. The first time the method is called it creates and
          # returns an object that provides the taglib's tags as
          # methods. On subsequent calls the object is cached in an
          # instance variable "@_#{as}_taglib"

          taglib_module = @module
          ivar = "@_#{as}_taglib"
          class_or_module.send(:define_method, as) do
            instance_variable_get(ivar) or begin
                                             as_class = Class.new(TemplateEnvironment) { include taglib_module }
                                             as_object = as_class.new
                                             as_object.copy_instance_variables_from(self)
                                             instance_variable_set(ivar, as_object)
                                           end
          end
        else
          class_or_module.send(:include, @module)
          class_or_module.tag_attrs.update(@module.tag_attrs) if @module.respond_to?(:tag_attrs)
        end
      end

    end

  end

end
