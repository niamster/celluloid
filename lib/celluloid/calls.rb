module Celluloid
  # Calls represent requests to an actor
  class Call
    attr_reader :method, :arguments, :block

    def initialize(method, arguments = [], block = nil)
      @method, @arguments = method, arguments
      if block
        if Celluloid.exclusive?
          # FIXME: nicer exception
          raise "Cannot execute blocks on sender in exclusive mode"
        end
        @block = BlockProxy.new(self, Celluloid.mailbox, block)
      else
        @block = nil
      end
    end

    def execute_block_on_receiver
      @block && @block.execution = :receiver
    end

    def dispatch(obj)
      check(obj)
      _block = @block && @block.to_proc
      obj.public_send(@method, *@arguments, &_block)
    end

    def check(obj)
      # NOTE: don't use respond_to? here
      begin
        meth = obj.method(@method)
      rescue NameError
        inspect_dump = begin
                         obj.inspect
                       rescue RuntimeError, NameError
                         simulated_inspect_dump(obj)
                       end
        raise NoMethodError, "undefined method `#{@method}' for #{inspect_dump}"
      end

      arity = meth.arity

      if arity >= 0
        raise ArgumentError, "wrong number of arguments (#{@arguments.size} for #{arity})" if @arguments.size != arity
      elsif arity < -1
        mandatory_args = -arity - 1
        raise ArgumentError, "wrong number of arguments (#{@arguments.size} for #{mandatory_args}+)" if arguments.size < mandatory_args
      end
    rescue => ex
      raise AbortError.new(ex)
    end

    def simulated_inspect_dump(obj)
      vars = obj.instance_variables.map do |var|
        begin
          "#{var}=#{obj.instance_variable_get(var).inspect}"
        rescue RuntimeError
        end
      end.compact.join(" ")
      "#<#{obj.class}:0x#{obj.object_id.to_s(16)} #{vars}>"
    end
  end

  # Synchronous calls wait for a response
  class SyncCall < Call
    attr_reader :sender, :task, :chain_id

    def initialize(sender, method, arguments = [], block = nil, task = Thread.current[:celluloid_task], chain_id = CallChain.current_id)
      super(method, arguments, block)

      @sender   = sender
      @task     = task
      @chain_id = chain_id || Celluloid.uuid
    end

    def dispatch(obj)
      CallChain.current_id = @chain_id
      result = super(obj)
      respond SuccessResponse.new(self.task, result)
    rescue Exception => ex
      # Exceptions that occur during synchronous calls are reraised in the
      # context of the sender
      respond ErrorResponse.new(self, ex)

      # Aborting indicates a protocol error on the part of the sender
      # It should crash the sender, but the exception isn't reraised
      # Otherwise, it's a bug in this actor and should be reraised
      raise unless ex.is_a?(AbortError)
    ensure
      CallChain.current_id = nil
    end

    def cleanup
      exception = DeadActorError.new("attempted to call a dead actor")
      respond ErrorResponse.new(self, exception)
    end

    def respond(message)
      @sender << message
    end

    def response
      Celluloid.suspend(:callwait, self)
    end

    def value
      response.value
    end

    def self.preceive(task)
      Proc.new do |msg|
        msg.respond_to?(:task) and msg.task == task
      end
    end

    def wait
      while true
        message = Celluloid.mailbox.receive &SyncCall.preceive(self.task)

        if message.is_a?(SystemEvent)
          Thread.current[:celluloid_actor].handle_system_event(message)
        else
          # FIXME: add check for receiver block execution
          if message.respond_to?(:value)
            # FIXME: disable block execution if on :sender and (exclusive or outside of task)
            # probably now in Call
            return message
          else
            message.dispatch
          end
        end
      end
    end
  end

  # Asynchronous calls don't wait for a response
  class AsyncCall < Call
    def dispatch(obj)
      CallChain.current_id = Celluloid.uuid
      super(obj)
    rescue AbortError => ex
      # Swallow aborted async calls, as they indicate the sender made a mistake
      Logger.debug("#{obj.class}: async call `#@method` aborted!\n#{Logger.format_exception(ex.cause)}")
    ensure
      CallChain.current_id = nil
    end
  end

  class BlockCall
    def initialize(block_proxy, sender, arguments, task = Thread.current[:celluloid_task])
      @block_proxy = block_proxy
      @sender = sender
      @arguments = arguments
      @task = task
    end
    attr_reader :task

    def call
      @block_proxy.call
    end

    def dispatch
      response = @block_proxy.block.call(*@arguments)
      @sender << BlockResponse.new(self, response)
    end
  end
end
