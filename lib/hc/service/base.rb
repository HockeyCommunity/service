# frozen_string_literal: true

module Hc
  module Service

    # Used for abstraction and clarity of service objects
    #
    class Base

      require 'active_model'
      include ActiveModel::Validations
      include ActiveModel::Callbacks

      attr_accessor :result, :manual_status_code

      # Set instance variables based on arg smearing
      #
      def initialize(args)
        args.each do |k, v|
          instance_variable_set("@#{k}", v)
        end
      end

      # Abstraction for getting a stable service code
      #
      def status_code
        return manual_status_code if manual_status_code
        return 422 if errors.present?
        return 200 if result
        return 400
      end

      def raise_error!(field, message, code = 0)
        errors.add(field, message)
        self.manual_status_code = code
        raise ActiveRecord::Rollback
      end

      def raise_errors!(child_errors)
        Array.wrap(child_errors).each do |error|
          error.messages.each_key do |field|
            error.messages[field].each do |message|
              errors.add(field, message)
            end
          end
        end
        raise ActiveRecord::Rollback
      end

      def unauthorized!
        errors.add(:user, 'Unauthorized')
        self.manual_status_code = 401
        raise ActiveRecord::Rollback
      end

      def present(object, method: nil, options: {})
        Hc::Presenter.present(object, method: method, options: options)
      end

      def errors?
        errors.count.positive?
      end

      def enqueue_job(job_class:, params:, current_user:)
        Hc::Jobs.enqueue(job_class: job_class, user: current_user, params: params)
      end

      # Abstracted execution instanciates class, sets variables, runs validations, and handles errors
      #
      def self.execute(args)

        # Build the new service
        #
        service = new(args)

        # Service executions should be wrapped in a transaction, and gracefully handle errors
        #
        exception = nil
        ActiveRecord::Base.transaction do

          # Validate service args
          #
          service.try(:before_validation)
          return service unless service.valid?

          # Attempt execution of service
          #
          begin
            service.execute
          rescue ActiveRecord::RecordInvalid => ex
            if service.errors.blank?
              service.errors.add(:validation, ex.record.errors)
              service.manual_status_code = 422
            end
            raise ActiveRecord::Rollback
          rescue ActiveRecord::Rollback => ex
            raise ex
          rescue StandardError => ex
            exception = ex
            Rails.logger.debug '================================='
            Rails.logger.debug ex.inspect
            Rails.logger.debug ex.backtrace.join("\n")
            Rails.logger.debug '================================='
            if service.errors.blank?
              service.errors.add(:exception, 'An error occurred')
              service.manual_status_code = 500
            end
            raise ActiveRecord::Rollback
          end
        end

        raise exception if exception
        return service

      end

    end

  end
end
