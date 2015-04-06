module Celluloid
  # Responses to calls
  class Response
    attr_reader :task, :value

    def initialize(task, value)
      @task, @value = task, value
    end

    def dispatch
      @task.resume self
    end
  end

  # Call completed successfully
  class SuccessResponse < Response; end

  # Call was aborted due to sender error
  class ErrorResponse < Response
    def value
      ex = super
      ex = ex.cause if ex.is_a? AbortError

      if ex.backtrace
        ex.backtrace << "(celluloid):0:in `remote procedure call'"
        ex.backtrace.concat(caller)
      end

      raise ex
    end
  end

  class BlockResponse
    def initialize(call, result)
      @call = call
      @result = result
    end

    def dispatch
      @call.task.resume(@result)
    end
  end
end
