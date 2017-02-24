require_relative 'common'

module Stacks
  class Create < Mutations::Command
    include Common

    common_validations

    required do
      model :grid, class: Grid
      string :name, matches: /^(?!-)(\w|-)+$/ # do not allow "-" as a first character
    end

    def validate
      if self.grid.stacks.find_by(name: name)
        add_error(:name, :exists, "#{name} already exists")
        return
      end
      if self.services.size == 0
        add_error(:services, :empty, "stack does not specify any services")
        return
      end
      validate_expose
      validate_volumes
      validate_services
    end

    def validate_services
      sort_services(self.services).each do |s|
        service = s.dup
        validate_service_links(service)
        service[:grid] = self.grid
        outcome = GridServices::Create.validate(service)
        unless outcome.success?
          handle_service_outcome_errors(service[:name], outcome.errors.message, :validate)
        end
      end
    end

    def validate_volumes
      if self.volumes
        self.volumes.each do |volume|
          if volume['external']
            vol = Volume.where(name: volume['name'], grid: grid, stack: nil).first
            unless vol
              add_error(:volumes, :not_found, "External volume #{volume['name']} not found")
            end
          end
        end
      end
    end

    def execute
      attributes = self.inputs.clone
      grid = attributes.delete(:grid)
      stack = Stack.create(name: self.name, grid: grid)
      unless stack.save
        stack.errors.each do |key, message|
          add_error(key, :invalid, message)
        end
        return
      end

      if self.volumes
        # TODO Separate into own method
        attributes.delete(:volumes)
        self.volumes.each do |volume|
          if volume[:external]
            vol = Volume.where(name: volume['name'], grid: grid, stack: nil).first
            if vol
              stack.external_volumes.create!(volume: vol)
            end
          else
            outcome = Volumes::Create.run(grid: grid, stack: stack, **volume.symbolize_keys)
            unless outcome.success?
              outcome.errors.message.each do |key, msg|
                add_error(:volumes, :key, "Volume create failed for '#{volume[:name]}': #{msg}")
              end
            end
          end
        end
      end

      services = sort_services(attributes.delete(:services))
      attributes[:services] = services
      attributes[:stack_name] = attributes.delete(:stack)
      stack.stack_revisions.create!(attributes)

      create_services(stack, services)

      stack
    end

    # @param [Stack] stack
    # @param [Array<Hash>] services
    def create_services(stack, services)
      services.each do |s|
        service = s.dup
        service[:grid] = stack.grid
        service[:stack] = stack
        outcome = GridServices::Create.run(service)
        unless outcome.success?
          handle_service_outcome_errors(service[:name], outcome.errors.message, :create)
        end
      end
    end
  end
end
