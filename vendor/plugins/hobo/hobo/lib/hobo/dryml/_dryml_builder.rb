module Hobo::Dryml
  class DRYMLBuilder
    include Logging
    include SaveEnv

    def set_context(context)
      @context = context
    end

    def initialize(template)
      log "Hobo::Dryml::DRYMLBuilder.initialize(#{template})"
      @template = template
      @build_instructions = nil # set to [] on the first add_build_instruction
      @part_names = []
    end

    attr_reader :template

    def template_path
      template.template_path
    end


    def set_environment(environment)
      @environment = environment
    end


    def ready?(mtime, d=false)
      @build_instructions && @last_build_mtime && @last_build_mtime >= mtime
    end


    def start
      @part_names.clear
      @build_instructions = []
      log "Hobo::Dryml::DRYMLBuilder.start"
    end


    def add_build_instruction(type, params)
      log "Hobo::Dryml::DRYMLBuilder.add_build_instruction(#{type})"
      mparams = params.merge(:type => type)
      log_detail mparams.inspect      
      @build_instructions << mparams
    end


    def add_part(name, src, line_num)      
      raise DrymlException.new("duplicate part: #{name}", template_path, line_num) if name.in?(@part_names)
      log "Hobo::Dryml::DRYMLBuilder.add_part(#{name})"     
      log "line #: #{line_num}"
      log_detail "SRC:\n #{src}"       
      add_build_instruction(:def, :src => src, :line_num => line_num)
      @part_names << name
    end


    def <<(params)
      @build_instructions << params
    end


    def render_page_source(src, local_names)
      log "Hobo::Dryml::DRYMLBuilder.render_page_source : BEGIN"            
      locals = local_names.map{|l| "#{l} = __local_assigns__[:#{l}];"}.join(' ')

      res = ("def render_page(__page_this__, __local_assigns__); " + "#{locals} new_object_context(__page_this__) do " + src + "; output_buffer; end; end")
      
      log "Hobo::Dryml::DRYMLBuilder.render_page_source : END"                             
      res
    end


    def erb_process(erb_src, method_def=false)
      log "Hobo::Dryml::DRYMLBuilder.erb_process : BEGIN"                  
      trim_mode = ActionView::TemplateHandlers::ERB.erb_trim_mode
      log_detail erb_src
      erb = ERB.new(erb_src, nil, trim_mode, "output_buffer")
      src = erb.src[("output_buffer = '';").length..-("; output_buffer".length)]
      
      res = if method_def
        src.sub /^\s*def.*?\(.*?\)/, '\0 __in_erb_template=true; '
      else
        "__in_erb_template=true; " + src
      end
      log "Hobo::Dryml::DRYMLBuilder.erb_process : END"                        
      res
    end

    def build(local_names, auto_taglibs, src_mtime, template_path)
      log "DRYMLBuilder:: build - template:#{template_path} : BEGIN"
      log "import #{auto_taglibs.size} auto_taglibs" if auto_taglibs.size > 0
      auto_taglibs.each do |t| 
        log "import taglib: #{t}"
        import_taglib(t) 
      end

      log "BEFORE: Environment instance methods: #{@environment.instance_methods.size}" if @environment.instance_methods.size > 0
      total_src = ""
      tag_name = nil
      log "Executing #{@build_instructions.size} build_instructions..." if @build_instructions.size > 0
      @build_instructions._?.each do |instruction|
        name = instruction[:name]
        
        log "BUILD instruction: #{name}" if !name.blank?
        
        # log "- type : #{instruction[:type]}"
        # log "- src: #{instruction[:src]}"
        src = instruction[:src] || ""

        if src
          _match = /def\s(\S*?)\(/.match(src)
          if _match
            tag_name = _match[1]
          end
          total_src += "# =============================== \n"          
          total_src += "# DEF: #{tag_name}\n"          
          total_src += "# #{instruction[:type]}\n"
          total_src += "# =============================== \n"                    
          total_src += (src + "\n")
        end
                
        case instruction[:type]
        when :eval
          if instruction[:src].nil?
            log "Instruction SRC == nil !!!"
            next
          end
          
          @environment.class_eval(instruction[:src], template_path, instruction[:line_num])

        when :def
          if instruction[:src].nil?
            log "Instruction SRC == nil !!!"
            next
          end
          
          src = erb_process(instruction[:src], true)
          # log "DEF"
          # log "SRC:" + src
          @environment.class_eval(src, template_path, instruction[:line_num])

        when :render_page
          if instruction[:src].nil?
            log "Instruction SRC == nil !!!"
            next
          end

          method_src = render_page_source(erb_process(instruction[:src]), local_names)
          @environment.compiled_local_names = local_names
          @environment.class_eval(method_src, template_path, instruction[:line_num])

        when :include
          import_taglib(instruction)

        when :module
          import_module(name.constantize, instruction[:as])

        when :set_theme
          set_theme(name)

        when :alias_method
          @environment.send(:alias_method, instruction[:new], instruction[:old])

        else
          raise RuntimeError.new("DRYML: Unknown build instruction :#{instruction[:type]}, " +
                                 "building #{template_path}")
        end        
      end
      
      log "AFTER: Environment instance methods: #{@environment.instance_methods.size}" if @environment.instance_methods.size > 0
      # @environment.class_eval do
      #   class << self
      #     define_method :set_context do |context|
      #       @set_context = context
      #     end
      #   end 
      # end
      log "save_environment_file : #{tag_name} to #{template_path}"
      taglib = File.basename(template_path, '.dryml')
      log "#{taglib}"
      save_environment_file(tag_name, total_src, taglib)        
      log "BUILD: #{template_path} : END"                              
      @last_build_mtime = src_mtime      
    end


    def import_taglib(options)
      log "DRYMLBuilder:: import_taglib : BEGIN"
      res = if options[:module]
        import_module(options[:module].constantize, options[:as])
      else
        template_dir = File.dirname(template_path)
        options = options.merge(:template_dir => template_dir)

        # Pass on the current bundle, if there is one, to the sub-taglib
        options[:bundle] = template.bundle.name unless template.bundle.nil? || options[:bundle] || options[:plugin]

        taglib = Taglib.get(options)
        taglib.import_into(@environment, options[:as])
      end
      log "DRYMLBuilder:: import_taglib : END"      
      res
    end


    def import_module(mod, as=nil)
      raise NotImplementedError if as
      log "DRYMLBuilder:: import_module : BEGIN"                  
      res = @environment.send(:include, mod)
      log "DRYMLBuilder:: import_module : END"                        
      res
    end


    def set_theme(name)
      if Hobo.current_theme.nil? or Hobo.current_theme == name
        log "DRYMLBuilder:: set_theme(#{name}) : BEGIN "                    
        Hobo.current_theme = name
        path = "taglibs/themes/#{name}/#{name}"
        
        res = import_taglib(:src => path)
        log "DRYMLBuilder:: set_theme(#{name}) : END "                            
        res
      end
    end
  end
end

