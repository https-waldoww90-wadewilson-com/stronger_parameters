require 'stronger_parameters/constraints'

module StrongerParameters
  module ControllerSupport
    module PermittedParameters
      def self.included(klass)
        klass.extend ClassMethods
        method = (klass.respond_to?(:before_action) ? :before_action : :before_filter)
        klass.public_send method, :permit_parameters
      end

      def self.sugar(value)
        case value
        when Array
          ActionController::Parameters.array(*value.map { |v| sugar(v) })
        when Hash
          constraints = value.each_with_object({}) do |(key, v), memo|
            memo[key] = sugar(v)
          end
          ActionController::Parameters.map(constraints)
        else
          value
        end
      end

      DEFAULT_PERMITTED = {
        controller: ActionController::Parameters.anything,
        action: ActionController::Parameters.anything,
        format: ActionController::Parameters.anything,
        authenticity_token: ActionController::Parameters.string
      }

      module ClassMethods
        def self.extended(base)
          base.send :class_attribute, :log_unpermitted_parameters, instance_accessor: false
        end

        def log_unpermitted_parameters!
          self.log_unpermitted_parameters = true
        end

        def permitted_parameters(action, permitted)
          if permit_parameters[action] == :anything
            raise ArgumentError, "#{self}/#{action} can not add to :anything" if permitted != :anything
          elsif permitted == :anything
            permit_parameters[action] = permitted
          else
            action_permitted = (permit_parameters[action] ||= {})
            action_permitted.deep_merge!(permitted)
          end
        end

        def permitted_parameters_for(action)
          unless for_action = permit_parameters[action]
            location = instance_method(action).source_location
            raise KeyError, "Action #{action} for #{self} does not have any permitted parameters (#{location.join(":")})"
          end
          return :anything if for_action == :anything

          # TODO: we should be able to call sugar on the result of deep_merge, but it breaks tests
          permit_parameters[:all].deep_merge(for_action).
            each_with_object({}) { |(k, v), a| a[k] = PermittedParameters.sugar(v) }
        end

        private

        def permit_parameters
          @permit_parameters ||= if superclass.respond_to?(:permit_parameters, true)
            superclass.send(:permit_parameters).deep_dup
          else
            {all: DEFAULT_PERMITTED.deep_dup}
          end
        end
      end

      private

      def permit_parameters
        action = params[:action].to_sym
        permitted = self.class.permitted_parameters_for(action)

        if permitted == :anything
          Rails.logger.warn("#{params[:controller]}/#{params[:action]} does not filter parameters")
          return
        end

        # TODO: invalid values should also be logged, but atm only invalid keys are
        permitted_params = without_invalid_parameter_exceptions { params.permit(permitted) }
        unpermitted_keys = flat_keys(params) - flat_keys(permitted_params)
        log_unpermitted = self.class.log_unpermitted_parameters

        show_unpermitted_keys(unpermitted_keys, log_unpermitted)

        return if log_unpermitted

        params.replace(permitted_params)
        params.permit!
        request.params.replace(permitted_params)

        logged_params = request.send(:parameter_filter).filter(permitted_params) # Removing passwords, etc
        Rails.logger.info("  Filtered Parameters: #{logged_params.inspect}")
      end

      def show_unpermitted_keys(unpermitted_keys, log_unpermitted)
        return if unpermitted_keys.empty?

        log_prefix = (log_unpermitted ? 'Found' : 'Removed')
        message = "#{log_prefix} restricted keys #{unpermitted_keys.inspect} from parameters according to permitted list"

        header = Rails.configuration.stronger_parameters_violation_header if Rails.configuration.respond_to?(:stronger_parameters_violation_header)
        response.headers[header] = message if response && header

        Rails.logger.info("  #{message}")
      end

      def without_invalid_parameter_exceptions
        if self.class.log_unpermitted_parameters
          begin
            old = ActionController::Parameters.action_on_invalid_parameters
            ActionController::Parameters.action_on_invalid_parameters = :log
            yield
          ensure
            ActionController::Parameters.action_on_invalid_parameters = old
          end
        else
          yield
        end
      end

      def flat_keys(hash)
        hash.flat_map { |k, v| v.is_a?(Hash) ? flat_keys(v).map { |x| "#{k}.#{x}" }.push(k) : k }
      end
    end
  end
end