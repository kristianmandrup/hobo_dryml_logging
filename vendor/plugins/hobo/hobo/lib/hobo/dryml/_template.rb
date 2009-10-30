require 'rexml/document'
require 'pathname'

module Hobo::Dryml

  class Template
    include Logging
    include SaveErb
    
    DRYML_ERB_DEBUG_TO_FILE = true

    DRYML_NAME = "[a-zA-Z\-][a-zA-Z0-9\-]*"
    DRYML_NAME_RX = /^#{DRYML_NAME}$/

    RUBY_NAME = "[a-zA-Z_][a-zA-Z0-9_]*"
    RUBY_NAME_RX = /^#{RUBY_NAME}$/

    CODE_ATTRIBUTE_CHAR = "&"

    NO_METADATA_TAGS = %w(doctype if else unless repeat do with name type-name)

    SPECIAL_ATTRIBUTES = %w(param merge merge-params merge-attrs
                            for-type
                            if unless repeat
                            part part-locals
                            restore)

    VALID_PARAMETER_TAG_ATTRIBUTES = %w(param replace)

    @build_cache = {}

    class << self
      attr_reader :build_cache

      def clear_build_cache
        @build_cache.clear()
      end
    end

    def initialize(src, environment, template_path, bundle=nil)
      log "Hobo::Dryml::Template.initialize : BEGIN"
      @src = src
      @environment = environment # a class or a module
      @template_path = template_path.sub(%r(^#{Regexp.escape(RAILS_ROOT)}/), "")
      @bundle = bundle

      cached_builder = Template.build_cache[@template_path]
      
      if cached_builder
        log "using cached Template builder"
        @builder = cached_builder
      else    
        log "creating new Template builder"        
        @builder = DRYMLBuilder.new(self)      
      end
      
      @builder.set_environment(environment)

      # @context = []
      # @builder.set_context(@context)
      log "Hobo::Dryml::Template.initialize : END"
      @last_element = nil
    end

    attr_reader :tags, :template_path, :bundle

    def compile(local_names=[], auto_taglibs=[])
      now = Time.now
      log "Template::Compile : BEGIN"
      
      unless @template_path.ends_with?(EMPTY_PAGE)
        p = Pathname.new template_path
        p = Pathname.new(RAILS_ROOT) + p unless p.absolute?
        mtime = p.mtime
      
        if !@builder.ready?(mtime)
          @builder.start
          parsed = true
          # parse the DRYML file creating a list of build instructions
          if is_taglib?
            process_src
          else
            create_render_page_method
          end

          # store build instructions in the cache
          Template.build_cache[@template_path] = @builder
        end
      end
      
      log "Build template with #{@builder.class}"   
      # compile the build instructions
      @builder.build(local_names, auto_taglibs, mtime, template_path)
      log "Template::Compile : END"
      
      logger.info("  DRYML: Compiled #{template_path} in %.2fs" % (Time.now - now)) if parsed
    end


    def create_render_page_method
      erb_src = process_src

      @builder.add_build_instruction(:render_page, :src => erb_src, :line_num => 1)
    end


    def is_taglib?
      @environment.class == Module
    end

    # process taglib src
    def process_src
      log "Template::proces_src : BEGIN"
      log "processing taglib #{@template_path}"
      @doc = Hobo::Dryml::Parser::Document.new(@src, @template_path)
      result = children_to_erb(@doc.root)
      res = if DRYML_ERB_DEBUG_TO_FILE
        save_erb_file(restore_erb_scriptlets(result))
      else
        restore_erb_scriptlets(result)
      end
      log "Template::proces_src : END"   
      res   
    end
    
    def restore_erb_scriptlets(src)
      @doc.restore_erb_scriptlets(src)
    end


    def children_to_erb(nodes)
      log "Template::children_to_erb : BEGIN"      
      erb_res = nodes.map do |x| 
        node_to_erb(x) 
      end
      tres = erb_res.join
      log "Template::children_to_erb : END"      
      tres
    end


    def node_to_erb(node)
      log "Template::node_to_erb : BEGIN"
      case node

      # v important this comes before REXML::Text, as REXML::CData < REXML::Text
      when REXML::CData
        REXML::CData::START + node.to_s + REXML::CData::STOP

      when REXML::Comment
        REXML::Comment::START + node.to_s + REXML::Comment::STOP

      when REXML::Text
        strip_suppressed_whiteaspace(node.to_s)

      when REXML::Element
        res = element_to_erb(node)
        # log res        
        res
      end
      #log "Template::node_to_erb : END"      
      # tres
    end


    def strip_suppressed_whiteaspace(s)
      s # s.gsub(/ -(\s*\n\s*)/, '<% \1 %>')
    end


    def element_to_erb(el)
      log "Template::element_to_erb : BEGIN"
      dryml_exception("old-style parameter tag (<#{el.name}>)", el) if el.name.starts_with?(":")

      @last_element = el
      case el.dryml_name

      when "include"
        include_element(el)
        # return just the newlines to keep line-number matching - the
        # include has no presence in the erb source
        tag_newlines(el)

      when "set-theme"
        require_attribute(el, "name", /^#{DRYML_NAME}$/)
        @builder.add_build_instruction(:set_theme, :name => el.attributes['name'])

        # return nothing - set_theme has no presence in the erb source
        tag_newlines(el)

      when "def"
        def_element(el)

      when "extend"
        extend_element(el)

      when "set"
        set_element(el)

      when "set-scoped"
        set_scoped_element(el)

      when "param-content"
        param_content_element(el)

      else
        if el.dryml_name.not_in?(Hobo.static_tags) || el.attributes['param'] || el.attributes['restore']
          tag_call(el)
        else
          static_element_to_erb(el)
        end
      end
      # log res
      #log "Template::element_to_erb : END"      
      # res
    end


    def include_element(el)
      log "Template::include_element : BEGIN"      
      require_toplevel(el)
      require_attribute(el, "as", /^#{DRYML_NAME}$/, true)
      options = {}
      %w(src module plugin bundle as).each do |attr|
        options[attr.to_sym] = el.attributes[attr] if el.attributes[attr]
      end
      res = @builder.add_build_instruction(:include, options)
      log "Template::include_element : END"            
      res
    end


    def import_module(mod, as=nil)
      @builder.import_module(mod, as)
    end


    def set_element(el)
      assigns = el.attributes.map do |name, value|
        next if name.in?(SPECIAL_ATTRIBUTES)
        dryml_exception("invalid name in <set> (remember to use '-' rather than '_')", el) unless name =~ /^#{DRYML_NAME}(\.#{DRYML_NAME})*$/
        "#{ruby_name name} = #{attribute_to_ruby(value)}; "
      end.join
      code = apply_control_attributes("begin; #{assigns}; end", el)
      "<% #{code}#{tag_newlines(el)} %>"
    end


    def set_scoped_element(el)
      variables = el.attributes.map do |name, value|
        dryml_exception("invalid name in <set-scoped> (remember to use '-' rather than '_')", el) unless name =~ DRYML_NAME_RX
        ":#{ruby_name name} => #{attribute_to_ruby(value)} "
      end
      "<% scope.new_scope(#{variables * ', '}) { #{tag_newlines(el)} %>#{children_to_erb(el)}<% } %>"
    end


    def declared_attributes(def_element)
      attrspec = def_element.attributes["attrs"]
      attr_names = attrspec ? attrspec.split(/\s*,\s*/).map{ |n| n.underscore.to_sym } : []
      invalids = attr_names & ([:with, :field, :this] + SPECIAL_ATTRIBUTES.*.to_sym)
      dryml_exception("invalid attrs in def: #{invalids * ', '}", def_element) unless invalids.empty?
      attr_names
    end


    def ruby_name(dryml_name)
      dryml_name.gsub('-', '_')
    end


    def with_containing_tag_name(el)
      old = @containing_tag_name
      @containing_tag_name = el.dryml_name
      yield
      @containing_tag_name = old
    end


    def define_polymorphic_dispatcher(el, name)
      # FIXME: The new erb context ends up being set-up twice 
      log "Template::define_polymorphic_dispatcher : BEGIN"      
      src = %(
      def #{name}(attributes={}, parameters={})
        _tag_context(attributes) do
          attributes.delete :with
          attributes.delete :field
          call_polymorphic_tag('#{name}', attributes, parameters) { #{name}__base(attributes.except, parameters) }
        end
      end
      )
      res = @builder.add_build_instruction(:eval, :src => src, :line_num => element_line_num(el))
      log "Template::define_polymorphic_dispatcher : END"      
      res      
    end
    
    
    def extend_element(el)
      def_element(el, true)
    end
    
    
    def type_specific_suffix
      el = @def_element
      for_type = el.attributes['for']
      if for_type
        type_name = if defined?(HoboFields) && for_type =~ /^[a-z]/
                      # It's a symbolic type name - look up the Ruby type name
                      klass = HoboFields.to_class(for_type) or 
                        dryml_exception("No such type in polymorphic tag definition: '#{for_type}'", el)
                      klass.name
                    elsif for_type =~ /^_.*_$/
                      rename_class(for_type)
                    else
                      for_type
                    end.underscore.gsub('/', '__')
        "__for_#{type_name}"
      end
    end
        

    def def_element(el, extend_tag=false)
      log "Template::def_element : BEGIN"
      require_toplevel(el)
      require_attribute(el, "tag", DRYML_NAME_RX)
      require_attribute(el, "attrs", /^\s*#{DRYML_NAME}(\s*,\s*#{DRYML_NAME})*\s*$/, true)
      require_attribute(el, "alias-of", DRYML_NAME_RX, true)

      @def_element = el

      unsafe_name = el.attributes["tag"]
      name = Hobo::Dryml.unreserve(unsafe_name)
      
      log "Tag Name: #{name}"
      suffix = type_specific_suffix
      if suffix
        name        += suffix
        unsafe_name += suffix
      end
      
      if el.attributes['polymorphic']
        log "Polymorphic"
        %w(for alias-of).each do |attr|
          dryml_exception("def cannot have both 'polymorphic' and '#{attr}' attributes") if el.attributes[attr]
        end
        
        define_polymorphic_dispatcher(el, ruby_name(name))
        name        += "__base"
        unsafe_name += "__base"
      end

      alias_of = el.attributes['alias-of']
      dryml_exception("def with alias-of must be empty", el) if alias_of and el.size > 0

      alias_of and @builder.add_build_instruction(:alias_method,
                                                  :new => ruby_name(name).to_sym,
                                                  :old => ruby_name(Hobo::Dryml.unreserve(alias_of)).to_sym)

      empty = false
      res = if alias_of
              "<% #{tag_newlines(el)} %>"
            else
              src = tag_method(name, el, extend_tag) +
                "<% _register_tag_attrs(:#{ruby_name name}, #{declared_attributes(el).inspect.underscore}) %>"

              logger.debug(restore_erb_scriptlets(src)) if el.attributes["debug-source"]

              @builder.add_build_instruction(:def,
                                             :src => restore_erb_scriptlets(src),
                                             :line_num => element_line_num(el))
              # keep line numbers matching up
              empty = true              
              "<% #{"\n" * src.count("\n")} %>"
            end
      @def_element = nil
      "Template::def_element : END"
      res
    end

    def param_names_in_definition(el)
      REXML::XPath.match(el, ".//*[@param]").map do |e|
        name = get_param_name(e)
        dryml_exception("invalid param name: #{name.inspect}", e) unless
          is_code_attribute?(name) || name =~ RUBY_NAME_RX || name =~ /#\{/
        name.to_sym unless is_code_attribute?(name)
      end.compact
    end


    def tag_method(name, el, extend_tag=false)
      log "Template::tag_method - #{name} : BEGIN"      
      name = ruby_name name
      param_names = param_names_in_definition(el)
      
      if extend_tag
        @extend_key = 'a' + Digest::SHA1.hexdigest(el.to_s)[0..10]
        alias_statement = "; alias_method_chain_on_include :#{name}, :#{@extend_key}"
        name = "#{name}_with_#{@extend_key}"
        log "extends tag: #{name}"                      
      end
            
      res = "<% def #{name}(all_attributes={}, all_parameters={}); " +
        "parameters = Hobo::Dryml::TagParameters.new(all_parameters, #{param_names.inspect.underscore}); " +
        "all_parameters = Hobo::Dryml::TagParameters.new(all_parameters); " +
        tag_method_body(el) +
        "; end#{alias_statement} %>"
      @extend_key = nil
      
      log res 
      "Template::tag_method : END"                                 
      res
    end


    def tag_method_body(el)
      log "Template::tag_method_body : BEGIN"      
      attrs = declared_attributes(el)

      # A statement to assign values to local variables named after the tag's attrs
      # The trailing comma on `attributes` is supposed to be there!
      setup_locals = attrs.map{|a| "#{Hobo::Dryml.unreserve(a).underscore}, "}.join + "attributes, = " +
        "_tag_locals(all_attributes, #{attrs.inspect})"

      start = "_tag_context(all_attributes) do #{setup_locals}"

      res = "#{start} " +
        # reproduce any line breaks in the start-tag so that line numbers are preserved
        tag_newlines(el) + "%>" +
        wrap_tag_method_body_with_metadata(children_to_erb(el)) +
        "<% output_buffer; end"
        
      log res  
      log "Template::tag_method_body END"            
      res
    end


    def wrap_source_with_metadata(content, kind, name, *args)
      log "Template::wrap_source_with_metadata : BEGIN"            
      res = if (!include_source_metadata) || name.in?(NO_METADATA_TAGS)
        content
      else
        metadata = [kind, name] + args + [@template_path]
        "<!--[DRYML|#{metadata * '|'}[-->" + content + "<!--]DRYML]-->"
      end
      # log res
      log "Template::wrap_source_with_metadata : END"                  
      res
    end


    def wrap_tag_method_body_with_metadata(content)
      log "Template.wrap_tag_method_body_with_metadata : BEGIN"            
      name   = @def_element.attributes['tag']
      for_   = @def_element.attributes['for']
      name += " for #{for_}" if for_
      
      res = wrap_source_with_metadata(content, "def", name, element_line_num(@def_element))
      log "Template.wrap_tag_method_body_with_metadata : END"                  
      res
    end


    def wrap_tag_call_with_metadata(el, content)
      log "Template.wrap_tag_call_with_metadata : BEGIN"      
      name = el.expanded_name
      param = el.attributes['param']

      if param == "&true"
        name += " param"
      elsif param
        name += " param='#{param}'"
      end

      res = wrap_source_with_metadata(content, "call", name, element_line_num(el))
      log "Template.wrap_tag_call_with_metadata : END"            
      res
    end


    def param_content_local_name(name)
      "_#{ruby_name name}__default_content"
    end


    def param_content_element(name_or_el)
      log "Template.param_content_element : BEGIN"            
      name = if name_or_el.is_a?(String)
               name_or_el
             else
               el = name_or_el
               el.attributes['for'] || @containing_tag_name
             end
      local_name = param_content_local_name(name)
      res = "<%= #{local_name} && #{local_name}.call %>"
      
      log res
      log "Template.param_content_element : END"            
      res      
    end


    def part_element(el, content)
      require_attribute(el, "part", DRYML_NAME_RX)

      if contains_param?(el)
        delegated_part_element(el, content)
      else
        simple_part_element(el, content)
      end
    end


    def simple_part_element(el, content)
      part_name  = el.attributes['part']
      
      log "Template.simple_part_element [#{part_name}] : BEGIN"
      dom_id = el.attributes['id'] || part_name
      part_name = ruby_name(part_name)
      part_locals = el.attributes["part-locals"]

      part_src = "<% def #{part_name}_part(#{part_locals._?.gsub('@', '')}) #{tag_newlines(el)}; new_context do %>" +
        content +
        "<% end; end %>"
      @builder.add_part(part_name, restore_erb_scriptlets(part_src), element_line_num(el))

      newlines = "\n" * part_src.count("\n")
      args = [attribute_to_ruby(dom_id), ":#{part_name}", part_locals].compact
      
      res = "<%= call_part(#{args * ', '}) #{newlines} %>"      
      log "Template.simple_part_element [#{part_name}] : END"      
      res
    end


    def delegated_part_element(el, content)
      # TODO
    end


    def contains_param?(el)
      # TODO
      false
    end


    def part_delegate_tag_name(el)
      "#{@def_name}_#{el.attributes['part']}__part_delegate"
    end
    
    
    def current_def_name
      @def_element && @def_element.attributes['tag']
    end


    def get_param_name(el)
      param_name = el.attributes["param"]

      if param_name
        def_tag = find_ancestor(el) {|e| e.name == "def" || e.name == "extend" }
        dryml_exception("param is not allowed outside of tag definitions", el) if def_tag.nil?

        ruby_name(param_name == "&true" ? el.dryml_name : param_name)
      else
        nil
      end
    end
    
    
    def inside_def_for_type?
      @def_element && @def_element.attributes['for']
    end


    def call_name(el)
      dryml_exception("invalid tag name", el) unless el.dryml_name =~ /^#{DRYML_NAME}(\.#{DRYML_NAME})*$/

      log "Template::call_name : BEGIN"                  
            
      name = Hobo::Dryml.unreserve(ruby_name(el.dryml_name))
      res = if call_to_self_from_type_specific_def?(el)
        "#{name}__base"
      elsif old_tag_call?(el)
        name = name[4..-1] # remove 'old-' prefix
        name += type_specific_suffix if inside_def_for_type?
        "#{name}_without_#{@extend_key}"
      else
        name
      end
      log "Template::call_name : END"                        
      res
    end
    
    
    def old_tag_call?(el)
      @def_element && el.dryml_name == "old-#{current_def_name}"
    end


    def call_to_self_from_type_specific_def?(el)
      inside_def_for_type? && el.dryml_name == current_def_name &&!el.attributes['for-type']
    end
    

    def polymorphic_call_type(el)
      log "Template:: polymorphic_call_type : BEGIN"                  
      t = el.attributes['for-type']
      res = if t.nil?
        nil
      elsif t == "&true"
        'this_type'
      elsif t =~ /^[A-Z]/
        t
      elsif t =~ /^[a-z]/ && defined? HoboFields.to_class
        klass = HoboFields.to_class(t)
        klass.name
      elsif is_code_attribute?(t)
        t[1..-1]
      else
        dryml_exception("invalid for-type attribute", el)
      end
      log "Template:: polymorphic_call_type : END"                        
      res
    end


    def tag_call(el)
      name = call_name(el)
      log "Template::tag_call - #{name} : BEGIN"                  
      param_name = get_param_name(el)
      attributes = tag_attributes(el)
      newlines = tag_newlines(el)

      parameters = tag_newlines(el) + parameter_tags_hash(el)

      is_param_restore = el.attributes['restore']

      call = if param_name
               param_name = attribute_to_ruby(param_name, :symbolize => true)
               args = "#{attributes}, #{parameters}, all_parameters, #{param_name}"
               to_call = if is_param_restore
                           # The tag is available in a local variable
                           # holding a proc
                           param_restore_local_name(name)
                         elsif (call_type = polymorphic_call_type(el))
                           "find_polymorphic_tag(:#{ruby_name name}, #{call_type})"
                         else
                           ":#{ruby_name name}"
                         end
               "call_tag_parameter(#{to_call}, #{args})"
             else
               if is_param_restore
                 # The tag is a proc available in a local variable
                 "#{param_restore_local_name(name)}.call(#{attributes}, #{parameters})"
               elsif (call_type = polymorphic_call_type(el))
                 "send(find_polymorphic_tag(:#{ruby_name name}, #{call_type}), #{attributes}, #{parameters})"
               elsif attributes == "{}" && parameters == "{}"
                 if name =~ /^[A-Z]/
                   # it's a tag with a cap name - not a local
                   "#{ruby_name name}()"
                 else
                   # could be a tag or a local variable
                   "#{ruby_name name}.to_s"
                 end
               else
                 "#{ruby_name name}(#{attributes}, #{parameters})"
               end
             end


      log "call - #{call}"                  
      
      call = apply_control_attributes(call, el)
      # call = maybe_make_part_call(el, "<% concat(#{call}) %>")

      if has_context?
        call = maybe_make_part_call(el, "<% concat_erb(#{ctx_str} #{call}) %>")
      else
        call = maybe_make_part_call(el, "<% concat(#{call}) %>")
      end

      log "call before metadata - #{call}"
      
      res = wrap_tag_call_with_metadata(el, call)
      log "Template::tag_call - #{name} : END"       
      res
    end
    
    
    def merge_attribute(el)
      log "Template::merge_attribute : BEGIN"
            
      merge = el.attributes['merge']
      dryml_exception("merge cannot have a RHS", el) if merge && merge != "&true"
      res = merge
      log "Template::merge_attribute : END"
      res
    end


    def parameter_tags_hash(el, containing_tag_name=nil)
      log "Template::parameter_tags_hash : BEGIN"      
      call_type = nil

      metadata_name = containing_tag_name || el.expanded_name
      
      param_items = el.map do |node|
        case node
        when REXML::Text
          text = node.to_s
          unless text.blank?
            dryml_exception("mixed content and parameter tags", el) if call_type == :named_params
            call_type = :default_param_only
          end
          text
        when REXML::Element
          e = node
          is_parameter_tag = e.parameter_tag?

          # Make sure there isn't a mix of parameter tags and normal content
          case call_type
          when nil
            call_type = is_parameter_tag ? :named_params : :default_param_only
          when :named_params
            dryml_exception("mixed parameter tags and non-parameter tags (did you forget a ':'?)", el) unless is_parameter_tag
          when :default_param_only
            dryml_exception("mixed parameter tags and non-parameter tags (did you forget a ':'?)", el) if is_parameter_tag
          end

          if is_parameter_tag
            parameter_tag_hash_item(e, metadata_name) + ", "
          end
        end
      end.join

      if call_type == :default_param_only || (call_type.nil? && param_items.length > 0) || (el.children.empty? && el.has_end_tag?)
        with_containing_tag_name(el) do
          param_items = " :default => #{default_param_proc(el, containing_tag_name)}, "
        end
      end
      
      param_items.concat without_parameters(el)

      merge_params = el.attributes['merge-params'] || merge_attribute(el)
      res = if merge_params
        extra_params = if merge_params == "&true"
                         "parameters"
                       elsif is_code_attribute?(merge_params)
                         merge_params[1..-1]
                       else
                         merge_param_names = merge_params.split(/\s*,\s*/).*.gsub("-", "_")
                         "all_parameters & #{merge_param_names.inspect}"
                       end
        "merge_parameter_hashes({#{param_items}}, (#{extra_params}) || {})"
      else
        "{#{param_items}}"
      end
      
      # log res
      log "Template::parameter_tags_hash : END"            
      res            
    end
    
    
    def without_parameters(el)
      log "Template::without_parameters : BEGIN"            
      without_names = el.attributes.keys.map { |name| name =~ /^without-(.*)/ and $1 }.compact

      res = without_names.map { |name| ":#{ruby_name name}_replacement => proc {|__discard__| '' }, " }.join
      log "Template::without_parameters : END"                  
      res
    end


    def parameter_tag_hash_item(el, metadata_name)
      log "Template::parameter_tag_hash_item : BEGIN"                  
      name = el.name.dup
      res = if name.sub!(/^before-/, "")
        before_parameter_tag_hash_item(name, el, metadata_name)
      elsif name.sub!(/^after-/, "")
        after_parameter_tag_hash_item(name, el, metadata_name)
      elsif name.sub!(/^prepend-/, "")
        prepend_parameter_tag_hash_item(name, el, metadata_name)
      elsif name.sub!(/^append-/, "")
        append_parameter_tag_hash_item(name, el, metadata_name)
      else
        hash_key = ruby_name name
        hash_key += "_replacement" if el.attribute("replace")
        if (param_name = get_param_name(el))
          ":#{hash_key} => merge_tag_parameter(#{param_proc(el, metadata_name)}, all_parameters[:#{param_name}])"
        else
          ":#{hash_key} => #{param_proc(el, metadata_name)}"
        end
      end
      
      # log res
      log "Template::parameter_tag_hash_item : END"                        
      res      
    end

    def has_context?(context = @context)
      context && context.size > 0      
    end

    def ctx_str
      "" # has_context? ? "#{@context.inspect}," : "{},"
    end

    def before_parameter_tag_hash_item(name, el, metadata_name)
      log "Template::before_parameter_tag_hash_item - #{name} : BEGIN"                        
      param_name = get_param_name(el)
      dryml_exception("param declaration not allowed on 'before' parameters", el) if param_name
      # content = children_to_erb(el) + "<% concat(#{param_restore_local_name(name)}.call({}, {})) %>"      
      
      if has_context?
        content = children_to_erb(el) + "<% concat_erb(#{ctx_str} #{param_restore_local_name(name)}.call({}, {})) %>"
      else
        content = children_to_erb(el) + "<% concat(#{param_restore_local_name(name)}.call({}, {})) %>"
      end
      # return
      res = ":#{ruby_name name}_replacement => #{replace_parameter_proc(el, metadata_name, content)}"
      log res
      log "Template::before_parameter_tag_hash_item - #{name} : END"                              
      res      
    end


    def after_parameter_tag_hash_item(name, el, metadata_name)
      log "Template::after_parameter_tag_hash_item - #{name} : BEGIN"                              
      param_name = get_param_name(el)
      dryml_exception("param declaration not allowed on 'after' parameters", el) if param_name
      # content = "<% concat(#{param_restore_local_name(name)}.call({}, {})) %>" + children_to_erb(el)
      if has_context?
        content = "<% concat_erb(#{ctx_str} #{param_restore_local_name(name)}.call({}, {})) %>" + children_to_erb(el)
      else
        content = "<% concat(#{param_restore_local_name(name)}.call({}, {})) %>" + children_to_erb(el)
      end
        
      res = ":#{ruby_name name}_replacement => #{replace_parameter_proc(el, metadata_name, content)}"
      log res
      log "Template::after_parameter_tag_hash_item - #{name} : END"                                    
      res
    end


    def append_parameter_tag_hash_item(name, el, metadata_name)
      log "Template::append_parameter_tag_hash_item - #{name} : BEGIN"                                    
      res = ":#{ruby_name name} => proc { [{}, { :default => proc { |#{param_content_local_name(name)}| new_context { %>" +
        param_content_element(name) + children_to_erb(el) +
        "<% } } } ] }"
      log res
      log "Template::append_parameter_tag_hash_item - #{name} : END"                                          
      res
    end


    def prepend_parameter_tag_hash_item(name, el, metadata_name)
      log "Template::prepend_parameter_tag_hash_item - #{name} : BEGIN"                                          
      res = ":#{ruby_name name} => proc { [{}, { :default => proc { |#{param_content_local_name(name)}| new_context { %>" +
        children_to_erb(el) + param_content_element(name) +
        "<% } } } ] }"
      log res
      log "Template::prepend_parameter_tag_hash_item - #{name} : END"      
      res
    end


    def default_param_proc(el, containing_param_name=nil)
      log "Template::default_param_proc : BEGIN"                                                
      content = children_to_erb(el)
      content = wrap_source_with_metadata(content, "param", containing_param_name,
                                          element_line_num(el)) if containing_param_name
      res = "proc { |#{param_content_local_name(el.dryml_name)}| new_context { %>#{content}<% } #{tag_newlines(el)}}"
      log res
      log "Template::default_param_proc : END"      
      res
    end


    def param_restore_local_name(name)
      log "Template::default_param_proc : BEGIN"      
      res = "_#{ruby_name name}_restore"
      # log res
      log "Template::default_param_proc : END"            
      res
    end


    def wrap_replace_parameter(el, name)
      wrap_source_with_metadata(children_to_erb(el), "replace", name, element_line_num(el))
    end


    def param_proc(el, metadata_name_prefix)
      log "Template::param_proc : BEGIN"      
            
      metadata_name = "#{metadata_name_prefix}><#{el.name}"

      nl = tag_newlines(el)

      res = if (repl = el.attribute("replace"))
        log "attribute replace"
        dryml_exception("replace attribute must not have a value", el) if repl.has_rhs?
        dryml_exception("replace parameters must not have attributes", el) if el.attributes.length > 1

        replace_parameter_proc(el, metadata_name)
      else
        attributes = el.attributes.dup
        # Providing one of 'with' or 'field' but not the other should cancel out the other
        attributes[:with] = "&nil"  if attributes.key?(:field) && !attributes.key?(:with)
        attributes[:field] = "&nil" if !attributes.key?(:field) && attributes.key?(:with)
        attribute_items = attributes.map do |name, value|
          if name.in?(VALID_PARAMETER_TAG_ATTRIBUTES)
            # just ignore
          elsif name.in?(SPECIAL_ATTRIBUTES)
            dryml_exception("attribute '#{name}' is not allowed on parameter tags (<#{el.name}:>)", el)
          else
            ":#{ruby_name name} => #{attribute_to_ruby(value, el)}"
          end
        end.compact

        nested_parameters_hash = parameter_tags_hash(el, metadata_name)
        "proc { [{#{attribute_items * ', '}}, #{nested_parameters_hash}] #{nl}}"
      end
      log res
      log "Template::param_proc : END"              
      res
    end


    def replace_parameter_proc(el, metadata_name, content=nil)
      log "Template::replace_parameter_proc : BEGIN"      
      content ||= wrap_replace_parameter(el, metadata_name)
      param_name = el.dryml_name.sub(/^(before|after|append|prepend)-/, "")
      
      res = "proc { |#{param_restore_local_name(param_name)}| new_context { %>#{content}<% } #{tag_newlines(el)}}"
      log res
      log "Template::replace_parameter_proc : END"            
      res
    end


    def maybe_make_part_call(el, call)
      log "Template::maybe_make_part_call : BEGIN"            
      part_name = el.attributes['part']
      res = if part_name
        part_id = el.attributes['id'] || part_name
        "<div class='part-wrapper' id='<%= #{attribute_to_ruby part_id} %>'>#{part_element(el, call)}</div>"
      else
        call
      end
      
      log res
      log "Template::maybe_make_part_call : END"                  
      res
    end


    def field_shorthand_element?(el)
      el.expanded_name =~ /:./
    end


    def tag_attributes(el)
      log "Template::tag_attributes : BEGIN"                  
      attributes = el.attributes
      items = attributes.map do |n,v|
        dryml_exception("invalid attribute name '#{n}'", el) unless n =~ DRYML_NAME_RX

        next if n.in?(SPECIAL_ATTRIBUTES) || n =~ /^without-/
        next if el.attributes['part'] && n == 'id' # The id is rendered on the <div class="part-wrapper"> instead
        
        ":#{ruby_name n} => #{attribute_to_ruby(v)}"
      end.compact

      # if there's a ':' el.name is just the part after the ':'
      items << ":field => \"#{ruby_name el.name}\"" if field_shorthand_element?(el)

      hash = "{#{items.join(", ")}}"

      res = if merge_attribute(el)
        "merge_attrs(#{hash}, attributes)"
      elsif el.attributes['merge-attrs']
        merge_attrs = compile_merge_attrs(el)
        "merge_attrs(#{hash}, #{merge_attrs} || {})"
      else
        hash
      end
      log res
      log "Template::tag_attributes : END"                        
      res
    end
    
    
    def compile_merge_attrs(el)
      log "Template::compile_merge_attrs : BEGIN"      
      merge_attrs = el.attributes['merge-attrs']
      res = if merge_attrs == "&true"
        "attributes"
      elsif is_code_attribute?(merge_attrs)
        "(#{merge_attrs[1..-1]})"
      else
        merge_attr_names = merge_attrs.split(/\s*,\s*/).*.gsub("-", "_").*.to_sym
        "(all_attributes & #{merge_attr_names.inspect})"
      end
      log res
      log "Template::compile_merge_attrs : END"            
      res
    end
    

    def static_tag_to_method_call(el)
      log "Template::static_tag_to_method_call : BEGIN"            
      part = el.attributes["part"]
      attrs = el.attributes.map do |n, v|
        next if n.in? SPECIAL_ATTRIBUTES
        val = restore_erb_scriptlets(v).gsub('"', '\"').gsub(/<%=(.*?)%>/, '#{\1}')
        %('#{n}' => "#{val}")
      end.compact

      # If there's a part but no id, the id defaults to the part name
      if part && !el.attributes["id"]
        attrs << ":id => '#{part}'"
      end

      # Convert the attributes hash to a call to merge_attrs if
      # there's a merge-attrs attribute
      attrs = if el.attributes['merge-attrs']
                merge_attrs = compile_merge_attrs(el)
                "merge_attrs({#{attrs * ', '}}, #{merge_attrs} || {})"
              else
                "{" + attrs.join(', ') + "}"
              end

      res = if el.children.empty?
        dryml_exception("part attribute on empty static tag", el) if part

        "<%= " + apply_control_attributes("element(:#{el.name}, #{attrs}, nil, true, #{!el.has_end_tag?} #{tag_newlines(el)})", el) + " %>"
      else
        if part
          body = part_element(el, children_to_erb(el))
        else
          body = children_to_erb(el)
        end

        output_tag = "element(:#{el.name}, #{attrs}, new_context { %>#{body}<% })"
        # "<% concat(" + apply_control_attributes(output_tag, el) + ") %>"

        if has_context?
          "<% concat_erb(#{ctx_str} " + apply_control_attributes(output_tag, el) + ") %>"
        else
          "<% concat(" + apply_control_attributes(output_tag, el) + ") %>"
        end
      end
      
      log res
      log "Template::static_tag_to_method_call : END"                  
      res      
    end


    def static_element_to_erb(el)
      log "Template::static_element_to_erb : BEGIN"                  
      res = if promote_static_tag_to_method_call?(el)
        static_tag_to_method_call(el)
      else
        start_tag_src = el.start_tag_source.gsub(REXML::CData::START, "").gsub(REXML::CData::STOP, "")

        # Allow #{...} as an alternate to <%= ... %>
        start_tag_src.gsub!(/=\s*('.*?'|".*?")/) do |s|
          s.gsub(/#\{(.*?)\}/, '<%= \1 %>')
        end

        if el.has_end_tag?
          start_tag_src + children_to_erb(el) + "</#{el.name}>"
        else
          start_tag_src
        end
      end
      
      log_detail res
      log "Template::static_element_to_erb : END"                        
      res      
    end


    def promote_static_tag_to_method_call?(el)
      %w(part merge-attrs if unless repeat).any? {|x| el.attributes[x]}
    end


    def apply_control_attributes(expression, el)
      log "Template::apply_control_attributes : BEGIN"                        
      controls = %w(if unless repeat).map_hash { |x| el.attributes[x] }.compact

      dryml_exception("You can't have multiple control attributes on the same element", el) if
        controls.length > 1

      attr = controls.keys.first
      val = controls.values.first
      res = if val.nil?
        expression
      else
        control = if !el.attribute(attr).has_rhs?
                    "this"
                  elsif is_code_attribute?(val)
                    "#{val[1..-1]}"
                  else
                    val.gsub!('-', '_')
                    attr == "repeat" ? %("#{val}") : "this.#{val}"
                  end

        x = gensym
        case attr
        when "if"
          "(if !(#{control}).blank?; (#{x} = #{expression}; Hobo::Dryml.last_if = true; #{x}) " +
            "else (Hobo::Dryml.last_if = false; ''); end)"
        when "unless"
          "(if (#{control}).blank?; (#{x} = #{expression}; Hobo::Dryml.last_if = true; #{x}) " +
            "else (Hobo::Dryml.last_if = false; ''); end)"
        when "repeat"
          "repeat_attribute(#{control}) { #{expression} }"
        end
      end
      
      log_detail res
      log "Template::apply_control_attributes : END"                              
      res            
    end


    def attribute_to_ruby(*args)
      options = args.extract_options!
      attr, el = args

      dryml_exception('erb scriptlet not allowed in this attribute (use #{ ... } instead)', el) if
        attr.is_a?(String) && attr.index("[![HOBO-ERB")

      if options[:symbolize] && attr =~ /^[a-zA-Z_][^a-zA-Z0-9_]*[\?!]?/
        ":#{attr}"
      else
        res = if attr.nil?
                "nil"
              elsif is_code_attribute?(attr)
                "(#{attr[1..-1]})"
              else
                if attr !~ /"/
                  '"' + attr + '"'
                elsif attr !~ /'/
                  "'#{attr}'"
                else
                  dryml_exception("invalid quote(s) in attribute value")
                end
              end
        options[:symbolize] ? (res + ".to_sym") : res
      end
    end

    def find_ancestor(el)
      e = el.parent
      until e.is_a? REXML::Document
        return e if yield(e)
        e = e.parent
      end
      return nil
    end

    def require_toplevel(el, message=nil)
      message ||= "can only be at the top level"
      dryml_exception("<#{el.dryml_name}> #{message}", el) if el.parent != @doc.root
    end

    def require_attribute(el, name, rx=nil, optional=false)
      val = el.attributes[name]
      if val
        dryml_exception("invalid #{name}=\"#{val}\" attribute on <#{el.dryml_name}>", el) unless rx && val =~ rx
      else
        dryml_exception("missing #{name} attribute on <#{el.dryml_name}>", el) unless optional
      end
    end

    def dryml_exception(message, el=nil)
      el ||= @last_element
      raise DrymlException.new(message, template_path, element_line_num(el))
    end

    def element_line_num(el)
      @doc.element_line_num(el)
    end

    def tag_newlines(el)
      src = el.start_tag_source
      "\n" * src.count("\n")
    end

    def is_code_attribute?(attr_value)
      attr_value =~ /^\&/ && attr_value !~ /^\&\S+;/
    end

    def logger
      ActionController::Base.logger rescue nil
    end

    def gensym(name="__tmp")
      @gensym_counter ||= 0
      @gensym_counter += 1
      "#{name}_#{@gensym_counter}"
    end

    def rename_class(name)
      @bundle && name.starts_with?("_") ? @bundle.send(name) : name
    end

    def include_source_metadata
      # disabled for now -- we're still getting broken rendering with this feature on
      return false
      @include_source_metadata = RAILS_ENV == "development" && !ENV['DRYML_EDITOR'].blank? if @include_source_metadata.nil?
      @include_source_metadata
    end

  end

end
