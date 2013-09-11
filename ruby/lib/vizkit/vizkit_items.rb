require 'utilrb/qt/variant/from_ruby'
require 'utilrb/qt/mime_data/mime_data'
require 'orocos/uri'
require 'vizkit/context_menu'

module Vizkit
    class VizkitItem < Qt::StandardItem
        NormalBrush = Qt::Brush.new(Qt::black)
        ModifiedBrush = Qt::Brush.new(Qt::red)
        ErrorBrush = Qt::Brush.new(Qt::red)

        attr_reader :modified
        attr_reader :options

        def initialize(*args)
            super
            setEditable false
            @options ||= Hash.new
            @childs = Array.new
        end

        def collapse(propagated = false)
            each_child do |item|
                item.collapse(true)
            end
        end

        def expand(propagated = false)
            each_child do |item|
                item.expand(true)
            end
        end

        def modified?
            !!@modified
        end

        def each_child(columns = nil,&block)
            columns = Array(0..columnCount-1) unless columns
            columns = Array(columns)
            0.upto(rowCount-1) do |r|
                columns.each do |c|
                    ch = child(r,c)
                    block.call ch if ch
                end
            end
        end

        def enabled(value=true)
            setEnabled(value)
            each_child do |item|
                item.enabled(value)
            end
        end

        def context_menu(pos,parent_widget,items = [])
            items << self
            parent.context_menu(pos,parent_widget,items) if parent
        end

        def mime_data(items=[])
            items << self
            return parent.mime_data(items) if parent
            0
        end

        def modified!(value = true, items = [],update_parent = true)
            return if value == @modified
            @modified = value
            items << self
            if value
                setForeground(ModifiedBrush)
                parent.modified!(value,items,update_parent) if parent && update_parent
            else
                setForeground(NormalBrush)
                each_child do |item|
                    item.modified!(value,items,false)
                end
            end
            if column == 1
                i = index.sibling(row,0)
                if i.isValid
                    item = i.model.itemFromIndex i
                    item.modified!(value,items,update_parent)
                end
            end
        end

        def child?(text)
            each_child(0) do |item|
                return true if item.text == text
            end
            false
        end

        def appendRow(*args)
           #store childs otherwise they might get garbage collected
           @childs << args.flatten
           super
        end

        def from_variant(data,klass)
            if klass == Integer || klass == Fixnum
                data.to_i
            elsif klass == Float
                data.to_f
            elsif klass == String
                data.toString.to_s
            elsif klass == Time
                Time.at(data.toDateTime.toTime_t)
            elsif klass == Symbol
                data.toString.to_sym
            elsif klass == (FalseClass) || klass == (TrueClass)
                data.toBool
            else
                raise "cannot convert #{data.toString} to #{klass} - no conversion"
            end
        end
    end

    # Item which can be bind to a member variable of an object which 
    # have simple types as possible values
    class VizkitAccessorItem< VizkitItem
        def initialize(obj,variable_name)
            super()
            variable_name = variable_name.to_sym
            @obj = obj
            @getter = if @obj.respond_to?(variable_name)
                          @obj.method(variable_name)
                      else
                          raise ArgumentError,"no getter for #{variable_name} on obj #{obj}"
                      end
            name = "#{variable_name}=".to_sym
            @setter = if @obj.respond_to?(name)
                          setEditable true
                          @obj.method(name)
                      end
        end

        def data(role = Qt::UserRole+1)
            # workaround memeroy leak qt-ruby
            # the returned Qt::Variant is never be deleted
            @last_data.dispose if @last_data
            @last_data = if role == Qt::DisplayRole || role == Qt::EditRole
                             Qt::Variant.new @getter.call
                         else
                             super
                         end
        end

        def setData(data,role = Qt::UserRole+1)
            if role == Qt::EditRole && !data.isNull && @setter
                @setter.call(from_variant(data,@getter.call.class))
            else
                super
            end
        end
    end

    class VizkitAccessorsItem < VizkitItem
        def add_accessor_item(obj,*names)
            names.each do |name|
                item = VizkitItem.new(name.to_s)
                value = VizkitAccessorItem.new(obj,name)
                appendRow([item,value])
            end
        end
    end

    class TypelibItem < VizkitItem
        DIRECTLY_DISPLAYED_RUBY_TYPES = [String,Numeric,Symbol,Time,TrueClass,FalseClass]
        MAX_NUMBER_OF_CHILDS = 20
        attr_reader :typelib_val

        def initialize(typelib_val=nil,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:text => nil,:item_type => :label,:editable => false
            @typelib_val = nil
            @truncated = false
            setEditable false
            update typelib_val if typelib_val
        end

        def setData(data,role = Qt::UserRole+1)
            return super if role != Qt::EditRole || data.isNull
            item_val = @typelib_val.to_ruby
            val = from_variant data,item_val.class
            return false unless val != nil
            update(val)
            modified!
        end

        def direct_type?
            !!@direct_type
        end

        def truncated?
            @truncated
        end

        def data(role = Qt::UserRole+1)
            # workaround memeroy leak qt-ruby
            # the returned Qt::Variant is never be deleted
            @last_data.dispose if @last_data
            @last_data = if role == Qt::DisplayRole
                             val = if @options.has_key?(:text)
                                       @options[:text]
                                   elsif !@typelib_val
                                       "no data"
                                   elsif !@direct_type
                                       if modified?
                                           @typelib_val.class.name + " (modified)"
                                       elsif truncated?
                                           @typelib_val.class.name + " (truncated,size=#{@typelib_val.size})"
                                       else
                                           @typelib_val.class.name
                                       end
                                   else
                                       item_val = @typelib_val.to_ruby
                                       if item_val.is_a?(Float) || item_val.is_a?(Fixnum) ||
                                           item_val.is_a?(TrueClass) || item_val.is_a?(FalseClass)
                                           item_val
                                       elsif item_val.is_a? Time
                                           "#{item_val.strftime("%-d %b %Y %H:%M:%S")}.#{item_val.usec.to_s}"
                                       else
                                           item_val.to_s
                                       end
                                   end
                             begin
                                 Qt::Variant.new(val)
                             rescue Expetion => e
                                 setEditable(false)
                                 Qt::Variant.new(e.message)
                             end
                         elsif role == Qt::EditRole
                             val = if !@direct_type
                                       nil
                                   else
                                       item_val = @typelib_val.to_ruby
                                       if item_val.is_a?(Float) || item_val.is_a?(Fixnum) ||
                                           item_val.is_a?(TrueClass) || item_val.is_a?(FalseClass)
                                           item_val
                                       elsif item_val.is_a? Time
                                           Qt::DateTime.new(item_val)
                                       elsif item_val.is_a? Symbol
                                           #move current value to the front
                                           arr = @typelib_val.class.keys.keys
                                           arr.delete(item_val.to_s)
                                           arr.insert(0,item_val.to_s)
                                           arr
                                       else
                                           item_val.to_s
                                       end
                                   end
                             Qt::Variant.new(val)
                         else
                             super
                         end
        end

        def clear
            @childs.each do |items|
                items[0].clear
                items[1].clear
                removeRow(items[0].index.row)
            end
            @childs = []
            @typelib_val = nil
        end

        def update(data = nil)
            if !data.nil?
                if !@typelib_val.nil?
                    begin
                        Typelib.copy(@typelib_val,Typelib.from_ruby(data,@typelib_val.class))
                    rescue ArgumentError => e
                        Vizkit.error "error during copying #{@typelib_val.class.name}: #{e}"
                        Vizkit.log_nest(2) do
                            Vizkit.log_pp(:debug, e.backtrace)
                        end
                    end
                else
                    @typelib_val = data
                    rb_sample = @typelib_val.to_ruby
                    @direct_type = DIRECTLY_DISPLAYED_RUBY_TYPES.any? { |rt| rt === rb_sample }
                    if !@direct_type || @options[:item_type] == :label
                        setEditable false
                    else
                        setEditable @options[:editable]
                    end
                end
            end
            # this might be called by update after the child
            # was delete therefore just return here
            return unless @typelib_val

            rows = if @direct_type
                       0
                   elsif @typelib_val.class.respond_to? :fields
                       @typelib_val.class.fields.size
                   elsif @typelib_val.respond_to? :raw_get
                       r = @typelib_val.size
                       if r > MAX_NUMBER_OF_CHILDS
                           @truncated = true
                           MAX_NUMBER_OF_CHILDS
                       else
                           @truncated = false
                           r
                       end
                   else
                       0
                   end
            # we do not need to update the childs if the item is not a label
            # otherwise check all childs
            if @options[:item_type] != :label
                emitDataChanged
                return
            end

            # detect resizing
            if rows < @childs.size
                @childs[rows..-1].each do |items|
                   items[0].clear
                   items[1].clear
                   removeRow items[0].index.row
                end
                @childs = if rows < 1
                              []
                          else
                              @childs[0, rows]
                          end
            end

            0.upto(rows-1) do |row|
                field = if @typelib_val.class.respond_to? :fields
                            field = @typelib_val.class.fields[row]
                            field.first
                        else
                            row
                        end
                val = @typelib_val.raw_get(field)
                if row >= @childs.size
                    field_item = TypelibItem.new(val,:text => field.to_s,:editable => @options[:editable])
                    val_item = TypelibItem.new(val,:item_type => :value,:editable => @options[:editable])
                    appendRow [field_item,val_item]
                else
                    field_item,val_item = @childs[row]
                    if field_item.typelib_val.object_id != val.object_id
                        field_item.clear
                        val_item.clear
                        field_item.update val
                        val_item.update val
                    else
                        field_item.update
                        val_item.update
                    end
                end
            end
        end
    end

    class PortItem < TypelibItem
        attr_reader :port
        def initialize(port,options = Hash.new)
            options,other_options = Kernel.filter_options options,:item_type => :label,:full_name => false
            other_options[:item_type] = options[:item_type]
            if options[:item_type] == :label
                other_options[:text] = if options[:full_name]
                                           port.full_name
                                       else
                                           port.name
                                       end
            end
            @port = port
            super(nil,other_options)
        end
    end

    class PortsItem < VizkitItem
        attr_reader :task
        def initialize(task,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label
            @task = task
            setEditable false
            if @options[:item_type] == :label
                setText "Ports"
                task.on_port_reachable do |port_name|
                    next if child?(port_name)
                    port = task.port(port_name)
                    p = proc do
                        if port.reachable?
                            append_port(port)
                        else
                            Orocos::Async.event_loop.once 0.1,&p
                        end
                    end
                    p.call
                end
            end
        end

        def append_port(port)
            if port.input? 
                appendRow([InputPortItem.new(port),InputPortItem.new(port,:item_type => :value)])
            elsif port.output?
                appendRow([OutputPortItem.new(port),OutputPortItem.new(port,:item_type => :value)])
            else
                raise "Port #{port} is neither an input nor an output port"
            end
        end

        def context_menu(pos,parent_widget,items = [])
        end
    end

    class InputPortItem < PortItem
        def initialize(port,options = Hash.new)
            options[:editable] = true unless options.has_key?(:editable)
            options,other_options = Kernel.filter_options options,:accept => true
	    super(port,other_options)
            @options.merge! options
            @sent_sample = nil

            port.once_on_reachable do
                begin
                    update port.new_sample.zero!
                    @sent_sample = port.new_sample.zero!
                    setEditable @options[:editable] if @options[:item_type] != :label
                rescue Orocos::TypekitTypeNotFound
                    setForeground(ErrorBrush)
                    if @options[:item_type] != :label
                        @options[:text] = "No typekit for: #{port.type.name}"
                    end
                end
            end
        end

        def data(role = Qt::UserRole+1)
            if role == Qt::EditRole && !direct_type?
                # we have to use the one from the first row
                # the other one has a copy which was not changed
                i = index.sibling(row,0)
                if i.isValid
                    # workaround memeroy leak qt-ruby
                    # the returned Qt::Variant is never be deleted
                    @last_value.dispose if @last_value
                    @last_value = Qt::Variant.from_ruby i.model.itemFromIndex(i)
                else
                    super
                end
            else
                super
            end
        end

        def modified!(value = true, items = [],update_parent = false)
            return if value == @modified
            super(value,items,false)
            if !value
                update @sent_sample
            elsif direct_type?
                write
            end
            if column == 0 && !direct_type?
                i = index.sibling(row,1)
                if i.isValid
                    item = i.model.itemFromIndex i
                    item.modified!(value,items)
                end
            end
        end

        def write(&block)
            block ||= proc {}
            @port.write(typelib_val,&block)
            Typelib.copy(@sent_sample,Typelib.from_ruby(typelib_val,typelib_val.class))
            modified!(false)
        end
    end

    class InputPortsItem < PortsItem
        def initialize(task,options = Hash.new)
            super
            if @options[:item_type] == :label
                setText "InputPorts"
            end
        end

        def append_port(port)
            super if port.input?
        end
    end

    module PortItemUserInteraction
        def port_from_items(items = [])
            # do not show context menu if clicked on second column
            return if items.find{|i|i.column == 1}
            sub_path = items.reverse.map(&:text)
            #convert string to number if possible
            sub_path = sub_path.map do |s|
                if s.to_i.to_s == s
                    s.to_i
                else
                    s
                end
            end
            if !sub_path.empty?
                item = items.last
                port.sub_port(sub_path)
            else
                port
            end
        end

        def set_widget_title(widget, name)
            # It seems that #respond_to? is broken on QtRuby. try the different
            # methods one by one ...
            begin
                widget.window_title = "#{name} #{widget.window_title}"
            rescue NoMethodError
                begin
                    widget.setPluginName("#{name} #{widget.getPluginName}")
                rescue NoMethodError
                end
            end
        end

        def context_menu(pos,parent_widget,items = [])
            if port.output?
                port_temp = port_from_items items
                return unless port_temp
                widget_name = Vizkit::ContextMenu.widget_for(port_temp.type_name,parent_widget,pos)
                if widget_name
                    widget = Vizkit.display(port_temp, :widget => widget_name)
                    set_widget_title(widget, port_temp.full_name)
                    widget.setAttribute(Qt::WA_QuitOnClose, false) if widget.is_a? Qt::Widget
                end
            else
                widget_name = Vizkit::ContextMenu.control_widget_for(port.type_name,parent_widget,pos)
                if widget_name
                    widget = Vizkit.control port, :widget => widget_name
                end
            end
        end

        def mime_data(items=[])
            port_temp = port_from_items items
            return 0 unless port_temp
            val = Qt::MimeData.new
            val.setText URI::Orocos.from_port(port_temp).to_s if defined? URI::DEFAULT_PARSER
            val
        end
    end

    class OutputPortItem < PortItem
        include PortItemUserInteraction
        attr_reader :listener

        def initialize(port,options = Hash.new)
            super
            @listener = port.on_data do |data|
                # depending on the type we receive none typelip objects
                # therefore if have to initialize it with a new sample
                begin 
                    update port.new_sample.zero! unless typelib_val
                    update data
                rescue Orocos::NotFound
                end
            end
            @listener.stop
            @stop_propagated = false

            if @options[:item_type] != :label
                @error_listener = port.on_error do |error|
                    @options[:text] = error.to_s
                    emitDataChanged
                end
                @reachable_listener = port.on_reachable do
                    @options.delete :text
                    emitDataChanged
                end
            end
        end

        def collapse(propagated = false)
            if @listener.listening?
                @stop_propagated = propagated
                @listener.stop
            end
        end

        def expand(propagated = false)
            @listener.start if !propagated || @stop_propagated
        end

    end

    class OutputPortsItem < PortsItem
        def initialize(task,options = Hash.new)
            super
            if @options[:item_type] == :label
                setText "OutputPorts"
            end
        end

        def append_port(port)
            super if port.output?
        end
        def expand(propagated = false)
            each_child do |item|
                item.expand(propagated)
            end
        end
    end

    class PropertyItem < TypelibItem
        attr_reader :property
        attr_reader :listener

        def initialize(property,options = Hash.new)
            options[:item_type] ||= :label
            options[:editable] = true unless options.has_key?(:editable)
            options[:text] = property.name if options[:item_type] == :label
            options,other_options = Kernel.filter_options options,:accept => true
            super(nil,other_options)
            @options.merge! options

            @property = property
            @listener = @property.on_change do |data|
                # depending on the type we receive none typelip objects
                # therefore if have to initialize it with a new sample
                begin
                    unless typelib_val
                        update property.new_sample.zero!
                        setEditable @options[:editable] if @options[:item_type] != :label
                    end
                    update data if !modified?
                rescue Orocos::NotFound
                end
            end
            @listener.stop
            @stop_propagated = false

            if @options[:item_type] != :label
                @error_listener = property.on_error do |error|
                    @options[:text] = error.to_s
                    emitDataChanged
                end
                @reachable_listener = property.on_reachable do
                    @options.delete :text
                    emitDataChanged
                end
            end
        end

        def collapse(propagated = false)
            if @listener.listening?
                @stop_propagated = propagated 
                @listener.stop
            end
        end

        def expand(propagated = false)
            @listener.start if !propagated || @stop_propagated
        end

        def context_menu(pos,parent_widget,items = [])
        end

        def data(role = Qt::UserRole+1)
            if role == Qt::EditRole && !direct_type?
                # we have to use the one from the first row
                # the other one has a copy which was not changed
                i = index.sibling(row,0)
                if i.isValid
                    # workaround memeroy leak qt-ruby
                    # the returned Qt::Variant is never be deleted
                    @last_value.dispose if @last_value
                    @last_value = Qt::Variant.from_ruby i.model.itemFromIndex(i)
                else
                    super
                end
            else
                super
            end
        end

        def modified!(value = true, items = [],update_parent = false)
            return if value == @modified
            super(value,items,false)
            if !value
                update @property.read
            elsif direct_type?
                write
            end
            if column == 0 && !direct_type?
                i = index.sibling(row,1)
                if i.isValid
                    item = i.model.itemFromIndex i
                    item.modified!(value,items)
                end
            end
        end

        def write(&block)
            begin
                @property.write(typelib_val,&block)
                modified!(false)
            rescue Orocos::NotFound
            end
        end
    end


    class PropertiesItem < VizkitItem
        attr_reader :task

        def initialize(task,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label,:editable => true
            @task = task
            setEditable false
            if @options[:item_type] == :label
                setText "Properties"
                task.on_property_reachable do |property_name|
                    next if child?(property_name)
                    prop = task.property(property_name)
                    prop.once_on_reachable do
                        appendRow [PropertyItem.new(prop,@options),PropertyItem.new(prop,:item_type => :value,:editable => @options[:editable])]
                    end
                end
            end
        end

        def context_menu(pos,parent_widget,items = [])
        end

        def data(role = Qt::UserRole+1)
            # workaround memeroy leak qt-ruby
            # the returned Qt::Variant is never be deleted
            @last_value.dispose if @last_value
            @last_value = if role == Qt::EditRole
                              i = index.sibling(row,0)
                              if i.isValid
                                  item = i.model.itemFromIndex i
                                  Qt::Variant.from_ruby item
                              else
                                  super
                              end
                          else
                              super
                          end
        end

        def expand(propagated = false)
            each_child do |item|
                item.expand(propagated)
            end
        end

        def write(&block)
            0.upto(rowCount-1) do |i|
                child(i,0).write(&block)
            end
        end
    end

    class TaskContextItem < VizkitItem
        attr_reader :task

        def initialize(task,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label,:basename => false
         
            @task = task
            if @options[:item_type] == :label
                if @options[:basename]
                    setText task.basename
                else
                    setText task.name
                end
                @input_ports = InputPortsItem.new(task)
                @input_ports2 = InputPortsItem.new(task,:item_type => :value)
                @output_ports = OutputPortsItem.new(task)
                @output_ports2 = OutputPortsItem.new(task,:item_type => :value)
                @properties = PropertiesItem.new(task)
                @properties2 = PropertiesItem.new(task,:item_type => :value)
                @properties2.setEditable true

                appendRow [@input_ports,@input_ports2]
                appendRow [@output_ports,@output_ports2]
                appendRow [@properties,@properties2]

                task.on_unreachable do
                    enabled false
                end
                task.on_reachable do
                    enabled true
                end
            else #just display the statues of the task
                task.on_state_change do |state|
                    setText state.to_s
                end
                task.on_unreachable do
                    setText "UNREACHABLE"
                    enabled false
                end
                task.on_reachable do
                    setText "INITIALIZING"
                    enabled true
                end
            end
        end

        def context_menu(pos,parent_widget,items = [])
            if task.respond_to? :current_state
                ContextMenu.task(task,parent_widget,pos)
                true
            end
        end
    end

    class NameServiceItem < VizkitItem
        def initialize(name_service,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label
            if @options[:item_type] == :label
                setText name_service.name
                name_service.on_task_added do |task_name|
                    task = name_service.proxy task_name
                    next if child?(task.basename)
                    appendRow([TaskContextItem.new(task,:basename => true),TaskContextItem.new(task,:item_type => :value)])
                end
            else
                name_service.on_error do |error|
                    setText error.to_s
                end
                name_service.on_reachable do
                    setText "reachable"
                end
            end
        end
    end

    class LogAnnotationItem < VizkitItem
        attr_reader :annotation
        def initialize(annotation,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label
            @annotation = annotation
            if @options[:item_type] == :label
                setText annotation.stream.name
                appendRow [VizkitItem.new("Samples"),VizkitItem.new(annotation.samples.size.to_s)]
            else
                setText annotation.stream.type_name
            end
        end

        def context_menu(pos,parent_widget,items = [])
            widget_name = Vizkit::ContextMenu.widget_for(Orocos::Log::Annotations,parent_widget,pos)
            if widget_name
                widget = Vizkit.default_loader.create_plugin(widget_name)
                fct = widget.plugin_spec.find_callback!(:argument => Orocos::Log::Annotations,:callback_type => :display)
                fct = fct.bind(widget)
                fct.call(annotation)
                widget.setAttribute(Qt::WA_QuitOnClose, false) if widget.is_a? Qt::Widget
                widget.show
            end
        end
    end

    class GlobalMetaItem < VizkitItem
        attr_reader :log_replay
        def initialize(log_replay,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label
            @log_replay = log_replay
            if @options[:item_type] == :label
                setText "- Global Meta Data -"
                log_replay.annotations.each do |annotation|
                    field = LogAnnotationItem.new annotation
                    value = LogAnnotationItem.new annotation,:item_type => :value
                    appendRow [field,value]
                end
            end
        end
    end

    class PortMetaDataItem < VizkitItem
        attr_reader :port
        def initialize(port,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label
            @port = port
            if @options[:item_type] == :label
                setText "Meta Data"
                port.metadata.each_pair do |key,value|
                    appendRow([VizkitItem.new(key.to_s),VizkitItem.new(value.to_s)])
                end
            end
        end
    end

    class LogOutputPortItem < VizkitItem
        include PortItemUserInteraction
        attr_reader :port

        def initialize(port,options = Hash.new)
            super()
            @options = Kernel.validate_options options,:item_type => :label
            @port = port
            setEnabled(port.number_of_samples > 0)
            if @options[:item_type] == :label
                setText port.name
                appendRow([VizkitItem.new("Samples"),VizkitItem.new(port.number_of_samples.to_s)])
                appendRow([VizkitItem.new("First Sample"),VizkitItem.new(port.first_sample_pos.to_s)])
                appendRow([VizkitItem.new("Last Sample"),VizkitItem.new(port.last_sample_pos.to_s)])
                @meta = PortMetaDataItem.new port
                @meta2 = PortMetaDataItem.new port,:item_type => :value
                appendRow([@meta,@meta2])
            else
                setText port.type.name
                @error_listener = port.on_error do |error|
                    @options[:text] = error.to_s
                    emitDataChanged
                end
            end
        end

        def port_from_items(items = [])
            port.to_proxy()
        end
    end

    class LogOutputPortsItem < OutputPortsItem
        def append_port(port)
            if port.output?
                raise ArgumentError, "port #{port.name} is already added" if child?(port.name)
                appendRow([LogOutputPortItem.new(port),LogOutputPortItem.new(port,:item_type => :value)])
            else
                raise "Port #{port} is not an output port"
            end
        end
    end

    class LogTaskItem < VizkitItem
        def initialize(task,options = Hash.new)
            super()
            @task = task
            @options = Kernel.validate_options options,:item_type => :label
            if @options[:item_type] == :label
                setText task.name
                @props = PropertiesItem.new(task,:editable => false)
                @props2 = PropertiesItem.new(task,:item_type => :value,:editable => false)
                @ports = LogOutputPortsItem.new(task)
                @ports2 = LogOutputPortsItem.new(task,:item_type => :value)
                appendRow [@props,@props2]
                appendRow [@ports,@ports2]
            else
                setText task.file_path
            end
        end

        def context_menu(pos,parent_widget,items = [])
            ContextMenu.log_task(@task,parent_widget,pos)
        end
    end

    class ThreadPoolItem < VizkitAccessorsItem
        def initialize(thread_pool,options = Hash.new)
            @options = Kernel.validate_options options,:item_type => :label
            if @options[:item_type] == :label
                super "ThreadPool"
                add_accessor_item(thread_pool,:min,:max,:spawned,:waiting,:auto_trim)
            else
                super()
            end
        end
    end

    class EventLoopTimerItem < VizkitAccessorsItem
        def initialize(timer,options = Hash.new)
            @options = Kernel.validate_options options,:item_type => :label
            if @options[:item_type] == :label
                super(timer.doc)
                add_accessor_item(timer,:single_shot,:period)
            else
                super()
            end
        end
    end

    class EventLoopTimersItem < VizkitItem
        def initialize(event_loop,options = Hash.new)
            @options = Kernel.validate_options options,:item_type => :label

            if @options[:item_type] == :label
                super "Timers"
                @timers = Hash.new
                t = event_loop.every 1.0 do
                    timers_new = Hash.new
                    event_loop.timers.each do |timer|
                        next if timer.single_shot?
                        item = if @timers.has_key? timer
                                   @timers[timer]
                               else
                                   label = EventLoopTimerItem.new(timer)
                                   value = VizkitItem.new
                                   appendRow([label,value])
                                   label
                               end
                        timers_new[timer] = item
                    end
                    # remove old timers
                    @timers.each_pair do |timer,item|
                        if !timers_new.has_key? timer
                            removeRow item.index.row
                        end
                    end
                    @timers = timers_new
                end
                t.doc = "Debug Timer Refresh"
            else
                super()
            end
        end
    end

    class EventLoopItem < VizkitItem
        def initialize(event_loop,options = Hash.new)
            @options = Kernel.validate_options options,:item_type => :label

            if @options[:item_type] == :label
                super("EventLoop")
                appendRow([EventLoopTimersItem.new(event_loop),VizkitItem.new])
                appendRow([ThreadPoolItem.new(event_loop.thread_pool),VizkitItem.new])
            else
                super()
            end
        end
    end
    
    class SyskitActionItem < VizkitItem
            
        attr_reader :name
        attr_reader :action
        attr_reader :arguments
        
        # Mapping from action states to colors
        @@state_colors = {
            :model => Qt::Color.new("black"),
            :pending => Qt::Color.new("dodgerblue"),
            :planned => Qt::Color.new("dodgerblue"),
            :running => Qt::Color.new("limegreen"),
            :failed => Qt::Color.new("orangered"),
            :successful => Qt::Color.new("silver")
        }
        
        def initialize(action)
            Kernel.raise "Not an action or job." unless action.is_a? DummyRobyAction
            @action = action
            @base_name = @action.name
            @arguments = @action.arguments
            
            @name = generate_name(@base_name, arguments)
            
            super(@name)

            set_selectable(false)
            update_view
        end
        
        # Updates the item display. Checks for state change and updates color, tooltip, etc.
        def update_view
            set_foreground(Qt::Brush.new(@@state_colors[state]))
            set_tool_tip("State: #{state}")
        end
        
        # Creates string of base name and arguments
        def generate_name(base_name, arguments)
            
            name = "" << base_name
            name << " ("
            if arguments
                
                arguments.each do |key,value|
                    value ||= "nil"
                    name << key.to_s << " => \"" << value.to_s << "\", "
                end 
                name.rstrip! # remove whitespace at the end
                name.chop! if name.end_with?(",")   # remove last comma
            end
            name << ")"
            name
        end
        
        def state
            @action.state
        end
        
        #def data(role = Qt::UserRole + 1)
        #    case role
        #    when Qt::ForegroundRole
        #        return Qt::Brush.new(@state_colors[:pending])
        #    else
        #        #TODO choose suitable default value.
        #        #return Qt::Variant.new(@action.name)
        #        super.data(role)
        #    end
        #    
        #end
       
        # TODO rename
        def running?
            # Returns false if action has no state (e.g. if action is an action model, not a job)
            return @action.state != :model
        end

    end
end
